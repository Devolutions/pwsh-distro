[CmdletBinding()]
param(
  [string] $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path,

  [switch] $RequireSubmodule
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$Errors = [System.Collections.Generic.List[string]]::new()
$Warnings = [System.Collections.Generic.List[string]]::new()

function Add-AuditError {
  param([Parameter(Mandatory)][string] $Message)
  $Errors.Add($Message) | Out-Null
}

function Add-AuditWarning {
  param([Parameter(Mandatory)][string] $Message)
  $Warnings.Add($Message) | Out-Null
}

function Get-RepositoryFileText {
  param([Parameter(Mandatory)][string] $RelativePath)

  $Path = Join-Path $RepositoryRoot $RelativePath
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Required file '$RelativePath' was not found."
  }

  return Get-Content -Raw -LiteralPath $Path
}

function Get-RequiredRegexValue {
  param(
    [Parameter(Mandatory)][string] $Text,
    [Parameter(Mandatory)][string] $Pattern,
    [Parameter(Mandatory)][string] $Description
  )

  $Match = [regex]::Match($Text, $Pattern, [System.Text.RegularExpressions.RegexOptions]::Multiline)
  if (-not $Match.Success) {
    throw "Unable to find $Description."
  }

  return $Match.Groups[1].Value.Trim()
}

function Get-YamlScalar {
  param(
    [Parameter(Mandatory)][string] $Text,
    [Parameter(Mandatory)][string] $Name,
    [Parameter(Mandatory)][string] $FileName
  )

  $EscapedName = [regex]::Escape($Name)
  return Get-RequiredRegexValue `
    -Text $Text `
    -Pattern "^\s*$EscapedName\s*:\s*['""]?([^'""\r\n]+)['""]?\s*$" `
    -Description "$Name in $FileName"
}

function Get-PowerShellWorkflowPins {
  param([Parameter(Mandatory)][string] $RelativePath)

  $Text = Get-RepositoryFileText $RelativePath
  $Pins = [ordered]@{}
  foreach ($Name in @(
    'POWERSHELL_VERSION',
    'POWERSHELL_RELEASE_TAG',
    'POWERSHELL_UPSTREAM_TAG',
    'POWERSHELL_SOURCE_REF'
  )) {
    $Pins[$Name] = Get-YamlScalar -Text $Text -Name $Name -FileName $RelativePath
  }

  return $Pins
}

function Assert-Equal {
  param(
    [Parameter(Mandatory)][string] $Actual,
    [Parameter(Mandatory)][string] $Expected,
    [Parameter(Mandatory)][string] $Description
  )

  if ($Actual -ne $Expected) {
    Add-AuditError "$Description expected '$Expected' but found '$Actual'."
  }
}

$SdkWorkflow = '.github\workflows\powershell-sdk.yml'
$DistributionWorkflow = '.github\workflows\powershell.yml'
$SdkPins = Get-PowerShellWorkflowPins $SdkWorkflow
$DistributionPins = Get-PowerShellWorkflowPins $DistributionWorkflow

foreach ($Name in $SdkPins.Keys) {
  Assert-Equal `
    -Actual $DistributionPins[$Name] `
    -Expected $SdkPins[$Name] `
    -Description "$Name in $DistributionWorkflow"
}

$Version = $SdkPins['POWERSHELL_VERSION']
$ReleaseTag = $SdkPins['POWERSHELL_RELEASE_TAG']
$UpstreamTag = $SdkPins['POWERSHELL_UPSTREAM_TAG']
$SourceRef = $SdkPins['POWERSHELL_SOURCE_REF']
$SdkWorkflowText = Get-RepositoryFileText $SdkWorkflow
$SdkPackageId = Get-YamlScalar -Text $SdkWorkflowText -Name 'SDK_PACKAGE_ID' -FileName $SdkWorkflow
$SdkPackageRevision = Get-YamlScalar -Text $SdkWorkflowText -Name 'SDK_PACKAGE_REVISION' -FileName $SdkWorkflow
if ($SdkPackageRevision -notmatch '^\d+$') {
  Add-AuditError "SDK_PACKAGE_REVISION in $SdkWorkflow must be numeric, found '$SdkPackageRevision'."
}
$SdkPackageVersion = "$Version.$SdkPackageRevision"

Assert-Equal -Actual $ReleaseTag -Expected "v$Version" -Description 'POWERSHELL_RELEASE_TAG'
Assert-Equal -Actual $UpstreamTag -Expected "upstream/$ReleaseTag" -Description 'POWERSHELL_UPSTREAM_TAG'
Assert-Equal -Actual $SourceRef -Expected "downstream/$ReleaseTag" -Description 'POWERSHELL_SOURCE_REF'

$GitmodulesText = Get-RepositoryFileText '.gitmodules'
$GitmodulesBranch = Get-RequiredRegexValue `
  -Text $GitmodulesText `
  -Pattern '^\s*branch\s*=\s*(\S+)\s*$' `
  -Description 'pwsh-src branch in .gitmodules'
Assert-Equal -Actual $GitmodulesBranch -Expected $SourceRef -Description 'pwsh-src branch in .gitmodules'

$ReadmeText = Get-RepositoryFileText 'README.md'
$ReadmeReleaseMatch = [regex]::Match(
  $ReadmeText,
  'PowerShell upstream release \| `([^`]+)` / `([^`]+)`',
  [System.Text.RegularExpressions.RegexOptions]::Multiline)
if ($ReadmeReleaseMatch.Success) {
  Assert-Equal -Actual $ReadmeReleaseMatch.Groups[1].Value -Expected $Version -Description 'README PowerShell upstream release version'
  Assert-Equal -Actual $ReadmeReleaseMatch.Groups[2].Value -Expected $ReleaseTag -Description 'README PowerShell upstream release tag'
} else {
  Add-AuditError 'README Current pins table is missing the PowerShell upstream release row.'
}

$ReadmeSourceMatch = [regex]::Match(
  $ReadmeText,
  'PowerShell downstream source ref \| `([^`]+)` based on `([^`]+)`',
  [System.Text.RegularExpressions.RegexOptions]::Multiline)
if ($ReadmeSourceMatch.Success) {
  Assert-Equal -Actual $ReadmeSourceMatch.Groups[1].Value -Expected $SourceRef -Description 'README PowerShell downstream source ref'
  Assert-Equal -Actual $ReadmeSourceMatch.Groups[2].Value -Expected $UpstreamTag -Description 'README PowerShell upstream base tag'
} else {
  Add-AuditError 'README Current pins table is missing the PowerShell downstream source ref row.'
}

$ReadmeSdkPackageMatch = [regex]::Match(
  $ReadmeText,
  'PowerShell SDK package \| `([^`]+)` / `([^`]+)`',
  [System.Text.RegularExpressions.RegexOptions]::Multiline)
if ($ReadmeSdkPackageMatch.Success) {
  Assert-Equal -Actual $ReadmeSdkPackageMatch.Groups[1].Value -Expected $SdkPackageId -Description 'README PowerShell SDK package ID'
  Assert-Equal -Actual $ReadmeSdkPackageMatch.Groups[2].Value -Expected $SdkPackageVersion -Description 'README PowerShell SDK package version'
} else {
  Add-AuditError 'README Current pins table is missing the PowerShell SDK package row.'
}

$ReadmeFrameworkMatch = [regex]::Match(
  $ReadmeText,
  'PowerShell target framework \| `([^`]+)`',
  [System.Text.RegularExpressions.RegexOptions]::Multiline)
if (-not $ReadmeFrameworkMatch.Success) {
  Add-AuditError 'README Current pins table is missing the PowerShell target framework row.'
}

$PowerShellCommonProps = Join-Path $RepositoryRoot 'pwsh-src\PowerShell.Common.props'
if (Test-Path -LiteralPath $PowerShellCommonProps -PathType Leaf) {
  $PropsText = Get-Content -Raw -LiteralPath $PowerShellCommonProps
  $TargetFramework = Get-RequiredRegexValue `
    -Text $PropsText `
    -Pattern '<TargetFramework>([^<]+)</TargetFramework>' `
    -Description 'TargetFramework in pwsh-src\PowerShell.Common.props'

  if ($ReadmeFrameworkMatch.Success) {
    Assert-Equal -Actual $ReadmeFrameworkMatch.Groups[1].Value -Expected $TargetFramework -Description 'README PowerShell target framework'
  }
} elseif ($RequireSubmodule) {
  Add-AuditError 'pwsh-src\PowerShell.Common.props was not found. Initialize the pwsh-src submodule before release-bump validation.'
} else {
  Add-AuditWarning 'pwsh-src\PowerShell.Common.props was not found; target-framework verification was skipped.'
}

if ($Warnings.Count -gt 0) {
  Write-Warning "PowerShell pin audit completed with $($Warnings.Count) warning(s):"
  foreach ($Warning in $Warnings) {
    Write-Warning "  $Warning"
  }
}

if ($Errors.Count -gt 0) {
  foreach ($AuditError in $Errors) {
    Write-Error $AuditError -ErrorAction Continue
  }

  throw "PowerShell pin audit failed with $($Errors.Count) error(s)."
}

Write-Host "PowerShell pin audit passed for $Version ($ReleaseTag)."
