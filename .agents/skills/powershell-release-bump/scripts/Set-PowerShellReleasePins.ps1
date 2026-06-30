[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory)]
  [string] $Version,

  [string] $TargetFramework,

  [string] $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
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

function Set-RepositoryFileText {
  param(
    [Parameter(Mandatory)][string] $RelativePath,
    [Parameter(Mandatory)][string] $Text
  )

  $Path = Get-RepositoryPath $RelativePath
  if ($PSCmdlet.ShouldProcess($RelativePath, 'Update PowerShell release pins')) {
    Set-Content -LiteralPath $Path -Value $Text -Encoding utf8NoBOM
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

function Set-YamlEnvValue {
  param(
    [Parameter(Mandatory)][string] $Text,
    [Parameter(Mandatory)][string] $Name,
    [Parameter(Mandatory)][string] $Value,
    [Parameter(Mandatory)][string] $FileName
  )

  $EscapedName = [regex]::Escape($Name)
  return Set-RegexValue `
    -Text $Text `
    -Pattern "^(\s*$EscapedName\s*:\s*)['""]?[^'""\r\n]+['""]?(\s*)$" `
    -ReplacementValue "`"$Value`"" `
    -Description "$Name in $FileName"
}

function Get-PowerShellTargetFramework {
  $CommonPropsPath = Get-RepositoryPath 'pwsh-src\PowerShell.Common.props'
  if (-not (Test-Path -LiteralPath $CommonPropsPath -PathType Leaf)) {
    throw 'pwsh-src\PowerShell.Common.props was not found. Initialize pwsh-src or pass -TargetFramework explicitly.'
  }

  [xml] $CommonProps = Get-Content -LiteralPath $CommonPropsPath
  $Framework = $CommonProps.Project.PropertyGroup |
    ForEach-Object { $_.TargetFramework } |
    Where-Object { $_ } |
    Select-Object -First 1
  if (-not $Framework) {
    throw 'Unable to determine TargetFramework from pwsh-src\PowerShell.Common.props.'
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

if (-not $TargetFramework) {
  $TargetFramework = Get-PowerShellTargetFramework
}

$ReleaseTag = "v$NormalizedVersion"
$UpstreamTag = "upstream/$ReleaseTag"
$SourceRef = "downstream/$ReleaseTag"
$ReadmeReleaseValue = "``$NormalizedVersion`` / ``$ReleaseTag``"
$ReadmeSourceRefValue = "``$SourceRef`` based on ``$UpstreamTag``"
$ReadmeTargetFrameworkValue = "``$TargetFramework``"

$WorkflowPins = [ordered]@{
  POWERSHELL_VERSION = $NormalizedVersion
  POWERSHELL_RELEASE_TAG = $ReleaseTag
  POWERSHELL_UPSTREAM_TAG = $UpstreamTag
  POWERSHELL_SOURCE_REF = $SourceRef
}

foreach ($WorkflowPath in @('.github\workflows\powershell-sdk.yml', '.github\workflows\powershell.yml')) {
  $WorkflowText = Get-RepositoryFileText $WorkflowPath
  foreach ($Pin in $WorkflowPins.GetEnumerator()) {
    $WorkflowText = Set-YamlEnvValue -Text $WorkflowText -Name $Pin.Key -Value $Pin.Value -FileName $WorkflowPath
  }
  Set-RepositoryFileText -RelativePath $WorkflowPath -Text $WorkflowText
}

$GitmodulesText = Get-RepositoryFileText '.gitmodules'
$GitmodulesText = Set-RegexValue `
  -Text $GitmodulesText `
  -Pattern '^(\s*branch\s*=\s*)\S+(\s*)$' `
  -ReplacementValue $SourceRef `
  -Description 'pwsh-src branch in .gitmodules'
Set-RepositoryFileText -RelativePath '.gitmodules' -Text $GitmodulesText

$ReadmeText = Get-RepositoryFileText 'README.md'
$ReadmeText = Set-RegexValue `
  -Text $ReadmeText `
  -Pattern '^(\| PowerShell upstream release \| )`[^`]+` / `[^`]+`( \|\r?)$' `
  -ReplacementValue $ReadmeReleaseValue `
  -Description 'README PowerShell upstream release row'
$ReadmeText = Set-RegexValue `
  -Text $ReadmeText `
  -Pattern '^(\| PowerShell downstream source ref \| )`[^`]+` based on `[^`]+`( \|\r?)$' `
  -ReplacementValue $ReadmeSourceRefValue `
  -Description 'README PowerShell downstream source ref row'
$ReadmeText = Set-RegexValue `
  -Text $ReadmeText `
  -Pattern '^(\| PowerShell target framework \| )`[^`]+`( \|\r?)$' `
  -ReplacementValue $ReadmeTargetFrameworkValue `
  -Description 'README PowerShell target framework row'
Set-RepositoryFileText -RelativePath 'README.md' -Text $ReadmeText

Write-Output "PowerShellVersion=$NormalizedVersion"
Write-Output "PowerShellReleaseTag=$ReleaseTag"
Write-Output "PowerShellUpstreamTag=$UpstreamTag"
Write-Output "PowerShellSourceRef=$SourceRef"
Write-Output "PowerShellTargetFramework=$TargetFramework"
Write-Output 'NextStep=git submodule update --remote pwsh-src && git add pwsh-src'
