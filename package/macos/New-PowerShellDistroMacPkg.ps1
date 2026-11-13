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
  [string] $OutputDirectory,

  # Developer ID Application identity used to sign every Mach-O payload file with the hardened runtime.
  [string] $CodeSigningIdentity,

  # Developer ID Installer identity used to sign the product archive.
  [string] $InstallerSigningIdentity,

  # Keychain containing the signing identities; defaults to the keychain search list.
  [string] $Keychain
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if (-not $IsMacOS) {
  throw 'macOS pkg packaging requires macOS (pkgbuild and productbuild).'
}
if ([string]::IsNullOrWhiteSpace($CodeSigningIdentity) -ne [string]::IsNullOrWhiteSpace($InstallerSigningIdentity)) {
  throw 'Specify both -CodeSigningIdentity and -InstallerSigningIdentity, or neither.'
}
$Sign = -not [string]::IsNullOrWhiteSpace($CodeSigningIdentity)
$KeychainArguments = if ($Keychain) { @('--keychain', $Keychain) } else { @() }

function Invoke-NativeCommand {
  param(
    [Parameter(Mandatory)]
    [string] $FilePath,

    [string[]] $ArgumentList = @()
  )

  & $FilePath @ArgumentList
  if ($LASTEXITCODE -ne 0) {
    throw "$FilePath $($ArgumentList -join ' ') failed with exit code $LASTEXITCODE"
  }
}

function Test-MachOFile {
  param(
    [Parameter(Mandatory)]
    [string] $Path
  )

  $Stream = [System.IO.File]::OpenRead($Path)
  try {
    $Header = [byte[]]::new(8)
    if ($Stream.Read($Header, 0, 8) -ne 8) {
      return $false
    }
  } finally {
    $Stream.Dispose()
  }
  $Magic = [System.BitConverter]::ToUInt32($Header, 0)
  if ($Magic -in 0xFEEDFACEu, 0xFEEDFACFu) {
    return $true
  }
  # Universal binaries share the CAFEBABE magic with Java class files, which store a class version instead of a small slice count.
  if ($Magic -in 0xBEBAFECAu, 0xBFBAFECAu) {
    $SliceCount = ([uint32] $Header[4] -shl 24) -bor ([uint32] $Header[5] -shl 16) -bor ([uint32] $Header[6] -shl 8) -bor [uint32] $Header[7]
    return ($SliceCount -gt 0 -and $SliceCount -lt 32)
  }
  return $false
}

$AssetsRoot = Join-Path $PSScriptRoot 'assets'
$Payload = (Resolve-Path -LiteralPath $PayloadDirectory -ErrorAction Stop).Path
if (-not (Test-Path -LiteralPath $Payload -PathType Container)) {
  throw "Payload directory was not found: $Payload"
}
foreach ($File in 'pwsh', 'pwsh.dll', 'LICENSE.txt', 'ThirdPartyNotices.txt') {
  if (-not (Test-Path -LiteralPath (Join-Path $Payload $File) -PathType Leaf)) {
    throw "macOS pkg payload is missing $File in $Payload"
  }
}

# Reject a pwsh apphost whose thin 64-bit Mach-O CPU type does not match the requested package architecture.
$ExecutablePath = Join-Path $Payload 'pwsh'
$ExpectedCpuType = if ($Architecture -eq 'x64') { 0x01000007 } else { 0x0100000C }
$Stream = [System.IO.File]::OpenRead($ExecutablePath)
try {
  $Reader = [System.IO.BinaryReader]::new($Stream)
  if ($Stream.Length -lt 32 -or $Reader.ReadUInt32() -ne 0xFEEDFACFu) {
    throw "macOS pkg payload is not a thin 64-bit Mach-O executable: $ExecutablePath"
  }
  $CpuType = $Reader.ReadUInt32()
  if ($CpuType -ne $ExpectedCpuType) {
    throw "macOS pkg payload pwsh CPU type 0x$($CpuType.ToString('X8')) does not match $Architecture (expected 0x$($ExpectedCpuType.ToString('X8')))."
  }
} finally {
  $Stream.Dispose()
}

$Version = [version] $PackageVersion
$MajorVersion = $Version.Major
$PackageIdentifier = 'com.devolutions.powershell'
$LauncherIdentifier = 'com.devolutions.powershell.launcher'
$ProductName = 'Devolutions PowerShell'
$InstallDirectory = "/usr/local/devolutions/powershell/$MajorVersion"
$LinkPath = '/usr/local/bin/pwsh'
$ManPagePath = '/usr/local/share/man/man1/pwsh.1.gz'
$AppName = "$ProductName.app"
$HostArchitecture = if ($Architecture -eq 'x64') { 'x86_64' } else { 'arm64' }
$MinimumOSVersion = '12.0'
$MinimumOSVersionMajor = [int] ($MinimumOSVersion.Split('.')[0])

$Output = [System.IO.Path]::GetFullPath($OutputDirectory)
if ($Output.StartsWith($Payload.TrimEnd('/') + '/', [System.StringComparison]::Ordinal) -or $Output -eq $Payload) {
  throw "macOS pkg output must be outside the payload directory: $Output"
}
New-Item -ItemType Directory -Path $Output -Force | Out-Null
$PkgPath = Join-Path $Output "Devolutions.PowerShell-$PackageVersion-osx-$Architecture.pkg"
if (Test-Path -LiteralPath $PkgPath) {
  throw "macOS pkg output already exists: $PkgPath"
}

$Work = Join-Path ([System.IO.Path]::GetTempPath()) "pwsh-distro-pkg-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $Work | Out-Null
try {
  $Root = Join-Path $Work 'root'
  $Scripts = Join-Path $Work 'scripts'
  $Resources = Join-Path $Work 'resources'
  $Packages = Join-Path $Work 'packages'
  New-Item -ItemType Directory -Path $Root, $Scripts, $Resources, $Packages | Out-Null

  # PowerShell payload, normalized like upstream osxpkg: only the executables keep the execute bit.
  $InstallRoot = Join-Path $Root $InstallDirectory.TrimStart('/')
  New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
  Invoke-NativeCommand cp @('-R', "$Payload/.", $InstallRoot)
  Invoke-NativeCommand find @($InstallRoot, '-type', 'd', '-exec', 'chmod', '755', '{}', '+')
  Invoke-NativeCommand find @($InstallRoot, '-type', 'f', '-exec', 'chmod', '644', '{}', '+')
  foreach ($Executable in 'pwsh', 'createdump') {
    $ExecutableFile = Join-Path $InstallRoot $Executable
    if (Test-Path -LiteralPath $ExecutableFile -PathType Leaf) {
      Invoke-NativeCommand chmod @('755', $ExecutableFile)
    }
  }

  if ($Sign) {
    # Notarization requires every Mach-O file to carry a Developer ID signature, secure timestamp, and hardened runtime.
    $ApphostPath = Join-Path $InstallRoot 'pwsh'
    $MachOFiles = @(Get-ChildItem -LiteralPath $InstallRoot -Recurse -File |
      Where-Object { -not $_.LinkType -and $_.FullName -ne $ApphostPath -and (Test-MachOFile $_.FullName) } |
      Sort-Object FullName)
    foreach ($MachOFile in $MachOFiles) {
      Invoke-NativeCommand codesign (@('--force', '--timestamp', '--options', 'runtime', '--sign', $CodeSigningIdentity) + $KeychainArguments + @($MachOFile.FullName))
    }
    # The apphost is signed last with the entitlements PowerShell requires for JIT and loading unsigned native modules.
    Invoke-NativeCommand codesign (@('--force', '--timestamp', '--options', 'runtime', '--entitlements', (Join-Path $AssetsRoot 'pwsh-entitlements.plist'), '--sign', $CodeSigningIdentity) + $KeychainArguments + @($ApphostPath))
    Invoke-NativeCommand codesign @('--verify', '--strict', '--verbose=2', $ApphostPath)
    Write-Host "Signed $($MachOFiles.Count + 1) Mach-O payload files with $CodeSigningIdentity."
  }

  # A wrapper preserves the apphost's payload location; a symlink is treated as a multi-pwsh manager shim.
  $LinkDirectory = Join-Path $Root (Split-Path -Parent $LinkPath).TrimStart('/')
  New-Item -ItemType Directory -Path $LinkDirectory -Force | Out-Null
  $PwshLauncher = Join-Path $Root $LinkPath.TrimStart('/')
  Set-Content -LiteralPath $PwshLauncher -Value "#!/bin/sh`nexec `"$InstallDirectory/pwsh`" `"`$@`"`n" -Encoding ascii -NoNewline
  Invoke-NativeCommand chmod @('755', $PwshLauncher)

  # Compressed man page.
  $ManDirectory = Join-Path $Root (Split-Path -Parent $ManPagePath).TrimStart('/')
  New-Item -ItemType Directory -Path $ManDirectory -Force | Out-Null
  $ManFile = Join-Path $Root $ManPagePath.TrimStart('/')
  Invoke-NativeCommand /bin/sh @('-c', 'gzip -9 -n -c "$1" > "$2"', 'sh', (Join-Path $AssetsRoot 'pwsh.1'), $ManFile)
  Invoke-NativeCommand chmod @('644', $ManFile)

  # Launcher application that opens pwsh in Terminal.
  $AppContents = Join-Path (Join-Path (Join-Path $Root 'Applications') $AppName) 'Contents'
  New-Item -ItemType Directory -Path (Join-Path $AppContents 'MacOS'), (Join-Path $AppContents 'Resources') -Force | Out-Null
  Copy-Item -LiteralPath (Join-Path $AssetsRoot 'Powershell.icns') -Destination (Join-Path $AppContents 'Resources/Powershell.icns')
  $InfoPlist = @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>PowerShell.sh</string>
    <key>CFBundleGetInfoString</key>
    <string>$PackageVersion</string>
    <key>CFBundleIconFile</key>
    <string>Powershell</string>
    <key>CFBundleIdentifier</key>
    <string>$LauncherIdentifier</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$ProductName</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$PackageVersion</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>MacOSX</string>
    </array>
    <key>CFBundleVersion</key>
    <string>$PackageVersion</string>
</dict>
</plist>
"@
  Set-Content -LiteralPath (Join-Path $AppContents 'Info.plist') -Value $InfoPlist -Encoding utf8NoBOM
  $LauncherScript = Join-Path $AppContents 'MacOS/PowerShell.sh'
  Set-Content -LiteralPath $LauncherScript -Value "#!/usr/bin/env bash`nopen $InstallDirectory/pwsh`n" -Encoding ascii -NoNewline
  Invoke-NativeCommand chmod @('644', (Join-Path $AppContents 'Info.plist'), (Join-Path $AppContents 'Resources/Powershell.icns'))
  Invoke-NativeCommand chmod @('755', $LauncherScript)

  # Keep the launcher at /Applications instead of letting Installer relocate it to a copy found elsewhere.
  $ComponentPlist = Join-Path $Work 'component.plist'
  Set-Content -LiteralPath $ComponentPlist -Encoding utf8NoBOM -Value @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
    <dict>
        <key>BundleHasStrictIdentifier</key>
        <true/>
        <key>BundleIsRelocatable</key>
        <false/>
        <key>BundleIsVersionChecked</key>
        <false/>
        <key>BundleOverwriteAction</key>
        <string>upgrade</string>
        <key>RootRelativeBundlePath</key>
        <string>Applications/$AppName</string>
    </dict>
</array>
</plist>
"@

  # preinstall removes the previous payload so upgrades do not leave stale files; postinstall registers the login shell.
  $PreInstall = Join-Path $Scripts 'preinstall'
  Set-Content -LiteralPath $PreInstall -Encoding ascii -Value @"
#!/bin/bash
set -e
OS_VERSION=`$(/usr/bin/sw_vers -productVersion)
if [[ ! "`$OS_VERSION" =~ ^([0-9]+)\.([0-9]+) ]]; then
    echo "Unable to determine macOS version: `$OS_VERSION" >&2
    exit 1
fi
if (( BASH_REMATCH[1] < $MinimumOSVersionMajor )); then
    echo "Devolutions PowerShell requires macOS $MinimumOSVersion or later; found `$OS_VERSION." >&2
    exit 1
fi
if [ -d "$InstallDirectory" ] ; then
    rm -rf "$InstallDirectory"
fi
"@
  $PostInstall = Join-Path $Scripts 'postinstall'
  Set-Content -LiteralPath $PostInstall -Encoding ascii -Value @"
#!/bin/bash
chmod 755 "$LinkPath"
chmod 755 "$InstallDirectory/pwsh"
if [ -f "$InstallDirectory/createdump" ] ; then
    chmod 755 "$InstallDirectory/createdump"
fi
if [ ! -f /etc/shells ] ; then
    echo "$LinkPath" > /etc/shells
else
    grep -q "^$LinkPath`$" /etc/shells || echo "$LinkPath" >> /etc/shells
fi
"@
  Invoke-NativeCommand chmod @('755', $PreInstall, $PostInstall)

  Copy-Item -LiteralPath (Join-Path $AssetsRoot 'macDialog.png') -Destination $Resources

  $ComponentFileName = 'powershell.pkg'
  Invoke-NativeCommand pkgbuild @(
    '--root', $Root,
    '--component-plist', $ComponentPlist,
    '--identifier', $PackageIdentifier,
    '--version', $PackageVersion,
    '--scripts', $Scripts,
    '--install-location', '/',
    '--ownership', 'recommended',
    (Join-Path $Packages $ComponentFileName)
  )

  $Distribution = Join-Path $Work 'distribution.xml'
  Set-Content -LiteralPath $Distribution -Encoding utf8NoBOM -Value @"
<?xml version="1.0" encoding="utf-8" standalone="yes"?>
<installer-gui-script minSpecVersion="1">
    <title>$ProductName $PackageVersion</title>
    <options hostArchitectures="$HostArchitecture"/>
    <options customize="never" rootVolumeOnly="true" require-scripts="false"/>
    <background file="macDialog.png" scaling="tofit" alignment="bottomleft"/>
    <allowed-os-versions>
        <os-version min="$MinimumOSVersion" />
    </allowed-os-versions>
    <product id="$PackageIdentifier" version="$PackageVersion" />
    <choices-outline>
        <line choice="default">
            <line choice="powershell"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="powershell" visible="false">
        <pkg-ref id="$PackageIdentifier"/>
    </choice>
    <pkg-ref id="$PackageIdentifier" version="$PackageVersion" onConclusion="none">$ComponentFileName</pkg-ref>
</installer-gui-script>
"@

  $ProductBuildArguments = @(
    '--distribution', $Distribution,
    '--package-path', $Packages,
    '--resources', $Resources
  )
  if ($Sign) {
    $ProductBuildArguments += @('--sign', $InstallerSigningIdentity, '--timestamp') + $KeychainArguments
  }
  Invoke-NativeCommand productbuild ($ProductBuildArguments + @($PkgPath))
  Write-Host "Built $PkgPath"
} finally {
  Remove-Item -LiteralPath $Work -Recurse -Force
}
