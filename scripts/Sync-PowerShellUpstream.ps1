[CmdletBinding(SupportsShouldProcess)]
param(
  [string] $UpstreamRepository = 'https://github.com/PowerShell/PowerShell.git',

  [string] $UpstreamBranch = 'master',

  [string] $UpstreamRemote = 'powershell',

  [string] $OriginRemote = 'origin',

  [switch] $SyncTags,

  [switch] $Push,

  [string] $TagIncludePattern = '^v(?:[8-9]\.\d+\.\d+|7\.[6-9]\.\d+)$'
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

function Test-GitRemote {
  param(
    [Parameter(Mandatory)]
    [string] $Name
  )

  & git remote get-url $Name *> $null
  return $LASTEXITCODE -eq 0
}

if (Test-GitRemote $UpstreamRemote) {
  Invoke-Git remote set-url $UpstreamRemote $UpstreamRepository
} else {
  Invoke-Git remote add $UpstreamRemote $UpstreamRepository
}

Invoke-Git fetch $UpstreamRemote --prune --no-tags
# --no-tags is intentional: upstream PowerShell publishes bare vX.Y.Z tags that
# would otherwise be fetched into refs/tags/vX.Y.Z and pollute the downstream
# namespace. Upstream tags are mirrored only under refs/tags/upstream/* by the
# SyncTags block below. Keep this flag whenever fetching from $UpstreamRemote.

$RemoteBranchRef = "refs/remotes/$UpstreamRemote/$UpstreamBranch"
Invoke-Git rev-parse --verify $RemoteBranchRef
$UpstreamCommit = (& git rev-parse $RemoteBranchRef).Trim()
if ($LASTEXITCODE -ne 0) {
  throw "Unable to resolve $RemoteBranchRef"
}

if ($PSCmdlet.ShouldProcess('refs/heads/upstream', "Update to $UpstreamCommit")) {
  Invoke-Git update-ref refs/heads/upstream $UpstreamCommit
}

if ($Push) {
  if ($PSCmdlet.ShouldProcess($OriginRemote, 'Push refs/heads/upstream')) {
    Invoke-Git push $OriginRemote refs/heads/upstream:refs/heads/upstream --force
  }
}

if ($SyncTags) {
  # Fetch all upstream tags into refs/tags/upstream/*, then prune to those
  # matching TagIncludePattern. Filtering after fetch keeps the refspec stable
  # (git refspecs do not support arbitrary regexes) while avoiding deleting
  # unrelated tags that may exist under refs/tags/upstream/* on the remote.
  Invoke-Git fetch $UpstreamRemote --prune --no-tags '+refs/tags/*:refs/tags/upstream/*'
  $Tags = @(git for-each-ref --format='%(refname)' refs/tags/upstream)
  if ($LASTEXITCODE -ne 0) {
    throw "Unable to enumerate refs/tags/upstream"
  }

  if ($Tags.Count -eq 0) {
    Write-Host 'No upstream tags found.'
    return
  }

  $Kept = @()
  $Dropped = @()
  foreach ($Tag in $Tags) {
    $ShortName = $Tag -replace '^refs/tags/upstream/',''
    if ($ShortName -match $TagIncludePattern) {
      $Kept += $Tag
    } else {
      $Dropped += $Tag
    }
  }

  if ($Dropped.Count -gt 0) {
    Invoke-Git tag -d @($Dropped | ForEach-Object { $_ -replace '^refs/tags/','' })
  }

  Write-Host "Kept $($Kept.Count) upstream tag(s) matching '$TagIncludePattern'; dropped $($Dropped.Count) non-matching tag(s)."

  if ($Push) {
    foreach ($Tag in $Kept) {
      if ($PSCmdlet.ShouldProcess($OriginRemote, "Push $Tag")) {
        Invoke-Git push $OriginRemote "$Tag`:$Tag"
      }
    }
  }
}
