[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $BundlePath,

  [Parameter(Mandatory)]
  [string] $AppInstallerPath,

  [string] $PackageVersion,

  [switch] $RequireSignature
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Read-ZipTextEntry {
  param(
    [Parameter(Mandatory)]
    [System.IO.Compression.ZipArchive] $Archive,

    [Parameter(Mandatory)]
    [string] $EntryName
  )

  $Entry = $Archive.GetEntry($EntryName)
  if ($null -eq $Entry) {
    throw "Missing package entry: $EntryName."
  }

  $Reader = [System.IO.StreamReader]::new($Entry.Open(), [System.Text.Encoding]::UTF8, $true)
  try {
    return $Reader.ReadToEnd()
  } finally {
    $Reader.Dispose()
  }
}

function Assert-PackageIdentity {
  param(
    [Parameter(Mandatory)]
    [System.Xml.XmlElement] $Identity,

    [Parameter(Mandatory)]
    [System.Xml.XmlElement] $Expected,

    [Parameter(Mandatory)]
    [string] $Context
  )

  foreach ($Attribute in 'Name', 'Publisher', 'Version') {
    $ActualValue = $Identity.GetAttribute($Attribute)
    $ExpectedValue = $Expected.GetAttribute($Attribute)
    if ($ActualValue -cne $ExpectedValue) {
      throw "$Context identity mismatch on '$Attribute': expected '$ExpectedValue', got '$ActualValue'."
    }
  }
}

function Get-ZipPeMachine {
  param(
    [Parameter(Mandatory)]
    [System.IO.Compression.ZipArchive] $Archive,

    [Parameter(Mandatory)]
    [string] $EntryName
  )

  $Entry = $Archive.GetEntry($EntryName)
  if ($null -eq $Entry) {
    throw "Missing PE entry: $EntryName."
  }

  $Memory = [System.IO.MemoryStream]::new()
  try {
    $Source = $Entry.Open()
    try {
      $Source.CopyTo($Memory)
    } finally {
      $Source.Dispose()
    }
    $Memory.Position = 0
    $Reader = [System.IO.BinaryReader]::new($Memory)
    if ($Memory.Length -lt 0x40 -or $Reader.ReadUInt16() -ne 0x5A4D) {
      throw "Invalid MZ header in packaged $EntryName."
    }
    $Memory.Position = 0x3C
    $PeOffset = $Reader.ReadInt32()
    if ($PeOffset -lt 0x40 -or $PeOffset -gt $Memory.Length - 6) {
      throw "Invalid PE offset in packaged $EntryName."
    }
    $Memory.Position = $PeOffset
    if ($Reader.ReadUInt32() -ne 0x00004550) {
      throw "Invalid PE signature in packaged $EntryName."
    }
    return $Reader.ReadUInt16()
  } finally {
    $Memory.Dispose()
  }
}

if (-not (Test-Path -LiteralPath $BundlePath -PathType Leaf)) {
  throw "MSIX bundle was not found: $BundlePath"
}
if (-not (Test-Path -LiteralPath $AppInstallerPath -PathType Leaf)) {
  throw "App Installer file was not found: $AppInstallerPath"
}

$ResolvedBundlePath = (Resolve-Path -LiteralPath $BundlePath).Path
$ResolvedAppInstallerPath = (Resolve-Path -LiteralPath $AppInstallerPath).Path
$PublishedFeedContent = [System.IO.File]::ReadAllText($ResolvedAppInstallerPath, [System.Text.Encoding]::UTF8)

[xml] $InstallerXml = $PublishedFeedContent
$FeedRoot = $InstallerXml.DocumentElement
if ($null -eq $FeedRoot -or
    $FeedRoot.LocalName -cne 'AppInstaller' -or
    $FeedRoot.NamespaceURI -cne 'http://schemas.microsoft.com/appx/appinstaller/2021') {
  throw 'The App Installer feed must use root element AppInstaller in namespace http://schemas.microsoft.com/appx/appinstaller/2021.'
}

$FeedNs = [System.Xml.XmlNamespaceManager]::new($InstallerXml.NameTable)
$FeedNs.AddNamespace('ai', 'http://schemas.microsoft.com/appx/appinstaller/2021')

$MainBundle = $FeedRoot.SelectSingleNode('ai:MainBundle', $FeedNs)
$MainPackage = $FeedRoot.SelectSingleNode('ai:MainPackage', $FeedNs)
if ($null -eq $MainBundle -or $null -ne $MainPackage) {
  throw 'The App Installer feed must describe a MainBundle and must not contain MainPackage.'
}
if ($MainBundle.HasAttribute('ProcessorArchitecture')) {
  throw 'MainBundle must not restrict ProcessorArchitecture.'
}

$FeedVersion = $FeedRoot.GetAttribute('Version')
if ([string]::IsNullOrWhiteSpace($FeedVersion) -or $MainBundle.GetAttribute('Version') -cne $FeedVersion) {
  throw 'The App Installer Version and MainBundle Version must match.'
}
if (-not [string]::IsNullOrWhiteSpace($PackageVersion) -and $FeedVersion -cne $PackageVersion) {
  throw "Expected App Installer version '$PackageVersion', got '$FeedVersion'."
}
if ($MainBundle.GetAttribute('Name') -cne 'Devolutions.PowerShell') {
  throw "Unexpected MSIX package identity Name '$($MainBundle.GetAttribute('Name'))'."
}

$FeedUri = [uri] $FeedRoot.GetAttribute('Uri')
if ($FeedUri.Scheme -cne 'https' -or $FeedUri.AbsolutePath -notmatch '/releases/latest/download/Devolutions-PowerShell\.appinstaller$') {
  throw "App Installer Uri must point to the stable latest-release feed URL, got '$($FeedRoot.GetAttribute('Uri'))'."
}

$BundleUri = [uri] $MainBundle.GetAttribute('Uri')
if ($BundleUri.Scheme -cne 'https' -or $BundleUri.AbsolutePath -notmatch '/releases/download/[^/]+/[^/]+\.msixbundle$') {
  throw "MainBundle Uri must point to a tag-pinned GitHub release MSIX bundle, got '$($MainBundle.GetAttribute('Uri'))'."
}
$UriBundleFileName = [uri]::UnescapeDataString($BundleUri.Segments[-1])
if ($UriBundleFileName -cne [System.IO.Path]::GetFileName($ResolvedBundlePath)) {
  throw "MainBundle Uri file name '$UriBundleFileName' does not match bundle '$([System.IO.Path]::GetFileName($ResolvedBundlePath))'."
}

$OnLaunch = $FeedRoot.SelectSingleNode('ai:UpdateSettings/ai:OnLaunch', $FeedNs)
if ($null -eq $OnLaunch -or
    $OnLaunch.GetAttribute('HoursBetweenUpdateChecks') -cne '0' -or
    $OnLaunch.GetAttribute('ShowPrompt') -cne 'false' -or
    $OnLaunch.GetAttribute('UpdateBlocksActivation') -cne 'false') {
  throw 'App Installer OnLaunch must configure silent non-blocking checks on every launch.'
}
if ($null -eq $FeedRoot.SelectSingleNode('ai:UpdateSettings/ai:AutomaticBackgroundTask', $FeedNs)) {
  throw 'App Installer UpdateSettings must enable AutomaticBackgroundTask.'
}
if ($null -ne $FeedRoot.SelectSingleNode('ai:UpdateSettings/ai:ForceUpdateFromAnyVersion', $FeedNs)) {
  throw 'App Installer UpdateSettings must not enable ForceUpdateFromAnyVersion.'
}

if ($RequireSignature) {
  if (-not $IsWindows) {
    throw 'Authenticode verification of MSIX bundles requires Windows.'
  }
  $BundleSignature = Get-AuthenticodeSignature -LiteralPath $ResolvedBundlePath
  if ($BundleSignature.Status -ne 'Valid' -or $null -eq $BundleSignature.SignerCertificate) {
    throw "MSIX bundle signature is not valid: $ResolvedBundlePath ($($BundleSignature.Status): $($BundleSignature.StatusMessage))."
  }
  if ($BundleSignature.SignerCertificate.Subject -cne $MainBundle.GetAttribute('Publisher')) {
    throw "MSIX bundle signer '$($BundleSignature.SignerCertificate.Subject)' does not match Publisher '$($MainBundle.GetAttribute('Publisher'))'."
  }
}

$RequiredInnerEntries = @(
  'pwsh.exe',
  'pwsh.dll',
  'System.Management.Automation.dll',
  'LICENSE.txt',
  'ThirdPartyNotices.txt',
  'resources.pri',
  'Update.appinstaller',
  'assets/StoreLogo.png',
  'assets/Square150x150Logo.png',
  'assets/Square44x44Logo.png',
  'assets/Square44x44Logo.targetsize-48.png',
  'assets/Square44x44Logo.targetsize-48_altform-unplated.png'
)

$BundleArchive = [System.IO.Compression.ZipFile]::OpenRead($ResolvedBundlePath)
try {
  if ($RequireSignature -and $null -eq $BundleArchive.GetEntry('AppxSignature.p7x')) {
    throw "Signed MSIX bundle is missing AppxSignature.p7x: $ResolvedBundlePath"
  }

  [xml] $BundleManifest = Read-ZipTextEntry -Archive $BundleArchive -EntryName 'AppxMetadata/AppxBundleManifest.xml'
  $BundleNs = [System.Xml.XmlNamespaceManager]::new($BundleManifest.NameTable)
  $BundleNs.AddNamespace('b', $BundleManifest.DocumentElement.NamespaceURI)
  $BundleIdentity = $BundleManifest.SelectSingleNode('/b:Bundle/b:Identity', $BundleNs)
  if ($null -eq $BundleIdentity) {
    throw 'AppxBundleManifest.xml is missing Bundle/Identity.'
  }
  Assert-PackageIdentity -Identity $BundleIdentity -Expected $MainBundle -Context 'Bundle'

  $ApplicationPackages = @($BundleManifest.SelectNodes("/b:Bundle/b:Packages/b:Package[@Type='application']", $BundleNs))
  $Architectures = [System.Collections.Generic.List[string]]::new()
  foreach ($PackageEntry in $ApplicationPackages) {
    $Architecture = $PackageEntry.GetAttribute('Architecture')
    if ($Architecture -notin @('x64', 'arm64') -or $Architectures.Contains($Architecture)) {
      throw "Unexpected or duplicate application architecture in MSIX bundle: '$Architecture'."
    }
    $Architectures.Add($Architecture) | Out-Null

    if ($PackageEntry.GetAttribute('Version') -cne $FeedVersion) {
      throw "Bundled $Architecture MSIX version '$($PackageEntry.GetAttribute('Version'))' does not match '$FeedVersion'."
    }

    $FileName = $PackageEntry.GetAttribute('FileName')
    $InnerZipEntry = $BundleArchive.GetEntry($FileName)
    if ($null -eq $InnerZipEntry) {
      throw "Missing bundled application package '$FileName' in $ResolvedBundlePath."
    }

    $InnerStream = [System.IO.MemoryStream]::new()
    try {
      $SourceStream = $InnerZipEntry.Open()
      try {
        $SourceStream.CopyTo($InnerStream)
      } finally {
        $SourceStream.Dispose()
      }
      $InnerStream.Position = 0
      $InnerArchive = [System.IO.Compression.ZipArchive]::new($InnerStream, [System.IO.Compression.ZipArchiveMode]::Read, $true)
      try {
        if ($RequireSignature -and $null -eq $InnerArchive.GetEntry('AppxSignature.p7x')) {
          throw "Signed inner MSIX '$FileName' is missing AppxSignature.p7x."
        }

        foreach ($RequiredEntry in $RequiredInnerEntries) {
          if ($null -eq $InnerArchive.GetEntry($RequiredEntry)) {
            throw "Bundled $Architecture MSIX '$FileName' is missing '$RequiredEntry'."
          }
        }

        $ExpectedMachine = if ($Architecture -eq 'x64') { 0x8664 } else { 0xAA64 }
        $ActualMachine = Get-ZipPeMachine -Archive $InnerArchive -EntryName 'pwsh.exe'
        if ($ActualMachine -ne $ExpectedMachine) {
          throw "Bundled $Architecture MSIX pwsh.exe machine 0x$($ActualMachine.ToString('X4')) does not match expected 0x$($ExpectedMachine.ToString('X4'))."
        }

        [xml] $InnerManifest = Read-ZipTextEntry -Archive $InnerArchive -EntryName 'AppxManifest.xml'
        $InnerNs = [System.Xml.XmlNamespaceManager]::new($InnerManifest.NameTable)
        $InnerNs.AddNamespace('p', 'http://schemas.microsoft.com/appx/manifest/foundation/windows10')
        $InnerNs.AddNamespace('uap3', 'http://schemas.microsoft.com/appx/manifest/uap/windows10/3')
        $InnerNs.AddNamespace('uap13', 'http://schemas.microsoft.com/appx/manifest/uap/windows10/13')
        $InnerNs.AddNamespace('uap17', 'http://schemas.microsoft.com/appx/manifest/uap/windows10/17')
        $InnerNs.AddNamespace('desktop', 'http://schemas.microsoft.com/appx/manifest/desktop/windows10')

        $InnerIdentity = $InnerManifest.SelectSingleNode('/p:Package/p:Identity', $InnerNs)
        if ($null -eq $InnerIdentity) {
          throw "Bundled $Architecture AppxManifest.xml is missing Package/Identity."
        }
        Assert-PackageIdentity -Identity $InnerIdentity -Expected $MainBundle -Context "Bundled $Architecture MSIX"
        if ($InnerIdentity.GetAttribute('ProcessorArchitecture') -cne $Architecture) {
          throw "Bundled $Architecture MSIX ProcessorArchitecture mismatch: '$($InnerIdentity.GetAttribute('ProcessorArchitecture'))'."
        }

        $EmbeddedFeedContent = Read-ZipTextEntry -Archive $InnerArchive -EntryName 'Update.appinstaller'
        if ($EmbeddedFeedContent -cne $PublishedFeedContent) {
          throw "Embedded Update.appinstaller in $Architecture MSIX differs from the published App Installer feed."
        }

        $AutoUpdateRef = $InnerManifest.SelectSingleNode('/p:Package/p:Properties/uap13:AutoUpdate/uap13:AppInstaller', $InnerNs)
        if ($null -eq $AutoUpdateRef -or $AutoUpdateRef.GetAttribute('File') -cne 'Update.appinstaller') {
          throw "Bundled $Architecture AppxManifest.xml must reference Update.appinstaller via uap13:AutoUpdate."
        }

        $UpdateWhileInUse = $InnerManifest.SelectSingleNode('/p:Package/p:Properties/uap17:UpdateWhileInUse', $InnerNs)
        if ($null -eq $UpdateWhileInUse -or $UpdateWhileInUse.InnerText -cne 'defer') {
          throw "Bundled $Architecture AppxManifest.xml must set uap17:UpdateWhileInUse to 'defer'."
        }

        $AliasNode = $InnerManifest.SelectSingleNode('/p:Package/p:Applications/p:Application/p:Extensions/uap3:Extension/uap3:AppExecutionAlias/desktop:ExecutionAlias', $InnerNs)
        if ($null -eq $AliasNode -or $AliasNode.GetAttribute('Alias') -cne 'pwsh.exe') {
          throw "Bundled $Architecture AppxManifest.xml must declare the pwsh.exe AppExecutionAlias."
        }
      } finally {
        $InnerArchive.Dispose()
      }
    } finally {
      $InnerStream.Dispose()
    }
  }

  foreach ($RequiredArch in 'x64', 'arm64') {
    if (-not $Architectures.Contains($RequiredArch)) {
      throw "The MSIX bundle is missing the $RequiredArch application package."
    }
  }
} finally {
  $BundleArchive.Dispose()
}

Write-Host "Validated MSIX bundle and App Installer update configuration: $ResolvedBundlePath"
