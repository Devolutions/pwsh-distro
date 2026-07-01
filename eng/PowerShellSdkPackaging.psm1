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

Export-ModuleMember -Function `
  Get-PowerShellSdkSourceBuiltAssemblyDirectory, `
  Get-PowerShellSdkSourceBuiltAssemblyName, `
  Copy-PowerShellSdkSourceBuiltFile
