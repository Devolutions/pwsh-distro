[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory)]
  [string] $Version,

  [string] $BranchName,

  [string] $UpstreamTag
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Invoke-Git {
  param(
    [Parameter(Mandatory, ValueFromRemainingArguments)]
    [string[]] $Arguments
  )

  & git @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
  }
}

function Test-GitRef {
  param(
    [Parameter(Mandatory)]
    [string] $Ref
  )

  & git rev-parse --verify "$Ref^{commit}" *> $null
  return $LASTEXITCODE -eq 0
}

$TagVersion = $Version.Trim()
if (-not $TagVersion.StartsWith('v', [System.StringComparison]::OrdinalIgnoreCase)) {
  $TagVersion = "v$TagVersion"
}

if (-not $BranchName) {
  $BranchName = "downstream/$TagVersion"
}

if (-not $UpstreamTag) {
  $UpstreamTag = "upstream/$TagVersion"
}

if (-not (Test-GitRef $UpstreamTag)) {
  throw "Upstream tag '$UpstreamTag' was not found. Run scripts\Sync-PowerShellUpstream.ps1 -SyncTags first."
}

& git show-ref --verify --quiet "refs/heads/$BranchName"
if ($LASTEXITCODE -eq 0) {
  throw "Branch '$BranchName' already exists."
}

if ($PSCmdlet.ShouldProcess($BranchName, "Create from $UpstreamTag")) {
  Invoke-Git branch $BranchName $UpstreamTag
}

Write-Output "Branch=$BranchName"
Write-Output "BaseTag=$UpstreamTag"
Write-Output "WorktreeCommand=git worktree add pwsh-src-worktree $BranchName"
