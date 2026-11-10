Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'LinuxElf.ps1')
. (Join-Path $PSScriptRoot 'LinuxAppHost.ps1')

function New-TestElf {
  param(
    [string] $Path,
    [int] $Machine,
    [AllowEmptyString()]
    [string] $Interpreter
  )

  $Stream = [System.IO.File]::Create($Path)
  $Writer = [System.IO.BinaryWriter]::new($Stream)
  try {
    $Writer.Write([byte[]](0x7F, 0x45, 0x4C, 0x46, 2, 1, 1))
    $Stream.Position = 0x10
    $Writer.Write([uint16] 3)
    $Writer.Write([uint16] $Machine)
    $Stream.Position = 0x20
    $Writer.Write([uint64] 64)
    $Stream.Position = 0x36
    $Writer.Write([uint16] 56)
    $Writer.Write([uint16] 1)
    $Stream.Position = 64
    $ProgramHeaderType = if ($Interpreter) { 3 } else { 1 }
    $Writer.Write([uint32] $ProgramHeaderType)
    $Stream.Position = 72
    $Writer.Write([uint64] 120)
    $Bytes = [System.Text.Encoding]::ASCII.GetBytes("$Interpreter`0")
    $Stream.Position = 96
    $Writer.Write([uint64] $Bytes.Length)
    $Stream.Position = 120
    $Writer.Write($Bytes)
  } finally {
    $Writer.Dispose()
  }
}

function New-TestPackage {
  param([string] $Path, [string] $Architecture)

  $HostDirectory = Join-Path $Path "tools/apphost/linux-$Architecture"
  $DistroDirectory = Join-Path $Path "buildTransitive/powershell-distro-payload/linux-$Architecture"
  New-Item -ItemType Directory -Path $HostDirectory, $DistroDirectory -Force | Out-Null
  foreach ($File in 'pwsh', 'pwsh.dll', 'pwsh.runtimeconfig.json') {
    Set-Content -LiteralPath (Join-Path $HostDirectory $File) -Value $File
  }
  Set-Content -LiteralPath (Join-Path $DistroDirectory 'pwsh.xml') -Value 'documentation'
}

function Assert-Throws {
  param([scriptblock] $Action, [string] $Message)

  try {
    & $Action
  } catch {
    if ($_.Exception.Message -like "*$Message*") {
      return
    }
    throw "Expected an error containing '$Message', got: $_"
  }
  throw "Expected an error containing '$Message'."
}

$WorkRoot = Join-Path ([System.IO.Path]::GetTempPath()) "linux-apphost-test-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $WorkRoot | Out-Null
try {
  $Cases = @(
    @{ Rid = 'linux-x64'; Arch = 'x64'; Machine = 0x3E; Interpreter = '/lib64/ld-linux-x86-64.so.2' },
    @{ Rid = 'linux-arm64'; Arch = 'arm64'; Machine = 0xB7; Interpreter = '/lib/ld-linux-aarch64.so.1' },
    @{ Rid = 'linux-musl-x64'; Arch = 'x64'; Machine = 0x3E; Interpreter = '/lib/ld-musl-x86_64.so.1' },
    @{ Rid = 'linux-musl-arm64'; Arch = 'arm64'; Machine = 0xB7; Interpreter = '/lib/ld-musl-aarch64.so.1' }
  )
  foreach ($Case in $Cases) {
    $ElfPath = Join-Path $WorkRoot "$($Case.Rid).elf"
    $PackageRoot = Join-Path $WorkRoot "sdk-$($Case.Rid)"
    New-TestElf -Path $ElfPath -Machine $Case.Machine -Interpreter $Case.Interpreter
    New-TestPackage -Path $PackageRoot -Architecture $Case.Arch
    Set-LinuxAppHost -PackageRoot $PackageRoot -Rid $Case.Rid -AppHostPath $ElfPath

    $AppHostDirectory = Join-Path $PackageRoot "tools/apphost/$($Case.Rid)"
    $StagedHost = Join-Path $AppHostDirectory 'pwsh'
    if ((Get-FileHash -LiteralPath $StagedHost).Hash -ne (Get-FileHash -LiteralPath $ElfPath).Hash -or
        -not (Test-Path -LiteralPath (Join-Path $AppHostDirectory 'pwsh.dll') -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $AppHostDirectory 'pwsh.runtimeconfig.json') -PathType Leaf)) {
      throw "Apphost staging failed for $($Case.Rid)."
    }
    if ($Case.Rid -like 'linux-musl-*' -and
        -not (Test-Path -LiteralPath (Join-Path $PackageRoot "buildTransitive/powershell-distro-payload/$($Case.Rid)/pwsh.xml") -PathType Leaf)) {
      throw "Distro payload staging failed for $($Case.Rid)."
    }
  }

  $PackageRoot = Join-Path $WorkRoot 'invalid-sdk'
  New-TestPackage -Path $PackageRoot -Architecture 'arm64'
  $ArmMusl = Join-Path $WorkRoot 'linux-musl-arm64.elf'
  $X64Musl = Join-Path $WorkRoot 'linux-musl-x64.elf'
  $ArmGlibc = Join-Path $WorkRoot 'linux-arm64.elf'
  Assert-Throws { Set-LinuxAppHost -PackageRoot $PackageRoot -Rid 'linux-musl-arm64' -AppHostPath $X64Musl } 'architecture'
  Assert-Throws { Set-LinuxAppHost -PackageRoot $PackageRoot -Rid 'linux-musl-arm64' -AppHostPath $ArmGlibc } 'interpreter'
  Assert-Throws { Set-LinuxAppHost -PackageRoot $PackageRoot -Rid 'win-arm64' -AppHostPath $ArmMusl } 'cannot be used'

  $NoInterpreter = Join-Path $WorkRoot 'no-interpreter.elf'
  New-TestElf -Path $NoInterpreter -Machine 0xB7 -Interpreter ''
  Assert-Throws { Set-LinuxAppHost -PackageRoot $PackageRoot -Rid 'linux-musl-arm64' -AppHostPath $NoInterpreter } 'interpreter'

  $BadHeaders = Join-Path $WorkRoot 'bad-headers.elf'
  Copy-Item -LiteralPath $ArmMusl -Destination $BadHeaders
  $Stream = [System.IO.File]::OpenWrite($BadHeaders)
  try { $Stream.SetLength(80) } finally { $Stream.Dispose() }
  Assert-Throws { Get-LinuxElfInfo -Path $BadHeaders } 'program headers'

  Remove-Item -LiteralPath (Join-Path $PackageRoot 'tools/apphost/linux-arm64/pwsh.dll')
  Assert-Throws { Set-LinuxAppHost -PackageRoot $PackageRoot -Rid 'linux-musl-arm64' -AppHostPath $ArmMusl } 'apphost payload'
  New-TestPackage -Path $PackageRoot -Architecture 'arm64'
  Remove-Item -LiteralPath (Join-Path $PackageRoot 'buildTransitive/powershell-distro-payload/linux-arm64/pwsh.xml')
  Assert-Throws { Set-LinuxAppHost -PackageRoot $PackageRoot -Rid 'linux-musl-arm64' -AppHostPath $ArmMusl } 'distro payload'

  if ($IsLinux) {
    $PayloadRoot = Join-Path $WorkRoot 'package-payload'
    New-Item -ItemType Directory -Path $PayloadRoot | Out-Null
    foreach ($File in 'pwsh.dll', 'LICENSE.txt', 'ThirdPartyNotices.txt') {
      Set-Content -LiteralPath (Join-Path $PayloadRoot $File) -Value $File
    }
    Copy-Item -LiteralPath $ArmGlibc -Destination (Join-Path $PayloadRoot 'pwsh')
    foreach ($File in 'libhostfxr.so', 'libhostpolicy.so', 'libcoreclr.so', 'libSystem.Native.so', 'libSystem.Security.Cryptography.Native.OpenSsl.so') {
      New-TestElf -Path (Join-Path $PayloadRoot $File) -Machine 0xB7 -Interpreter ''
    }
    New-TestElf -Path (Join-Path $PayloadRoot 'libpsl-native.so') -Machine 0x3E -Interpreter ''
    $PackageScript = Join-Path $PSScriptRoot '../package/linux/New-PowerShellDistroLinuxPackage.ps1'
    $PackageArguments = @{
      PayloadDirectory = $PayloadRoot
      PackageVersion = '7.6.9.2'
      Architecture = 'arm64'
      Distribution = 'deb'
      OutputDirectory = (Join-Path $WorkRoot 'packages')
    }
    Assert-Throws { & $PackageScript @PackageArguments } 'architecture'
    Remove-Item -LiteralPath (Join-Path $PayloadRoot 'libhostfxr.so')
    Assert-Throws { & $PackageScript @PackageArguments } 'missing libhostfxr.so'
  }

  if ($IsLinux -or $IsMacOS) {
    $RegistryRoot = Join-Path $WorkRoot 'registry'
    $CrateRoot = Join-Path $RegistryRoot 'index/example-1.0.0'
    $LicenseRoot = Join-Path $WorkRoot 'licenses'
    $RustLibraryNotice = Join-Path $WorkRoot 'COPYRIGHT-library.html'
    New-Item -ItemType Directory -Path $CrateRoot -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $CrateRoot 'Cargo.toml') -Value 'license = "MIT"'
    Set-Content -LiteralPath (Join-Path $CrateRoot 'LICENSE-MIT') -Value 'example license'
    Set-Content -LiteralPath (Join-Path $CrateRoot 'COPYRIGHT') -Value 'example copyright'
    Set-Content -LiteralPath $RustLibraryNotice -Value 'Rust standard library notice'
    New-Item -ItemType Directory -Path (Join-Path $CrateRoot 'third_party/example') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $CrateRoot 'third_party/example/LICENSE') -Value 'nested license'
    New-Item -ItemType Directory -Path (Join-Path $CrateRoot 'third_party/LICENSES') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $CrateRoot 'third_party/LICENSES/Apache-2.0.txt') -Value 'nested SPDX license'
    $Collector = Join-Path $PSScriptRoot 'Collect-RustLicenseFiles.sh'
    & sh $Collector $RegistryRoot $LicenseRoot $RustLibraryNotice
    if ($LASTEXITCODE -ne 0 -or
        -not (Test-Path -LiteralPath (Join-Path $LicenseRoot 'example-1.0.0/Cargo.toml') -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $LicenseRoot 'example-1.0.0/LICENSE-MIT') -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $LicenseRoot 'example-1.0.0/COPYRIGHT') -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $LicenseRoot 'rust-standard-library/COPYRIGHT-library.html') -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $LicenseRoot 'example-1.0.0/third_party/LICENSES/Apache-2.0.txt') -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $LicenseRoot 'example-1.0.0/third_party/example/LICENSE') -PathType Leaf)) {
      throw 'Rust license collection failed.'
    }
    $DuplicateOutput = & sh $Collector $RegistryRoot $LicenseRoot $RustLibraryNotice 2>&1
    if ($LASTEXITCODE -eq 0 -or $DuplicateOutput -notmatch 'destination must not exist') {
      throw 'Rust license collection did not reject an existing destination.'
    }
    $MissingNoticeRoot = Join-Path $WorkRoot 'missing-notice-licenses'
    $MissingNoticeOutput = & sh $Collector $RegistryRoot $MissingNoticeRoot (Join-Path $WorkRoot 'missing-notice.html') 2>&1
    if ($LASTEXITCODE -eq 0 -or $MissingNoticeOutput -notmatch 'notice must exist' -or
        (Test-Path -LiteralPath $MissingNoticeRoot)) {
      throw 'Rust license collection did not reject a missing standard-library notice.'
    }
  }

  Write-Host 'Linux apphost ELF and SDK staging tests passed.'
} finally {
  Remove-Item -LiteralPath $WorkRoot -Recurse -Force
}
