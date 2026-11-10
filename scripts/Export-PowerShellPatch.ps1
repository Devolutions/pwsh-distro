[CmdletBinding()]
param(
  [string] $RepoPath,

  [string] $Branch,

  [string] $BaseTag,

  [string] $ReleaseVersion,

  [string] $OutputDir = 'patchsets\squashed'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoPath)) {
  if ($Branch -match '^(?:(?:refs/heads|refs/remotes/[^/]+|origin)/)?downstream/v(?<channel>\d+\.\d+)\.') {
    $ChannelName = $Matches['channel']
    $Candidates = @("pwsh-src-$ChannelName-worktree", 'pwsh-src-worktree', "pwsh-src-$ChannelName")
    $RepoPath = @($Candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Container } | Select-Object -First 1)
    if (-not $RepoPath) {
      $RepoPath = $Candidates[0]
    }
  } else {
    $DiscoveredWorktrees = @(
      Get-ChildItem -LiteralPath . -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'pwsh-src-worktree' -or $_.Name -like 'pwsh-src-*-worktree' } |
        Sort-Object FullName -Unique
    )
    if ($DiscoveredWorktrees.Count -gt 1) {
      $Names = @($DiscoveredWorktrees | ForEach-Object { $_.Name }) -join ', '
      throw "Multiple PowerShell source worktrees were found ($Names). Pass -RepoPath explicitly."
    } elseif ($DiscoveredWorktrees.Count -eq 1) {
      $RepoPath = $DiscoveredWorktrees[0].FullName
    } else {
      $RepoPath = 'pwsh-src-worktree'
    }
  }
}

if (-not (Test-Path -LiteralPath $RepoPath -PathType Container)) {
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

function Resolve-BranchCommitRef {
  param(
    [Parameter(Mandatory)]
    [string] $RepositoryPath,

    [Parameter(Mandatory)]
    [string] $RequestedBranch,

    [Parameter(Mandatory)]
    [string] $LogicalBranch
  )

  $CandidateRefs = [System.Collections.Generic.List[string]]::new()
  foreach ($InitialCandidate in @($RequestedBranch, "refs/heads/$LogicalBranch", "refs/remotes/origin/$LogicalBranch")) {
    if (-not [string]::IsNullOrWhiteSpace($InitialCandidate) -and -not $CandidateRefs.Contains($InitialCandidate)) {
      $CandidateRefs.Add($InitialCandidate)
    }
  }

  $Remotes = @(& git -C $RepositoryPath remote 2>$null)
  if ($LASTEXITCODE -eq 0) {
    foreach ($RemoteName in $Remotes) {
      $TrimmedRemote = ([string] $RemoteName).Trim()
      if (-not [string]::IsNullOrWhiteSpace($TrimmedRemote)) {
        $RemoteTrackingRef = "refs/remotes/$TrimmedRemote/$LogicalBranch"
        if (-not $CandidateRefs.Contains($RemoteTrackingRef)) {
          $CandidateRefs.Add($RemoteTrackingRef)
        }
      }
    }
  }

  foreach ($CandidateRef in $CandidateRefs) {
    & git -C $RepositoryPath rev-parse --verify "${CandidateRef}^{commit}" *> $null
    if ($LASTEXITCODE -eq 0) {
      return $CandidateRef
    }
  }

  throw "Unable to resolve branch '$RequestedBranch' locally or under remote-tracking refs in $RepositoryPath."
}

if (-not $Branch) {
  $Branch = (& git -C $RepoPath rev-parse --abbrev-ref HEAD).Trim()
  if ($LASTEXITCODE -ne 0) {
    throw "Unable to determine current branch for $RepoPath"
  }
  if ($Branch -eq 'HEAD') {
    throw "Repository '$RepoPath' has a detached HEAD. Pass -Branch explicitly."
  }
}

$LogicalBranch = $Branch.Trim() -replace '^(?:refs/heads/|refs/remotes/[^/]+/|origin/)', ''

if (-not $BaseTag) {
  if ($LogicalBranch -match '^downstream/(v.+)$') {
    $BaseTag = "upstream/$($Matches[1])"
  } else {
    throw "Could not infer base tag from branch '$Branch'. Pass -BaseTag explicitly."
  }
}

if (-not $ReleaseVersion) {
  if ($LogicalBranch -match '^downstream/v(.+)$') {
    $ReleaseVersion = "$($Matches[1]).0"
  } else {
    throw "Could not infer release version from branch '$Branch'. Pass -ReleaseVersion explicitly."
  }
}

$ResolvedBranchRef = Resolve-BranchCommitRef `
  -RepositoryPath $RepoPath `
  -RequestedBranch $Branch.Trim() `
  -LogicalBranch $LogicalBranch

Invoke-GitSource rev-parse --verify "$BaseTag^{commit}"

$CommitCount = [int](& git -C $RepoPath rev-list --count "$BaseTag..$ResolvedBranchRef").Trim()
if ($LASTEXITCODE -ne 0) {
  throw "Unable to count commits in range $BaseTag..$ResolvedBranchRef"
}
if ($CommitCount -eq 0) {
  throw "No commits found in range $BaseTag..$ResolvedBranchRef"
}

New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
$OutputFile = Join-Path $OutputDir "powershell-patch-$ReleaseVersion.patch"

$Diff = & git -C $RepoPath diff --binary "$BaseTag...$ResolvedBranchRef"
if ($LASTEXITCODE -ne 0) {
  throw "Unable to generate diff for $BaseTag...$ResolvedBranchRef"
}
if ([string]::IsNullOrWhiteSpace(($Diff -join [Environment]::NewLine))) {
  throw "No diff produced for range $BaseTag...$ResolvedBranchRef"
}

$Diff | Set-Content -Path $OutputFile -Encoding utf8

Write-Output "Branch=$LogicalBranch"
Write-Output "ResolvedRef=$ResolvedBranchRef"
Write-Output "BaseTag=$BaseTag"
Write-Output "ReleaseVersion=$ReleaseVersion"
Write-Output "CommitCount=$CommitCount"
Write-Output "OutputFile=$OutputFile"
