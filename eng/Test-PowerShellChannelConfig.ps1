[CmdletBinding()]
param(
  [string] $WorkRoot = (Join-Path $(if ($Env:RUNNER_TEMP) { $Env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }) "pwsh-channel-config-test-$([guid]::NewGuid().ToString('N'))")
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'PowerShellChannelConfig.ps1')
Import-Module (Join-Path $PSScriptRoot 'PowerShellSdkPackaging.psm1') -Force

function Assert-True {
  param(
    [Parameter(Mandatory)]
    [bool] $Condition,

    [Parameter(Mandatory)]
    [string] $Message
  )

  if (-not $Condition) {
    throw $Message
  }
}

function Assert-Throws {
  param(
    [Parameter(Mandatory)]
    [scriptblock] $Action,

    [Parameter(Mandatory)]
    [string] $ExpectedSubstring
  )

  try {
    & $Action | Out-Null
  } catch {
    if ($_.Exception.Message -like "*$ExpectedSubstring*") {
      return
    }
    throw "Expected an error containing '$ExpectedSubstring', got: $($_.Exception.Message)"
  }

  throw "Expected an error containing '$ExpectedSubstring', but no exception was thrown."
}

$Manifest = Get-PowerShellChannelsManifest
Assert-True ($Manifest.DefaultChannel -eq '7.6') "Expected default channel '7.6', got '$($Manifest.DefaultChannel)'."
Assert-True (($Manifest.ChannelNames -join ',') -eq '7.6,7.7') "Expected channels '7.6,7.7', got '$($Manifest.ChannelNames -join ',')'."

$DefaultChannel = Resolve-PowerShellChannelConfig
Assert-True ($DefaultChannel.Channel -eq '7.6') 'Default channel resolution did not return 7.6.'
Assert-True ($DefaultChannel.SubmodulePath -eq 'pwsh-src-7.6') '7.6 submodule path mismatch.'
Assert-True ($DefaultChannel.TargetFramework -eq 'net10.0') '7.6 target framework mismatch.'
Assert-True ($DefaultChannel.PowerShellVersion -eq '7.6.10') '7.6 PowerShell version mismatch.'
Assert-True ($DefaultChannel.SdkPackageVersion -eq '7.6.10.0') '7.6 SDK package version mismatch.'

$Channel77 = Resolve-PowerShellChannelConfig -Channel '7.7'
Assert-True ($Channel77.Channel -eq '7.7') 'Explicit 7.7 channel resolution failed.'
Assert-True ($Channel77.SubmodulePath -eq 'pwsh-src-7.7') '7.7 submodule path mismatch.'
Assert-True ($Channel77.TargetFramework -eq 'net11.0') '7.7 target framework mismatch.'
Assert-True ($Channel77.PowerShellVersion -eq '7.7.0') '7.7 PowerShell version mismatch.'
Assert-True ($Channel77.DotnetRuntimeRef -eq 'v11.0.0') '7.7 dotnet runtime ref mismatch.'

$DerivedFromFourPart = Resolve-PowerShellChannelConfig -PowerShellVersion '7.7.0.2'
Assert-True ($DerivedFromFourPart.Channel -eq '7.7') 'Version-derived channel resolution failed for 7.7.0.2.'

$DerivedFromTag = Resolve-PowerShellChannelConfig -PowerShellVersion 'v7.6.10'
Assert-True ($DerivedFromTag.Channel -eq '7.6') 'Version-derived channel resolution failed for v7.6.10.'

Assert-Throws -Action { Resolve-PowerShellChannelConfig -Channel '7.5' } -ExpectedSubstring "Unsupported PowerShell channel '7.5'"
Assert-Throws -Action { Resolve-PowerShellChannelConfig -Channel '7.6' -PowerShellVersion '7.7.0.0' } -ExpectedSubstring "belongs to channel '7.7'"

$WorkRoot = [System.IO.Path]::GetFullPath($WorkRoot)
New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null
try {
  $InvalidManifestPath = Join-Path $WorkRoot 'invalid-channels.json'
  $InvalidJson = Get-Content -LiteralPath $Manifest.ManifestPath -Raw | ConvertFrom-Json
  $InvalidJson.channels.'7.7'.powerShellReleaseTag = 'downstream/v7.7.0'
  $InvalidJson | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $InvalidManifestPath -Encoding utf8
  Assert-Throws -Action { Get-PowerShellChannelsManifest -ManifestPath $InvalidManifestPath } -ExpectedSubstring 'powerShellReleaseTag'

  $ReleasesBefore77 = @(
    [pscustomobject]@{ tagName = 'v7.6.9.1'; isDraft = $false; isPrerelease = $false }
  )
  Assert-True (Test-ShouldMarkGitHubReleaseLatest -CandidateVersion '7.6.10.0' -ExistingReleases $ReleasesBefore77) '7.6.10.0 should be Latest when only 7.6.9.1 exists.'
  Assert-True (Test-ShouldMarkGitHubReleaseLatest -CandidateVersion '7.7.0.0' -ExistingReleases $ReleasesBefore77) '7.7.0.0 should be Latest when only 7.6.9.1 exists.'

  $ReleasesWith77 = @(
    [pscustomobject]@{ tagName = 'v7.6.9.1'; isDraft = $false; isPrerelease = $false },
    [pscustomobject]@{ tagName = 'v7.7.0.0'; isDraft = $false; isPrerelease = $false }
  )
  Assert-True (-not (Test-ShouldMarkGitHubReleaseLatest -CandidateVersion '7.6.10.0' -ExistingReleases $ReleasesWith77)) '7.6.10.0 must not overwrite Latest when v7.7.0.0 already exists.'
  Assert-True (-not (Test-ShouldMarkGitHubReleaseLatest -CandidateVersion '7.6.11.0' -ExistingReleases $ReleasesWith77)) '7.6.11.0 must not overwrite Latest when v7.7.0.0 already exists.'
  Assert-True (Test-ShouldMarkGitHubReleaseLatest -CandidateVersion '7.7.0.0' -ExistingReleases $ReleasesWith77) 'Re-evaluating v7.7.0.0 against itself should remain Latest.'
  Assert-True (Test-ShouldMarkGitHubReleaseLatest -CandidateVersion '7.7.0.1' -ExistingReleases $ReleasesWith77) '7.7.0.1 should become Latest over v7.7.0.0.'

  $ReleasesWithDraftAndPrerelease78 = @(
    [pscustomobject]@{ tagName = 'v7.6.10.0'; isDraft = $false; isPrerelease = $false },
    [pscustomobject]@{ tagName = 'v7.8.0.0'; isDraft = $true; isPrerelease = $false },
    [pscustomobject]@{ tagName = 'v7.8.0-preview.1'; isDraft = $false; isPrerelease = $true }
  )
  Assert-True (Test-ShouldMarkGitHubReleaseLatest -CandidateVersion '7.6.10.1' -ExistingReleases $ReleasesWithDraftAndPrerelease78) 'Draft and prerelease higher versions must not block Latest.'

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $FixtureProject = Join-Path $WorkRoot 'PSGalleryModules.csproj'
  @'
<Project>
  <ItemGroup>
    <PackageReference Include="Microsoft.PowerShell.Archive" Version="1.2.7" />
    <PackageReference Include="PSReadLine" Version="2.4.5" />
  </ItemGroup>
</Project>
'@ | Set-Content -LiteralPath $FixtureProject -Encoding utf8

  $FixtureZipStage = Join-Path $WorkRoot 'fxdep-stage'
  foreach ($FixtureModule in @(
      @{ Name = 'Microsoft.PowerShell.Archive'; Version = '1.2.7' },
      @{ Name = 'PSReadLine'; Version = '2.4.5' })) {
    $ModDir = Join-Path $FixtureZipStage (Join-Path 'Modules' $FixtureModule.Name)
    New-Item -ItemType Directory -Path (Join-Path $ModDir 'fullclr') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $ModDir "$($FixtureModule.Name).psd1") -Value "@{ ModuleVersion = '$($FixtureModule.Version)' }" -Encoding utf8
    Set-Content -LiteralPath (Join-Path $ModDir '.signature.p7s') -Value 'sig' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $ModDir 'fullclr\legacy.dll') -Value 'legacy' -Encoding utf8
  }
  $FixtureZip = Join-Path $WorkRoot 'win-fxdependent.zip'
  [System.IO.Compression.ZipFile]::CreateFromDirectory($FixtureZipStage, $FixtureZip)

  $StagedModulesDir = Join-Path $WorkRoot 'staged-psgallery'
  Copy-PowerShellSdkPSGalleryModules `
    -ProjectPath $FixtureProject `
    -DestinationRoot $StagedModulesDir `
    -UpstreamReleaseArchivePath $FixtureZip
  Assert-True (Test-Path -LiteralPath (Join-Path $StagedModulesDir 'Microsoft.PowerShell.Archive\Microsoft.PowerShell.Archive.psd1') -PathType Leaf) 'Archive psd1 missing after archive fallback.'
  Assert-True (Test-Path -LiteralPath (Join-Path $StagedModulesDir 'PSReadLine\.signature.p7s') -PathType Leaf) 'PSReadLine .signature.p7s missing after archive fallback.'
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $StagedModulesDir 'PSReadLine\fullclr'))) 'Excluded fullclr directory was not removed.'

  $MismatchProject = Join-Path $WorkRoot 'PSGalleryModules.mismatch.csproj'
  @'
<Project>
  <ItemGroup>
    <PackageReference Include="Microsoft.PowerShell.Archive" Version="9.9.9" />
  </ItemGroup>
</Project>
'@ | Set-Content -LiteralPath $MismatchProject -Encoding utf8
  Assert-Throws -Action {
    Copy-PowerShellSdkPSGalleryModules `
      -ProjectPath $MismatchProject `
      -DestinationRoot (Join-Path $WorkRoot 'staged-mismatch') `
      -UpstreamReleaseArchivePath $FixtureZip
  } -ExpectedSubstring "expected '9.9.9'"

  Write-Host 'PowerShell channel configuration and GitHub release Latest tests passed.'
} finally {
  try {
    Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction Stop
  } catch {
  }
}
