[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $RepositoryRoot,

  [Parameter(Mandatory)]
  [string] $SourceRef,

  [Parameter(Mandatory)]
  [string] $UpstreamRef,

  [Parameter(Mandatory)]
  [string] $ReleaseVersion,

  [Parameter(Mandatory)]
  [string] $OutputDir
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$ResolvedRepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$PwshSourcePath = Join-Path $ResolvedRepositoryRoot 'pwsh-src'
if (-not (Test-Path $PwshSourcePath -PathType Container)) {
  throw "PowerShell source checkout not found at $PwshSourcePath."
}

if ([System.IO.Path]::IsPathRooted($OutputDir)) {
  $ResolvedOutputDir = [System.IO.Path]::GetFullPath($OutputDir)
} else {
  $ResolvedOutputDir = [System.IO.Path]::GetFullPath((Join-Path $ResolvedRepositoryRoot $OutputDir))
}

New-Item -ItemType Directory -Path $ResolvedOutputDir -Force | Out-Null

$PatchScript = Join-Path $ResolvedRepositoryRoot 'scripts/Export-PowerShellPatch.ps1'
if (-not (Test-Path $PatchScript -PathType Leaf)) {
  throw "Patch export helper not found at $PatchScript."
}

function ConvertTo-RemoteHeadRef {
  param(
    [Parameter(Mandatory)]
    [string] $Ref,

    [Parameter(Mandatory)]
    [string] $Description
  )

  $TrimmedRef = $Ref.Trim()
  if ([string]::IsNullOrWhiteSpace($TrimmedRef)) {
    throw "Expected $Description to be a non-empty branch ref."
  }

  if ($TrimmedRef -match '^refs/heads/(.+)$') {
    $HeadName = $Matches[1]
  } elseif ($TrimmedRef -match '^origin/(.+)$') {
    $HeadName = $Matches[1]
  } elseif ($TrimmedRef -notmatch '^refs/') {
    $HeadName = $TrimmedRef
  } else {
    throw "Expected $Description to be a branch ref, got '$Ref'."
  }

  [pscustomobject]@{
    HeadName = $HeadName
    FetchSpec = "refs/heads/${HeadName}:refs/remotes/origin/${HeadName}"
    RemoteRef = "origin/$HeadName"
  }
}

function ConvertTo-LocalTagRef {
  param(
    [Parameter(Mandatory)]
    [string] $Ref,

    [Parameter(Mandatory)]
    [string] $Description
  )

  $TrimmedRef = $Ref.Trim()
  if ([string]::IsNullOrWhiteSpace($TrimmedRef)) {
    throw "Expected $Description to be a non-empty tag ref."
  }

  if ($TrimmedRef -match '^refs/tags/(.+)$') {
    $TagName = $Matches[1]
  } elseif ($TrimmedRef -notmatch '^refs/' -and $TrimmedRef -notmatch '^origin/') {
    $TagName = $TrimmedRef
  } else {
    throw "Expected $Description to be a tag ref, got '$Ref'."
  }

  [pscustomobject]@{
    TagName = $TagName
    FetchSpec = "refs/tags/${TagName}:refs/tags/${TagName}"
    LocalRef = "refs/tags/$TagName"
  }
}

$SourceHead = ConvertTo-RemoteHeadRef -Ref $SourceRef -Description 'source ref'
$UpstreamTag = ConvertTo-LocalTagRef -Ref $UpstreamRef -Description 'upstream ref'
$SourceFetchSpec = $SourceHead.FetchSpec
$UpstreamFetchSpec = $UpstreamTag.FetchSpec
$RemoteSourceRef = $SourceHead.RemoteRef
$LocalUpstreamRef = $UpstreamTag.LocalRef

try {
  Push-Location $PwshSourcePath

  & git fetch --force origin $UpstreamFetchSpec $SourceFetchSpec | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Unable to fetch mirrored PowerShell refs '$($UpstreamTag.TagName)' and '$($SourceHead.HeadName)' in pwsh-src."
  }

  & git rev-parse --verify "${LocalUpstreamRef}^{commit}" *> $null
  if ($LASTEXITCODE -ne 0) {
    throw "Unable to resolve upstream ref '$LocalUpstreamRef' in pwsh-src."
  }

  & git rev-parse --verify "${RemoteSourceRef}^{commit}" *> $null
  if ($LASTEXITCODE -ne 0) {
    throw "Unable to resolve source ref '$RemoteSourceRef' in pwsh-src."
  }

  & $PatchScript -RepoPath $PwshSourcePath -Branch $RemoteSourceRef -BaseTag $LocalUpstreamRef -ReleaseVersion $ReleaseVersion -OutputDir $ResolvedOutputDir
  if ($LASTEXITCODE -ne 0) {
    throw "Patch export failed with exit code $LASTEXITCODE."
  }
}
finally {
  Pop-Location
}

$PatchFiles = @(Get-ChildItem -LiteralPath $ResolvedOutputDir -Filter 'powershell-patch-*.patch' -File | Sort-Object Name)
if ($PatchFiles.Count -ne 1) {
  throw "Expected exactly one generated patch file in $ResolvedOutputDir, found $($PatchFiles.Count)."
}

Write-Host "Exported patch file: $($PatchFiles[0].FullName)"
