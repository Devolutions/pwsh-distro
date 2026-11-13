[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $PkgPath,

  [Parameter(Mandatory)]
  [ValidateSet('x64', 'arm64')]
  [string] $Architecture,

  [Parameter(Mandatory)]
  [ValidatePattern('^\d+\.\d+\.\d+\.\d+$')]
  [string] $PackageVersion,

  # Installs the package with sudo, then exercises an in-place upgrade. Use only on disposable machines such as CI runners.
  [switch] $Install,

  # Package for the other architecture; with -Install, verifies that Installer refuses it on this host.
  [string] $OppositePkgPath,

  # Requires a Developer ID Installer signature and Developer ID Application, hardened-runtime signatures on payload Mach-O files.
  [switch] $RequireSignature,

  # Requires a stapled notarization ticket accepted by Gatekeeper; implies -RequireSignature.
  [switch] $RequireNotarization
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if (-not $IsMacOS) {
  throw 'macOS pkg validation requires macOS.'
}

function Invoke-NativeCommand {
  param(
    [Parameter(Mandatory)]
    [string] $FilePath,

    [string[]] $ArgumentList = @()
  )

  $Result = & $FilePath @ArgumentList
  if ($LASTEXITCODE -ne 0) {
    throw "$FilePath $($ArgumentList -join ' ') failed with exit code $LASTEXITCODE"
  }
  return $Result
}

function Assert-True {
  param(
    [Parameter(Mandatory)]
    [bool] $Condition,

    [Parameter(Mandatory)]
    [string] $Message
  )

  if (-not $Condition) {
    throw $Message
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
  if ($Magic -in 0xBEBAFECAu, 0xBFBAFECAu) {
    $SliceCount = ([uint32] $Header[4] -shl 24) -bor ([uint32] $Header[5] -shl 16) -bor ([uint32] $Header[6] -shl 8) -bor [uint32] $Header[7]
    return ($SliceCount -gt 0 -and $SliceCount -lt 32)
  }
  return $false
}

function Assert-DeveloperIdCodeSignature {
  param(
    [Parameter(Mandatory)]
    [string] $Path,

    [switch] $RequireEntitlements
  )

  Invoke-NativeCommand codesign @('--verify', '--strict', $Path) | Out-Null
  $Details = (& codesign --display --verbose=4 $Path 2>&1) -join "`n"
  Assert-True ($LASTEXITCODE -eq 0) "Unable to read the code signature of $Path."
  Assert-True ($Details -match '(?m)^Authority=Developer ID Application: ') "$Path is not signed with a Developer ID Application certificate."
  Assert-True ($Details -match '(?m)^Timestamp=') "$Path does not have a secure timestamp."
  Assert-True ($Details -match '(?m)^CodeDirectory .*flags=0x[0-9a-f]*\(.*runtime.*\)') "$Path is not signed with the hardened runtime."
  if ($RequireEntitlements) {
    $Entitlements = (& codesign --display --entitlements - --xml $Path 2>$null) -join ''
    foreach ($Entitlement in 'com.apple.security.cs.allow-jit', 'com.apple.security.cs.allow-unsigned-executable-memory', 'com.apple.security.cs.allow-dyld-environment-variables', 'com.apple.security.cs.disable-library-validation') {
      Assert-True ($Entitlements.Contains("<key>$Entitlement</key>")) "$Path is missing the $Entitlement entitlement."
    }
  }
}

if ($RequireNotarization) {
  $RequireSignature = $true
}

$Pkg = (Resolve-Path -LiteralPath $PkgPath).Path
$Version = [version] $PackageVersion
$PowerShellVersion = "$($Version.Major).$($Version.Minor).$($Version.Build)"
$PackageIdentifier = 'com.devolutions.powershell'
$LauncherIdentifier = 'com.devolutions.powershell.launcher'
$InstallDirectory = "/usr/local/devolutions/powershell/$($Version.Major)"
$LinkPath = '/usr/local/bin/pwsh'
$ManPagePath = '/usr/local/share/man/man1/pwsh.1.gz'
$AppPath = '/Applications/Devolutions PowerShell.app'
$MinimumOSVersion = '12.0'
$HostArchitecture = if ($Architecture -eq 'x64') { 'x86_64' } else { 'arm64' }
$ExpectedCpuType = if ($Architecture -eq 'x64') { 'x86_64' } else { 'arm64' }

Assert-True ((Split-Path -Leaf $Pkg) -eq "Devolutions.PowerShell-$PackageVersion-osx-$Architecture.pkg") "Unexpected pkg file name: $Pkg"

$Work = Join-Path ([System.IO.Path]::GetTempPath()) "pwsh-distro-pkg-test-$([guid]::NewGuid().ToString('N'))"
try {
  $Expanded = Join-Path $Work 'expanded'
  New-Item -ItemType Directory -Path $Work | Out-Null
  Invoke-NativeCommand pkgutil @('--expand-full', $Pkg, $Expanded) | Out-Null

  [xml] $Distribution = Get-Content -LiteralPath (Join-Path $Expanded 'Distribution') -Raw
  $Script = $Distribution.'installer-gui-script'
  $HostArchitectures = @($Script.options | ForEach-Object { $_.GetAttribute('hostArchitectures') } | Where-Object { $_ })
  Assert-True ($HostArchitectures.Count -eq 1 -and $HostArchitectures[0] -eq $HostArchitecture) "Distribution hostArchitectures '$($HostArchitectures -join ',')' does not match $HostArchitecture."
  Assert-True ($Script.product.id -eq $PackageIdentifier -and $Script.product.version -eq $PackageVersion) "Distribution product is '$($Script.product.id)' '$($Script.product.version)'."
  $AllowedOSVersions = @($Script.'allowed-os-versions'.'os-version' | ForEach-Object { $_.GetAttribute('min') })
  Assert-True ($AllowedOSVersions.Count -eq 1 -and $AllowedOSVersions[0] -eq $MinimumOSVersion) "Distribution minimum macOS version '$($AllowedOSVersions -join ',')' does not match $MinimumOSVersion."

  $ComponentDirectories = @(Get-ChildItem -LiteralPath $Expanded -Directory -Filter '*.pkg')
  Assert-True ($ComponentDirectories.Count -eq 1) "Expected one component package, found $($ComponentDirectories.Count)."
  $Component = $ComponentDirectories[0].FullName
  [xml] $PackageInfo = Get-Content -LiteralPath (Join-Path $Component 'PackageInfo') -Raw
  $Info = $PackageInfo.'pkg-info'
  Assert-True ($Info.identifier -eq $PackageIdentifier -and $Info.version -eq $PackageVersion -and $Info.'install-location' -eq '/') "Unexpected component PackageInfo: $($Info.identifier) $($Info.version) $($Info.'install-location')."
  $Bundle = @($Info.bundle)
  Assert-True ($Bundle.Count -eq 1 -and $Bundle[0].id -eq $LauncherIdentifier -and $Bundle[0].path -eq "./$($AppPath.TrimStart('/'))") 'The launcher bundle is missing from PackageInfo.'
  $Relocatable = @($Info.SelectNodes('relocate/bundle'))
  Assert-True ($Relocatable.Count -eq 0) 'The launcher bundle must not be relocatable.'
  foreach ($ScriptName in 'preinstall', 'postinstall') {
    $ScriptPath = Join-Path $Component "Scripts/$ScriptName"
    Assert-True (Test-Path -LiteralPath $ScriptPath -PathType Leaf) "Component is missing its $ScriptName script."
    Assert-True ((Get-Item -LiteralPath $ScriptPath).UnixFileMode.HasFlag([System.IO.UnixFileMode]::UserExecute)) "$ScriptName is not executable."
    if ($ScriptName -eq 'preinstall') {
      $PreInstallContent = Get-Content -LiteralPath $ScriptPath -Raw
      $OSVersionCheck = $PreInstallContent.IndexOf('sw_vers -productVersion', [System.StringComparison]::Ordinal)
      $PayloadRemoval = $PreInstallContent.IndexOf("rm -rf `"$InstallDirectory`"", [System.StringComparison]::Ordinal)
      Assert-True ($OSVersionCheck -ge 0 -and $OSVersionCheck -lt $PayloadRemoval -and $PreInstallContent.Contains('BASH_REMATCH[1] < 12')) 'preinstall must reject unsupported macOS versions before removing the existing payload.'
    }
  }

  $PayloadRoot = Join-Path $Component 'Payload'
  $PayloadPwsh = Join-Path $PayloadRoot "$($InstallDirectory.TrimStart('/'))/pwsh"
  Assert-True (Test-Path -LiteralPath $PayloadPwsh -PathType Leaf) "Payload is missing $InstallDirectory/pwsh."
  Assert-True ((Get-Item -LiteralPath $PayloadPwsh).UnixFileMode.HasFlag([System.IO.UnixFileMode]::UserExecute)) 'Payload pwsh is not executable.'
  Assert-True ((Invoke-NativeCommand lipo @('-archs', $PayloadPwsh)).Trim() -eq $ExpectedCpuType) "Payload pwsh is not $ExpectedCpuType."
  $PayloadDll = Join-Path $PayloadRoot "$($InstallDirectory.TrimStart('/'))/pwsh.dll"
  Assert-True (-not (Get-Item -LiteralPath $PayloadDll).UnixFileMode.HasFlag([System.IO.UnixFileMode]::UserExecute)) 'Managed payload files must not be executable.'
  $PayloadLauncher = Join-Path $PayloadRoot $LinkPath.TrimStart('/')
  Assert-True ((Get-Item -LiteralPath $PayloadLauncher).UnixFileMode.HasFlag([System.IO.UnixFileMode]::UserExecute)) "Payload $LinkPath is not executable."
  $ExpectedLauncher = "#!/bin/sh`nexec `"$InstallDirectory/pwsh`" `"`$@`"`n"
  Assert-True ((Get-Content -LiteralPath $PayloadLauncher -Raw) -eq $ExpectedLauncher) "Payload $LinkPath does not launch $InstallDirectory/pwsh."
  $PayloadManPage = Join-Path $PayloadRoot $ManPagePath.TrimStart('/')
  Assert-True (Test-Path -LiteralPath $PayloadManPage -PathType Leaf) "Payload is missing $ManPagePath."
  $ManPageContent = (Invoke-NativeCommand gzip @('-dc', $PayloadManPage)) -join "`n"
  Assert-True ($ManPageContent.Contains('.SH "OPTIONS"') -and $ManPageContent.Contains('.SH "COPYRIGHT"')) 'The packaged pwsh man page is incomplete.'
  $PayloadApp = Join-Path $PayloadRoot $AppPath.TrimStart('/')
  $BundleId = (Invoke-NativeCommand /usr/libexec/PlistBuddy @('-c', 'Print :CFBundleIdentifier', "$PayloadApp/Contents/Info.plist")).Trim()
  Assert-True ($BundleId -eq $LauncherIdentifier) "Launcher bundle identifier is '$BundleId'."
  Assert-True ((Get-Item -LiteralPath "$PayloadApp/Contents/MacOS/PowerShell.sh").UnixFileMode.HasFlag([System.IO.UnixFileMode]::UserExecute)) 'Launcher script is not executable.'
  Write-Host "Validated pkg structure: $Pkg"

  if ($RequireSignature) {
    $PkgSignature = (& pkgutil --check-signature $Pkg 2>&1) -join "`n"
    Assert-True ($LASTEXITCODE -eq 0 -and $PkgSignature -match 'Status: signed by a developer certificate issued by Apple' -and $PkgSignature -match '\d+\. Developer ID Installer: ') "The pkg is not signed with a Developer ID Installer certificate:`n$PkgSignature"
    $PayloadInstallRoot = Join-Path $PayloadRoot $InstallDirectory.TrimStart('/')
    $PayloadMachOFiles = @(Get-ChildItem -LiteralPath $PayloadInstallRoot -Recurse -File | Where-Object { -not $_.LinkType -and (Test-MachOFile $_.FullName) })
    foreach ($MachOFile in $PayloadMachOFiles) {
      Assert-DeveloperIdCodeSignature -Path $MachOFile.FullName -RequireEntitlements:($MachOFile.FullName -eq $PayloadPwsh)
    }
    Write-Host "Validated Developer ID signatures on the pkg and $($PayloadMachOFiles.Count) payload Mach-O files."
  }
  if ($RequireNotarization) {
    Invoke-NativeCommand xcrun @('stapler', 'validate', $Pkg) | Write-Host
    $Assessment = (& spctl --assess --type install --verbose=2 $Pkg 2>&1) -join "`n"
    Assert-True ($LASTEXITCODE -eq 0 -and $Assessment -match 'source=Notarized Developer ID') "Gatekeeper did not accept the pkg as notarized:`n$Assessment"
    Write-Host 'Validated the stapled notarization ticket.'
  }

  if (-not $Install) {
    return
  }

  if ($OppositePkgPath) {
    $OppositePkg = (Resolve-Path -LiteralPath $OppositePkgPath).Path
    & sudo installer -pkg $OppositePkg -target / *> (Join-Path $Work 'opposite.log')
    Assert-True ($LASTEXITCODE -ne 0) "Installer accepted the opposite-architecture package $OppositePkg on $Architecture."
    Assert-True (-not (& pkgutil --pkg-info $PackageIdentifier 2>$null)) 'A refused opposite-architecture install registered the package receipt.'
    Write-Host "Installer refused the opposite-architecture package as expected."
  }

  function Test-Installation {
    $Receipt = Invoke-NativeCommand pkgutil @('--pkg-info', $PackageIdentifier)
    Assert-True (($Receipt -match "^version: $([regex]::Escape($PackageVersion))$").Count -eq 1) "pkgutil receipt does not report version $PackageVersion."
    Assert-True ((Get-Item -LiteralPath $LinkPath).UnixFileMode.HasFlag([System.IO.UnixFileMode]::UserExecute)) "$LinkPath is not executable."
    Assert-True ((Get-Content -LiteralPath $LinkPath -Raw) -eq $ExpectedLauncher) "$LinkPath does not launch $InstallDirectory/pwsh."
    $InstalledPwsh = Join-Path $InstallDirectory 'pwsh'
    Assert-True ((Get-Item -LiteralPath $InstalledPwsh).UnixFileMode.HasFlag([System.IO.UnixFileMode]::UserExecute)) "$InstalledPwsh is not executable."
    $Reported = Invoke-NativeCommand $LinkPath @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', '"$($PSVersionTable.PSVersion)|$PSHOME|$([System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture)"')
    Assert-True ("$Reported".Trim() -eq "$PowerShellVersion|$InstallDirectory|$($Architecture.Substring(0,1).ToUpperInvariant())$($Architecture.Substring(1))") "Installed pwsh reported '$Reported'."
    Assert-True (@(Get-Content -LiteralPath /etc/shells) -contains $LinkPath) "/etc/shells does not contain $LinkPath."
    Assert-True (Test-Path -LiteralPath $ManPagePath -PathType Leaf) "$ManPagePath was not installed."
    Assert-True (Test-Path -LiteralPath "$AppPath/Contents/MacOS/PowerShell.sh" -PathType Leaf) "$AppPath was not installed."
    if ($RequireSignature) {
      Assert-DeveloperIdCodeSignature -Path $InstalledPwsh -RequireEntitlements
    }
  }

  Invoke-NativeCommand sudo @('installer', '-pkg', $Pkg, '-target', '/') | Write-Host
  Test-Installation
  Write-Host 'Validated initial install.'

  $StaleFile = "$InstallDirectory/stale-file-from-previous-version.dll"
  Invoke-NativeCommand sudo @('touch', $StaleFile) | Out-Null
  Invoke-NativeCommand sudo @('installer', '-pkg', $Pkg, '-target', '/') | Write-Host
  Test-Installation
  Assert-True (-not (Test-Path -LiteralPath $StaleFile)) "Reinstall did not remove stale file $StaleFile."
  Write-Host 'Validated reinstall over an existing installation.'
} finally {
  Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
}
