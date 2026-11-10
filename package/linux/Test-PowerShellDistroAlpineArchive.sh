#!/bin/sh
set -eu

ARCHIVE="$1"
EXPECTED_VERSION="$2"
EXPECTED_ARCH="$3"

apk add --no-cache ca-certificates icu-libs krb5-libs libgcc libstdc++ openssl tzdata
mkdir -p /tmp/powershell-distro
tar -xzf "$ARCHIVE" -C /tmp/powershell-distro
PWSH=/tmp/powershell-distro/pwsh
[ -x "$PWSH" ] || { echo "Missing executable $PWSH" >&2; exit 1; }

ACTUAL_VERSION="$("$PWSH" -NoLogo -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()' | tail -n 1 | tr -d '\r')"
[ "$ACTUAL_VERSION" = "$EXPECTED_VERSION" ] || { echo "pwsh reported '$ACTUAL_VERSION', expected '$EXPECTED_VERSION'" >&2; exit 1; }

EXPECTED_RID="linux-musl-$EXPECTED_ARCH" "$PWSH" -NoLogo -NoProfile -NonInteractive -Command '
$ErrorActionPreference = "Stop"
$Rid = [System.Runtime.InteropServices.RuntimeInformation]::RuntimeIdentifier
if ($Rid -ne $Env:EXPECTED_RID) { throw "Runtime identifier $Rid does not match $Env:EXPECTED_RID" }
if ($PSHOME -ne "/tmp/powershell-distro") { throw "Unexpected PSHOME: $PSHOME" }
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
"Alpine archive smoke test passed for $Rid"
'
