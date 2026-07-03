[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $InputPath,

  [Parameter(Mandatory)]
  [string] $RuntimeIdentifier,

  [string] $RuntimeConfigFile = 'pwsh.runtimeconfig.json',

  [string[]] $IncludeFilter = @(
    'pwsh.dll',
    'System.Management.Automation.dll',
    'Microsoft.PowerShell*.dll',
    'Microsoft.Management.Infrastructure.CimCmdlets.dll',
    'Microsoft.WSMan.Management.dll'
  ),

  [string] $TargetFramework,

  [string] $CachePath,

  [switch] $UseCache,

  [switch] $PrintCommands
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Invoke-NativeCommand {
  param(
    [Parameter(Mandatory)]
    [string] $FilePath,

    [Parameter(ValueFromRemainingArguments)]
    [string[]] $Arguments
  )

  & $FilePath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "$FilePath $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
  }
}

function Get-DotNetGlobalPackagesPath {
  if (-not [string]::IsNullOrWhiteSpace($Env:NUGET_PACKAGES)) {
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Env:NUGET_PACKAGES)
  }

  $Output = & dotnet nuget locals global-packages --list
  if ($LASTEXITCODE -ne 0) {
    throw "dotnet nuget locals global-packages --list failed with exit code $LASTEXITCODE"
  }

  $GlobalPackagesLine = $Output | Where-Object { $_ -match '^\s*global-packages:\s*(.+)$' } | Select-Object -First 1
  if (-not $GlobalPackagesLine -or $GlobalPackagesLine -notmatch '^\s*global-packages:\s*(.+)$') {
    throw "Unable to determine NuGet global packages path."
  }

  return $Matches[1].Trim()
}

function Get-ReadyToRunTarget {
  param(
    [Parameter(Mandatory)]
    [string] $Rid
  )

  if ($Rid -notmatch '^(win|linux|osx)-(.+)$') {
    throw "Unsupported ReadyToRun runtime identifier '$Rid'."
  }

  $TargetOS = switch ($Matches[1]) {
    'win' { 'windows'; break }
    'linux' { 'linux'; break }
    'osx' { 'osx'; break }
  }

  $TargetArch = $Matches[2]
  if ($TargetArch -notin @('x64', 'arm64')) {
    throw "Unsupported ReadyToRun architecture '$TargetArch' from runtime identifier '$Rid'."
  }

  return [PSCustomObject] @{
    OS = $TargetOS
    Arch = $TargetArch
  }
}

function Get-PowerShellRuntimeTargetFramework {
  param(
    [Parameter(Mandatory)]
    [string] $RuntimeConfigPath
  )

  if (-not (Test-Path -LiteralPath $RuntimeConfigPath -PathType Leaf)) {
    throw "Runtime config was not found: $RuntimeConfigPath"
  }

  $RuntimeConfig = Get-Content -LiteralPath $RuntimeConfigPath -Raw | ConvertFrom-Json
  $Tfm = [string] $RuntimeConfig.runtimeOptions.tfm
  if ([string]::IsNullOrWhiteSpace($Tfm)) {
    throw "Runtime config '$RuntimeConfigPath' does not contain runtimeOptions.tfm."
  }

  return $Tfm
}

function Get-PowerShellRuntimeVersionPrefix {
  param(
    [Parameter(Mandatory)]
    [string] $RuntimeConfigPath
  )

  $RuntimeConfig = Get-Content -LiteralPath $RuntimeConfigPath -Raw | ConvertFrom-Json
  $Framework = @($RuntimeConfig.runtimeOptions.includedFrameworks) |
    Where-Object { [string] $_.name -eq 'Microsoft.NETCore.App' } |
    Select-Object -First 1
  if (-not $Framework) {
    $Framework = @($RuntimeConfig.runtimeOptions.frameworks) |
      Where-Object { [string] $_.name -eq 'Microsoft.NETCore.App' } |
      Select-Object -First 1
  }

  if (-not $Framework -or [string]::IsNullOrWhiteSpace([string] $Framework.version)) {
    return $null
  }

  $Version = [version] ([string] $Framework.version)
  return "$($Version.Major).$($Version.Minor)."
}

function Initialize-Crossgen2Package {
  param(
    [Parameter(Mandatory)]
    [string] $Tfm,

    [Parameter(Mandatory)]
    [string] $Rid,

    [Parameter(Mandatory)]
    [string] $WorkRoot
  )

  $ProjectDirectory = Join-Path $WorkRoot 'crossgen2-bootstrap'
  $PublishDirectory = Join-Path $WorkRoot 'crossgen2-bootstrap-publish'
  New-Item -Path $ProjectDirectory, $PublishDirectory -ItemType Directory -Force | Out-Null

  Invoke-NativeCommand dotnet @('new', 'classlib', '-o', $ProjectDirectory, '--force', '-f', $Tfm, '--no-restore')
  Invoke-NativeCommand dotnet @(
    'publish',
    $ProjectDirectory,
    '-p:PublishReadyToRun=True',
    '-c',
    'Release',
    '-r',
    $Rid,
    '-v:minimal',
    '--nologo',
    '-o',
    $PublishDirectory
  )
}

function Find-Crossgen2Executable {
  param(
    [Parameter(Mandatory)]
    [string] $PackagesPath,

    [AllowNull()]
    [string] $RuntimeVersionPrefix
  )

  $ExecutableName = if ($IsWindows) { 'crossgen2.exe' } else { 'crossgen2' }
  $PackageRoots = @(Get-ChildItem -LiteralPath $PackagesPath -Directory -Filter 'microsoft.netcore.app.crossgen2.*' -ErrorAction SilentlyContinue)
  $Candidates = foreach ($PackageRoot in $PackageRoots) {
    Get-ChildItem -LiteralPath $PackageRoot.FullName -Directory -ErrorAction SilentlyContinue |
      Where-Object { [string]::IsNullOrWhiteSpace($RuntimeVersionPrefix) -or $_.Name.StartsWith($RuntimeVersionPrefix, [System.StringComparison]::OrdinalIgnoreCase) } |
      ForEach-Object {
        $ToolPath = Join-Path $_.FullName (Join-Path 'tools' $ExecutableName)
        if (Test-Path -LiteralPath $ToolPath -PathType Leaf) {
          [PSCustomObject] @{
            Version = $_.Name
            Path = $ToolPath
          }
        }
      }
  }

  $Crossgen2 = $Candidates | Sort-Object Version, Path -Descending | Select-Object -First 1
  if (-not $Crossgen2) {
    throw "Unable to find $ExecutableName under restored Microsoft.NETCore.App.Crossgen2 packages in '$PackagesPath'."
  }

  return [string] $Crossgen2.Path
}

function Test-DotNetAssembly {
  param(
    [Parameter(Mandatory)]
    [string] $Path
  )

  try {
    [System.Reflection.AssemblyName]::GetAssemblyName($Path) | Out-Null
    return $true
  } catch {
    return $false
  }
}

function Get-HashText {
  param(
    [Parameter(Mandatory)]
    [string] $Text
  )

  $Sha256 = [System.Security.Cryptography.SHA256]::Create()
  try {
    $HashBytes = $Sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
    return ([BitConverter]::ToString($HashBytes) -replace '-', '').ToLowerInvariant()
  } finally {
    $Sha256.Dispose()
  }
}

function ConvertTo-ResponseFileArgument {
  param(
    [Parameter(Mandatory)]
    [string] $Argument
  )

  if ($Argument -notmatch '[\s"]') {
    return $Argument
  }

  return '"' + ($Argument -replace '\\', '\\' -replace '"', '\"') + '"'
}

$InputRoot = (Resolve-Path -LiteralPath $InputPath).Path
$RuntimeConfigPath = Join-Path $InputRoot $RuntimeConfigFile
if ([string]::IsNullOrWhiteSpace($TargetFramework)) {
  $TargetFramework = Get-PowerShellRuntimeTargetFramework -RuntimeConfigPath $RuntimeConfigPath
}

if ($RuntimeIdentifier -like 'win-*') {
  Write-Warning "ReadyToRun rewrites managed PE files. Run a signing pass after this step if Windows Authenticode signatures are required."
}

$Target = Get-ReadyToRunTarget -Rid $RuntimeIdentifier
$TempRoot = if ($Env:RUNNER_TEMP) { $Env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
$WorkRoot = Join-Path $TempRoot "powershell-distro-r2r-$([Guid]::NewGuid().ToString('N'))"
$PackagesPath = Get-DotNetGlobalPackagesPath
New-Item -Path $WorkRoot -ItemType Directory -Force | Out-Null
try {
  Initialize-Crossgen2Package -Tfm $TargetFramework -Rid $RuntimeIdentifier -WorkRoot $WorkRoot
  $RuntimeVersionPrefix = Get-PowerShellRuntimeVersionPrefix -RuntimeConfigPath $RuntimeConfigPath
  $Crossgen2Path = Find-Crossgen2Executable -PackagesPath $PackagesPath -RuntimeVersionPrefix $RuntimeVersionPrefix
  Write-Host "Using crossgen2: $Crossgen2Path"

  $ReferenceAssemblies = @(
    Get-ChildItem -LiteralPath $InputRoot -File -Filter '*.dll' |
      Where-Object { Test-DotNetAssembly -Path $_.FullName } |
      Sort-Object Name |
      ForEach-Object { $_.FullName }
  )
  if ($ReferenceAssemblies.Count -eq 0) {
    throw "No managed assemblies were found in '$InputRoot'."
  }

  $AssembliesToCompile = @(
    Get-ChildItem -LiteralPath $InputRoot -File -Filter '*.dll' |
      Where-Object {
        $Name = $_.Name
        (@($IncludeFilter | Where-Object { $Name -like $_ }).Count -gt 0) -and
          (Test-DotNetAssembly -Path $_.FullName)
      } |
      Sort-Object Name
  )
  if ($AssembliesToCompile.Count -eq 0) {
    throw "No ReadyToRun input assemblies matched filters '$($IncludeFilter -join ', ')' in '$InputRoot'."
  }

  if ($UseCache) {
    if ([string]::IsNullOrWhiteSpace($CachePath)) {
      $CachePath = if ($Env:R2R_CACHE_PATH) { $Env:R2R_CACHE_PATH } else { Join-Path $TempRoot 'powershell-distro-r2r-cache' }
    }
    New-Item -Path $CachePath -ItemType Directory -Force | Out-Null
  }

  $ReferenceFingerprint = @(
    foreach ($ReferenceAssembly in $ReferenceAssemblies) {
      $ReferenceItem = Get-Item -LiteralPath $ReferenceAssembly
      "$($ReferenceItem.Name) $((Get-FileHash -LiteralPath $ReferenceItem.FullName -Algorithm SHA256).Hash.ToLowerInvariant())"
    }
  ) -join "`n"
  $ReferenceHash = Get-HashText -Text $ReferenceFingerprint

  $StartTime = [datetime]::UtcNow
  $TotalSizeDifference = [int64] 0
  $CacheHitCount = 0

  foreach ($Assembly in $AssembliesToCompile) {
    $InputFile = $Assembly.FullName
    $InputHash = (Get-FileHash -LiteralPath $InputFile -Algorithm SHA256).Hash.ToLowerInvariant()
    $OutputFile = Join-Path $WorkRoot "$($Assembly.BaseName).r2r$($Assembly.Extension)"
    $CacheFilePath = $null

    if ($UseCache) {
      $CacheFileDirectory = Join-Path $CachePath (Join-Path $RuntimeIdentifier (Join-Path $Assembly.Name (Join-Path $InputHash $ReferenceHash)))
      $CacheFilePath = Join-Path $CacheFileDirectory $Assembly.Name
      if (Test-Path -LiteralPath $CacheFilePath -PathType Leaf) {
        Copy-Item -LiteralPath $CacheFilePath -Destination $InputFile -Force
        $CacheHitCount++
        Write-Host "ReadyToRun cache hit: $($Assembly.Name)"
        continue
      }
    }

    $CrossgenArguments = @(
      "--targetos:$($Target.OS)",
      "--targetarch:$($Target.Arch)",
      '-O'
    )
    foreach ($ReferenceAssembly in $ReferenceAssemblies) {
      $CrossgenArguments += "-r:$ReferenceAssembly"
    }
    $CrossgenArguments += "--out:$OutputFile"
    $CrossgenArguments += $InputFile

    $ResponseFilePath = Join-Path $WorkRoot "$($Assembly.BaseName).crossgen2.rsp"
    $CrossgenArguments |
      ForEach-Object { ConvertTo-ResponseFileArgument -Argument $_ } |
      Set-Content -LiteralPath $ResponseFilePath -Encoding utf8NoBOM

    if ($PrintCommands) {
      Write-Host "$Crossgen2Path @$ResponseFilePath"
    }

    Invoke-NativeCommand $Crossgen2Path "@$ResponseFilePath"
    if (-not (Test-Path -LiteralPath $OutputFile -PathType Leaf)) {
      throw "crossgen2 did not produce expected output file: $OutputFile"
    }

    $InputFileSize = (Get-Item -LiteralPath $InputFile).Length
    $OutputFileSize = (Get-Item -LiteralPath $OutputFile).Length
    $TotalSizeDifference += ($OutputFileSize - $InputFileSize)
    Copy-Item -LiteralPath $OutputFile -Destination $InputFile -Force

    if ($UseCache) {
      New-Item -Path (Split-Path -Parent $CacheFilePath) -ItemType Directory -Force | Out-Null
      Copy-Item -LiteralPath $InputFile -Destination $CacheFilePath -Force
    }

    $SizePercentage = [math]::Round((($OutputFileSize - $InputFileSize) / $InputFileSize) * 100, 2)
    Write-Host "ReadyToRun compiled $($Assembly.Name): $SizePercentage% larger"
  }

  $TotalSizeDiffMB = [math]::Round($TotalSizeDifference / 1MB, 2)
  $TotalTimeSeconds = [math]::Round(([datetime]::UtcNow - $StartTime).TotalSeconds, 2)
  Write-Host "ReadyToRun compiled $($AssembliesToCompile.Count) assemblies; output is $TotalSizeDiffMB MiB larger."
  if ($UseCache) {
    $CacheHitPercentage = [math]::Round(($CacheHitCount / $AssembliesToCompile.Count) * 100, 2)
    Write-Host "ReadyToRun cache hits: $CacheHitCount ($CacheHitPercentage%)."
  }
  Write-Host "ReadyToRun generation time: $TotalTimeSeconds seconds."
} finally {
  Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
}
