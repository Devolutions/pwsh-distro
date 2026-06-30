[CmdletBinding()]
param(
  [string] $RepoPath = 'pwsh-src-worktree',

  [string] $Branch,

  [string] $BaseTag,

  [string] $ReleaseVersion,

  [string] $OutputDir = 'patchsets\squashed'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $RepoPath -PathType Container)) {
  throw "Repository path not found: $RepoPath"
}

function Invoke-GitSource {
  param(
    [Parameter(Mandatory, ValueFromRemainingArguments)]
    [string[]] $Arguments
  )

  & git -C $RepoPath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "git -C $RepoPath $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
  }
}

if (-not $Branch) {
  $Branch = (& git -C $RepoPath rev-parse --abbrev-ref HEAD).Trim()
  if ($LASTEXITCODE -ne 0) {
    throw "Unable to determine current branch for $RepoPath"
  }
}

if (-not $BaseTag) {
  if ($Branch -match '^downstream/(v.+)$') {
    $BaseTag = "upstream/$($Matches[1])"
  } else {
    throw "Could not infer base tag from branch '$Branch'. Pass -BaseTag explicitly."
  }
}

if (-not $ReleaseVersion) {
  if ($Branch -match '^downstream/v(.+)$') {
    $ReleaseVersion = "$($Matches[1]).0"
  } else {
    throw "Could not infer release version from branch '$Branch'. Pass -ReleaseVersion explicitly."
  }
}

Invoke-GitSource rev-parse --verify "$BaseTag^{commit}"

$CommitCount = [int](& git -C $RepoPath rev-list --count "$BaseTag..$Branch").Trim()
if ($LASTEXITCODE -ne 0) {
  throw "Unable to count commits in range $BaseTag..$Branch"
}
if ($CommitCount -eq 0) {
  throw "No commits found in range $BaseTag..$Branch"
}

New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
$OutputFile = Join-Path $OutputDir "powershell-patch-$ReleaseVersion.patch"

$Diff = & git -C $RepoPath diff --binary "$BaseTag...$Branch"
if ($LASTEXITCODE -ne 0) {
  throw "Unable to generate diff for $BaseTag...$Branch"
}
if ([string]::IsNullOrWhiteSpace(($Diff -join [Environment]::NewLine))) {
  throw "No diff produced for range $BaseTag...$Branch"
}

$Diff | Set-Content -Path $OutputFile -Encoding utf8

Write-Output "Branch=$Branch"
Write-Output "BaseTag=$BaseTag"
Write-Output "ReleaseVersion=$ReleaseVersion"
Write-Output "CommitCount=$CommitCount"
Write-Output "OutputFile=$OutputFile"
