[CmdletBinding()]
param(
  [string] $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path,

  [string] $RuntimeIdentifier,

  [string] $OutputRoot = 'output\local-sdk',

  [string] $NuGetExe,

  [switch] $SkipPinAudit
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path

function Get-RepositoryPath {
  param([Parameter(Mandatory)][string] $RelativePath)

  return Join-Path $RepositoryRoot $RelativePath
}

function Get-RepositoryFileText {
  param([Parameter(Mandatory)][string] $RelativePath)

  $Path = Get-RepositoryPath $RelativePath
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Required file '$RelativePath' was not found."
  }

  return Get-Content -Raw -LiteralPath $Path
}

function Get-YamlScalar {
  param(
    [Parameter(Mandatory)][string] $Text,
    [Parameter(Mandatory)][string] $Name,
    [Parameter(Mandatory)][string] $FileName
  )

  $EscapedName = [regex]::Escape($Name)
  $Match = [regex]::Match(
    $Text,
    "^\s*$EscapedName\s*:\s*['""]?([^'""\r\n]+)['""]?\s*$",
    [System.Text.RegularExpressions.RegexOptions]::Multiline)
  if (-not $Match.Success) {
    throw "Unable to find $Name in $FileName."
  }

  return $Match.Groups[1].Value.Trim()
}

$WorkflowPath = '.github\workflows\powershell-sdk.yml'
$WorkflowText = Get-RepositoryFileText $WorkflowPath
$PowerShellVersion = Get-YamlScalar -Text $WorkflowText -Name 'POWERSHELL_VERSION' -FileName $WorkflowPath
$SdkPackageRevision = Get-YamlScalar -Text $WorkflowText -Name 'SDK_PACKAGE_REVISION' -FileName $WorkflowPath
if ($SdkPackageRevision -notmatch '^\d+$') {
  throw "SDK_PACKAGE_REVISION in $WorkflowPath must be numeric."
}

$BuildArguments = @{
  PowerShellVersion = $PowerShellVersion
  PowerShellReleaseTag = Get-YamlScalar -Text $WorkflowText -Name 'POWERSHELL_RELEASE_TAG' -FileName $WorkflowPath
  SdkPackageVersion = "$PowerShellVersion.$SdkPackageRevision"
  PackageId = Get-YamlScalar -Text $WorkflowText -Name 'SDK_PACKAGE_ID' -FileName $WorkflowPath
  VendorName = Get-YamlScalar -Text $WorkflowText -Name 'SDK_VENDOR_NAME' -FileName $WorkflowPath
  MultiPwshPackageId = Get-YamlScalar -Text $WorkflowText -Name 'MULTI_PWSH_APPHOST_PACKAGE_ID' -FileName $WorkflowPath
  MultiPwshPackageVersion = Get-YamlScalar -Text $WorkflowText -Name 'MULTI_PWSH_APPHOST_PACKAGE_VERSION' -FileName $WorkflowPath
  MultiPwshPackageSource = Get-YamlScalar -Text $WorkflowText -Name 'MULTI_PWSH_APPHOST_PACKAGE_SOURCE' -FileName $WorkflowPath
  OutputRoot = $OutputRoot
  Validate = $true
}

if ($RuntimeIdentifier) {
  $BuildArguments.RuntimeIdentifier = $RuntimeIdentifier
}
if ($NuGetExe) {
  $BuildArguments.NuGetExe = $NuGetExe
}

if (-not $SkipPinAudit) {
  $PinAuditScript = Get-RepositoryPath '.agents\skills\powershell-pin-audit\scripts\Test-PowerShellPins.ps1'
  if (-not (Test-Path -LiteralPath $PinAuditScript -PathType Leaf)) {
    throw "Pin audit script was not found: $PinAuditScript"
  }

  & $PinAuditScript -RepositoryRoot $RepositoryRoot -RequireSubmodule
  if (-not $?) {
    throw 'PowerShell pin audit failed.'
  }
}

$BuildScript = Get-RepositoryPath 'scripts\Build-LocalPowerShellSdk.ps1'
if (-not (Test-Path -LiteralPath $BuildScript -PathType Leaf)) {
  throw "Local SDK build script was not found: $BuildScript"
}

& $BuildScript @BuildArguments
if (-not $?) {
  throw 'Local PowerShell SDK build failed.'
}
