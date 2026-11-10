[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory)]
  [string] $Version,

  [string] $Channel,

  [string] $TargetFramework,

  [string] $SdkPackageRevision = '0',

  [string] $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
. (Join-Path $RepositoryRoot 'eng\PowerShellChannelConfig.ps1')

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

function Set-RepositoryFileText {
  param(
    [Parameter(Mandatory)][string] $RelativePath,
    [Parameter(Mandatory)][string] $Text
  )

  $Path = Get-RepositoryPath $RelativePath
  if ($PSCmdlet.ShouldProcess($RelativePath, 'Update PowerShell release pins')) {
    [System.IO.File]::WriteAllText(
      $Path,
      $Text,
      [System.Text.UTF8Encoding]::new($false))
  }
}

function Set-RegexValue {
  param(
    [Parameter(Mandatory)][string] $Text,
    [Parameter(Mandatory)][string] $Pattern,
    [Parameter(Mandatory)][string] $ReplacementValue,
    [Parameter(Mandatory)][string] $Description
  )

  $Regex = [regex]::new($Pattern, [System.Text.RegularExpressions.RegexOptions]::Multiline)
  $Matches = $Regex.Matches($Text)
  if ($Matches.Count -ne 1) {
    throw "Expected exactly one match for $Description, found $($Matches.Count)."
  }

  $Evaluator = [System.Text.RegularExpressions.MatchEvaluator] {
    param([System.Text.RegularExpressions.Match] $Match)
    return "$($Match.Groups[1].Value)$ReplacementValue$($Match.Groups[2].Value)"
  }

  return $Regex.Replace($Text, $Evaluator, 1)
}

function Get-PowerShellTargetFramework {
  param([Parameter(Mandatory)][string] $SubmodulePath)

  $CommonPropsPath = Get-RepositoryPath (Join-Path $SubmodulePath 'PowerShell.Common.props')
  if (-not (Test-Path -LiteralPath $CommonPropsPath -PathType Leaf)) {
    throw "$SubmodulePath\PowerShell.Common.props was not found. Initialize $SubmodulePath or pass -TargetFramework explicitly."
  }

  [xml] $CommonProps = Get-Content -LiteralPath $CommonPropsPath
  $Framework = $CommonProps.Project.PropertyGroup |
    ForEach-Object { $_.TargetFramework } |
    Where-Object { $_ } |
    Select-Object -First 1
  if (-not $Framework) {
    throw "Unable to determine TargetFramework from $SubmodulePath\PowerShell.Common.props."
  }

  return [string] $Framework
}

$NormalizedVersion = $Version.Trim()
if ($NormalizedVersion.StartsWith('v', [System.StringComparison]::OrdinalIgnoreCase)) {
  $NormalizedVersion = $NormalizedVersion.Substring(1)
}
if ($NormalizedVersion -notmatch '^\d+\.\d+\.\d+$') {
  throw "Version must be in X.Y.Z or vX.Y.Z form. Received '$Version'."
}

$SdkPackageRevision = $SdkPackageRevision.Trim()
if ($SdkPackageRevision -notmatch '^\d+$') {
  throw "SdkPackageRevision must be a non-negative integer. Received '$SdkPackageRevision'."
}

$ChannelConfig = Resolve-PowerShellChannelConfig `
  -Channel $Channel `
  -PowerShellVersion $NormalizedVersion `
  -RepositoryRoot $RepositoryRoot

$ChannelKey = $ChannelConfig.Channel
$SupportTrack = $ChannelConfig.SupportTrack
$SubmoduleName = $ChannelConfig.SubmoduleName
$SubmodulePath = $ChannelConfig.SubmodulePath

if (-not $TargetFramework) {
  $TargetFramework = Get-PowerShellTargetFramework -SubmodulePath $SubmodulePath
}

$ReleaseTag = "v$NormalizedVersion"
$UpstreamTag = "upstream/$ReleaseTag"
$SourceRef = "downstream/$ReleaseTag"
$SdkPackageVersion = "$NormalizedVersion.$SdkPackageRevision"

$ManifestRelativePath = 'eng\powershell-channels.json'
$ManifestJson = Get-RepositoryFileText $ManifestRelativePath | ConvertFrom-Json
$ChannelNode = $ManifestJson.channels.$ChannelKey
$ChannelNode.powerShellVersion = $NormalizedVersion
$ChannelNode.powerShellReleaseTag = $ReleaseTag
$ChannelNode.powerShellUpstreamTag = $UpstreamTag
$ChannelNode.powerShellSourceRef = $SourceRef
$ChannelNode.targetFramework = $TargetFramework
$ChannelNode.sdkPackageRevision = $SdkPackageRevision
$ChannelNode.cliSdkPackageVersion = $SdkPackageVersion
$ChannelNode.cliSdkPackageRevision = $SdkPackageRevision
$ManifestContent = ($ManifestJson | ConvertTo-Json -Depth 10) + "`n"
Set-RepositoryFileText -RelativePath $ManifestRelativePath -Text $ManifestContent

$EscapedSubmoduleName = [regex]::Escape($SubmoduleName)
$GitmodulesText = Get-RepositoryFileText '.gitmodules'
$GitmodulesText = Set-RegexValue `
  -Text $GitmodulesText `
  -Pattern "(?ms)(^\[submodule ""$EscapedSubmoduleName""\]\r?\n(?:\t(?:path|url)\s*=\s*\S+\r?\n)+\tbranch\s*=\s*)\S+(\r?$)" `
  -ReplacementValue $SourceRef `
  -Description "$SubmoduleName branch in .gitmodules"
Set-RepositoryFileText -RelativePath '.gitmodules' -Text $GitmodulesText

$EscapedChannel = [regex]::Escape($ChannelKey)
$EscapedTrack = [regex]::Escape($SupportTrack)
$RowPrefix = "PowerShell $EscapedChannel \($EscapedTrack\)"
$ReadmeReleaseValue = "``$NormalizedVersion`` / ``$ReleaseTag``"
$ReadmeSourceRefValue = "``$SourceRef`` based on ``$UpstreamTag`` (``$SubmodulePath``)"
$ReadmeTargetFrameworkValue = "``$TargetFramework``"
$ReadmeSdkPackageDefaultValue = "``$SdkPackageVersion``"

$ReadmeText = Get-RepositoryFileText 'README.md'
$ReadmeText = Set-RegexValue `
  -Text $ReadmeText `
  -Pattern "^(\| $RowPrefix upstream release \| )``[^``]+`` / ``[^``]+``( \|\r?)$" `
  -ReplacementValue $ReadmeReleaseValue `
  -Description "README PowerShell $ChannelKey upstream release row"
$ReadmeText = Set-RegexValue `
  -Text $ReadmeText `
  -Pattern "^(\| $RowPrefix downstream source ref \| )``[^``]+`` based on ``[^``]+`` \(``[^``]+``\)( \|\r?)$" `
  -ReplacementValue $ReadmeSourceRefValue `
  -Description "README PowerShell $ChannelKey downstream source ref row"
$ReadmeText = Set-RegexValue `
  -Text $ReadmeText `
  -Pattern "^(\| $RowPrefix target framework \| )``[^``]+``( \|\r?)$" `
  -ReplacementValue $ReadmeTargetFrameworkValue `
  -Description "README PowerShell $ChannelKey target framework row"
$ReadmeText = Set-RegexValue `
  -Text $ReadmeText `
  -Pattern "^(\| $RowPrefix SDK package \| ``[^``]+`` / )``[^``]+``( workflow default(?:; ``[^``]+`` latest published package)? \|\r?)$" `
  -ReplacementValue $ReadmeSdkPackageDefaultValue `
  -Description "README PowerShell $ChannelKey SDK package workflow default"
Set-RepositoryFileText -RelativePath 'README.md' -Text $ReadmeText

Write-Output "Channel=$ChannelKey"
Write-Output "SubmodulePath=$SubmodulePath"
Write-Output "PowerShellVersion=$NormalizedVersion"
Write-Output "PowerShellReleaseTag=$ReleaseTag"
Write-Output "PowerShellUpstreamTag=$UpstreamTag"
Write-Output "PowerShellSourceRef=$SourceRef"
Write-Output "PowerShellTargetFramework=$TargetFramework"
Write-Output "SdkPackageVersion=$SdkPackageVersion"
Write-Output "NextStep=git submodule update --remote $SubmodulePath && git add $SubmodulePath"
