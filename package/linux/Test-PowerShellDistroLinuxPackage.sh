#!/bin/sh
set -eu

PACKAGE="$1"
EXPECTED_VERSION="$2"
INSTALL_DIR=/opt/devolutions/powershell/7
LINK=/usr/bin/pwsh

case "$PACKAGE" in
  *.deb)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq "$PACKAGE"
    REMOVE="apt-get remove -y -qq devolutions-powershell"
    ;;
  *.rpm)
    if command -v dnf >/dev/null 2>&1 ; then
      dnf install -y "$PACKAGE"
      REMOVE="dnf remove -y devolutions-powershell"
    else
      tdnf install -y "$PACKAGE"
      REMOVE="tdnf remove -y devolutions-powershell"
    fi
    ;;
  *)
    echo "Unsupported package: $PACKAGE" >&2
    exit 1
    ;;
esac

[ -x "$INSTALL_DIR/pwsh" ] || { echo "Missing $INSTALL_DIR/pwsh" >&2; exit 1; }
[ "$(readlink "$LINK")" = "$INSTALL_DIR/pwsh" ] || { echo "$LINK does not point to $INSTALL_DIR/pwsh" >&2; exit 1; }
grep -q "^$LINK\$" /etc/shells || { echo "$LINK was not registered in /etc/shells" >&2; exit 1; }

ACTUAL_VERSION="$(pwsh -NoLogo -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()' | tail -n 1 | tr -d '\r')"
[ "$ACTUAL_VERSION" = "$EXPECTED_VERSION" ] || { echo "pwsh reported '$ACTUAL_VERSION', expected '$EXPECTED_VERSION'" >&2; exit 1; }

pwsh -NoLogo -NoProfile -NonInteractive -Command '
$ErrorActionPreference = "Stop"
if ($PSHOME -ne "/opt/devolutions/powershell/7") { throw "Unexpected PSHOME: $PSHOME" }
$Native = [System.Runtime.InteropServices.NativeLibrary]::Load((Join-Path $PSHOME "libpsl-native.so"))
try { $null = [System.Runtime.InteropServices.NativeLibrary]::GetExport($Native, "GetCurrentThreadId") }
finally { [System.Runtime.InteropServices.NativeLibrary]::Free($Native) }
$HardLink = "/tmp/pwsh-hardlink"
New-Item -ItemType HardLink -Path $HardLink -Target (Join-Path $PSHOME "pwsh") | Out-Null
Remove-Item -Force -LiteralPath $HardLink
$null = [System.Globalization.CultureInfo]::GetCultureInfo("fr-CA")
$null = [System.Security.Cryptography.SHA256]::HashData([byte[]](1,2,3))
$RootStore = [System.Security.Cryptography.X509Certificates.X509Store]::new(
  [System.Security.Cryptography.X509Certificates.StoreName]::Root,
  [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
try {
  $RootStore.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
  if ($RootStore.Certificates.Count -eq 0) { throw "No trusted root certificates are installed" }
} finally {
  $RootStore.Dispose()
}
$null = [System.TimeZoneInfo]::FindSystemTimeZoneById("America/Toronto")
Import-Module Microsoft.PowerShell.Utility, PSReadLine
if ((Start-Job { 42 } | Receive-Job -Wait -AutoRemoveJob) -ne 42) { throw "Background job failed" }
"Package smoke test passed on $([System.Runtime.InteropServices.RuntimeInformation]::OSDescription) ($([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture))"
'

$REMOVE
[ ! -e "$LINK" ] || { echo "$LINK still exists after removal" >&2; exit 1; }
[ ! -e "$INSTALL_DIR/pwsh" ] || { echo "$INSTALL_DIR/pwsh still exists after removal" >&2; exit 1; }
if grep -q "^$LINK\$" /etc/shells ; then
  echo "$LINK is still registered in /etc/shells after removal" >&2
  exit 1
fi
echo "Install/remove test passed for $PACKAGE"
