[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $BundlePath,

  [Parameter(Mandatory)]
  [string] $AppInstallerPath,

  [Parameter(Mandatory)]
  [ValidateSet('x64', 'arm64')]
  [string] $Architecture,

  [string] $PackageVersion,

  [switch] $RequireSignature,

  [switch] $AllowEphemeralTestSigning
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
  throw 'MSIX installation tests require Windows.'
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$MsixRoot = $PSScriptRoot
$ResolvedBundlePath = (Resolve-Path -LiteralPath $BundlePath -ErrorAction Stop).Path
$ResolvedAppInstallerPath = (Resolve-Path -LiteralPath $AppInstallerPath -ErrorAction Stop).Path

if ([string]::IsNullOrWhiteSpace($PackageVersion)) {
  if ([System.IO.Path]::GetFileName($ResolvedBundlePath) -notmatch '^Devolutions-PowerShell-(?<version>\d+\.\d+\.\d+\.\d+)-win\.msixbundle$') {
    throw "Unable to infer four-part package version from MSIX bundle name: $ResolvedBundlePath"
  }
  $PackageVersion = $Matches['version']
}

$VerifyArgs = @{
  BundlePath = $ResolvedBundlePath
  AppInstallerPath = $ResolvedAppInstallerPath
  PackageVersion = $PackageVersion
}
if ($RequireSignature) {
  $VerifyArgs.RequireSignature = $true
}
& (Join-Path $MsixRoot 'Test-PowerShellDistroMsixPackage.ps1') @VerifyArgs

function Find-WindowsSdkTool {
  param([Parameter(Mandatory)] [string] $ToolName)

  $Command = Get-Command -Name $ToolName -CommandType Application -ErrorAction SilentlyContinue
  if ($null -ne $Command) {
    return $Command.Source
  }

  $HostArch = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq [System.Runtime.InteropServices.Architecture]::Arm64) {
    'arm64'
  } else {
    'x64'
  }
  $Candidates = @(
    Get-ChildItem -Path "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\$HostArch\$ToolName" -File -ErrorAction SilentlyContinue |
      Sort-Object FullName -Descending
  )
  if ($Candidates.Count -eq 0 -and $HostArch -ne 'x64') {
    $Candidates = @(
      Get-ChildItem -Path "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\$ToolName" -File -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending
    )
  }
  if ($Candidates.Count -eq 0) {
    throw "Windows SDK tool '$ToolName' was not found under Program Files (x86)\Windows Kits\10\bin."
  }

  return $Candidates[0].FullName
}

function Get-PriorFourPartVersion {
  param([Parameter(Mandatory)] [string] $CurrentVersion)

  $Parsed = [version] $CurrentVersion
  if ($Parsed.Revision -gt 0) {
    return "$($Parsed.Major).$($Parsed.Minor).$($Parsed.Build).$($Parsed.Revision - 1)"
  }
  if ($Parsed.Build -gt 0) {
    return "$($Parsed.Major).$($Parsed.Minor).$($Parsed.Build - 1).0"
  }
  if ($Parsed.Minor -gt 0) {
    return "$($Parsed.Major).$($Parsed.Minor - 1).0.0"
  }
  if ($Parsed.Major -gt 1) {
    return "$($Parsed.Major - 1).0.0.0"
  }
  throw "No prior four-part MSIX version can be derived from '$CurrentVersion'."
}

function Assert-InstalledMsixPackage {
  param(
    [Parameter(Mandatory)] [string] $ExpectedPackageVersion,
    [Parameter(Mandatory)] [string] $ExpectedPowerShellVersion,
    [Parameter(Mandatory)] [string] $ExpectedAppInstallerContent,
    [switch] $CheckPayloadSignatures
  )

  $ExpectedAppxArch = if ($Architecture -eq 'arm64') { 'Arm64' } else { 'X64' }
  $Packages = @(Get-AppxPackage -Name 'Devolutions.PowerShell')
  if ($Packages.Count -ne 1) {
    throw "Expected one installed Devolutions.PowerShell MSIX package, found $($Packages.Count)."
  }

  $Pkg = $Packages[0]
  if ([version] $Pkg.Version -ne [version] $ExpectedPackageVersion) {
    throw "Expected installed MSIX version '$ExpectedPackageVersion', got '$($Pkg.Version)'."
  }
  if ($Pkg.Architecture.ToString() -ine $ExpectedAppxArch) {
    throw "Expected installed MSIX architecture '$ExpectedAppxArch', got '$($Pkg.Architecture)'."
  }

  $InstallDir = $Pkg.InstallLocation
  $InstalledFeedPath = Join-Path $InstallDir 'Update.appinstaller'
  if (-not (Test-Path -LiteralPath $InstalledFeedPath -PathType Leaf)) {
    throw "Installed MSIX is missing Update.appinstaller in $InstallDir."
  }
  $ActualFeedContent = [System.IO.File]::ReadAllText($InstalledFeedPath, [System.Text.Encoding]::UTF8)
  if ($ActualFeedContent -cne $ExpectedAppInstallerContent) {
    throw 'Installed Update.appinstaller does not match the expected App Installer feed.'
  }

  $Exe = Join-Path $InstallDir 'pwsh.exe'
  if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) {
    throw "Installed MSIX is missing pwsh.exe in $InstallDir."
  }
  $ProbeLines = @(& $Exe -NoLogo -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString(); [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()')
  if ($LASTEXITCODE -ne 0 -or $ProbeLines.Count -lt 2) {
    throw "Installed MSIX pwsh.exe failed to run from $InstallDir (exit: $LASTEXITCODE, output: $($ProbeLines -join '; '))."
  }
  if ($ProbeLines[0].Trim() -cne $ExpectedPowerShellVersion) {
    throw "Installed MSIX pwsh.exe reported version '$($ProbeLines[0].Trim())', expected '$ExpectedPowerShellVersion'."
  }
  if ($ProbeLines[1].Trim() -ine $ExpectedAppxArch) {
    throw "Installed MSIX pwsh.exe reported architecture '$($ProbeLines[1].Trim())', expected '$ExpectedAppxArch'."
  }

  if ($CheckPayloadSignatures) {
    foreach ($BinaryName in 'pwsh.exe', 'pwsh.dll', 'System.Management.Automation.dll') {
      $BinaryPath = Join-Path $InstallDir $BinaryName
      $Sig = Get-AuthenticodeSignature -LiteralPath $BinaryPath
      if ($Sig.Status -ne 'Valid') {
        throw "Installed MSIX payload '$BinaryPath' has invalid signature: $($Sig.Status)."
      }
    }
  }

  return $Pkg
}

$Existing = @(Get-AppxPackage -Name 'Devolutions.PowerShell')
if ($Existing.Count -gt 0) {
  throw "Expected a clean runner, but Devolutions.PowerShell is already installed ($($Existing[0].PackageFullName))."
}

$PowerShellVersion = $PackageVersion -replace '\.\d+$', ''
$PublishedFeedContent = [System.IO.File]::ReadAllText($ResolvedAppInstallerPath, [System.Text.Encoding]::UTF8)

$TempBase = if ($Env:RUNNER_TEMP) { $Env:RUNNER_TEMP } else { Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Temp' }
if ([string]::IsNullOrWhiteSpace($TempBase) -or -not (Test-Path -LiteralPath $TempBase -PathType Container)) {
  $TempBase = [System.IO.Path]::GetTempPath()
}
$Work = Join-Path $TempBase "pwsh-distro-msix-install-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $Work -Force | Out-Null
$ImportedCertThumbprint = ''

try {
  if ($RequireSignature) {
    Write-Host "Installing signed MSIX bundle: $ResolvedBundlePath"
    Add-AppxPackage -Path $ResolvedBundlePath
    $Installed = Assert-InstalledMsixPackage `
      -ExpectedPackageVersion $PackageVersion `
      -ExpectedPowerShellVersion $PowerShellVersion `
      -ExpectedAppInstallerContent $PublishedFeedContent `
      -CheckPayloadSignatures
    Remove-AppxPackage -Package $Installed.PackageFullName
    if (@(Get-AppxPackage -Name 'Devolutions.PowerShell').Count -ne 0) {
      throw 'Removing the signed MSIX bundle left Devolutions.PowerShell installed.'
    }
  }

  if ($AllowEphemeralTestSigning) {
    $SignToolPath = Find-WindowsSdkTool -ToolName 'signtool.exe'
    $MakeAppxPath = Find-WindowsSdkTool -ToolName 'makeappx.exe'

    # Extract x64 and arm64 payloads from the bundle using makeappx unbundle/unpack so OPC-encoded entry names round-trip cleanly.
    $ExtractedPayloads = @{}
    $UnpackedBundleDir = Join-Path $Work 'unpacked-bundle'
    $ToolOutput = & $MakeAppxPath unbundle /o /p $ResolvedBundlePath /d $UnpackedBundleDir 2>&1
    if ($LASTEXITCODE -ne 0) {
      $ToolOutput | ForEach-Object { Write-Host $_ }
      throw "makeappx unbundle failed for bundle $ResolvedBundlePath with exit code $LASTEXITCODE."
    }
    [xml] $BundleManifest = Get-Content -LiteralPath (Join-Path $UnpackedBundleDir 'AppxMetadata\AppxBundleManifest.xml') -Raw
    $BundleNs = [System.Xml.XmlNamespaceManager]::new($BundleManifest.NameTable)
    $BundleNs.AddNamespace('b', $BundleManifest.DocumentElement.NamespaceURI)
    foreach ($PkgEntry in @($BundleManifest.SelectNodes("/b:Bundle/b:Packages/b:Package[@Type='application']", $BundleNs))) {
      $Arch = $PkgEntry.GetAttribute('Architecture')
      $InnerMsixPath = Join-Path $UnpackedBundleDir $PkgEntry.GetAttribute('FileName')
      $PayloadDir = Join-Path $Work "payload-$Arch"
      $ToolOutput = & $MakeAppxPath unpack /o /p $InnerMsixPath /d $PayloadDir 2>&1
      if ($LASTEXITCODE -ne 0) {
        $ToolOutput | ForEach-Object { Write-Host $_ }
        throw "makeappx unpack failed for inner MSIX $InnerMsixPath with exit code $LASTEXITCODE."
      }
      foreach ($PackagingArtifact in 'AppxManifest.xml', 'AppxBlockMap.xml', 'AppxSignature.p7x', '[Content_Types].xml', 'resources.pri', 'Update.appinstaller') {
        Remove-Item -LiteralPath (Join-Path $PayloadDir $PackagingArtifact) -Force -ErrorAction SilentlyContinue
      }
      Remove-Item -LiteralPath (Join-Path $PayloadDir 'AppxMetadata') -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath (Join-Path $PayloadDir 'assets') -Recurse -Force -ErrorAction SilentlyContinue
      $ExtractedPayloads[$Arch] = $PayloadDir
    }

    $TestSubject = "CN=Devolutions MSIX Test $([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $Cert = New-SelfSignedCertificate `
      -Type Custom `
      -Subject $TestSubject `
      -KeyUsage DigitalSignature `
      -FriendlyName 'Devolutions PowerShell MSIX Ephemeral Test' `
      -CertStoreLocation 'Cert:\CurrentUser\My' `
      -NotAfter (Get-Date).AddDays(1) `
      -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}')
    $ImportedCertThumbprint = $Cert.Thumbprint
    $PfxPasswordPlain = [guid]::NewGuid().ToString('N')
    $PfxSecure = ConvertTo-SecureString -String $PfxPasswordPlain -Force -AsPlainText
    $PfxPath = Join-Path $Work 'ephemeral.pfx'
    $CerPath = Join-Path $Work 'ephemeral.cer'
    [void] (Export-PfxCertificate -Cert $Cert -FilePath $PfxPath -Password $PfxSecure)
    [void] (Export-Certificate -Cert $Cert -FilePath $CerPath)
    Remove-Item -LiteralPath "Cert:\CurrentUser\My\$ImportedCertThumbprint" -Force -ErrorAction SilentlyContinue
    [void] (Import-Certificate -FilePath $CerPath -CertStoreLocation 'Cert:\LocalMachine\Root')
    [void] (Import-Certificate -FilePath $CerPath -CertStoreLocation 'Cert:\LocalMachine\TrustedPeople')

    $PriorVersion = Get-PriorFourPartVersion -CurrentVersion $PackageVersion
    $Fixtures = @{}
    foreach ($FixtureVersion in $PriorVersion, $PackageVersion) {
      $FixtureDir = Join-Path $Work "fixture-$FixtureVersion"
      & (Join-Path $MsixRoot 'New-ReleasePowerShellDistroMsix.ps1') `
        -X64PayloadDirectory $ExtractedPayloads['x64'] `
        -Arm64PayloadDirectory $ExtractedPayloads['arm64'] `
        -PackageVersion $FixtureVersion `
        -Publisher $TestSubject `
        -OutputDirectory $FixtureDir

      # Sign inner MSIX packages and re-bundle + sign with signtool so Windows Deployment accepts the bundle offline.
      $FixtureBundlePath = Join-Path $FixtureDir "Devolutions-PowerShell-$FixtureVersion-win.msixbundle"
      $RepackDir = Join-Path $FixtureDir 'repack'
      New-Item -ItemType Directory -Path $RepackDir -Force | Out-Null
      $Zip = [System.IO.Compression.ZipFile]::OpenRead($FixtureBundlePath)
      try {
        foreach ($Entry in @($Zip.Entries | Where-Object { $_.FullName -like '*.msix' })) {
          $InnerOut = Join-Path $RepackDir $Entry.Name
          [System.IO.Compression.ZipFileExtensions]::ExtractToFile($Entry, $InnerOut, $true)
          & $SignToolPath sign /q /f $PfxPath /p $PfxPasswordPlain /fd SHA256 $InnerOut
          if ($LASTEXITCODE -ne 0) {
            throw "signtool failed to sign inner fixture MSIX $InnerOut with exit code $LASTEXITCODE."
          }
        }
      } finally {
        $Zip.Dispose()
      }
      $ToolOutput = & $MakeAppxPath bundle /o /d $RepackDir /p $FixtureBundlePath /bv $FixtureVersion 2>&1
      if ($LASTEXITCODE -ne 0) {
        $ToolOutput | ForEach-Object { Write-Host $_ }
        throw "makeappx bundle failed on fixture $FixtureVersion with exit code $LASTEXITCODE."
      }
      & $SignToolPath sign /q /f $PfxPath /p $PfxPasswordPlain /fd SHA256 $FixtureBundlePath
      if ($LASTEXITCODE -ne 0) {
        throw "signtool failed to sign fixture bundle $FixtureBundlePath with exit code $LASTEXITCODE."
      }

      $Fixtures[$FixtureVersion] = @{
        BundlePath = $FixtureBundlePath
        FeedContent = [System.IO.File]::ReadAllText((Join-Path $FixtureDir 'Devolutions-PowerShell.appinstaller'), [System.Text.Encoding]::UTF8)
      }
    }

    Write-Host "Installing prior-version MSIX bundle fixture ($PriorVersion) on $Architecture"
    Add-AppxPackage -Path $Fixtures[$PriorVersion].BundlePath
    [void] (Assert-InstalledMsixPackage `
      -ExpectedPackageVersion $PriorVersion `
      -ExpectedPowerShellVersion $PowerShellVersion `
      -ExpectedAppInstallerContent $Fixtures[$PriorVersion].FeedContent)

    Write-Host "Upgrading MSIX bundle in place ($PriorVersion -> $PackageVersion) on $Architecture"
    Add-AppxPackage -Path $Fixtures[$PackageVersion].BundlePath
    $Upgraded = Assert-InstalledMsixPackage `
      -ExpectedPackageVersion $PackageVersion `
      -ExpectedPowerShellVersion $PowerShellVersion `
      -ExpectedAppInstallerContent $Fixtures[$PackageVersion].FeedContent

    Remove-AppxPackage -Package $Upgraded.PackageFullName
    if (@(Get-AppxPackage -Name 'Devolutions.PowerShell').Count -ne 0) {
      throw 'Uninstalling upgraded MSIX bundle left Devolutions.PowerShell installed.'
    }
  }

  Write-Host "Passed MSIX installation and upgrade verification for $Architecture ($PackageVersion)."
} finally {
  foreach ($Leftover in @(Get-AppxPackage -Name 'Devolutions.PowerShell' -ErrorAction SilentlyContinue)) {
    Remove-AppxPackage -Package $Leftover.PackageFullName -ErrorAction SilentlyContinue
  }
  if (-not [string]::IsNullOrWhiteSpace($ImportedCertThumbprint)) {
    Remove-Item -LiteralPath "Cert:\LocalMachine\Root\$ImportedCertThumbprint" -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath "Cert:\LocalMachine\TrustedPeople\$ImportedCertThumbprint" -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath "Cert:\CurrentUser\My\$ImportedCertThumbprint" -Force -ErrorAction SilentlyContinue
  }
  Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
}
