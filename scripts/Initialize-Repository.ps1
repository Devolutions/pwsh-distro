[CmdletBinding(SupportsShouldProcess)]
param(
  [string] $Channel,

  [string] $SubmodulePath,

  [ValidateSet('Local', 'Global', 'Both', 'None')]
  [string] $LongPathScope = 'Both'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\eng\PowerShellChannelConfig.ps1')

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

function Get-GitOutput {
  param(
    [Parameter(Mandatory, ValueFromRemainingArguments)]
    [string[]] $Arguments
  )

  $Output = & git @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
  }

  return $Output
}

function Test-WindowsPlatform {
  return [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
    [System.Runtime.InteropServices.OSPlatform]::Windows)
}

function Set-GitLongPaths {
  param(
    [Parameter(Mandatory)]
    [ValidateSet('Local', 'Global', 'Both')]
    [string] $Scope
  )

  $Scopes = if ($Scope -eq 'Both') { @('Local', 'Global') } else { @($Scope) }
  foreach ($ConfigScope in $Scopes) {
    $Arguments = if ($ConfigScope -eq 'Global') {
      @('config', '--global', 'core.longpaths', 'true')
    } else {
      @('config', 'core.longpaths', 'true')
    }

    if ($PSCmdlet.ShouldProcess("$ConfigScope git config", 'Set core.longpaths=true')) {
      Invoke-Git @Arguments
    }
  }
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  throw 'git was not found on PATH.'
}

$RepositoryRoot = (Get-GitOutput rev-parse --show-toplevel | Select-Object -First 1).Trim()
if (-not $RepositoryRoot) {
  throw 'Unable to determine git repository root.'
}

$PreviousLocation = Get-Location
try {
  Set-Location $RepositoryRoot

  if (-not (Test-Path '.gitmodules' -PathType Leaf)) {
    throw "No .gitmodules file was found in $RepositoryRoot."
  }

  if (Test-WindowsPlatform) {
    if ($LongPathScope -ne 'None') {
      Set-GitLongPaths -Scope $LongPathScope
    }

    $LongPaths = (& git config --bool --get core.longpaths 2>$null)
    if ($LASTEXITCODE -ne 0 -or $LongPaths -ne 'true') {
      throw "core.longpaths is not enabled for this repository. Re-run with -LongPathScope Local, Global, or Both."
    }
  }

  $Manifest = Get-PowerShellChannelsManifest -RepositoryRoot $RepositoryRoot
  $Targets = @()
  if (-not [string]::IsNullOrWhiteSpace($SubmodulePath)) {
    $TrimmedSubmodulePath = $SubmodulePath.Trim()
    $MatchedChannel = @($Manifest.Channels.Values | Where-Object { $_.SubmodulePath -eq $TrimmedSubmodulePath } | Select-Object -First 1)
    if (-not [string]::IsNullOrWhiteSpace($Channel)) {
      if ($Channel.Trim() -ieq 'All') {
        throw 'Cannot combine -Channel All with an explicit -SubmodulePath.'
      }
      $ResolvedChannel = Resolve-PowerShellChannelConfig -Channel $Channel -RepositoryRoot $RepositoryRoot
      if ($ResolvedChannel.SubmodulePath -ne $TrimmedSubmodulePath) {
        throw "Channel '$($ResolvedChannel.Channel)' maps to submodule '$($ResolvedChannel.SubmodulePath)', not '$TrimmedSubmodulePath'."
      }
      $MatchedChannel = @($ResolvedChannel)
    }

    $Targets += [pscustomobject]@{
      SubmodulePath = $TrimmedSubmodulePath
      ChannelConfig = if ($MatchedChannel.Count -gt 0) { $MatchedChannel[0] } else { $null }
    }
  } elseif (-not [string]::IsNullOrWhiteSpace($Channel) -and $Channel.Trim() -ieq 'All') {
    foreach ($ChannelEntry in $Manifest.Channels.Values) {
      $Targets += [pscustomobject]@{
        SubmodulePath = $ChannelEntry.SubmodulePath
        ChannelConfig = $ChannelEntry
      }
    }
  } else {
    $ResolvedChannel = Resolve-PowerShellChannelConfig -Channel $Channel -RepositoryRoot $RepositoryRoot
    $Targets += [pscustomobject]@{
      SubmodulePath = $ResolvedChannel.SubmodulePath
      ChannelConfig = $ResolvedChannel
    }
  }

  Write-Output "RepositoryRoot=$RepositoryRoot"
  if (Test-WindowsPlatform) {
    Write-Output "GitCoreLongPaths=$((& git config --bool --get core.longpaths).Trim())"
  }

  foreach ($Target in $Targets) {
    $TargetSubmodulePath = $Target.SubmodulePath
    $TargetChannelConfig = $Target.ChannelConfig

    if ($PSCmdlet.ShouldProcess($TargetSubmodulePath, 'Synchronize submodule URL configuration')) {
      Invoke-Git submodule sync --recursive -- $TargetSubmodulePath
    }

    if ($PSCmdlet.ShouldProcess($TargetSubmodulePath, 'Initialize and update submodule to the pinned commit')) {
      Invoke-Git submodule update --init --recursive -- $TargetSubmodulePath
    }

    $SubmoduleStatus = @(Get-GitOutput submodule status --recursive -- $TargetSubmodulePath)
    foreach ($Line in $SubmoduleStatus) {
      if ($Line.StartsWith('-')) {
        throw "Submodule is not initialized: $Line"
      }
      if ($Line.StartsWith('+')) {
        throw "Submodule checkout does not match the pinned commit: $Line"
      }
      if ($Line.StartsWith('U')) {
        throw "Submodule has unresolved conflicts: $Line"
      }
    }

    if ($null -ne $TargetChannelConfig) {
      $UpstreamTag = $TargetChannelConfig.PowerShellUpstreamTag
      & git -C $TargetSubmodulePath rev-parse --verify "$UpstreamTag^{commit}" *> $null
      if ($LASTEXITCODE -ne 0 -and $PSCmdlet.ShouldProcess($TargetSubmodulePath, "Fetch base tag $UpstreamTag")) {
        $IsShallow = (& git -C $TargetSubmodulePath rev-parse --is-shallow-repository 2>$null)
        if ($IsShallow -and $IsShallow.Trim() -eq 'true') {
          Invoke-Git -C $TargetSubmodulePath fetch --unshallow origin "refs/tags/${UpstreamTag}:refs/tags/${UpstreamTag}"
        } else {
          Invoke-Git -C $TargetSubmodulePath fetch --force origin "refs/tags/${UpstreamTag}:refs/tags/${UpstreamTag}"
        }
      }
    }

    $CommonPropsPath = Join-Path $TargetSubmodulePath 'PowerShell.Common.props'
    if (-not (Test-Path $CommonPropsPath -PathType Leaf)) {
      throw "PowerShell source submodule did not initialize correctly; missing $CommonPropsPath."
    }

    [xml] $CommonProps = Get-Content -LiteralPath $CommonPropsPath
    $TargetFramework = $CommonProps.Project.PropertyGroup |
      ForEach-Object { $_.TargetFramework } |
      Where-Object { $_ } |
      Select-Object -First 1

    if ($null -ne $TargetChannelConfig -and $TargetFramework -ne $TargetChannelConfig.TargetFramework) {
      throw "Submodule '$TargetSubmodulePath' TargetFramework '$TargetFramework' does not match channel '$($TargetChannelConfig.Channel)' expected '$($TargetChannelConfig.TargetFramework)'."
    }

    $SubmoduleCommit = (Get-GitOutput @('-C', $TargetSubmodulePath, 'rev-parse', 'HEAD') | Select-Object -First 1).Trim()

    if ($null -ne $TargetChannelConfig) {
      Write-Output "Channel=$($TargetChannelConfig.Channel)"
    }
    Write-Output "SubmodulePath=$TargetSubmodulePath"
    Write-Output "SubmoduleCommit=$SubmoduleCommit"
    Write-Output "PowerShellTargetFramework=$TargetFramework"
  }
} finally {
  Set-Location $PreviousLocation
}
