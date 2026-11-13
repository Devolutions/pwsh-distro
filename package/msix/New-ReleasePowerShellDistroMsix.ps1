[CmdletBinding()]
param(
  [string] $ArchiveDirectory,

  [string] $X64PayloadDirectory,

  [string] $Arm64PayloadDirectory,

  [Parameter(Mandatory)]
  [ValidatePattern('^\d+\.\d+\.\d+\.\d+$')]
  [string] $PackageVersion,

  [string] $Repository = $(if ($Env:GITHUB_REPOSITORY) { $Env:GITHUB_REPOSITORY } else { 'Devolutions/pwsh-distro' }),

  [string] $ReleaseTag,

  [string] $OutputDirectory = (Join-Path $PWD 'output\msix'),

  [string] $Publisher,

  [switch] $SignMsix,

  [string] $PsignToolPath = 'psign-tool',

  [string] $PfxPath,

  [string] $PfxPassword
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
  throw 'Release MSIX packaging requires Windows.'
}

$HasArchiveDir = -not [string]::IsNullOrWhiteSpace($ArchiveDirectory)
$HasPayloadDirs = (-not [string]::IsNullOrWhiteSpace($X64PayloadDirectory)) -or (-not [string]::IsNullOrWhiteSpace($Arm64PayloadDirectory))
if ($HasArchiveDir -eq $HasPayloadDirs) {
  throw 'Specify either -ArchiveDirectory OR both -X64PayloadDirectory and -Arm64PayloadDirectory.'
}
if ($HasPayloadDirs -and ([string]::IsNullOrWhiteSpace($X64PayloadDirectory) -or [string]::IsNullOrWhiteSpace($Arm64PayloadDirectory))) {
  throw 'Both -X64PayloadDirectory and -Arm64PayloadDirectory must be provided together.'
}
if (-not [string]::IsNullOrWhiteSpace($PfxPath) -and -not $SignMsix) {
  throw '-PfxPath requires -SignMsix.'
}

function Write-UnsignedProbePeFile {
  param([Parameter(Mandatory)] [string] $Path)

  $Bytes = [byte[]]::new(0x400)
  # DOS header: 'MZ' and e_lfanew = 0x80
  [System.BitConverter]::GetBytes([uint16] 0x5A4D).CopyTo($Bytes, 0x00)
  [System.BitConverter]::GetBytes([int32] 0x80).CopyTo($Bytes, 0x3C)
  # NT Signature 'PE\0\0'
  [System.BitConverter]::GetBytes([uint32] 0x00004550).CopyTo($Bytes, 0x80)
  # COFF FileHeader: Machine=0x8664, NumberOfSections=1, SizeOfOptionalHeader=0xF0, Characteristics=0x0022
  [System.BitConverter]::GetBytes([uint16] 0x8664).CopyTo($Bytes, 0x84)
  [System.BitConverter]::GetBytes([uint16] 1).CopyTo($Bytes, 0x86)
  [System.BitConverter]::GetBytes([uint16] 0x00F0).CopyTo($Bytes, 0x94)
  [System.BitConverter]::GetBytes([uint16] 0x0022).CopyTo($Bytes, 0x96)
  # OptionalHeader PE32+: Magic=0x020B, SectionAlignment=0x1000, FileAlignment=0x200, SizeOfImage=0x2000, SizeOfHeaders=0x200, Subsystem=3, NumberOfRvaAndSizes=16
  [System.BitConverter]::GetBytes([uint16] 0x020B).CopyTo($Bytes, 0x98)
  [System.BitConverter]::GetBytes([uint32] 0x1000).CopyTo($Bytes, 0xB8)
  [System.BitConverter]::GetBytes([uint32] 0x0200).CopyTo($Bytes, 0xBC)
  [System.BitConverter]::GetBytes([uint32] 0x2000).CopyTo($Bytes, 0xD0)
  [System.BitConverter]::GetBytes([uint32] 0x0200).CopyTo($Bytes, 0xD4)
  [System.BitConverter]::GetBytes([uint16] 3).CopyTo($Bytes, 0xDC)
  [System.BitConverter]::GetBytes([uint32] 16).CopyTo($Bytes, 0x104)
  # SectionHeader '.text' at 0x188
  [System.Text.Encoding]::ASCII.GetBytes('.text').CopyTo($Bytes, 0x188)
  [System.BitConverter]::GetBytes([uint32] 0x0200).CopyTo($Bytes, 0x190)
  [System.BitConverter]::GetBytes([uint32] 0x1000).CopyTo($Bytes, 0x194)
  [System.BitConverter]::GetBytes([uint32] 0x0200).CopyTo($Bytes, 0x198)
  [System.BitConverter]::GetBytes([uint32] 0x0200).CopyTo($Bytes, 0x19C)
  [System.BitConverter]::GetBytes([uint32] 0x60000020).CopyTo($Bytes, 0x1AC)
  [System.IO.File]::WriteAllBytes($Path, $Bytes)
}

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

$UsePfxSigning = -not [string]::IsNullOrWhiteSpace($PfxPath)
$SigningArgs = @()
if ($SignMsix) {
  if ($UsePfxSigning) {
    $ResolvedPfxPath = (Resolve-Path -LiteralPath $PfxPath -ErrorAction Stop).Path
    $SigningArgs = @(
      '--mode', 'portable', 'sign',
      '--pfx', $ResolvedPfxPath,
      '--digest', 'sha256',
      '--exit-codes', 'azure'
    )
    if (-not [string]::IsNullOrWhiteSpace($PfxPassword)) {
      $SigningArgs += @('--password', $PfxPassword)
    }
    if (-not [string]::IsNullOrWhiteSpace($Env:CODE_SIGNING_TIMESTAMP_SERVER)) {
      $SigningArgs += @('--timestamp-url', $Env:CODE_SIGNING_TIMESTAMP_SERVER, '--timestamp-digest', 'sha256')
    }
  } else {
    foreach ($Name in @(
      'CODE_SIGNING_KEYVAULT_URL', 'AZURE_TENANT_ID', 'CODE_SIGNING_CLIENT_ID',
      'CODE_SIGNING_CLIENT_SECRET', 'CODE_SIGNING_CERTIFICATE_NAME', 'CODE_SIGNING_TIMESTAMP_SERVER'
    )) {
      if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($Name))) {
        throw "$Name is required to sign an MSIX bundle."
      }
    }
    $SigningArgs = @(
      '--mode', 'portable', 'sign',
      '--azure-key-vault-url', $Env:CODE_SIGNING_KEYVAULT_URL,
      '--azure-key-vault-certificate', $Env:CODE_SIGNING_CERTIFICATE_NAME,
      '--azure-key-vault-client-id', $Env:CODE_SIGNING_CLIENT_ID,
      '--azure-key-vault-client-secret', $Env:CODE_SIGNING_CLIENT_SECRET,
      '--azure-key-vault-tenant-id', $Env:AZURE_TENANT_ID,
      '--timestamp-url', $Env:CODE_SIGNING_TIMESTAMP_SERVER,
      '--timestamp-digest', 'sha256',
      '--digest', 'sha256',
      '--exit-codes', 'azure'
    )
  }
}

$MakeAppxPath = Find-WindowsSdkTool -ToolName 'makeappx.exe'
$ResolvedOutputDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
New-Item -ItemType Directory -Path $ResolvedOutputDirectory -Force | Out-Null

$BundleFileName = "Devolutions.PowerShell-$PackageVersion-win.msixbundle"
$BundlePath = Join-Path $ResolvedOutputDirectory $BundleFileName
$AppInstallerPath = Join-Path $ResolvedOutputDirectory 'Devolutions.PowerShell.appinstaller'
foreach ($ExistingOutput in $BundlePath, $AppInstallerPath) {
  if (Test-Path -LiteralPath $ExistingOutput) {
    throw "MSIX output already exists: $ExistingOutput"
  }
}

$TempBase = if ($Env:RUNNER_TEMP) { $Env:RUNNER_TEMP } else { Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Temp' }
if ([string]::IsNullOrWhiteSpace($TempBase) -or -not (Test-Path -LiteralPath $TempBase -PathType Container)) {
  $TempBase = [System.IO.Path]::GetTempPath()
}
$Work = Join-Path $TempBase "pwsh-distro-release-msix-$([guid]::NewGuid().ToString('N'))"
$BundleInputDirectory = Join-Path $Work 'bundle'
New-Item -ItemType Directory -Path $BundleInputDirectory -Force | Out-Null

try {
  $Payloads = @{}
  if ($HasArchiveDir) {
    $ArchiveRoot = (Resolve-Path -LiteralPath $ArchiveDirectory -ErrorAction Stop).Path
    foreach ($Architecture in 'x64', 'arm64') {
      $ArchivePath = Join-Path $ArchiveRoot "PowerShell-$PackageVersion-windows-$Architecture.tar.gz"
      if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
        throw "Release archive was not found: $ArchivePath"
      }
      $ExtractedDir = Join-Path $Work "payload-$Architecture"
      New-Item -ItemType Directory -Path $ExtractedDir -Force | Out-Null
      & tar -xzf $ArchivePath -C $ExtractedDir
      if ($LASTEXITCODE -ne 0) {
        throw "Unable to extract $ArchivePath."
      }
      $Payloads[$Architecture] = $ExtractedDir
    }
  } else {
    $Payloads['x64'] = (Resolve-Path -LiteralPath $X64PayloadDirectory -ErrorAction Stop).Path
    $Payloads['arm64'] = (Resolve-Path -LiteralPath $Arm64PayloadDirectory -ErrorAction Stop).Path
  }

  if ($SignMsix -and -not $UsePfxSigning) {
    foreach ($Architecture in 'x64', 'arm64') {
      foreach ($BinaryName in 'pwsh.exe', 'pwsh.dll', 'System.Management.Automation.dll') {
        $BinaryPath = Join-Path $Payloads[$Architecture] $BinaryName
        if (-not (Test-Path -LiteralPath $BinaryPath -PathType Leaf)) {
          throw "Expected a signed PowerShell payload in the $Architecture MSIX: $BinaryPath"
        }
        & $PsignToolPath portable verify-pe $BinaryPath
        if ($LASTEXITCODE -ne 0) {
          throw "psign-tool failed to verify the $Architecture MSIX payload $BinaryName with exit code $LASTEXITCODE."
        }
      }
    }
  }

  $EffectivePublisher = ''
  if (-not [string]::IsNullOrWhiteSpace($Publisher)) {
    $EffectivePublisher = $Publisher.Trim()
  } elseif ($SignMsix) {
    # Sign a fresh unsigned PE32+ probe with the exact MSIX signing configuration so Identity/@Publisher
    # always matches the active MSIX signing certificate (never an earlier apphost or OS signature).
    $ProbeBinaryPath = Join-Path $Work 'publisher-probe.exe'
    Write-UnsignedProbePeFile -Path $ProbeBinaryPath
    $ProbeSignOutput = & $PsignToolPath @SigningArgs $ProbeBinaryPath 2>&1
    if ($LASTEXITCODE -ne 0) {
      $ProbeSignOutput | ForEach-Object { Write-Host $_ }
      throw "psign-tool failed to sign publisher probe with exit code $LASTEXITCODE."
    }
    $ProbeSig = Get-AuthenticodeSignature -LiteralPath $ProbeBinaryPath
    Remove-Item -LiteralPath $ProbeBinaryPath -Force -ErrorAction SilentlyContinue
    if ($null -eq $ProbeSig -or $null -eq $ProbeSig.SignerCertificate -or
        [string]::IsNullOrWhiteSpace($ProbeSig.SignerCertificate.Subject)) {
      throw 'Unable to read SignerCertificate.Subject from the signed publisher probe.'
    }
    $EffectivePublisher = $ProbeSig.SignerCertificate.Subject
  } else {
    $X64DllSig = Get-AuthenticodeSignature -LiteralPath (Join-Path $Payloads['x64'] 'pwsh.dll')
    $X64ExeSig = Get-AuthenticodeSignature -LiteralPath (Join-Path $Payloads['x64'] 'pwsh.exe')
    if ($null -ne $X64DllSig.SignerCertificate -and -not [string]::IsNullOrWhiteSpace($X64DllSig.SignerCertificate.Subject)) {
      $EffectivePublisher = $X64DllSig.SignerCertificate.Subject
    } elseif ($null -ne $X64ExeSig.SignerCertificate -and -not [string]::IsNullOrWhiteSpace($X64ExeSig.SignerCertificate.Subject)) {
      $EffectivePublisher = $X64ExeSig.SignerCertificate.Subject
    } else {
      $EffectivePublisher = 'CN=Devolutions Inc.'
    }
  }

  $TemplateManifestPath = Join-Path $PSScriptRoot 'assets\AppxManifest.xml'
  $StampedManifestPath = Join-Path $Work 'Stamped.AppxManifest.xml'
  [xml] $StampedManifest = Get-Content -LiteralPath $TemplateManifestPath -Raw
  $ManifestNs = [System.Xml.XmlNamespaceManager]::new($StampedManifest.NameTable)
  $ManifestNs.AddNamespace('p', 'http://schemas.microsoft.com/appx/manifest/foundation/windows10')
  $ManifestIdentity = $StampedManifest.SelectSingleNode('/p:Package/p:Identity', $ManifestNs)
  $ManifestIdentity.SetAttribute('Publisher', $EffectivePublisher)
  $ManifestIdentity.SetAttribute('Version', $PackageVersion)
  $StampedManifest.Save($StampedManifestPath)

  $AppInstallerArgs = @{
    ManifestPath = $StampedManifestPath
    Repository = $Repository
    BundleFileName = $BundleFileName
    OutputPath = $AppInstallerPath
  }
  if (-not [string]::IsNullOrWhiteSpace($ReleaseTag)) {
    $AppInstallerArgs.ReleaseTag = $ReleaseTag
  }
  & (Join-Path $PSScriptRoot 'New-PowerShellDistroAppInstaller.ps1') @AppInstallerArgs

  foreach ($Architecture in 'x64', 'arm64') {
    & (Join-Path $PSScriptRoot 'New-PowerShellDistroMsix.ps1') `
      -PayloadDirectory $Payloads[$Architecture] `
      -PackageVersion $PackageVersion `
      -Architecture $Architecture `
      -Publisher $EffectivePublisher `
      -AppInstallerPath $AppInstallerPath `
      -OutputDirectory $BundleInputDirectory

    $InnerMsixPath = Join-Path $BundleInputDirectory "Devolutions.PowerShell-$PackageVersion-win-$Architecture.msix"
    if ($SignMsix) {
      & $PsignToolPath @SigningArgs $InnerMsixPath
      if ($LASTEXITCODE -ne 0) {
        throw "psign-tool failed to sign the $Architecture MSIX with exit code $LASTEXITCODE."
      }
      & $PsignToolPath portable verify-msix $InnerMsixPath
      if ($LASTEXITCODE -ne 0) {
        throw "psign-tool failed to verify the $Architecture MSIX with exit code $LASTEXITCODE."
      }
    }
  }

  $ToolOutput = & $MakeAppxPath bundle /o /d $BundleInputDirectory /p $BundlePath /bv $PackageVersion 2>&1
  if ($LASTEXITCODE -ne 0) {
    $ToolOutput | ForEach-Object { Write-Host $_ }
    throw "makeappx bundle failed with exit code $LASTEXITCODE."
  }

  if ($SignMsix) {
    & $PsignToolPath @SigningArgs $BundlePath
    if ($LASTEXITCODE -ne 0) {
      throw "psign-tool failed to sign the MSIX bundle with exit code $LASTEXITCODE."
    }
    & $PsignToolPath portable verify-msix $BundlePath
    if ($LASTEXITCODE -ne 0) {
      throw "psign-tool failed to verify the MSIX bundle with exit code $LASTEXITCODE."
    }

    $BundleSig = Get-AuthenticodeSignature -LiteralPath $BundlePath
    if ($UsePfxSigning) {
      if ($BundleSig.Status -in @('NotSigned', 'HashMismatch') -or $null -eq $BundleSig.SignerCertificate) {
        throw "Windows AppxSip rejected the PFX-signed MSIX bundle ($($BundleSig.Status): $($BundleSig.StatusMessage))."
      }
      if ($BundleSig.SignerCertificate.Subject -cne $EffectivePublisher) {
        throw "MSIX bundle signer '$($BundleSig.SignerCertificate.Subject)' does not match Publisher '$EffectivePublisher'."
      }
    }
  }

  $VerifyArgs = @{
    BundlePath = $BundlePath
    AppInstallerPath = $AppInstallerPath
    PackageVersion = $PackageVersion
  }
  if ($SignMsix -and -not $UsePfxSigning) {
    $VerifyArgs.RequireSignature = $true
  }
  & (Join-Path $PSScriptRoot 'Test-PowerShellDistroMsixPackage.ps1') @VerifyArgs
  Write-Host "Built $BundlePath and $AppInstallerPath"
} finally {
  Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
}
