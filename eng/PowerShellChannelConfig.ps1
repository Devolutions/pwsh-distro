Set-StrictMode -Version 3.0

function Get-PowerShellChannelsManifestPath {
  param(
    [string] $ManifestPath,

    [string] $RepositoryRoot
  )

  if (-not [string]::IsNullOrWhiteSpace($ManifestPath)) {
    return $ManifestPath
  }

  if (-not [string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    return Join-Path $RepositoryRoot 'eng\powershell-channels.json'
  }

  return Join-Path $PSScriptRoot 'powershell-channels.json'
}

function ConvertTo-NormalizedFourPartVersion {
  param(
    [Parameter(Mandatory)]
    [string] $VersionText
  )

  $Trimmed = $VersionText.Trim()
  if ($Trimmed.StartsWith('v', [System.StringComparison]::OrdinalIgnoreCase)) {
    $Trimmed = $Trimmed.Substring(1)
  }

  $Parsed = [version]::Parse($Trimmed)
  $Revision = if ($Parsed.Revision -lt 0) { 0 } else { $Parsed.Revision }
  return [version]::new($Parsed.Major, $Parsed.Minor, $Parsed.Build, $Revision)
}

function Get-PowerShellChannelFromVersion {
  param(
    [Parameter(Mandatory)]
    [string] $VersionText
  )

  $Trimmed = $VersionText.Trim()
  if ($Trimmed.StartsWith('v', [System.StringComparison]::OrdinalIgnoreCase)) {
    $Trimmed = $Trimmed.Substring(1)
  }

  if ($Trimmed -notmatch '^(?<major>\d+)\.(?<minor>\d+)(?:\.\d+(?:\.\d+)?)?$') {
    throw "Unable to derive a Major.Minor PowerShell channel from '$VersionText'."
  }

  return "$($Matches['major']).$($Matches['minor'])"
}

function Get-PowerShellChannelsManifest {
  [CmdletBinding()]
  param(
    [string] $ManifestPath,

    [string] $RepositoryRoot
  )

  $ResolvedPath = Get-PowerShellChannelsManifestPath -ManifestPath $ManifestPath -RepositoryRoot $RepositoryRoot
  if (-not (Test-Path -LiteralPath $ResolvedPath -PathType Leaf)) {
    throw "PowerShell channels manifest was not found: $ResolvedPath"
  }

  $Raw = Get-Content -LiteralPath $ResolvedPath -Raw | ConvertFrom-Json
  foreach ($TopProperty in @('defaultChannel', 'sdkPackageId', 'sdkVendorName', 'powerShellVendorName', 'channels')) {
    if (-not $Raw.PSObject.Properties[$TopProperty] -or $null -eq $Raw.$TopProperty) {
      throw "PowerShell channels manifest '$ResolvedPath' is missing required property '$TopProperty'."
    }
  }

  $DefaultChannel = ([string] $Raw.defaultChannel).Trim()
  $SdkPackageId = ([string] $Raw.sdkPackageId).Trim()
  $SdkVendorName = ([string] $Raw.sdkVendorName).Trim()
  $PowerShellVendorName = ([string] $Raw.powerShellVendorName).Trim()
  foreach ($NamedValue in @(
      @{ Name = 'defaultChannel'; Value = $DefaultChannel },
      @{ Name = 'sdkPackageId'; Value = $SdkPackageId },
      @{ Name = 'sdkVendorName'; Value = $SdkVendorName },
      @{ Name = 'powerShellVendorName'; Value = $PowerShellVendorName })) {
    if ([string]::IsNullOrWhiteSpace($NamedValue.Value)) {
      throw "PowerShell channels manifest '$ResolvedPath' has an empty '$($NamedValue.Name)'."
    }
  }

  $ChannelProperties = @($Raw.channels.PSObject.Properties)
  if ($ChannelProperties.Count -eq 0) {
    throw "PowerShell channels manifest '$ResolvedPath' does not define any channels."
  }

  $RequiredChannelFields = @(
    'supportTrack',
    'powerShellVersion',
    'powerShellReleaseTag',
    'powerShellUpstreamTag',
    'powerShellSourceRef',
    'submoduleName',
    'submodulePath',
    'targetFramework',
    'sdkPackageRevision',
    'cliSdkPackageVersion',
    'cliSdkPackageRevision',
    'dotnetRuntimeVersion',
    'dotnetRuntimeRef',
    'dotnetGlibcCrossImageX64',
    'dotnetGlibcCrossImageArm64',
    'dotnetMuslCrossImageX64',
    'dotnetMuslCrossImageArm64'
  )

  $Channels = [ordered]@{}
  foreach ($Property in $ChannelProperties) {
    $ChannelKey = $Property.Name.Trim()
    if ($ChannelKey -notmatch '^\d+\.\d+$') {
      throw "Invalid PowerShell channel key '$ChannelKey' in '$ResolvedPath'; expected Major.Minor."
    }

    $Entry = $Property.Value
    foreach ($Field in $RequiredChannelFields) {
      if (-not $Entry.PSObject.Properties[$Field] -or [string]::IsNullOrWhiteSpace([string] $Entry.$Field)) {
        throw "Channel '$ChannelKey' in '$ResolvedPath' is missing required field '$Field'."
      }
    }

    $PowerShellVersion = ([string] $Entry.powerShellVersion).Trim()
    if ($PowerShellVersion -notmatch "^$([regex]::Escape($ChannelKey))\.\d+$") {
      throw "Channel '$ChannelKey' powerShellVersion '$PowerShellVersion' must match '$ChannelKey.<patch>'."
    }

    $ReleaseTag = ([string] $Entry.powerShellReleaseTag).Trim()
    if ($ReleaseTag -ne "v$PowerShellVersion") {
      throw "Channel '$ChannelKey' powerShellReleaseTag '$ReleaseTag' must equal 'v$PowerShellVersion'."
    }

    $UpstreamTag = ([string] $Entry.powerShellUpstreamTag).Trim()
    if ($UpstreamTag -ne "upstream/$ReleaseTag") {
      throw "Channel '$ChannelKey' powerShellUpstreamTag '$UpstreamTag' must equal 'upstream/$ReleaseTag'."
    }

    $SourceRef = ([string] $Entry.powerShellSourceRef).Trim()
    if ($SourceRef -ne "downstream/$ReleaseTag") {
      throw "Channel '$ChannelKey' powerShellSourceRef '$SourceRef' must equal 'downstream/$ReleaseTag'."
    }

    $ExpectedSubmodule = "pwsh-src-$ChannelKey"
    $SubmoduleName = ([string] $Entry.submoduleName).Trim()
    $SubmodulePath = ([string] $Entry.submodulePath).Trim()
    if ($SubmoduleName -ne $ExpectedSubmodule -or $SubmodulePath -ne $ExpectedSubmodule) {
      throw "Channel '$ChannelKey' submoduleName/submodulePath must equal '$ExpectedSubmodule' (found '$SubmoduleName' / '$SubmodulePath')."
    }

    $TargetFramework = ([string] $Entry.targetFramework).Trim()
    if ($TargetFramework -notmatch '^net\d+\.\d+$') {
      throw "Channel '$ChannelKey' targetFramework '$TargetFramework' must match 'net<major>.<minor>'."
    }

    $SdkPackageRevision = ([string] $Entry.sdkPackageRevision).Trim()
    if ($SdkPackageRevision -notmatch '^\d+$') {
      throw "Channel '$ChannelKey' sdkPackageRevision '$SdkPackageRevision' must be numeric."
    }

    $CliSdkPackageRevision = ([string] $Entry.cliSdkPackageRevision).Trim()
    if ($CliSdkPackageRevision -notmatch '^\d+$') {
      throw "Channel '$ChannelKey' cliSdkPackageRevision '$CliSdkPackageRevision' must be numeric."
    }

    $CliSdkPackageVersion = ([string] $Entry.cliSdkPackageVersion).Trim()
    $ExpectedCliSdkVersion = "$PowerShellVersion.$CliSdkPackageRevision"
    if ($CliSdkPackageVersion -ne $ExpectedCliSdkVersion) {
      throw "Channel '$ChannelKey' cliSdkPackageVersion '$CliSdkPackageVersion' must equal '$ExpectedCliSdkVersion'."
    }

    $DotnetRuntimeVersion = ([string] $Entry.dotnetRuntimeVersion).Trim()
    $DotnetRuntimeRef = ([string] $Entry.dotnetRuntimeRef).Trim()
    if ($DotnetRuntimeRef -ne "v$DotnetRuntimeVersion") {
      throw "Channel '$ChannelKey' dotnetRuntimeRef '$DotnetRuntimeRef' must equal 'v$DotnetRuntimeVersion'."
    }

    $Channels[$ChannelKey] = [pscustomobject]@{
      Channel = $ChannelKey
      SupportTrack = ([string] $Entry.supportTrack).Trim()
      PowerShellVersion = $PowerShellVersion
      PowerShellReleaseTag = $ReleaseTag
      PowerShellUpstreamTag = $UpstreamTag
      PowerShellSourceRef = $SourceRef
      SubmoduleName = $SubmoduleName
      SubmodulePath = $SubmodulePath
      TargetFramework = $TargetFramework
      SdkPackageId = $SdkPackageId
      SdkVendorName = $SdkVendorName
      PowerShellVendorName = $PowerShellVendorName
      SdkPackageRevision = $SdkPackageRevision
      SdkPackageVersion = "$PowerShellVersion.$SdkPackageRevision"
      CliSdkPackageVersion = $CliSdkPackageVersion
      CliSdkPackageRevision = $CliSdkPackageRevision
      DotnetRuntimeVersion = $DotnetRuntimeVersion
      DotnetRuntimeRef = $DotnetRuntimeRef
      DotnetGlibcCrossImageX64 = ([string] $Entry.dotnetGlibcCrossImageX64).Trim()
      DotnetGlibcCrossImageArm64 = ([string] $Entry.dotnetGlibcCrossImageArm64).Trim()
      DotnetMuslCrossImageX64 = ([string] $Entry.dotnetMuslCrossImageX64).Trim()
      DotnetMuslCrossImageArm64 = ([string] $Entry.dotnetMuslCrossImageArm64).Trim()
    }
  }

  if (-not $Channels.Contains($DefaultChannel)) {
    throw "Default PowerShell channel '$DefaultChannel' is not defined in '$ResolvedPath' (available: $(@($Channels.Keys) -join ', '))."
  }

  return [pscustomobject]@{
    ManifestPath = (Resolve-Path -LiteralPath $ResolvedPath).Path
    DefaultChannel = $DefaultChannel
    SdkPackageId = $SdkPackageId
    SdkVendorName = $SdkVendorName
    PowerShellVendorName = $PowerShellVendorName
    ChannelNames = @($Channels.Keys)
    Channels = $Channels
  }
}

function Resolve-PowerShellChannelConfig {
  [CmdletBinding()]
  param(
    [string] $Channel,

    [string] $PowerShellVersion,

    [string] $ManifestPath,

    [string] $RepositoryRoot
  )

  $Manifest = Get-PowerShellChannelsManifest -ManifestPath $ManifestPath -RepositoryRoot $RepositoryRoot
  $RequestedChannel = if ($null -eq $Channel) { '' } else { $Channel.Trim() }
  $DerivedChannel = if ([string]::IsNullOrWhiteSpace($PowerShellVersion)) {
    ''
  } else {
    Get-PowerShellChannelFromVersion -VersionText $PowerShellVersion
  }

  if (-not [string]::IsNullOrWhiteSpace($RequestedChannel) -and
      -not [string]::IsNullOrWhiteSpace($DerivedChannel) -and
      $RequestedChannel -ne $DerivedChannel) {
    throw "PowerShell version '$PowerShellVersion' belongs to channel '$DerivedChannel', not requested channel '$RequestedChannel'."
  }

  $EffectiveChannel = if (-not [string]::IsNullOrWhiteSpace($RequestedChannel)) {
    $RequestedChannel
  } elseif (-not [string]::IsNullOrWhiteSpace($DerivedChannel)) {
    $DerivedChannel
  } else {
    $Manifest.DefaultChannel
  }

  if (-not $Manifest.Channels.Contains($EffectiveChannel)) {
    throw "Unsupported PowerShell channel '$EffectiveChannel'. Supported channels: $($Manifest.ChannelNames -join ', ')."
  }

  return $Manifest.Channels[$EffectiveChannel]
}

function Test-ShouldMarkGitHubReleaseLatest {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string] $CandidateVersion,

    [AllowEmptyCollection()]
    [AllowNull()]
    [object[]] $ExistingReleases = @()
  )

  $CandidateParsed = ConvertTo-NormalizedFourPartVersion -VersionText $CandidateVersion
  foreach ($Release in @($ExistingReleases)) {
    if ($null -eq $Release) {
      continue
    }

    $IsDraft = $false
    if ($Release.PSObject.Properties['isDraft'] -and [bool] $Release.isDraft) {
      $IsDraft = $true
    } elseif ($Release.PSObject.Properties['draft'] -and [bool] $Release.draft) {
      $IsDraft = $true
    }

    $IsPrerelease = $false
    if ($Release.PSObject.Properties['isPrerelease'] -and [bool] $Release.isPrerelease) {
      $IsPrerelease = $true
    } elseif ($Release.PSObject.Properties['prerelease'] -and [bool] $Release.prerelease) {
      $IsPrerelease = $true
    }

    if ($IsDraft -or $IsPrerelease) {
      continue
    }

    $TagName = if ($Release.PSObject.Properties['tagName']) {
      [string] $Release.tagName
    } elseif ($Release.PSObject.Properties['tag_name']) {
      [string] $Release.tag_name
    } else {
      [string] $Release
    }

    $TrimmedTag = $TagName.Trim()
    if ($TrimmedTag -notmatch '^v?(?<ver>\d+\.\d+\.\d+(?:\.\d+)?)$') {
      continue
    }

    $ExistingParsed = ConvertTo-NormalizedFourPartVersion -VersionText $Matches['ver']
    if ($ExistingParsed -gt $CandidateParsed) {
      return $false
    }
  }

  return $true
}
