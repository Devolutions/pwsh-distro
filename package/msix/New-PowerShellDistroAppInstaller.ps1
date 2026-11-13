[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $ManifestPath,

  [string] $Repository = 'Devolutions/pwsh-distro',

  [string] $ReleaseTag,

  [string] $BundleFileName,

  [string] $FeedFileName = 'Devolutions.PowerShell.appinstaller',

  [Parameter(Mandatory)]
  [string] $OutputPath
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
  throw "Expected an owner/repository name, got '$Repository'."
}
if ([string]::IsNullOrWhiteSpace($FeedFileName) -or $FeedFileName -match '[/\\]') {
  throw "Invalid App Installer feed file name: '$FeedFileName'."
}
if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
  throw "AppxManifest.xml was not found: $ManifestPath"
}

[xml] $Manifest = Get-Content -LiteralPath $ManifestPath -Raw
$Namespaces = [System.Xml.XmlNamespaceManager]::new($Manifest.NameTable)
$Namespaces.AddNamespace('p', 'http://schemas.microsoft.com/appx/manifest/foundation/windows10')
$Identity = $Manifest.SelectSingleNode('/p:Package/p:Identity', $Namespaces)
if ($null -eq $Identity) {
  throw "Package Identity element was not found in $ManifestPath."
}

$Name = $Identity.GetAttribute('Name')
$Publisher = $Identity.GetAttribute('Publisher')
$VersionText = $Identity.GetAttribute('Version')
if ([string]::IsNullOrWhiteSpace($Name) -or
    [string]::IsNullOrWhiteSpace($Publisher) -or
    $VersionText -notmatch '^\d{1,5}\.\d{1,5}\.\d{1,5}\.\d{1,5}$') {
  throw 'The package manifest must contain a non-empty Name, Publisher, and four-part Version (major.minor.build.revision).'
}

$Version = [version] $VersionText
if ("$($Version.Major).$($Version.Minor).$($Version.Build).$($Version.Revision)" -cne $VersionText) {
  throw "MSIX version components must not contain leading zeros: '$VersionText'."
}
if ($Version.Major -gt 65535 -or $Version.Minor -gt 65535 -or $Version.Build -gt 65535 -or $Version.Revision -gt 65535) {
  throw "MSIX version components must not exceed 65535: '$VersionText'."
}

$EffectiveReleaseTag = if ([string]::IsNullOrWhiteSpace($ReleaseTag)) { "v$VersionText" } else { $ReleaseTag.Trim() }
$EffectiveBundleFileName = if ([string]::IsNullOrWhiteSpace($BundleFileName)) {
  "Devolutions.PowerShell-$VersionText-win.msixbundle"
} else {
  $BundleFileName.Trim()
}
if ($EffectiveBundleFileName -match '[/\\]') {
  throw "Invalid MSIX bundle file name: '$EffectiveBundleFileName'."
}

$EscapedTag = [uri]::EscapeDataString($EffectiveReleaseTag)
$EscapedFeedName = [uri]::EscapeDataString($FeedFileName)
$EscapedBundleName = [uri]::EscapeDataString($EffectiveBundleFileName)
$BaseUri = "https://github.com/$Repository/releases"
$Namespace = 'http://schemas.microsoft.com/appx/appinstaller/2021'

$Document = [xml]::new()
[void] $Document.AppendChild($Document.CreateXmlDeclaration('1.0', 'utf-8', $null))
$Installer = $Document.CreateElement('AppInstaller', $Namespace)
$Installer.SetAttribute('Version', $VersionText)
$Installer.SetAttribute('Uri', "$BaseUri/latest/download/$EscapedFeedName")
[void] $Document.AppendChild($Installer)

$MainBundle = $Document.CreateElement('MainBundle', $Namespace)
$MainBundle.SetAttribute('Name', $Name)
$MainBundle.SetAttribute('Publisher', $Publisher)
$MainBundle.SetAttribute('Version', $VersionText)
$MainBundle.SetAttribute('Uri', "$BaseUri/download/$EscapedTag/$EscapedBundleName")
[void] $Installer.AppendChild($MainBundle)

$UpdateSettings = $Document.CreateElement('UpdateSettings', $Namespace)
$OnLaunch = $Document.CreateElement('OnLaunch', $Namespace)
$OnLaunch.SetAttribute('HoursBetweenUpdateChecks', '0')
$OnLaunch.SetAttribute('ShowPrompt', 'false')
$OnLaunch.SetAttribute('UpdateBlocksActivation', 'false')
[void] $UpdateSettings.AppendChild($OnLaunch)
[void] $UpdateSettings.AppendChild($Document.CreateElement('AutomaticBackgroundTask', $Namespace))
[void] $Installer.AppendChild($UpdateSettings)

$ResolvedOutput = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
$OutputDir = [System.IO.Path]::GetDirectoryName($ResolvedOutput)
if (-not [string]::IsNullOrWhiteSpace($OutputDir)) {
  [void] [System.IO.Directory]::CreateDirectory($OutputDir)
}

$WriterSettings = [System.Xml.XmlWriterSettings]::new()
$WriterSettings.Encoding = [System.Text.UTF8Encoding]::new($false)
$WriterSettings.Indent = $true
$Writer = [System.Xml.XmlWriter]::Create($ResolvedOutput, $WriterSettings)
try {
  $Document.Save($Writer)
} finally {
  $Writer.Dispose()
}

Write-Host "Created $ResolvedOutput"
