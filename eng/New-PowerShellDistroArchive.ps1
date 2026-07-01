[CmdletBinding()]
param(
  [string] $PackageId = 'Devolutions.PowerShell.SDK',

  [Parameter(Mandatory)]
  [string] $PackageVersion,

  [string] $PackageSource = 'https://api.nuget.org/v3/index.json',

  [Parameter(Mandatory)]
  [string] $PowerShellVersion,

  [Parameter(Mandatory)]
  [string] $RuntimeIdentifier,

  [Parameter(Mandatory)]
  [string] $OutputDirectory,

  [string] $ArchivePath,

  [string] $RepositoryRoot
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

function ConvertTo-XmlAttributeValue {
  param(
    [AllowNull()]
    [string] $Value
  )

  if ($null -eq $Value) {
    return ''
  }

  return [System.Security.SecurityElement]::Escape($Value)
}

function Get-PowerShellTargetFramework {
  param(
    [Parameter(Mandatory)]
    [string] $Root
  )

  $CommonPropsPath = Join-Path $Root 'pwsh-src\PowerShell.Common.props'
  if (-not (Test-Path -LiteralPath $CommonPropsPath -PathType Leaf)) {
    throw "PowerShell.Common.props was not found. Initialize the pwsh-src submodule first: $CommonPropsPath"
  }

  [xml] $CommonProps = Get-Content -LiteralPath $CommonPropsPath -Raw
  $TargetFramework = $CommonProps.Project.PropertyGroup |
    ForEach-Object { $_.TargetFramework } |
    Where-Object { $_ } |
    Select-Object -First 1

  if ([string]::IsNullOrWhiteSpace($TargetFramework)) {
    throw "Unable to determine PowerShell TargetFramework from $CommonPropsPath"
  }

  return [string] $TargetFramework
}

function Get-PowerShellExecutableName {
  param(
    [Parameter(Mandatory)]
    [string] $Rid
  )

  if ($Rid -like 'win-*') {
    return 'pwsh.exe'
  }

  return 'pwsh'
}

function Assert-SdkPackageVersion {
  param(
    [Parameter(Mandatory)]
    [string] $ExpectedPowerShellVersion,

    [Parameter(Mandatory)]
    [string] $ActualPackageVersion
  )

  if ($ActualPackageVersion -notmatch '^\d+\.\d+\.\d+\.\d+$') {
    throw "SDK package version '$ActualPackageVersion' must use X.Y.Z.R."
  }

  if (($ActualPackageVersion -replace '\.\d+$', '') -ne $ExpectedPowerShellVersion) {
    throw "SDK package version '$ActualPackageVersion' must start with PowerShell version '$ExpectedPowerShellVersion'."
  }
}

function Get-CurrentRuntimeIdentifier {
  $Architecture = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
    'X64' { 'x64'; break }
    'Arm64' { 'arm64'; break }
    default { return $null }
  }

  if ($IsWindows) {
    return "win-$Architecture"
  }
  if ($IsLinux) {
    return "linux-$Architecture"
  }
  if ($IsMacOS) {
    return "osx-$Architecture"
  }

  return $null
}

function Assert-RequiredFile {
  param(
    [Parameter(Mandatory)]
    [string] $Root,

    [Parameter(Mandatory)]
    [string] $RelativePath
  )

  $Path = Join-Path $Root ($RelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "PowerShell distro is missing required file: $Path"
  }
}

function Remove-DisposableHostFiles {
  param(
    [Parameter(Mandatory)]
    [string] $Root,

    [Parameter(Mandatory)]
    [string] $HostBaseName
  )

  $HostFileNames = @(
    $HostBaseName,
    "$HostBaseName.exe",
    "$HostBaseName.dll",
    "$HostBaseName.deps.json",
    "$HostBaseName.runtimeconfig.json",
    "$HostBaseName.pdb"
  )

  foreach ($HostFileName in $HostFileNames) {
    $HostPath = Join-Path $Root $HostFileName
    Remove-Item -LiteralPath $HostPath -Force -ErrorAction SilentlyContinue
  }

  foreach ($HostFileName in $HostFileNames) {
    $HostPath = Join-Path $Root $HostFileName
    if (Test-Path -LiteralPath $HostPath) {
      throw "Disposable host file was not removed from the PowerShell distro: $HostPath"
    }
  }
}

function Get-RequiredDistroRelativePaths {
  param(
    [Parameter(Mandatory)]
    [string] $Rid
  )

  $ExecutableName = Get-PowerShellExecutableName -Rid $Rid
  $RequiredPaths = @(
    $ExecutableName,
    'pwsh.dll',
    'pwsh.runtimeconfig.json',
    'powershell.config.json',
    'System.Management.Automation.dll',
    'Microsoft.PowerShell.ConsoleHost.dll'
  )

  foreach ($ModuleName in @(
      'Microsoft.PowerShell.Management',
      'Microsoft.PowerShell.Utility',
      'Microsoft.PowerShell.Security',
      'Microsoft.PowerShell.Archive',
      'Microsoft.PowerShell.PSResourceGet',
      'Microsoft.PowerShell.ThreadJob',
      'PackageManagement',
      'PowerShellGet',
      'PSReadLine')) {
    $RequiredPaths += "Modules/$ModuleName/$ModuleName.psd1"
  }

  return $RequiredPaths
}

function Test-PowerShellDistroLayout {
  param(
    [Parameter(Mandatory)]
    [string] $Root,

    [Parameter(Mandatory)]
    [string] $Rid,

    [Parameter(Mandatory)]
    [string] $ExpectedVersion
  )

  $ExecutableName = Get-PowerShellExecutableName -Rid $Rid
  foreach ($RelativePath in (Get-RequiredDistroRelativePaths -Rid $Rid)) {
    Assert-RequiredFile -Root $Root -RelativePath $RelativePath
  }

  $CurrentRid = Get-CurrentRuntimeIdentifier
  if ($CurrentRid -ne $Rid) {
    Write-Host "Skipping execution probe for $Rid on $CurrentRid."
    return
  }

  $PwshPath = Join-Path $Root $ExecutableName
  if (-not $IsWindows) {
    Invoke-NativeCommand chmod @('+x', $PwshPath)
  }

  $PwshOutput = & $PwshPath -NoLogo -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()'
  if ($LASTEXITCODE -ne 0) {
    throw "$PwshPath failed with exit code $LASTEXITCODE"
  }

  $ActualVersion = [string] ($PwshOutput | Select-Object -Last 1)
  if ($ActualVersion.Trim() -ne $ExpectedVersion) {
    throw "$PwshPath reported PowerShell version '$ActualVersion', expected '$ExpectedVersion'"
  }
}

function Test-PowerShellDistroArchive {
  param(
    [Parameter(Mandatory)]
    [string] $ArchivePath,

    [Parameter(Mandatory)]
    [string] $Rid,

    [Parameter(Mandatory)]
    [string] $HostBaseName
  )

  $ArchiveEntries = & tar -tf $ArchivePath
  if ($LASTEXITCODE -ne 0) {
    throw "tar -tf $ArchivePath failed with exit code $LASTEXITCODE"
  }

  $NormalizedEntries = @(
    $ArchiveEntries | ForEach-Object {
      $Entry = ([string] $_) -replace '\\', '/'
      $Entry = $Entry -replace '^\./', ''
      $Entry.TrimEnd('/')
    }
  )

  foreach ($RelativePath in (Get-RequiredDistroRelativePaths -Rid $Rid)) {
    if ($NormalizedEntries -notcontains $RelativePath) {
      throw "PowerShell distro archive is missing required entry: $RelativePath"
    }
  }

  foreach ($HostFileName in @(
      $HostBaseName,
      "$HostBaseName.exe",
      "$HostBaseName.dll",
      "$HostBaseName.deps.json",
      "$HostBaseName.runtimeconfig.json",
      "$HostBaseName.pdb")) {
    if ($NormalizedEntries -contains $HostFileName) {
      throw "PowerShell distro archive contains disposable host entry: $HostFileName"
    }
  }
}

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
  $RepositoryRoot = Split-Path -Parent $PSScriptRoot
}

$RepositoryRootPath = (Resolve-Path -LiteralPath $RepositoryRoot).Path
Assert-SdkPackageVersion -ExpectedPowerShellVersion $PowerShellVersion -ActualPackageVersion $PackageVersion
$TargetFramework = Get-PowerShellTargetFramework -Root $RepositoryRootPath
$ExecutableName = Get-PowerShellExecutableName -Rid $RuntimeIdentifier
$OutputDirectoryPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
if ([string]::IsNullOrWhiteSpace($ArchivePath)) {
  $ArchivePath = "$OutputDirectoryPath.tar.gz"
}
$ArchiveFullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ArchivePath)
$ArchiveDirectory = Split-Path -Parent $ArchiveFullPath
if ($ArchiveDirectory) {
  New-Item -Path $ArchiveDirectory -ItemType Directory -Force | Out-Null
}

$TempRoot = if ($Env:RUNNER_TEMP) { $Env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
$WorkRoot = Join-Path $TempRoot "powershell-distro-$([Guid]::NewGuid().ToString('N'))"
$ProjectDirectory = Join-Path $WorkRoot 'project'
$PublishDirectory = Join-Path $WorkRoot 'publish'
$PackagesDirectory = Join-Path $WorkRoot 'packages'
$ProjectPath = Join-Path $ProjectDirectory 'PowerShellDistroPackagerHost.csproj'
$NuGetConfigPath = Join-Path $ProjectDirectory 'nuget.config'
$ProgramPath = Join-Path $ProjectDirectory 'Program.cs'
$HostBaseName = 'PowerShellDistroPackagerHost'

$PreviousNuGetPackages = $Env:NUGET_PACKAGES
try {
  New-Item $ProjectDirectory, $PublishDirectory, $PackagesDirectory -ItemType Directory -Force | Out-Null
  $Env:NUGET_PACKAGES = $PackagesDirectory

  $EscapedPackageId = ConvertTo-XmlAttributeValue $PackageId
  $EscapedPackageVersion = ConvertTo-XmlAttributeValue $PackageVersion
  $EscapedPackageSource = ConvertTo-XmlAttributeValue $PackageSource
  $EscapedTargetFramework = ConvertTo-XmlAttributeValue $TargetFramework
  $EscapedRuntimeIdentifier = ConvertTo-XmlAttributeValue $RuntimeIdentifier
  $EscapedHostBaseName = ConvertTo-XmlAttributeValue $HostBaseName

  $ProjectXml = @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>$EscapedTargetFramework</TargetFramework>
    <RuntimeIdentifier>$EscapedRuntimeIdentifier</RuntimeIdentifier>
    <SelfContained>true</SelfContained>
    <AssemblyName>$EscapedHostBaseName</AssemblyName>
    <PowerShellSDKIncludeAppHost>true</PowerShellSDKIncludeAppHost>
    <PowerShellSDKAppHostRuntimeIdentifier>$EscapedRuntimeIdentifier</PowerShellSDKAppHostRuntimeIdentifier>
    <PowerShellSDKIncludePSGalleryModules>true</PowerShellSDKIncludePSGalleryModules>
    <PowerShellSDKConfigExecutionPolicy>Bypass</PowerShellSDKConfigExecutionPolicy>
    <PowerShellSDKConfigOverwriteExisting>true</PowerShellSDKConfigOverwriteExisting>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="$EscapedPackageId" Version="$EscapedPackageVersion" />
  </ItemGroup>
</Project>
"@
  Set-Content -LiteralPath $ProjectPath -Value $ProjectXml -Encoding utf8
  $Program = @'
using System;
using System.Management.Automation;

Console.WriteLine(typeof(PowerShell).Assembly.GetName().Name);
'@
  Set-Content -LiteralPath $ProgramPath -Value $Program -Encoding utf8

  $NuGetOrgSource = 'https://api.nuget.org/v3/index.json'
  $PackageSourceMatchesNuGetOrg = $PackageSource.TrimEnd('/') -eq $NuGetOrgSource.TrimEnd('/')
  if ($PackageSourceMatchesNuGetOrg) {
    $NuGetConfig = @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />
  </packageSources>
  <packageSourceMapping>
    <packageSource key="nuget.org">
      <package pattern="$EscapedPackageId" />
      <package pattern="*" />
    </packageSource>
  </packageSourceMapping>
</configuration>
"@
  } else {
    $NuGetConfig = @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="powershell-sdk" value="$EscapedPackageSource" />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />
  </packageSources>
  <packageSourceMapping>
    <packageSource key="powershell-sdk">
      <package pattern="$EscapedPackageId" />
    </packageSource>
    <packageSource key="nuget.org">
      <package pattern="*" />
    </packageSource>
  </packageSourceMapping>
</configuration>
"@
  }
  Set-Content -LiteralPath $NuGetConfigPath -Value $NuGetConfig -Encoding utf8

  Invoke-NativeCommand dotnet @('restore', $ProjectPath, '--configfile', $NuGetConfigPath, '--verbosity', 'minimal', '-r', $RuntimeIdentifier, '/p:SelfContained=true')
  Invoke-NativeCommand dotnet @(
    'publish',
    $ProjectPath,
    '--no-restore',
    '--nologo',
    '--verbosity',
    'minimal',
    '-c',
    'Release',
    '-r',
    $RuntimeIdentifier,
    '--self-contained',
    'true',
    '-o',
    $PublishDirectory
  )

  Remove-Item -LiteralPath $OutputDirectoryPath -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -Path $OutputDirectoryPath -ItemType Directory -Force | Out-Null
  Copy-Item -Path (Join-Path $PublishDirectory '*') -Destination $OutputDirectoryPath -Recurse -Force

  Remove-DisposableHostFiles -Root $OutputDirectoryPath -HostBaseName $HostBaseName
  Test-PowerShellDistroLayout -Root $OutputDirectoryPath -Rid $RuntimeIdentifier -ExpectedVersion $PowerShellVersion

  Remove-Item -LiteralPath $ArchiveFullPath -Force -ErrorAction SilentlyContinue
  Invoke-NativeCommand tar @('-czf', $ArchiveFullPath, '-C', $OutputDirectoryPath, '.')
  if (-not (Test-Path -LiteralPath $ArchiveFullPath -PathType Leaf)) {
    throw "PowerShell distro archive was not created: $ArchiveFullPath"
  }
  Test-PowerShellDistroArchive -ArchivePath $ArchiveFullPath -Rid $RuntimeIdentifier -HostBaseName $HostBaseName

  Write-Output "Archive=$ArchiveFullPath"
  Write-Output "OutputDirectory=$OutputDirectoryPath"
  Write-Output "RuntimeIdentifier=$RuntimeIdentifier"
  Write-Output "TargetFramework=$TargetFramework"
  Write-Output "Executable=$ExecutableName"
} finally {
  $Env:NUGET_PACKAGES = $PreviousNuGetPackages
  Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
}
