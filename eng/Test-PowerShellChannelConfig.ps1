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

  $FakeSourceRoot = Join-Path $WorkRoot 'fake-pwsh-src'
  $FakeModulesDir = Join-Path $FakeSourceRoot 'src\Modules'
  New-Item -ItemType Directory -Path $FakeModulesDir -Force | Out-Null
  $FakePSGalleryCsproj = Join-Path $FakeModulesDir 'PSGalleryModules.csproj'
  $OriginalFakeCsprojContent = @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Microsoft.PowerShell.Archive" Version="1.2.7" />
  </ItemGroup>
</Project>
"@
  [System.IO.File]::WriteAllText($FakePSGalleryCsproj, $OriginalFakeCsprojContent, [System.Text.UTF8Encoding]::new($false))
  $OriginalFakeBytes = [System.IO.File]::ReadAllBytes($FakePSGalleryCsproj)

  $ObservedDuringBuild = @{}
  Invoke-PowerShellSourceBuild `
    -SourceRoot $FakeSourceRoot `
    -BuildParameters @{ Clean = $true; PSModuleRestore = $true } `
    -BuildAction {
      param([hashtable] $Parameters)
      [xml] $DuringXml = Get-Content -LiteralPath $FakePSGalleryCsproj -Raw
      $ObservedDuringBuild['PackageRefCount'] = @($DuringXml.SelectNodes("//*[local-name()='PackageReference']")).Count
      $ObservedDuringBuild['NoPSModuleRestore'] = [bool] $Parameters['NoPSModuleRestore']
      $ObservedDuringBuild['HasPSModuleRestore'] = $Parameters.ContainsKey('PSModuleRestore')
    }
  Assert-True ($ObservedDuringBuild['PackageRefCount'] -eq 0) 'Invoke-PowerShellSourceBuild did not strip PackageReference items during build.'
  Assert-True ($ObservedDuringBuild['NoPSModuleRestore'] -eq $true) 'Invoke-PowerShellSourceBuild did not enforce NoPSModuleRestore.'
  Assert-True ($ObservedDuringBuild['HasPSModuleRestore'] -eq $false) 'Invoke-PowerShellSourceBuild did not remove PSModuleRestore.'
  Assert-True ([System.Linq.Enumerable]::SequenceEqual($OriginalFakeBytes, [System.IO.File]::ReadAllBytes($FakePSGalleryCsproj))) 'Invoke-PowerShellSourceBuild did not restore PSGalleryModules.csproj after success.'

  Assert-Throws -Action {
    Invoke-PowerShellSourceBuild `
      -SourceRoot $FakeSourceRoot `
      -BuildParameters @{ Configuration = 'Release' } `
      -BuildAction { throw 'simulated build failure' }
  } -ExpectedSubstring 'simulated build failure'
  Assert-True ([System.Linq.Enumerable]::SequenceEqual($OriginalFakeBytes, [System.IO.File]::ReadAllBytes($FakePSGalleryCsproj))) 'Invoke-PowerShellSourceBuild did not restore PSGalleryModules.csproj after failure.'

  $ExportScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\Export-PowerShellPatch.ps1'
  $PatchSandbox = Join-Path $WorkRoot 'patch-export-sandbox'
  $OriginBare = Join-Path $PatchSandbox 'origin.git'
  $SeedRepo = Join-Path $PatchSandbox 'seed'
  New-Item -ItemType Directory -Path $PatchSandbox -Force | Out-Null
  & git init --bare $OriginBare *> $null
  & git clone $OriginBare $SeedRepo *> $null
  & git -C $SeedRepo config user.name 'Test'
  & git -C $SeedRepo config user.email 'test@example.invalid'
  & git -C $SeedRepo checkout -b downstream/v7.7.0 *> $null
  Set-Content -LiteralPath (Join-Path $SeedRepo 'file.txt') -Value 'base' -Encoding utf8
  & git -C $SeedRepo add file.txt
  & git -C $SeedRepo commit -m 'base' *> $null
  & git -C $SeedRepo tag upstream/v7.7.0
  Set-Content -LiteralPath (Join-Path $SeedRepo 'file.txt') -Value 'patched' -Encoding utf8
  & git -C $SeedRepo commit -am 'patch' *> $null
  & git -C $SeedRepo push origin downstream/v7.7.0 --tags *> $null
  & git -C $SeedRepo checkout --detach *> $null

  $DetachedSubmodule = Join-Path $PatchSandbox 'pwsh-src-7.7'
  & git clone $OriginBare $DetachedSubmodule *> $null
  $TipSha = (& git -C $DetachedSubmodule rev-parse origin/downstream/v7.7.0).Trim()
  & git -C $DetachedSubmodule checkout --detach $TipSha *> $null
  & git -C $DetachedSubmodule branch -D downstream/v7.7.0 *> $null 2>&1

  Push-Location $PatchSandbox
  try {
    $RemoteExportOut = Join-Path $PatchSandbox 'out-remote'
    $RemoteExportLines = @(& $ExportScript -Branch 'downstream/v7.7.0' -OutputDir $RemoteExportOut)
    Assert-True ($RemoteExportLines -contains 'Branch=downstream/v7.7.0') 'Detached submodule export did not retain logical branch.'
    Assert-True ($RemoteExportLines -contains 'BaseTag=upstream/v7.7.0') 'Detached submodule export did not infer upstream tag.'
    Assert-True (Test-Path -LiteralPath (Join-Path $RemoteExportOut 'powershell-patch-7.7.0.0.patch') -PathType Leaf) 'Detached submodule export did not write patch file.'

    $ChannelWorktree = Join-Path $PatchSandbox 'pwsh-src-7.7-worktree'
    & git -C $SeedRepo worktree add $ChannelWorktree downstream/v7.7.0 *> $null
    $AutoExportOut = Join-Path $PatchSandbox 'out-auto'
    $AutoExportLines = @(& $ExportScript -OutputDir $AutoExportOut)
    Assert-True ($AutoExportLines -contains 'Branch=downstream/v7.7.0') 'No-arg export did not discover channel worktree.'
    Assert-True (Test-Path -LiteralPath (Join-Path $AutoExportOut 'powershell-patch-7.7.0.0.patch') -PathType Leaf) 'No-arg export did not write patch file.'

    New-Item -ItemType Directory -Path (Join-Path $PatchSandbox 'pwsh-src-7.6-worktree') -Force | Out-Null
    Assert-Throws -Action { & $ExportScript -OutputDir (Join-Path $PatchSandbox 'out-ambiguous') } -ExpectedSubstring 'Multiple PowerShell source worktrees were found'
  } finally {
    Pop-Location
  }

  Write-Host 'PowerShell channel configuration and GitHub release Latest tests passed.'
} finally {
  try {
    Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction Stop
  } catch {
  }
}
