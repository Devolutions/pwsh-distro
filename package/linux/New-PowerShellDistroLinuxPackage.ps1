[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $PayloadDirectory,

  [Parameter(Mandatory)]
  [ValidatePattern('^\d+\.\d+\.\d+\.\d+$')]
  [string] $PackageVersion,

  [Parameter(Mandatory)]
  [ValidateSet('x64', 'arm64')]
  [string] $Architecture,

  [Parameter(Mandatory)]
  [ValidateSet('deb', 'rh', 'cm', 'azl4')]
  [string] $Distribution,

  [Parameter(Mandatory)]
  [string] $OutputDirectory,

  [ValidatePattern('^\d+$')]
  [string] $Iteration = '1'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if (-not $IsLinux) {
  throw 'Linux packaging requires Linux.'
}

. (Join-Path $PSScriptRoot '../../eng/LinuxElf.ps1')

function Invoke-NativeCommand {
  param(
    [Parameter(Mandatory)]
    [string] $FilePath,

    [Parameter(ValueFromRemainingArguments)]
    [string[]] $Arguments
  )

  & $FilePath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "$FilePath $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
  }
}

function Format-Indented {
  param([string] $Text, [int] $Spaces)
  $Prefix = ' ' * $Spaces
  return (($Text -replace "`r", '') -split "`n" | ForEach-Object { if ($_) { "$Prefix$_" } else { $_ } }) -join "`n"
}

function Write-UnixTextFile {
  param([string] $Path, [string] $Content)
  [System.IO.File]::WriteAllText($Path, (($Content -replace "`r", '').TrimEnd("`n") + "`n"))
}

$PackageName = 'devolutions-powershell'
$InstallDirectory = '/opt/devolutions/powershell/7'
$LinkPath = '/usr/bin/pwsh'
$Maintainer = 'Devolutions Inc. <support@devolutions.net>'
$Homepage = 'https://github.com/Devolutions/pwsh-distro'
$Summary = 'PowerShell - Cross-platform automation and configuration tool/framework (Devolutions distribution)'
$DescriptionLines = @(
  'PowerShell is an automation and configuration management platform.',
  'It consists of a cross-platform command-line shell and associated scripting language.',
  'This package contains the Devolutions PowerShell distribution built from Devolutions.PowerShell.SDK.'
)

$Payload = (Resolve-Path -LiteralPath $PayloadDirectory -ErrorAction Stop).Path.TrimEnd('/')
$NativeLibraries = @(
  'libpsl-native.so',
  'libhostfxr.so',
  'libhostpolicy.so',
  'libcoreclr.so',
  'libSystem.Native.so',
  'libSystem.Security.Cryptography.Native.OpenSsl.so'
)
foreach ($File in @('pwsh', 'pwsh.dll', 'LICENSE.txt', 'ThirdPartyNotices.txt') + $NativeLibraries) {
  if (-not (Test-Path -LiteralPath (Join-Path $Payload $File) -PathType Leaf)) {
    throw "Linux package payload is missing $File in $Payload"
  }
}

foreach ($NativeLibrary in $NativeLibraries) {
  $LibraryElf = Get-LinuxElfInfo -Path (Join-Path $Payload $NativeLibrary)
  Assert-LinuxElfArchitecture -Elf $LibraryElf -Architecture $Architecture
  if ($LibraryElf.Type -ne 3) {
    throw "Linux package native library must be a shared ELF library: $($LibraryElf.Path)"
  }
}

$ExecutablePath = Join-Path $Payload 'pwsh'
$Elf = Get-LinuxElfInfo -Path $ExecutablePath
Assert-LinuxElfArchitecture -Elf $Elf -Architecture $Architecture
$ExpectedInterpreter = if ($Architecture -eq 'x64') { 'ld-linux-x86-64.so.2' } else { 'ld-linux-aarch64.so.1' }
if ($Elf.Type -notin 2, 3 -or [System.IO.Path]::GetFileName($Elf.Interpreter) -ne $ExpectedInterpreter) {
  throw "Linux package payload must use the $Architecture glibc interpreter '$ExpectedInterpreter': $ExecutablePath"
}

$Output = [System.IO.Path]::GetFullPath($OutputDirectory).TrimEnd('/')
if ($Output.StartsWith("$Payload/", [System.StringComparison]::Ordinal) -or $Output -eq $Payload) {
  throw "Linux package output must be outside the payload directory: $Output"
}
New-Item -ItemType Directory -Path $Output -Force | Out-Null

$AddShellCommands = @"
if [ ! -f /etc/shells ] ; then
    echo "$LinkPath" > /etc/shells
else
    grep -q "^$LinkPath`$" /etc/shells || echo "$LinkPath" >> /etc/shells
fi
"@
$RemoveShellCommands = @"
if [ -f /etc/shells ] ; then
    TmpFile=`$(mktemp /tmp/.devolutions-powershell.XXXXXX)
    grep -v "^$LinkPath`$" /etc/shells > "`$TmpFile" || true
    cat "`$TmpFile" > /etc/shells
    rm -f "`$TmpFile"
fi
"@

$Work = Join-Path ([System.IO.Path]::GetTempPath()) "pwsh-distro-linux-$([guid]::NewGuid().ToString('N'))"
$Stage = Join-Path $Work 'root'
$StageInstallDirectory = Join-Path $Stage $InstallDirectory.TrimStart('/')
New-Item -ItemType Directory -Path $StageInstallDirectory -Force | Out-Null
try {
  Invoke-NativeCommand -FilePath cp -Arguments @('-a', "$Payload/.", "$StageInstallDirectory/")
  Invoke-NativeCommand -FilePath chmod -Arguments @('0755', (Join-Path $StageInstallDirectory 'pwsh'))
  New-Item -ItemType Directory -Path (Join-Path $Stage (Split-Path -Parent $LinkPath).TrimStart('/')) -Force | Out-Null
  Invoke-NativeCommand -FilePath ln -Arguments @('-s', "$InstallDirectory/pwsh", (Join-Path $Stage $LinkPath.TrimStart('/')))

  if ($Distribution -eq 'deb') {
    $DebArchitecture = if ($Architecture -eq 'x64') { 'amd64' } else { 'arm64' }
    $DebVersion = "$PackageVersion-$Iteration.deb"
    $Dependencies = @(
      'ca-certificates',
      'libc6',
      'libgcc-s1 | libgcc1',
      'libgssapi-krb5-2',
      'libstdc++6',
      'tzdata',
      'zlib1g',
      ((106..60 | ForEach-Object { "libicu$_" }) -join ' | '),
      'libssl3t64 | libssl3 | libssl1.1 | libssl1.0.2 | libssl1.0.0'
    )
    $InstalledSizeKB = ([string] (& du -sk $Stage | Select-Object -First 1) -split '\s+')[0]
    if ($LASTEXITCODE -ne 0 -or $InstalledSizeKB -notmatch '^\d+$') {
      throw "Unable to compute the installed size of $Stage."
    }

    $DebianDirectory = Join-Path $Stage 'DEBIAN'
    New-Item -ItemType Directory -Path $DebianDirectory | Out-Null
    $Control = @(
      "Package: $PackageName",
      "Version: $DebVersion",
      "Architecture: $DebArchitecture",
      "Maintainer: $Maintainer",
      "Installed-Size: $InstalledSizeKB",
      'Priority: optional',
      'Section: shells',
      "Homepage: $Homepage",
      "Depends: $($Dependencies -join ', ')",
      'Conflicts: powershell',
      "Description: $Summary"
    ) + ($DescriptionLines | ForEach-Object { " $_" })
    Write-UnixTextFile (Join-Path $DebianDirectory 'control') ($Control -join "`n")

    Write-UnixTextFile (Join-Path $DebianDirectory 'postinst') @"
#!/bin/sh
set -e
case "`$1" in
    (configure)
        if command -v add-shell >/dev/null 2>&1 ; then
            add-shell "$LinkPath"
        else
$(Format-Indented $AddShellCommands 12)
        fi
    ;;
esac
exit 0
"@
    Write-UnixTextFile (Join-Path $DebianDirectory 'postrm') @"
#!/bin/sh
set -e
case "`$1" in
    (remove|purge)
        if command -v remove-shell >/dev/null 2>&1 ; then
            remove-shell "$LinkPath"
        else
$(Format-Indented $RemoveShellCommands 12)
        fi
    ;;
esac
exit 0
"@
    Invoke-NativeCommand -FilePath chmod -Arguments @('0755', $DebianDirectory, (Join-Path $DebianDirectory 'postinst'), (Join-Path $DebianDirectory 'postrm'))
    Invoke-NativeCommand -FilePath chmod -Arguments @('0644', (Join-Path $DebianDirectory 'control'))

    $PackagePath = Join-Path $Output "${PackageName}_${DebVersion}_${DebArchitecture}.deb"
    if (Test-Path -LiteralPath $PackagePath) {
      throw "Linux package output already exists: $PackagePath"
    }
    Invoke-NativeCommand -FilePath dpkg-deb -Arguments @('--root-owner-group', '-Zxz', '--build', $Stage, $PackagePath)
    Invoke-NativeCommand -FilePath dpkg-deb -Arguments @('--info', $PackagePath)
    $ActualArchitecture = (& dpkg-deb --field $PackagePath Architecture)
    if ($LASTEXITCODE -ne 0 -or $ActualArchitecture -ne $DebArchitecture) {
      throw "deb package architecture '$ActualArchitecture' does not match $DebArchitecture."
    }
  } else {
    $RpmArchitecture = if ($Architecture -eq 'x64') { 'x86_64' } else { 'aarch64' }
    $RpmRelease = "$Iteration.$Distribution"
    $Dependencies = if ($Distribution -eq 'rh') {
      @('ca-certificates', 'glibc', 'krb5-libs', 'libgcc', 'libicu', 'libstdc++',
        '(libssl.so.3()(64bit) or libssl.so.1.1()(64bit))', 'tzdata', 'zlib')
    } else {
      @('ca-certificates', 'glibc', 'icu', 'krb5-libs', 'libgcc', 'libstdc++', 'openssl-libs', 'tzdata', 'zlib')
    }

    $TopDirectory = Join-Path $Work 'rpmbuild'
    foreach ($Directory in 'BUILD', 'BUILDROOT', 'RPMS', 'SOURCES', 'SPECS', 'SRPMS') {
      New-Item -ItemType Directory -Path (Join-Path $TopDirectory $Directory) -Force | Out-Null
    }
    $ChangelogDate = [datetime]::UtcNow.ToString('ddd MMM dd yyyy', [System.Globalization.CultureInfo]::InvariantCulture)
    $Spec = @"
%global debug_package %{nil}
%global __os_install_post %{nil}
%global __arch_install_post %{nil}
%global __strip /bin/true
%global _build_id_links none
%global _binary_payload w6.xzdio

Name:           $PackageName
Version:        $PackageVersion
Release:        $RpmRelease
Summary:        $Summary
License:        MIT
URL:            $Homepage
AutoReqProv:    no
Conflicts:      powershell
$(($Dependencies | ForEach-Object { "Requires:       $_" }) -join "`n")

%description
$($DescriptionLines -join "`n")

%prep

%build

%install
rm -rf "%{buildroot}"
mkdir -p "%{buildroot}"
cp -a "$Stage/." "%{buildroot}/"

%post
$AddShellCommands

%postun
if [ "`$1" = 0 ] ; then
$(Format-Indented $RemoveShellCommands 4)
fi

%files
%defattr(-,root,root,-)
$InstallDirectory
$LinkPath

%changelog
* $ChangelogDate $Maintainer - $PackageVersion-$RpmRelease
- Devolutions PowerShell distribution $PackageVersion
"@
    $SpecPath = Join-Path $TopDirectory "SPECS/$PackageName.spec"
    Write-UnixTextFile $SpecPath $Spec

    Invoke-NativeCommand -FilePath rpmbuild -Arguments @(
      '-bb',
      '--target', $RpmArchitecture,
      '--define', "_topdir $TopDirectory",
      '--buildroot', (Join-Path $TopDirectory 'BUILDROOT/root'),
      $SpecPath
    )

    $RpmFileName = "$PackageName-$PackageVersion-$RpmRelease.$RpmArchitecture.rpm"
    $BuiltRpm = Join-Path $TopDirectory "RPMS/$RpmArchitecture/$RpmFileName"
    if (-not (Test-Path -LiteralPath $BuiltRpm -PathType Leaf)) {
      throw "rpmbuild did not produce the expected package: $BuiltRpm"
    }
    $PackagePath = Join-Path $Output $RpmFileName
    if (Test-Path -LiteralPath $PackagePath) {
      throw "Linux package output already exists: $PackagePath"
    }
    Move-Item -LiteralPath $BuiltRpm -Destination $PackagePath
    Invoke-NativeCommand -FilePath rpm -Arguments @('-qpi', $PackagePath)
    Invoke-NativeCommand -FilePath rpm -Arguments @('-qp', '--requires', $PackagePath)
    $ActualArchitecture = (& rpm -qp --queryformat '%{ARCH}' $PackagePath)
    if ($LASTEXITCODE -ne 0 -or $ActualArchitecture -ne $RpmArchitecture) {
      throw "RPM package architecture '$ActualArchitecture' does not match $RpmArchitecture."
    }
  }

  Write-Output $PackagePath
} finally {
  Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
}
