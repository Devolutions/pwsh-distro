[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $RepositoryRoot,

  [Parameter(Mandatory)]
  [string] $SourceRef,

  [Parameter(Mandatory)]
  [string] $ReleaseTag,

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

$RemoteBranchRef = "origin/$SourceRef"
$SourceBranch = $SourceRef

try {
  Push-Location $PwshSourcePath

  git fetch --tags --force origin | Out-Null
  git fetch --force origin "refs/heads/${SourceRef}:refs/remotes/origin/${SourceRef}" | Out-Null

  & git rev-parse --verify "$RemoteBranchRef^{commit}" *> $null
  if ($LASTEXITCODE -ne 0) {
    throw "Unable to resolve remote branch '$RemoteBranchRef' in pwsh-src."
  }

  & git rev-parse --verify "$ReleaseTag^{commit}" *> $null
  if ($LASTEXITCODE -ne 0) {
    throw "Unable to resolve base tag '$ReleaseTag' in pwsh-src."
  }

  & $PatchScript -RepoPath $PwshSourcePath -Branch $SourceBranch -BaseTag $ReleaseTag -ReleaseVersion $ReleaseVersion -OutputDir $ResolvedOutputDir
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
