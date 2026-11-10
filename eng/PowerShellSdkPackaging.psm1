Set-StrictMode -Version 3.0

function Get-PowerShellSdkSourceBuiltAssemblyDirectory {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string] $SourceRoot,

    [Parameter(Mandatory)]
    [string] $TargetFramework
  )

  $SourceRootPath = (Resolve-Path -LiteralPath $SourceRoot).Path
  $SourceDirectory = Join-Path $SourceRootPath 'src'
  if (-not (Test-Path -LiteralPath $SourceDirectory -PathType Container)) {
    throw "PowerShell source directory was not found: $SourceDirectory"
  }

  $ExpectedSuffix = [System.IO.Path]::Combine('bin', 'Release', $TargetFramework)
  $Directories = @(
    Get-ChildItem -LiteralPath $SourceDirectory -Recurse -Directory -Filter $TargetFramework |
      Where-Object {
        $RelativePath = $_.FullName.Substring($SourceRootPath.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
        $RelativePath.EndsWith($ExpectedSuffix, [System.StringComparison]::OrdinalIgnoreCase)
      } |
      Sort-Object FullName |
      ForEach-Object { $_.FullName }
  )

  return $Directories
}

function Get-PowerShellSdkSourceBuiltAssemblyName {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [AllowEmptyCollection()]
    [string[]] $Directory
  )

  $AssemblyNames = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($CandidateDirectory in $Directory) {
    if ([string]::IsNullOrWhiteSpace($CandidateDirectory) -or -not (Test-Path -LiteralPath $CandidateDirectory -PathType Container)) {
      continue
    }

    foreach ($Assembly in Get-ChildItem -LiteralPath $CandidateDirectory -File -Filter '*.dll') {
      if (-not $AssemblyNames.Contains($Assembly.BaseName)) {
        $AssemblyNames[$Assembly.BaseName] = $true
      }
    }
  }

  return @($AssemblyNames.Keys)
}

function Copy-PowerShellSdkSourceBuiltFile {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [AllowEmptyCollection()]
    [string[]] $AssemblyName,

    [Parameter(Mandatory)]
    [AllowEmptyCollection()]
    [string[]] $SourceDirectory,

    [Parameter(Mandatory)]
    [string] $DestinationDirectory,

    [string[]] $Extension = @('.dll', '.xml', '.config')
  )

  New-Item -Path $DestinationDirectory -ItemType Directory -Force | Out-Null

  foreach ($Name in @($AssemblyName | Sort-Object -Unique)) {
    $CopiedRequiredAssembly = $false
    foreach ($CurrentExtension in $Extension) {
      $SourcePath = $null
      foreach ($CandidateDirectory in $SourceDirectory) {
        if ([string]::IsNullOrWhiteSpace($CandidateDirectory) -or -not (Test-Path -LiteralPath $CandidateDirectory -PathType Container)) {
          continue
        }

        $CandidatePath = Join-Path $CandidateDirectory "$Name$CurrentExtension"
        if (Test-Path -LiteralPath $CandidatePath -PathType Leaf) {
          $SourcePath = $CandidatePath
          break
        }
      }

      if (-not $SourcePath) {
        continue
      }

      if ($CurrentExtension -eq '.dll') {
        $CopiedRequiredAssembly = $true
      } elseif (-not $CopiedRequiredAssembly) {
        continue
      }

      Copy-Item -LiteralPath $SourcePath -Destination (Join-Path $DestinationDirectory (Split-Path $SourcePath -Leaf)) -Force
    }
  }
}

function Get-NormalizedNuGetCacheVersion {
  param(
    [Parameter(Mandatory)]
    [string] $Version
  )

  if ($Version -match '^(\d+\.\d+\.\d+)\.0$') {
    return $Matches[1]
  }
  if ($Version -match '^\d+\.\d+$') {
    return "$Version.0"
  }

  return $Version
}

function Test-PSGalleryModuleVersionMatch {
  param(
    [Parameter(Mandatory)]
    [string] $ExpectedVersion,

    [Parameter(Mandatory)]
    [string] $ActualVersion
  )

  if ([string]::Equals($ExpectedVersion.Trim(), $ActualVersion.Trim(), [System.StringComparison]::OrdinalIgnoreCase)) {
    return $true
  }

  $ExpectedParsed = $null
  $ActualParsed = $null
  if ([version]::TryParse($ExpectedVersion.Trim(), [ref] $ExpectedParsed) -and
      [version]::TryParse($ActualVersion.Trim(), [ref] $ActualParsed)) {
    $NormExpected = [version]::new(
      $ExpectedParsed.Major,
      $ExpectedParsed.Minor,
      $(if ($ExpectedParsed.Build -lt 0) { 0 } else { $ExpectedParsed.Build }),
      $(if ($ExpectedParsed.Revision -lt 0) { 0 } else { $ExpectedParsed.Revision }))
    $NormActual = [version]::new(
      $ActualParsed.Major,
      $ActualParsed.Minor,
      $(if ($ActualParsed.Build -lt 0) { 0 } else { $ActualParsed.Build }),
      $(if ($ActualParsed.Revision -lt 0) { 0 } else { $ActualParsed.Revision }))
    return $NormExpected -eq $NormActual
  }

  return $false
}

function Remove-ExcludedPSGalleryModuleFiles {
  param(
    [Parameter(Mandatory)]
    [string] $DestinationPath
  )

  $ExcludedNames = @('fullclr', 'System.Runtime.InteropServices.RuntimeInformation.dll')
  $ExcludedPatterns = @('*.nupkg', '*.nupkg.metadata', '*.nupkg.sha512', '*.nuspec')
  Get-ChildItem -LiteralPath $DestinationPath -Recurse -Force |
    Sort-Object FullName -Descending |
    Where-Object {
      $ItemName = $_.Name
      $ExcludedNames -contains $ItemName -or
      (@($ExcludedPatterns | Where-Object { $ItemName -like $_ }).Count -gt 0)
    } |
    Remove-Item -Recurse -Force
}

function Copy-PowerShellSdkPSGalleryModules {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string] $ProjectPath,

    [Parameter(Mandatory)]
    [string] $DestinationRoot,

    [string] $PowerShellVersion,

    [string] $UpstreamReleaseArchivePath
  )

  if (-not (Test-Path -LiteralPath $ProjectPath -PathType Leaf)) {
    throw "PSGallery module project was not found: $ProjectPath"
  }

  [xml] $PSGalleryProject = Get-Content -LiteralPath $ProjectPath -Raw
  $PackageReferences = @($PSGalleryProject.Project.ItemGroup.PackageReference)
  if (-not $PackageReferences) {
    throw "PSGallery module project contains no PackageReference items: $ProjectPath"
  }

  $RequiredModules = [ordered]@{}
  foreach ($PackageReference in $PackageReferences) {
    $ModuleName = ([string] $PackageReference.Include).Trim()
    $ModuleVersion = ([string] $PackageReference.Version).Trim()
    if ([string]::IsNullOrWhiteSpace($ModuleName) -or [string]::IsNullOrWhiteSpace($ModuleVersion)) {
      throw "Invalid PSGallery module PackageReference in $ProjectPath"
    }
    $RequiredModules[$ModuleName] = $ModuleVersion
  }

  $TempRoot = if ($Env:RUNNER_TEMP) { $Env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
  $WorkDir = Join-Path $TempRoot "psgallery-modules-$([guid]::NewGuid().ToString('N'))"
  $RestoreProjectDir = Join-Path $WorkDir 'project'
  $RestorePackagesDir = Join-Path $WorkDir 'packages'
  New-Item -Path $RestoreProjectDir, $RestorePackagesDir -ItemType Directory -Force | Out-Null

  try {
    $TempProjectPath = Join-Path $RestoreProjectDir 'PSGalleryModules.csproj'
    Copy-Item -LiteralPath $ProjectPath -Destination $TempProjectPath -Force

    $NuGetConfigPath = Join-Path $RestoreProjectDir 'nuget.config'
    @(
      '<?xml version="1.0" encoding="utf-8"?>',
      '<configuration>',
      '  <packageSources>',
      '    <clear />',
      '    <add key="psgallery" value="https://www.powershellgallery.com/api/v2/" />',
      '    <add key="powershell" value="https://pkgs.dev.azure.com/powershell/PowerShell/_packaging/PowerShell/nuget/v3/index.json" />',
      '  </packageSources>',
      '</configuration>'
    ) | Set-Content -LiteralPath $NuGetConfigPath -Encoding utf8

    $RestoredFromFeeds = $false
    if ([string]::IsNullOrWhiteSpace($UpstreamReleaseArchivePath)) {
      $RestoreOutput = & dotnet restore $TempProjectPath --configfile $NuGetConfigPath --packages $RestorePackagesDir --verbosity minimal 2>&1
      if ($LASTEXITCODE -eq 0) {
        $RestoredFromFeeds = $true
      } elseif ([string]::IsNullOrWhiteSpace($PowerShellVersion)) {
        $RestoreOutput | ForEach-Object { Write-Host $_ }
        throw "dotnet restore failed for $ProjectPath with exit code $LASTEXITCODE"
      } else {
        Write-Host "Public feed restore did not resolve all bundled PSGallery module versions for PowerShell $PowerShellVersion; falling back to official upstream release archive v$PowerShellVersion."
      }
    }

    Remove-Item -LiteralPath $DestinationRoot -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -Path $DestinationRoot -ItemType Directory -Force | Out-Null

    if ($RestoredFromFeeds) {
      foreach ($ModuleName in $RequiredModules.Keys) {
        $ModuleVersion = $RequiredModules[$ModuleName]
        $CacheVersion = Get-NormalizedNuGetCacheVersion -Version $ModuleVersion
        $SourcePath = Join-Path $RestorePackagesDir (Join-Path $ModuleName.ToLowerInvariant() $CacheVersion)
        if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) {
          throw "Restored PSGallery module package was not found: $SourcePath"
        }

        $DestinationPath = Join-Path $DestinationRoot $ModuleName
        New-Item -Path $DestinationPath -ItemType Directory -Force | Out-Null
        Get-ChildItem -LiteralPath $SourcePath -Force |
          ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $DestinationPath -Recurse -Force
          }
        Remove-ExcludedPSGalleryModuleFiles -DestinationPath $DestinationPath
      }
      return
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $ArchivePath = $UpstreamReleaseArchivePath
    if ([string]::IsNullOrWhiteSpace($ArchivePath)) {
      $ArchivePath = Join-Path $WorkDir "PowerShell-$PowerShellVersion-win-fxdependent.zip"
      $DownloadUrl = "https://github.com/PowerShell/PowerShell/releases/download/v$PowerShellVersion/PowerShell-$PowerShellVersion-win-fxdependent.zip"
      Invoke-WebRequest -Uri $DownloadUrl -OutFile $ArchivePath
    }

    $ExtractDir = Join-Path $WorkDir 'fxdependent'
    [System.IO.Compression.ZipFile]::ExtractToDirectory($ArchivePath, $ExtractDir)

    foreach ($ModuleName in $RequiredModules.Keys) {
      $ExpectedVersion = $RequiredModules[$ModuleName]
      $SourceModulePath = Join-Path $ExtractDir (Join-Path 'Modules' $ModuleName)
      $ManifestPath = Join-Path $SourceModulePath "$ModuleName.psd1"
      if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw "Upstream release archive '$ArchivePath' is missing expected module manifest: Modules/$ModuleName/$ModuleName.psd1"
      }

      $ManifestData = Import-PowerShellDataFile -LiteralPath $ManifestPath
      $ActualVersion = ([string] $ManifestData['ModuleVersion']).Trim()
      if ([string]::IsNullOrWhiteSpace($ActualVersion)) {
        throw "Unable to parse ModuleVersion from '$ManifestPath'."
      }
      if (-not (Test-PSGalleryModuleVersionMatch -ExpectedVersion $ExpectedVersion -ActualVersion $ActualVersion)) {
        throw "Upstream release archive module '$ModuleName' has version '$ActualVersion', expected '$ExpectedVersion' from $ProjectPath."
      }

      $DestinationPath = Join-Path $DestinationRoot $ModuleName
      New-Item -Path $DestinationPath -ItemType Directory -Force | Out-Null
      Get-ChildItem -LiteralPath $SourceModulePath -Force |
        ForEach-Object {
          Copy-Item -LiteralPath $_.FullName -Destination $DestinationPath -Recurse -Force
        }
      Remove-ExcludedPSGalleryModuleFiles -DestinationPath $DestinationPath
    }
  } finally {
    try {
      Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction Stop
    } catch {
    }
  }
}

function Invoke-PowerShellSourceBuild {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string] $SourceRoot,

    [Parameter(Mandatory)]
    [hashtable] $BuildParameters,

    [scriptblock] $BuildAction = {
      param([hashtable] $Parameters)
      Start-PSBuild @Parameters
    }
  )

  $EffectiveParameters = @{}
  foreach ($Entry in $BuildParameters.GetEnumerator()) {
    if ($Entry.Key -eq 'PSModuleRestore') {
      continue
    }
    $EffectiveParameters[$Entry.Key] = $Entry.Value
  }
  $EffectiveParameters['NoPSModuleRestore'] = $true

  $ResolvedSourceRoot = (Resolve-Path -LiteralPath $SourceRoot).Path
  $PSGalleryProjectPath = Join-Path $ResolvedSourceRoot (Join-Path 'src' (Join-Path 'Modules' 'PSGalleryModules.csproj'))
  $HadPSGalleryProject = Test-Path -LiteralPath $PSGalleryProjectPath -PathType Leaf
  $OriginalBytes = if ($HadPSGalleryProject) { [System.IO.File]::ReadAllBytes($PSGalleryProjectPath) } else { $null }

  try {
    if ($HadPSGalleryProject) {
      # Start-PSBuild unconditionally restores src/Modules via Restore-PSPackage even when
      # -NoPSModuleRestore is passed. Strip PackageReferences during the source build so
      # Copy-PowerShellSdkPSGalleryModules owns module staging (and archive fallback) afterward.
      [xml] $ProjectXml = [System.Text.Encoding]::UTF8.GetString($OriginalBytes)
      foreach ($Node in @($ProjectXml.SelectNodes("//*[local-name()='PackageReference']"))) {
        if ($null -ne $Node.ParentNode) {
          [void] $Node.ParentNode.RemoveChild($Node)
        }
      }
      $WriterSettings = [System.Xml.XmlWriterSettings]::new()
      $WriterSettings.Encoding = [System.Text.UTF8Encoding]::new($false)
      $WriterSettings.Indent = $true
      $Writer = [System.Xml.XmlWriter]::Create($PSGalleryProjectPath, $WriterSettings)
      try {
        $ProjectXml.Save($Writer)
      } finally {
        $Writer.Dispose()
      }
    }

    & $BuildAction $EffectiveParameters
  } finally {
    if ($HadPSGalleryProject -and $null -ne $OriginalBytes) {
      [System.IO.File]::WriteAllBytes($PSGalleryProjectPath, $OriginalBytes)
    }
  }
}

Export-ModuleMember -Function `
  Get-PowerShellSdkSourceBuiltAssemblyDirectory, `
  Get-PowerShellSdkSourceBuiltAssemblyName, `
  Copy-PowerShellSdkSourceBuiltFile, `
  Copy-PowerShellSdkPSGalleryModules, `
  Invoke-PowerShellSourceBuild
