[CmdletBinding()]
param(
  [string] $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path,

  [string] $Channel,

  [switch] $RequireSubmodule
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
. (Join-Path $RepositoryRoot 'eng\PowerShellChannelConfig.ps1')

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

$Manifest = Get-PowerShellChannelsManifest -RepositoryRoot $RepositoryRoot
$TargetChannels = if ([string]::IsNullOrWhiteSpace($Channel)) {
  @($Manifest.Channels.Values)
} else {
  @(Resolve-PowerShellChannelConfig -Channel $Channel -RepositoryRoot $RepositoryRoot)
}

$SdkWorkflow = '.github\workflows\powershell-sdk.yml'
$CliWorkflow = '.github\workflows\powershell-cli.yml'
$RuntimeWorkflow = '.github\workflows\dotnet-runtime.yml'
$ReleaseWorkflow = '.github\workflows\release.yml'

foreach ($ManifestWorkflow in @($SdkWorkflow, $CliWorkflow, $RuntimeWorkflow)) {
  $WorkflowText = Get-RepositoryFileText $ManifestWorkflow
  $ManifestRef = Get-YamlScalar -Text $WorkflowText -Name 'POWERSHELL_CHANNELS_MANIFEST' -FileName $ManifestWorkflow
  Assert-Equal -Actual $ManifestRef -Expected 'eng/powershell-channels.json' -Description "POWERSHELL_CHANNELS_MANIFEST in $ManifestWorkflow"
}

foreach ($PackageWorkflow in @($SdkWorkflow, $CliWorkflow, $ReleaseWorkflow)) {
  $WorkflowText = Get-RepositoryFileText $PackageWorkflow
  $WorkflowPackageId = Get-YamlScalar -Text $WorkflowText -Name 'SDK_PACKAGE_ID' -FileName $PackageWorkflow
  Assert-Equal -Actual $WorkflowPackageId -Expected $Manifest.SdkPackageId -Description "SDK_PACKAGE_ID in $PackageWorkflow"
}

$SdkWorkflowText = Get-RepositoryFileText $SdkWorkflow
Assert-Equal `
  -Actual (Get-YamlScalar -Text $SdkWorkflowText -Name 'SDK_VENDOR_NAME' -FileName $SdkWorkflow) `
  -Expected $Manifest.SdkVendorName `
  -Description "SDK_VENDOR_NAME in $SdkWorkflow"
Assert-Equal `
  -Actual (Get-YamlScalar -Text $SdkWorkflowText -Name 'POWERSHELL_VENDOR_NAME' -FileName $SdkWorkflow) `
  -Expected $Manifest.PowerShellVendorName `
  -Description "POWERSHELL_VENDOR_NAME in $SdkWorkflow"

foreach ($ChannelWorkflow in @($SdkWorkflow, $CliWorkflow, $RuntimeWorkflow, $ReleaseWorkflow)) {
  $WorkflowText = Get-RepositoryFileText $ChannelWorkflow
  $DispatchChannelBlock = [regex]::Match(
    $WorkflowText,
    '(?ms)^\s*workflow_dispatch:\r?\n.*?^\s{6}channel:\r?\n(?<block>(?:^\s{8,}.*\r?\n)+)',
    [System.Text.RegularExpressions.RegexOptions]::None)
  if (-not $DispatchChannelBlock.Success) {
    Add-AuditError "$ChannelWorkflow is missing workflow_dispatch.inputs.channel."
    continue
  }

  $BlockText = $DispatchChannelBlock.Groups['block'].Value
  $DefaultMatch = [regex]::Match($BlockText, '^\s*default:\s*[''"]?([^''"\r\n]+)[''"]?\s*$', [System.Text.RegularExpressions.RegexOptions]::Multiline)
  if ($DefaultMatch.Success) {
    Assert-Equal -Actual $DefaultMatch.Groups[1].Value.Trim() -Expected $Manifest.DefaultChannel -Description "workflow_dispatch.inputs.channel.default in $ChannelWorkflow"
  } else {
    Add-AuditError "$ChannelWorkflow workflow_dispatch.inputs.channel is missing a default value."
  }

  foreach ($KnownChannel in $Manifest.ChannelNames) {
    $EscapedKnownChannel = [regex]::Escape($KnownChannel)
    if ($BlockText -notmatch "(?m)^\s*-\s*['""]?$EscapedKnownChannel['""]?\s*$") {
      Add-AuditError "$ChannelWorkflow workflow_dispatch.inputs.channel.options is missing channel '$KnownChannel'."
    }
  }
}

$GitmodulesText = Get-RepositoryFileText '.gitmodules'
$ReadmeText = Get-RepositoryFileText 'README.md'

$ReadmeDefaultChannelMatch = [regex]::Match(
  $ReadmeText,
  'Default PowerShell channel \| `([^`]+)`',
  [System.Text.RegularExpressions.RegexOptions]::Multiline)
if ($ReadmeDefaultChannelMatch.Success) {
  Assert-Equal -Actual $ReadmeDefaultChannelMatch.Groups[1].Value -Expected $Manifest.DefaultChannel -Description 'README Default PowerShell channel'
} else {
  Add-AuditError 'README Current pins table is missing the Default PowerShell channel row.'
}

foreach ($ChannelConfig in $TargetChannels) {
  $ChannelKey = $ChannelConfig.Channel
  $EscapedChannel = [regex]::Escape($ChannelKey)
  $EscapedTrack = [regex]::Escape($ChannelConfig.SupportTrack)
  $EscapedSubmoduleName = [regex]::Escape($ChannelConfig.SubmoduleName)
  $RowPrefix = "PowerShell $EscapedChannel \($EscapedTrack\)"

  $SubmoduleSectionMatch = [regex]::Match(
    $GitmodulesText,
    "(?ms)^\[submodule ""$EscapedSubmoduleName""\]\r?\n(?<body>(?:^\t[^\r\n]+\r?\n?)+)")
  if (-not $SubmoduleSectionMatch.Success) {
    Add-AuditError ".gitmodules is missing [submodule ""$($ChannelConfig.SubmoduleName)""]."
  } else {
    $SectionBody = $SubmoduleSectionMatch.Groups['body'].Value
    $SubmodulePathValue = Get-RequiredRegexValue -Text $SectionBody -Pattern '^\s*path\s*=\s*(\S+)\s*$' -Description "$($ChannelConfig.SubmoduleName) path in .gitmodules"
    $SubmoduleUrlValue = Get-RequiredRegexValue -Text $SectionBody -Pattern '^\s*url\s*=\s*(\S+)\s*$' -Description "$($ChannelConfig.SubmoduleName) url in .gitmodules"
    $SubmoduleBranchValue = Get-RequiredRegexValue -Text $SectionBody -Pattern '^\s*branch\s*=\s*(\S+)\s*$' -Description "$($ChannelConfig.SubmoduleName) branch in .gitmodules"
    Assert-Equal -Actual $SubmodulePathValue -Expected $ChannelConfig.SubmodulePath -Description "$($ChannelConfig.SubmoduleName) path in .gitmodules"
    Assert-Equal -Actual $SubmoduleUrlValue -Expected './' -Description "$($ChannelConfig.SubmoduleName) url in .gitmodules"
    Assert-Equal -Actual $SubmoduleBranchValue -Expected $ChannelConfig.PowerShellSourceRef -Description "$($ChannelConfig.SubmoduleName) branch in .gitmodules"
  }

  $ReadmeReleaseMatch = [regex]::Match(
    $ReadmeText,
    "$RowPrefix upstream release \| ``([^``]+)`` / ``([^``]+)``",
    [System.Text.RegularExpressions.RegexOptions]::Multiline)
  if ($ReadmeReleaseMatch.Success) {
    Assert-Equal -Actual $ReadmeReleaseMatch.Groups[1].Value -Expected $ChannelConfig.PowerShellVersion -Description "README $ChannelKey PowerShell upstream release version"
    Assert-Equal -Actual $ReadmeReleaseMatch.Groups[2].Value -Expected $ChannelConfig.PowerShellReleaseTag -Description "README $ChannelKey PowerShell upstream release tag"
  } else {
    Add-AuditError "README Current pins table is missing the PowerShell $ChannelKey ($($ChannelConfig.SupportTrack)) upstream release row."
  }

  $ReadmeSourceMatch = [regex]::Match(
    $ReadmeText,
    "$RowPrefix downstream source ref \| ``([^``]+)`` based on ``([^``]+)`` \(``([^``]+)``\)",
    [System.Text.RegularExpressions.RegexOptions]::Multiline)
  if ($ReadmeSourceMatch.Success) {
    Assert-Equal -Actual $ReadmeSourceMatch.Groups[1].Value -Expected $ChannelConfig.PowerShellSourceRef -Description "README $ChannelKey PowerShell downstream source ref"
    Assert-Equal -Actual $ReadmeSourceMatch.Groups[2].Value -Expected $ChannelConfig.PowerShellUpstreamTag -Description "README $ChannelKey PowerShell upstream base tag"
    Assert-Equal -Actual $ReadmeSourceMatch.Groups[3].Value -Expected $ChannelConfig.SubmodulePath -Description "README $ChannelKey PowerShell submodule path"
  } else {
    Add-AuditError "README Current pins table is missing the PowerShell $ChannelKey ($($ChannelConfig.SupportTrack)) downstream source ref row."
  }

  $ReadmeSdkPackageMatch = [regex]::Match(
    $ReadmeText,
    "$RowPrefix SDK package \| ``([^``]+)`` / ``([^``]+)`` workflow default",
    [System.Text.RegularExpressions.RegexOptions]::Multiline)
  if ($ReadmeSdkPackageMatch.Success) {
    Assert-Equal -Actual $ReadmeSdkPackageMatch.Groups[1].Value -Expected $ChannelConfig.SdkPackageId -Description "README $ChannelKey PowerShell SDK package ID"
    Assert-Equal -Actual $ReadmeSdkPackageMatch.Groups[2].Value -Expected $ChannelConfig.SdkPackageVersion -Description "README $ChannelKey PowerShell SDK package version"
  } else {
    Add-AuditError "README Current pins table is missing the PowerShell $ChannelKey ($($ChannelConfig.SupportTrack)) SDK package row."
  }

  $ReadmeFrameworkMatch = [regex]::Match(
    $ReadmeText,
    "$RowPrefix target framework \| ``([^``]+)``",
    [System.Text.RegularExpressions.RegexOptions]::Multiline)
  if ($ReadmeFrameworkMatch.Success) {
    Assert-Equal -Actual $ReadmeFrameworkMatch.Groups[1].Value -Expected $ChannelConfig.TargetFramework -Description "README $ChannelKey PowerShell target framework"
  } else {
    Add-AuditError "README Current pins table is missing the PowerShell $ChannelKey ($($ChannelConfig.SupportTrack)) target framework row."
  }

  $ReadmeRuntimeMatch = [regex]::Match(
    $ReadmeText,
    "$RowPrefix \.NET runtime workflow \| ``([^``]+)``",
    [System.Text.RegularExpressions.RegexOptions]::Multiline)
  if ($ReadmeRuntimeMatch.Success) {
    Assert-Equal -Actual $ReadmeRuntimeMatch.Groups[1].Value -Expected $ChannelConfig.DotnetRuntimeRef -Description "README $ChannelKey .NET runtime workflow ref"
  } else {
    Add-AuditError "README Current pins table is missing the PowerShell $ChannelKey ($($ChannelConfig.SupportTrack)) .NET runtime workflow row."
  }

  $PowerShellCommonProps = Join-Path $RepositoryRoot (Join-Path $ChannelConfig.SubmodulePath 'PowerShell.Common.props')
  if (Test-Path -LiteralPath $PowerShellCommonProps -PathType Leaf) {
    $PropsText = Get-Content -Raw -LiteralPath $PowerShellCommonProps
    $SubmoduleTargetFramework = Get-RequiredRegexValue `
      -Text $PropsText `
      -Pattern '<TargetFramework>([^<]+)</TargetFramework>' `
      -Description "TargetFramework in $($ChannelConfig.SubmodulePath)\PowerShell.Common.props"
    Assert-Equal `
      -Actual $SubmoduleTargetFramework `
      -Expected $ChannelConfig.TargetFramework `
      -Description "$($ChannelConfig.SubmodulePath)\PowerShell.Common.props TargetFramework"
  } elseif ($RequireSubmodule) {
    Add-AuditError "$($ChannelConfig.SubmodulePath)\PowerShell.Common.props was not found. Initialize the $($ChannelConfig.SubmodulePath) submodule before release-bump validation."
  } else {
    Add-AuditWarning "$($ChannelConfig.SubmodulePath)\PowerShell.Common.props was not found; target-framework verification was skipped for channel $ChannelKey."
  }
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

$Summary = @($TargetChannels | ForEach-Object { "$($_.Channel)=$($_.PowerShellVersion) ($($_.PowerShellReleaseTag), $($_.TargetFramework))" }) -join '; '
Write-Host "PowerShell pin audit passed: $Summary."
