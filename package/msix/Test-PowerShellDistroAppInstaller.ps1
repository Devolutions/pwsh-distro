[CmdletBinding()]
param(
  [string] $PsignToolPath
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$MsixRoot = $PSScriptRoot
$Generator = Join-Path $MsixRoot 'New-PowerShellDistroAppInstaller.ps1'
$Verifier = Join-Path $MsixRoot 'Test-PowerShellDistroMsixPackage.ps1'
$InstallVerifier = Join-Path $MsixRoot 'Test-PowerShellDistroMsixInstall.ps1'
$ReleaseBuilder = Join-Path $MsixRoot 'New-ReleasePowerShellDistroMsix.ps1'
$TemplateManifestPath = Join-Path $MsixRoot 'assets\AppxManifest.xml'

$TempBase = if ($Env:RUNNER_TEMP) { $Env:RUNNER_TEMP } else { Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Temp' }
if ([string]::IsNullOrWhiteSpace($TempBase) -or -not (Test-Path -LiteralPath $TempBase -PathType Container)) {
  $TempBase = [System.IO.Path]::GetTempPath()
}
$Directory = Join-Path $TempBase "pwsh-distro-appinstaller-test-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $Directory -Force | Out-Null

function Assert-True {
  param(
    [Parameter(Mandatory)] [bool] $Condition,
    [Parameter(Mandatory)] [string] $Message
  )

  if (-not $Condition) {
    throw $Message
  }
}

function Assert-Fails {
  param(
    [Parameter(Mandatory)] [scriptblock] $Action,
    [Parameter(Mandatory)] [string] $Message
  )

  $Failed = $false
  try {
    & $Action
  } catch {
    $Failed = $true
  }
  Assert-True -Condition $Failed -Message $Message
}

function New-MinimalPeBytes {
  param([Parameter(Mandatory)] [uint16] $Machine)

  $Bytes = [byte[]]::new(128)
  # 'MZ'
  $Bytes[0] = 0x4D
  $Bytes[1] = 0x5A
  # e_lfanew = 0x40
  $Bytes[0x3C] = 0x40
  # 'PE\0\0'
  $Bytes[0x40] = 0x50
  $Bytes[0x41] = 0x45
  $Bytes[0x42] = 0x00
  $Bytes[0x43] = 0x00
  # Machine (little-endian)
  $MachineBytes = [System.BitConverter]::GetBytes($Machine)
  $Bytes[0x44] = $MachineBytes[0]
  $Bytes[0x45] = $MachineBytes[1]
  return $Bytes
}

try {
  $ManifestPath = Join-Path $Directory 'AppxManifest.xml'
  [xml] $Manifest = Get-Content -LiteralPath $TemplateManifestPath -Raw
  $Ns = [System.Xml.XmlNamespaceManager]::new($Manifest.NameTable)
  $Ns.AddNamespace('p', 'http://schemas.microsoft.com/appx/manifest/foundation/windows10')
  $Ns.AddNamespace('uap13', 'http://schemas.microsoft.com/appx/manifest/uap/windows10/13')

  $Identity = $Manifest.SelectSingleNode('/p:Package/p:Identity', $Ns)
  $Publisher = 'CN=Test & Release, O="Example", OID.1.3.6.1.4.1.311.60.2.1.3=CA, SERIALNUMBER=1162544689'
  $Identity.SetAttribute('Publisher', $Publisher)
  $Identity.SetAttribute('Version', '7.6.10.0')
  $Manifest.Save($ManifestPath)

  $FeedPath = Join-Path $Directory 'Devolutions-PowerShell.appinstaller'
  & $Generator -ManifestPath $ManifestPath -Repository 'Devolutions/pwsh-distro' -OutputPath $FeedPath

  [xml] $FeedDoc = Get-Content -LiteralPath $FeedPath -Raw
  $FeedRoot = $FeedDoc.DocumentElement
  $FeedNs = [System.Xml.XmlNamespaceManager]::new($FeedDoc.NameTable)
  $FeedNs.AddNamespace('ai', 'http://schemas.microsoft.com/appx/appinstaller/2021')
  $MainBundle = $FeedRoot.SelectSingleNode('ai:MainBundle', $FeedNs)

  Assert-True ($FeedRoot.NamespaceURI -ceq 'http://schemas.microsoft.com/appx/appinstaller/2021') 'Wrong App Installer schema.'
  Assert-True ($FeedRoot.GetAttribute('Version') -ceq '7.6.10.0') 'Wrong feed version.'
  Assert-True ($FeedRoot.GetAttribute('Uri') -ceq 'https://github.com/Devolutions/pwsh-distro/releases/latest/download/Devolutions-PowerShell.appinstaller') 'Feed URI must use the stable latest-release download URL.'
  Assert-True ($null -ne $MainBundle) 'MainBundle must be present.'
  Assert-True ($null -eq $FeedRoot.SelectSingleNode('ai:MainPackage', $FeedNs)) 'MainPackage must not be present.'
  Assert-True (-not $MainBundle.HasAttribute('ProcessorArchitecture')) 'MainBundle must not select a single architecture.'
  Assert-True ($MainBundle.GetAttribute('Name') -ceq 'Devolutions.PowerShell') 'Wrong package identity Name.'
  Assert-True ($MainBundle.GetAttribute('Publisher') -ceq $Publisher) 'Publisher XML escaping did not round-trip.'
  Assert-True ($MainBundle.GetAttribute('Version') -ceq '7.6.10.0') 'Wrong MainBundle version.'
  Assert-True ($MainBundle.GetAttribute('Uri') -ceq 'https://github.com/Devolutions/pwsh-distro/releases/download/v7.6.10.0/Devolutions-PowerShell-7.6.10.0-win.msixbundle') 'Bundle URI must be pinned to the release tag.'

  $OnLaunch = $FeedRoot.SelectSingleNode('ai:UpdateSettings/ai:OnLaunch', $FeedNs)
  Assert-True ($null -ne $OnLaunch) 'OnLaunch must be present.'
  Assert-True ($OnLaunch.GetAttribute('HoursBetweenUpdateChecks') -ceq '0') 'Must check on every launch.'
  Assert-True ($OnLaunch.GetAttribute('ShowPrompt') -ceq 'false') 'Updates must be silent.'
  Assert-True ($OnLaunch.GetAttribute('UpdateBlocksActivation') -ceq 'false') 'Updates must not block activation.'
  Assert-True ($null -ne $FeedRoot.SelectSingleNode('ai:UpdateSettings/ai:AutomaticBackgroundTask', $FeedNs)) 'Background updates must be enabled.'
  Assert-True ($null -eq $FeedRoot.SelectSingleNode('ai:UpdateSettings/ai:ForceUpdateFromAnyVersion', $FeedNs)) 'Downgrades must not be enabled.'

  # Verify feed URI stability across revision and channel bumps, and URL escaping of custom tags.
  foreach ($NextVersion in '7.6.10.1', '7.7.0.0', '65535.65535.65535.65535') {
    $Identity.SetAttribute('Version', $NextVersion)
    $Manifest.Save($ManifestPath)
    & $Generator -ManifestPath $ManifestPath -Repository 'Devolutions/pwsh-distro' -OutputPath $FeedPath
    [xml] $NextDoc = Get-Content -LiteralPath $FeedPath -Raw
    $NextBundle = $NextDoc.DocumentElement.SelectSingleNode('ai:MainBundle', $FeedNs)
    Assert-True ($NextDoc.DocumentElement.GetAttribute('Uri') -ceq $FeedRoot.GetAttribute('Uri')) "Feed URI must stay constant across version $NextVersion."
    Assert-True ($NextBundle.GetAttribute('Uri') -ceq "https://github.com/Devolutions/pwsh-distro/releases/download/v$NextVersion/Devolutions-PowerShell-$NextVersion-win.msixbundle") "MainBundle URI did not update for $NextVersion."
  }

  $Identity.SetAttribute('Version', '7.6.10.1')
  $Manifest.Save($ManifestPath)
  & $Generator -ManifestPath $ManifestPath -Repository 'Devolutions/pwsh-distro' -ReleaseTag 'release/v7.6.10.1' -OutputPath $FeedPath
  [xml] $EscapedTagDoc = Get-Content -LiteralPath $FeedPath -Raw
  $EscapedBundle = $EscapedTagDoc.DocumentElement.SelectSingleNode('ai:MainBundle', $FeedNs)
  Assert-True ($EscapedBundle.GetAttribute('Uri') -ceq 'https://github.com/Devolutions/pwsh-distro/releases/download/release%2Fv7.6.10.1/Devolutions-PowerShell-7.6.10.1-win.msixbundle') 'Custom release tags must be URL-escaped.'

  # Restore 7.6.10.1 default tag feed for bundle verification tests.
  & $Generator -ManifestPath $ManifestPath -Repository 'Devolutions/pwsh-distro' -OutputPath $FeedPath

  $DummyFilesDir = Join-Path $Directory 'dummy-files'
  New-Item -ItemType Directory -Path $DummyFilesDir -Force | Out-Null
  foreach ($TextFile in 'pwsh.dll', 'System.Management.Automation.dll', 'LICENSE.txt', 'ThirdPartyNotices.txt', 'resources.pri') {
    Set-Content -LiteralPath (Join-Path $DummyFilesDir $TextFile) -Value 'placeholder' -Encoding utf8
  }
  $X64ExePath = Join-Path $DummyFilesDir 'pwsh-x64.exe'
  $Arm64ExePath = Join-Path $DummyFilesDir 'pwsh-arm64.exe'
  [System.IO.File]::WriteAllBytes($X64ExePath, (New-MinimalPeBytes -Machine 0x8664))
  [System.IO.File]::WriteAllBytes($Arm64ExePath, (New-MinimalPeBytes -Machine 0xAA64))

  [xml] $BundleManifest = '<Bundle xmlns="http://schemas.microsoft.com/appx/2013/bundle"><Identity Name="" Publisher="" Version=""/><Packages/></Bundle>'
  foreach ($Attr in 'Name', 'Publisher', 'Version') {
    $BundleManifest.Bundle.Identity.SetAttribute($Attr, $Identity.GetAttribute($Attr))
  }

  function Write-InnerMsix {
    param(
      [string] $Architecture,
      [string] $ExePath,
      [xml] $CustomManifest = $Manifest
    )

    $InnerIdentity = $CustomManifest.SelectSingleNode('/p:Package/p:Identity', $Ns)
    $InnerIdentity.SetAttribute('ProcessorArchitecture', $Architecture)
    $CustomManifest.Save($ManifestPath)
    $InnerMsixPath = Join-Path $Directory "$Architecture.msix"
    if (Test-Path -LiteralPath $InnerMsixPath) {
      Remove-Item -LiteralPath $InnerMsixPath -Force
    }
    $Archive = [System.IO.Compression.ZipFile]::Open($InnerMsixPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
      [void] [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($Archive, $ManifestPath, 'AppxManifest.xml')
      [void] [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($Archive, $FeedPath, 'Update.appinstaller')
      [void] [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($Archive, $ExePath, 'pwsh.exe')
      foreach ($File in 'pwsh.dll', 'System.Management.Automation.dll', 'LICENSE.txt', 'ThirdPartyNotices.txt', 'resources.pri') {
        [void] [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($Archive, (Join-Path $DummyFilesDir $File), $File)
      }
      foreach ($Logo in 'StoreLogo.png', 'Square150x150Logo.png', 'Square44x44Logo.png', 'Square44x44Logo.targetsize-48.png', 'Square44x44Logo.targetsize-48_altform-unplated.png') {
        [void] [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($Archive, (Join-Path $MsixRoot "assets\$Logo"), "assets/$Logo")
      }
    } finally {
      $Archive.Dispose()
    }
  }

  foreach ($Architecture in 'x64', 'arm64') {
    $Exe = if ($Architecture -eq 'x64') { $X64ExePath } else { $Arm64ExePath }
    Write-InnerMsix -Architecture $Architecture -ExePath $Exe
    $PkgEntry = $BundleManifest.CreateElement('Package', $BundleManifest.DocumentElement.NamespaceURI)
    $PkgEntry.SetAttribute('Type', 'application')
    $PkgEntry.SetAttribute('Architecture', $Architecture)
    $PkgEntry.SetAttribute('Version', '7.6.10.1')
    $PkgEntry.SetAttribute('FileName', "$Architecture.msix")
    [void] $BundleManifest.Bundle.SelectSingleNode("*[local-name()='Packages']").AppendChild($PkgEntry)
  }

  $BundleManifestPath = Join-Path $Directory 'AppxBundleManifest.xml'
  function New-SyntheticBundle {
    param([string] $FileName = 'Devolutions-PowerShell-7.6.10.1-win.msixbundle')
    $BundleManifest.Save($BundleManifestPath)
    $OutBundle = Join-Path $Directory $FileName
    if (Test-Path -LiteralPath $OutBundle) {
      Remove-Item -LiteralPath $OutBundle -Force
    }
    $Archive = [System.IO.Compression.ZipFile]::Open($OutBundle, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
      [void] [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($Archive, $BundleManifestPath, 'AppxMetadata/AppxBundleManifest.xml')
      foreach ($Arch in 'x64', 'arm64') {
        $Candidate = Join-Path $Directory "$Arch.msix"
        if (Test-Path -LiteralPath $Candidate) {
          [void] [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($Archive, $Candidate, "$Arch.msix")
        }
      }
    } finally {
      $Archive.Dispose()
    }
    return $OutBundle
  }

  $BundlePath = New-SyntheticBundle
  & $Verifier -BundlePath $BundlePath -AppInstallerPath $FeedPath -PackageVersion '7.6.10.1'

  # Negative verifier checks
  Assert-Fails { & $Verifier -BundlePath (New-SyntheticBundle -FileName 'WrongName.msixbundle') -AppInstallerPath $FeedPath } 'Must reject mismatched bundle file name.'

  [xml] $TamperedFeed = Get-Content -LiteralPath $FeedPath -Raw
  $TamperedNs = [System.Xml.XmlNamespaceManager]::new($TamperedFeed.NameTable)
  $TamperedNs.AddNamespace('ai', 'http://schemas.microsoft.com/appx/appinstaller/2021')
  $TamperedFeed.DocumentElement.SelectSingleNode('ai:MainBundle', $TamperedNs).SetAttribute('Version', '7.6.10.2')
  $TamperedFeedPath = Join-Path $Directory 'Tampered.appinstaller'
  $TamperedFeed.Save($TamperedFeedPath)
  Assert-Fails { & $Verifier -BundlePath $BundlePath -AppInstallerPath $TamperedFeedPath } 'Must reject mismatched feed/bundle versions.'

  [xml] $TamperedFeed = Get-Content -LiteralPath $FeedPath -Raw
  $TamperedNs = [System.Xml.XmlNamespaceManager]::new($TamperedFeed.NameTable)
  $TamperedNs.AddNamespace('ai', 'http://schemas.microsoft.com/appx/appinstaller/2021')
  $TamperedFeed.DocumentElement.SelectSingleNode('ai:UpdateSettings/ai:OnLaunch', $TamperedNs).SetAttribute('HoursBetweenUpdateChecks', '8')
  $TamperedFeed.Save($TamperedFeedPath)
  Assert-Fails { & $Verifier -BundlePath $BundlePath -AppInstallerPath $TamperedFeedPath } 'Must reject embedded vs published feed mismatch.'

  # Wrong PE architecture inside arm64 MSIX
  Write-InnerMsix -Architecture 'arm64' -ExePath $X64ExePath
  $BundlePath = New-SyntheticBundle
  Assert-Fails { & $Verifier -BundlePath $BundlePath -AppInstallerPath $FeedPath } 'Must reject mismatched PE architecture.'

  # Missing uap13:AutoUpdate reference
  [xml] $NoAutoUpdateManifest = $Manifest.OuterXml
  $NoAutoUpdateNs = [System.Xml.XmlNamespaceManager]::new($NoAutoUpdateManifest.NameTable)
  $NoAutoUpdateNs.AddNamespace('p', 'http://schemas.microsoft.com/appx/manifest/foundation/windows10')
  $NoAutoUpdateNs.AddNamespace('uap13', 'http://schemas.microsoft.com/appx/manifest/uap/windows10/13')
  $AutoNode = $NoAutoUpdateManifest.SelectSingleNode('/p:Package/p:Properties/uap13:AutoUpdate', $NoAutoUpdateNs)
  [void] $AutoNode.ParentNode.RemoveChild($AutoNode)
  Write-InnerMsix -Architecture 'arm64' -ExePath $Arm64ExePath -CustomManifest $NoAutoUpdateManifest
  $BundlePath = New-SyntheticBundle
  Assert-Fails { & $Verifier -BundlePath $BundlePath -AppInstallerPath $FeedPath } 'Must reject missing uap13:AutoUpdate.'
  Write-InnerMsix -Architecture 'arm64' -ExePath $Arm64ExePath

  # Duplicate / mismatched / missing bundled packages
  $SecondPackage = @($BundleManifest.Bundle.Packages.Package)[1]
  $SecondPackage.SetAttribute('Architecture', 'x64')
  $BundlePath = New-SyntheticBundle
  Assert-Fails { & $Verifier -BundlePath $BundlePath -AppInstallerPath $FeedPath } 'Must reject duplicate architectures.'

  $SecondPackage.SetAttribute('Architecture', 'arm64')
  $SecondPackage.SetAttribute('Version', '7.6.10.2')
  $BundlePath = New-SyntheticBundle
  Assert-Fails { & $Verifier -BundlePath $BundlePath -AppInstallerPath $FeedPath } 'Must reject mismatched bundled package version.'

  $SecondPackage.SetAttribute('Version', '7.6.10.1')
  $SecondPackage.SetAttribute('FileName', 'missing.msix')
  $BundlePath = New-SyntheticBundle
  Assert-Fails { & $Verifier -BundlePath $BundlePath -AppInstallerPath $FeedPath } 'Must reject missing bundled package entry.'

  [void] $BundleManifest.Bundle.Packages.RemoveChild($SecondPackage)
  $BundlePath = New-SyntheticBundle
  Assert-Fails { & $Verifier -BundlePath $BundlePath -AppInstallerPath $FeedPath } 'Must require both x64 and arm64 application packages.'

  # Negative generator checks
  $InvalidFeedPath = Join-Path $Directory 'invalid.appinstaller'
  Assert-Fails { & $Generator -ManifestPath $ManifestPath -Repository 'invalid/repo/path' -OutputPath $InvalidFeedPath } 'Must reject invalid repository.'
  foreach ($InvalidVersion in '65536.0.0.0', '0.65536.0.0', '01.2.3.0', '7.6.10', 'invalid') {
    $Identity.SetAttribute('Version', $InvalidVersion)
    $Manifest.Save($ManifestPath)
    Assert-Fails { & $Generator -ManifestPath $ManifestPath -Repository 'Devolutions/pwsh-distro' -OutputPath $InvalidFeedPath } "Must reject invalid version '$InvalidVersion'."
  }

  if ($IsWindows) {
    $X64Payload = Join-Path $Directory 'payload-x64'
    $Arm64Payload = Join-Path $Directory 'payload-arm64'
    New-Item -ItemType Directory -Path $X64Payload, $Arm64Payload -Force | Out-Null
    foreach ($TargetDir in $X64Payload, $Arm64Payload) {
      foreach ($File in 'pwsh.dll', 'System.Management.Automation.dll', 'LICENSE.txt', 'ThirdPartyNotices.txt') {
        Copy-Item -LiteralPath (Join-Path $DummyFilesDir $File) -Destination (Join-Path $TargetDir $File) -Force
      }
    }

    # Build clean unsigned signable PE32+ executables for x64 (0x8664) and arm64 (0xAA64).
    foreach ($Entry in @(@{ Arch = 'x64'; Machine = [uint16] 0x8664; Dir = $X64Payload }, @{ Arch = 'arm64'; Machine = [uint16] 0xAA64; Dir = $Arm64Payload })) {
      $PeBytes = [byte[]]::new(0x400)
      [System.BitConverter]::GetBytes([uint16] 0x5A4D).CopyTo($PeBytes, 0x00)
      [System.BitConverter]::GetBytes([int32] 0x80).CopyTo($PeBytes, 0x3C)
      [System.BitConverter]::GetBytes([uint32] 0x00004550).CopyTo($PeBytes, 0x80)
      [System.BitConverter]::GetBytes([uint16] $Entry.Machine).CopyTo($PeBytes, 0x84)
      [System.BitConverter]::GetBytes([uint16] 1).CopyTo($PeBytes, 0x86)
      [System.BitConverter]::GetBytes([uint16] 0x00F0).CopyTo($PeBytes, 0x94)
      [System.BitConverter]::GetBytes([uint16] 0x0022).CopyTo($PeBytes, 0x96)
      [System.BitConverter]::GetBytes([uint16] 0x020B).CopyTo($PeBytes, 0x98)
      [System.BitConverter]::GetBytes([uint32] 0x1000).CopyTo($PeBytes, 0xB8)
      [System.BitConverter]::GetBytes([uint32] 0x0200).CopyTo($PeBytes, 0xBC)
      [System.BitConverter]::GetBytes([uint32] 0x2000).CopyTo($PeBytes, 0xD0)
      [System.BitConverter]::GetBytes([uint32] 0x0200).CopyTo($PeBytes, 0xD4)
      [System.BitConverter]::GetBytes([uint16] 3).CopyTo($PeBytes, 0xDC)
      [System.BitConverter]::GetBytes([uint32] 16).CopyTo($PeBytes, 0x104)
      [System.Text.Encoding]::ASCII.GetBytes('.text').CopyTo($PeBytes, 0x188)
      [System.BitConverter]::GetBytes([uint32] 0x0200).CopyTo($PeBytes, 0x190)
      [System.BitConverter]::GetBytes([uint32] 0x1000).CopyTo($PeBytes, 0x194)
      [System.BitConverter]::GetBytes([uint32] 0x0200).CopyTo($PeBytes, 0x198)
      [System.BitConverter]::GetBytes([uint32] 0x0200).CopyTo($PeBytes, 0x19C)
      [System.BitConverter]::GetBytes([uint32] 0x60000020).CopyTo($PeBytes, 0x1AC)
      [System.IO.File]::WriteAllBytes((Join-Path $Entry.Dir 'pwsh.exe'), $PeBytes)
    }

    # Verify relative OutputDirectory resolution after Push-Location (where $PWD differs from [Environment]::CurrentDirectory).
    Push-Location $Directory
    try {
      & $ReleaseBuilder `
        -X64PayloadDirectory '.\payload-x64' `
        -Arm64PayloadDirectory '.\payload-arm64' `
        -PackageVersion '7.6.10.1' `
        -Repository 'Devolutions/pwsh-distro' `
        -OutputDirectory '.\out-unsigned'
    } finally {
      Pop-Location
    }
    $UnsignedOut = Join-Path $Directory 'out-unsigned'
    Assert-True (Test-Path -LiteralPath (Join-Path $UnsignedOut 'Devolutions-PowerShell-7.6.10.1-win.msixbundle') -PathType Leaf) 'Relative OutputDirectory must resolve against $PWD.'

    Assert-Fails {
      & $InstallVerifier `
        -BundlePath (Join-Path $UnsignedOut 'Devolutions-PowerShell-7.6.10.1-win.msixbundle') `
        -AppInstallerPath (Join-Path $UnsignedOut 'Devolutions-PowerShell.appinstaller') `
        -Architecture 'x64'
    } 'Test-PowerShellDistroMsixInstall.ps1 must reject invocations that omit both -RequireSignature and -AllowEphemeralTestSigning.'

    # Verify makeappx unbundle + unpack round-trip used by Test-PowerShellDistroMsixInstall.ps1.
    $HostArch = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq [System.Runtime.InteropServices.Architecture]::Arm64) { 'arm64' } else { 'x64' }
    $MakeAppxCandidates = @(Get-ChildItem -Path "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\$HostArch\makeappx.exe" -File | Sort-Object FullName -Descending)
    if ($MakeAppxCandidates.Count -gt 0) {
      $MakeAppxExe = $MakeAppxCandidates[0].FullName
      $UnbundledDir = Join-Path $Directory 'unbundled-check'
      & $MakeAppxExe unbundle /o /p (Join-Path $UnsignedOut 'Devolutions-PowerShell-7.6.10.1-win.msixbundle') /d $UnbundledDir *> $null
      Assert-True ($LASTEXITCODE -eq 0) 'makeappx unbundle must extract the generated MSIX bundle.'
      $UnpackedX64Dir = Join-Path $Directory 'unpacked-x64-check'
      & $MakeAppxExe unpack /o /p (Join-Path $UnbundledDir 'Devolutions-PowerShell-7.6.10.1-win-x64.msix') /d $UnpackedX64Dir *> $null
      Assert-True ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath (Join-Path $UnpackedX64Dir 'pwsh.exe') -PathType Leaf)) 'makeappx unpack must extract inner MSIX payload.'
    }

    if (-not [string]::IsNullOrWhiteSpace($PsignToolPath)) {
      # Pre-sign pwsh.exe with an older subject to ensure signed MSIX packaging derives Identity/@Publisher
      # from the active MSIX signing certificate rather than an older apphost signature.
      $LegacyRsa = [System.Security.Cryptography.RSA]::Create(2048)
      $LegacyReq = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
        'CN=Devolutions Inc, O=Devolutions Inc', $LegacyRsa, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
      $LegacyEku = [System.Security.Cryptography.OidCollection]::new()
      [void] $LegacyEku.Add([System.Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.3'))
      $LegacyReq.CertificateExtensions.Add([System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($LegacyEku, $false))
      $LegacyCert = $LegacyReq.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-5), [DateTimeOffset]::UtcNow.AddDays(1))
      $LegacyPfxPath = Join-Path $Directory 'legacy-apphost.pfx'
      [System.IO.File]::WriteAllBytes($LegacyPfxPath, $LegacyCert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, 'legacypass'))
      foreach ($ExeToPreSign in (Join-Path $X64Payload 'pwsh.exe'), (Join-Path $Arm64Payload 'pwsh.exe')) {
        & $PsignToolPath --mode portable sign --pfx $LegacyPfxPath --password 'legacypass' --digest sha256 $ExeToPreSign
        Assert-True ($LASTEXITCODE -eq 0) 'Pre-signing pwsh.exe with legacy apphost cert must succeed.'
      }

      $EvSubject = 'E=security@devolutions.net, CN=DEVOLUTIONS INC., O=DEVOLUTIONS INC., L=Lavaltrie, S=Quebec, C=CA, OID.1.3.6.1.4.1.311.60.2.1.2=Quebec, OID.1.3.6.1.4.1.311.60.2.1.3=CA, SERIALNUMBER=1162544689, OID.2.5.4.15=Private Organization'
      $X500 = [System.Security.Cryptography.X509Certificates.X500DistinguishedName]::new($EvSubject)
      $Rsa = [System.Security.Cryptography.RSA]::Create(2048)
      $Req = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
        $X500, $Rsa, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
      $Eku = [System.Security.Cryptography.OidCollection]::new()
      [void] $Eku.Add([System.Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.3'))
      $Req.CertificateExtensions.Add([System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($Eku, $false))
      $Req.CertificateExtensions.Add([System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($false, $false, 0, $true))
      $Req.CertificateExtensions.Add([System.Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new([System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature, $true))
      $Cert = $Req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-5), [DateTimeOffset]::UtcNow.AddDays(1))
      $PfxPath = Join-Path $Directory 'test-ev.pfx'
      [System.IO.File]::WriteAllBytes($PfxPath, $Cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, 'testpass'))

      $SignedOut = Join-Path $Directory 'out-signed'
      & $ReleaseBuilder `
        -X64PayloadDirectory $X64Payload `
        -Arm64PayloadDirectory $Arm64Payload `
        -PackageVersion '7.6.10.1' `
        -Repository 'Devolutions/pwsh-distro' `
        -OutputDirectory $SignedOut `
        -SignMsix `
        -PsignToolPath $PsignToolPath `
        -PfxPath $PfxPath `
        -PfxPassword 'testpass'

      [xml] $SignedFeed = Get-Content -LiteralPath (Join-Path $SignedOut 'Devolutions-PowerShell.appinstaller') -Raw
      $SignedMainBundle = $SignedFeed.DocumentElement.SelectSingleNode("*[local-name()='MainBundle']")
      Assert-True ($SignedMainBundle.GetAttribute('Publisher') -ceq $EvSubject) 'Signed MSIX feed Publisher must match the active MSIX signing certificate, not legacy pwsh.exe.'
    }
  }

  Write-Host 'App Installer generation and MSIX bundle verification tests passed.'
} finally {
  Remove-Item -LiteralPath $Directory -Recurse -Force -ErrorAction SilentlyContinue
}
