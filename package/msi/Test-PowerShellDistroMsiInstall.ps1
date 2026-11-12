[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $CurrentMsiPath,
  [Parameter(Mandatory)] [string] $LegacyMsiPath,
  [Parameter(Mandatory)] [ValidateSet('x64', 'arm64')] [string] $Architecture,
  [string] $OppositeMsiPath,
  [string] $LegacyOppositeMsiPath,
  [switch] $RequireSignature
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
  throw 'MSI installation tests require Windows.'
}
if ([bool] $OppositeMsiPath -ne [bool] $LegacyOppositeMsiPath) {
  throw 'Both opposite-architecture MSI paths must be provided together.'
}
if ($OppositeMsiPath -and $Architecture -ne 'arm64') {
  throw 'Cross-architecture installation tests require a native ARM64 Windows host.'
}

$CurrentMsi = (Resolve-Path -LiteralPath $CurrentMsiPath -ErrorAction Stop).Path
$LegacyMsi = (Resolve-Path -LiteralPath $LegacyMsiPath -ErrorAction Stop).Path
if ($RequireSignature) {
  $Signature = Get-AuthenticodeSignature -LiteralPath $CurrentMsi
  if ($Signature.Status -ne 'Valid') {
    throw "MSI signature is not valid: $CurrentMsi ($($Signature.Status))."
  }
}
$OppositeMsi = $null
$LegacyOppositeMsi = $null
if ($OppositeMsiPath) {
  if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne [System.Runtime.InteropServices.Architecture]::Arm64) {
    throw 'Cross-architecture installation tests must run on native ARM64 Windows.'
  }
  $OppositeMsi = (Resolve-Path -LiteralPath $OppositeMsiPath -ErrorAction Stop).Path
  $LegacyOppositeMsi = (Resolve-Path -LiteralPath $LegacyOppositeMsiPath -ErrorAction Stop).Path
}
$NamePattern = "^Devolutions-PowerShell-(?<version>\d+\.\d+\.\d+\.\d+)-win-$Architecture\.msi$"
if ([System.IO.Path]::GetFileName($CurrentMsi) -notmatch $NamePattern) {
  throw "Unexpected MSI filename: $CurrentMsi"
}
$Version = [version] $Matches.version
if ([System.IO.Path]::GetFileName($LegacyMsi) -notmatch $NamePattern) {
  throw "Unexpected legacy MSI filename: $LegacyMsi"
}
$LegacyVersion = [version] $Matches.version
if ($LegacyVersion -ge $Version) {
  throw 'The legacy MSI must have an earlier version of the same architecture.'
}
if ($OppositeMsi) {
  $OppositeNamePattern = '^Devolutions-PowerShell-(?<version>\d+\.\d+\.\d+\.\d+)-win-x64\.msi$'
  if ([System.IO.Path]::GetFileName($OppositeMsi) -notmatch $OppositeNamePattern -or
      [version] $Matches.version -ne $Version) {
    throw 'The opposite-architecture MSI must match the current package version.'
  }
  if ([System.IO.Path]::GetFileName($LegacyOppositeMsi) -notmatch $OppositeNamePattern -or
      [version] $Matches.version -ne $LegacyVersion) {
    throw 'The opposite-architecture legacy MSI must match the previous package version.'
  }
}

$Installer = New-Object -ComObject WindowsInstaller.Installer
$Database = $Installer.OpenDatabase($CurrentMsi, 0)
$View = $Database.OpenView("SELECT Value FROM Property WHERE Property='ProductCode'")
$null = $View.Execute()
try {
  $Record = $View.Fetch()
  if (-not $Record -or $Record.StringData(1) -notmatch '^\{[0-9A-Fa-f-]{36}\}$') {
    throw "ProductCode was not found in $CurrentMsi."
  }
  $CurrentProductCode = $Record.StringData(1)
} finally {
  $null = $View.Close()
}

$ProgramFiles = [Environment]::GetFolderPath('ProgramFiles')
$SharedPath = Join-Path $ProgramFiles "Devolutions\PowerShell\$($Version.Major)"
$TerminalFragmentDirectory = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Microsoft\Windows Terminal\Fragments\Devolutions.PowerShell'
$TerminalFragmentPath = Join-Path $TerminalFragmentDirectory 'profile.json'
$WsManPluginRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WSMAN\Plugin'
$RemotingEndpointName = "PowerShell.$($Version.Major)"
$InstallerPropertiesRegistryPath = "HKLM:\Software\Devolutions\PowerShell\InstallerProperties\$Architecture"
$LegacyPath = Join-Path $ProgramFiles "Devolutions\PowerShell\$($LegacyVersion.Major)-$Architecture"
$LegacyOppositePath = Join-Path $ProgramFiles "Devolutions\PowerShell\$($LegacyVersion.Major)-x64"
$LogDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "pwsh-distro-msi-install-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $LogDirectory | Out-Null
$Succeeded = $false
$SavedWsManPlugins = @{}
if (Test-Path -LiteralPath $WsManPluginRoot) {
  foreach ($PluginKey in @(Get-ChildItem -LiteralPath $WsManPluginRoot -ErrorAction SilentlyContinue)) {
    if ($PluginKey.PSChildName -ieq $RemotingEndpointName -or
        $PluginKey.PSChildName.StartsWith("$RemotingEndpointName.", [System.StringComparison]::OrdinalIgnoreCase)) {
      $Prop = Get-ItemProperty -LiteralPath $PluginKey.PSPath -Name ConfigXML -ErrorAction SilentlyContinue
      if ($null -ne $Prop -and -not [string]::IsNullOrWhiteSpace($Prop.ConfigXML)) {
        $SavedWsManPlugins[$PluginKey.PSChildName] = [string] $Prop.ConfigXML
      }
    }
  }
}

function Invoke-Msi {
  param(
    [string] $Action,
    [string] $Msi,
    [int[]] $ExpectedExitCodes = @(0),
    [switch] $ExpectArchitectureBlock,
    [string] $ExtraArguments = ''
  )

  $Log = Join-Path $LogDirectory "$([guid]::NewGuid().ToString('N')).log"
  $Arguments = "$Action `"$Msi`" /qn /norestart /l*v `"$Log`""
  if (-not [string]::IsNullOrWhiteSpace($ExtraArguments)) {
    $Arguments += " $ExtraArguments"
  }
  $ExitCode = (Start-Process -FilePath msiexec.exe -ArgumentList $Arguments -Wait -PassThru).ExitCode
  if ($ExitCode -notin $ExpectedExitCodes) {
    if (Test-Path -LiteralPath $Log) {
      Get-Content -LiteralPath $Log -Tail 40 | ForEach-Object { Write-Host $_ }
    }
    throw "msiexec $Action $Msi returned $ExitCode; expected $($ExpectedExitCodes -join ', '). Log: $Log"
  }
  if ($ExpectArchitectureBlock -and
      -not (Select-String -LiteralPath $Log -Pattern 'Uninstall the other architecture of Devolutions PowerShell' -Quiet)) {
    throw "MSI rejection did not report the cross-architecture guard: $Log"
  }
}

function Assert-PowerShell {
  param([string] $Directory)

  $Exe = Join-Path $Directory 'pwsh.exe'
  if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) {
    throw "Installed PowerShell executable was not found: $Exe"
  }
  $ActualVersion = & $Exe -NoLogo -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()'
  if ($LASTEXITCODE -ne 0 -or $ActualVersion -ne "$($Version.Major).$($Version.Minor).$($Version.Build)") {
    throw "Installed PowerShell did not run at $Directory (version: $ActualVersion, exit: $LASTEXITCODE)."
  }
  if ($RequireSignature -and $Directory -eq $SharedPath) {
    foreach ($Name in 'pwsh.exe', 'pwsh.dll', 'System.Management.Automation.dll') {
      $Binary = Join-Path $Directory $Name
      if (-not (Test-Path -LiteralPath $Binary -PathType Leaf)) {
        throw "Signed MSI is missing the installed payload $Binary."
      }
      $Signature = Get-AuthenticodeSignature -LiteralPath $Binary
      if ($Signature.Status -ne 'Valid') {
        throw "Installed payload has an invalid signature: $Binary ($($Signature.Status))."
      }
    }
  }
}

function Assert-WindowsTerminalProfile {
  param(
    [Parameter(Mandatory)] [string] $Directory,
    [Parameter(Mandatory)] [bool] $ExpectedPresent
  )

  if (-not $ExpectedPresent) {
    if (Test-Path -LiteralPath $TerminalFragmentPath) {
      throw "Windows Terminal profile fragment was not removed: $TerminalFragmentPath"
    }
    return
  }

  if (-not (Test-Path -LiteralPath $TerminalFragmentPath -PathType Leaf)) {
    throw "Windows Terminal profile fragment was not installed: $TerminalFragmentPath"
  }
  $ProfileDocument = Get-Content -LiteralPath $TerminalFragmentPath -Raw | ConvertFrom-Json
  $Profiles = @($ProfileDocument.profiles)
  $ExpectedCommandLine = '"' + (Join-Path $Directory 'pwsh.exe') + '"'
  if ($Profiles.Count -ne 1 -or
      $Profiles[0].guid -ne '{346bd64d-48b7-5053-a8ff-5815de1a38c2}' -or
      $Profiles[0].name -ne 'PowerShell' -or
      $Profiles[0].commandline -ne $ExpectedCommandLine -or
      $Profiles[0].icon -ne 'ms-appx:///ProfileIcons/pwsh.png' -or
      $Profiles[0].startingDirectory -ne '%USERPROFILE%') {
    throw "Windows Terminal profile fragment does not target the installed PowerShell at $Directory."
  }
}

function Assert-BlockedInstallation {
  param([string] $IncomingMsi)

  $Exe = Join-Path $SharedPath 'pwsh.exe'
  $Before = (Get-FileHash -LiteralPath $Exe -Algorithm SHA256).Hash
  Invoke-Msi '/i' $IncomingMsi -ExpectedExitCodes @(1603) -ExpectArchitectureBlock
  if ((Get-FileHash -LiteralPath $Exe -Algorithm SHA256).Hash -ne $Before) {
    throw "Blocked cross-architecture install changed the existing PowerShell executable: $IncomingMsi"
  }
  Assert-PowerShell $SharedPath
}

try {
  if (Test-Path -LiteralPath $SharedPath) {
    throw "Expected a clean runner, but the MSI directory already exists: $SharedPath"
  }
  if (Test-Path -LiteralPath $TerminalFragmentPath) {
    throw "Expected a clean runner, but a Windows Terminal profile fragment already exists: $TerminalFragmentPath"
  }

  Invoke-Msi '/i' $CurrentMsi
  Assert-PowerShell $SharedPath
  Assert-WindowsTerminalProfile $SharedPath $true
  Invoke-Msi '/x' $CurrentMsi
  Assert-WindowsTerminalProfile $SharedPath $false
  if (Test-Path -LiteralPath (Join-Path $SharedPath 'pwsh.exe')) {
    throw 'Fresh-install removal left PowerShell at the shared path.'
  }

  Invoke-Msi '/i' $LegacyMsi
  Assert-PowerShell $LegacyPath
  Assert-WindowsTerminalProfile $LegacyPath $true
  Invoke-Msi '/i' $CurrentMsi
  Assert-PowerShell $SharedPath
  Assert-WindowsTerminalProfile $SharedPath $true
  if (Test-Path -LiteralPath (Join-Path $LegacyPath 'pwsh.exe')) {
    throw "The prior MSI's $LegacyPath installation was not removed on upgrade."
  }
  Remove-Item -LiteralPath (Join-Path $SharedPath 'pwsh.exe')
  Remove-Item -LiteralPath $TerminalFragmentPath
  Invoke-Msi '/fa' $CurrentProductCode
  Assert-PowerShell $SharedPath
  Assert-WindowsTerminalProfile $SharedPath $true

  if ($OppositeMsi) {
    Assert-BlockedInstallation $OppositeMsi
    Assert-WindowsTerminalProfile $SharedPath $true
    Invoke-Msi '/i' $LegacyOppositeMsi
    Assert-PowerShell $LegacyOppositePath
    Assert-WindowsTerminalProfile $LegacyOppositePath $true
    Assert-BlockedInstallation $OppositeMsi
    Invoke-Msi '/fa' $CurrentProductCode
    Invoke-Msi '/x' $CurrentMsi
    Assert-WindowsTerminalProfile $SharedPath $false
    if (Test-Path -LiteralPath (Join-Path $SharedPath 'pwsh.exe')) {
      throw 'Uninstall left the new PowerShell executable at the shared path.'
    }
    Assert-PowerShell $LegacyOppositePath
    Invoke-Msi '/x' $LegacyOppositeMsi

    Invoke-Msi '/i' $OppositeMsi
    Assert-PowerShell $SharedPath
    Assert-BlockedInstallation $CurrentMsi
    Invoke-Msi '/x' $OppositeMsi
    Assert-WindowsTerminalProfile $SharedPath $false
  } else {
    Invoke-Msi '/x' $CurrentMsi
    Assert-WindowsTerminalProfile $SharedPath $false
  }

  if (Test-Path -LiteralPath (Join-Path $SharedPath 'pwsh.exe')) {
    throw 'Uninstall left the new PowerShell executable at the shared path.'
  }

  # Exercise WinRM remoting registration on legacy install, migration across upgrade, and removal on uninstall
  Invoke-Msi '/i' $LegacyMsi -ExtraArguments 'ENABLE_PSREMOTING=1'
  $RemotingKeyPath = Join-Path $WsManPluginRoot $RemotingEndpointName
  if (-not (Test-Path -LiteralPath $RemotingKeyPath)) {
    throw "MSI ENABLE_PSREMOTING=1 did not register $RemotingEndpointName."
  }
  $LegacyRemotingDoc = [xml] (Get-ItemProperty -LiteralPath $RemotingKeyPath -Name ConfigXML).ConfigXML
  $ExpectedLegacyPlugin = "%ProgramFiles%\Devolutions\PowerShell\$($LegacyVersion.Major)-$Architecture\pwrshplugin.dll"
  if ($LegacyRemotingDoc.PlugInConfiguration.Filename -cne $ExpectedLegacyPlugin -or
      ($LegacyRemotingDoc.PlugInConfiguration.InitializationParameters.Param | Where-Object { $_.Name -ieq 'PSVersion' }).Value -cne "$($LegacyVersion.Major)") {
    throw "Legacy MSI ENABLE_PSREMOTING=1 did not configure $RemotingEndpointName to $ExpectedLegacyPlugin with PSVersion=$($LegacyVersion.Major)."
  }

  Invoke-Msi '/i' $CurrentMsi
  $CurrentRemotingDoc = [xml] (Get-ItemProperty -LiteralPath $RemotingKeyPath -Name ConfigXML).ConfigXML
  $ExpectedSharedPlugin = "%ProgramFiles%\Devolutions\PowerShell\$($Version.Major)\pwrshplugin.dll"
  if ($CurrentRemotingDoc.PlugInConfiguration.Filename -cne $ExpectedSharedPlugin -or
      ($CurrentRemotingDoc.PlugInConfiguration.InitializationParameters.Param | Where-Object { $_.Name -ieq 'PSVersion' }).Value -cne "$($Version.Major)") {
    throw "Upgraded MSI did not migrate $RemotingEndpointName to $ExpectedSharedPlugin with PSVersion=$($Version.Major)."
  }
  $VersionPinnedPluginKey = Join-Path $WsManPluginRoot "PowerShell.$($Version.Major).$($Version.Minor).$($Version.Build)"
  $System32VersionCopyDir = Join-Path ([Environment]::GetFolderPath('Windows')) "System32\PowerShell\$($Version.Major).$($Version.Minor).$($Version.Build)"
  if ((Test-Path -LiteralPath $VersionPinnedPluginKey) -or (Test-Path -LiteralPath $System32VersionCopyDir)) {
    throw 'MSI remoting setup unexpectedly created a patch-pinned endpoint or System32\PowerShell plugin copy.'
  }

  Invoke-Msi '/x' $CurrentMsi
  if (Test-Path -LiteralPath $RemotingKeyPath) {
    throw "MSI uninstall did not remove the Devolutions-owned $RemotingEndpointName WSMan plugin."
  }

  $Succeeded = $true
  Write-Host "Passed $Architecture fresh install, same-architecture upgrade, repair, WinRM remoting, and uninstall tests."
} finally {
  $CleanupFailures = @()
  foreach ($Msi in @($CurrentMsi, $LegacyMsi, $OppositeMsi, $LegacyOppositeMsi)) {
    if ($Msi) {
      $ExitCode = (Start-Process -FilePath msiexec.exe -ArgumentList "/x `"$Msi`" /qn /norestart" -Wait -PassThru).ExitCode
      if ($ExitCode -notin @(0, 1605)) {
        $CleanupFailures += "Cleanup of $Msi returned MSI exit code $ExitCode."
      }
    }
  }
  if (Test-Path -LiteralPath $InstallerPropertiesRegistryPath) {
    Remove-Item -LiteralPath $InstallerPropertiesRegistryPath -Recurse -Force -ErrorAction SilentlyContinue
  }
  if (Test-Path -LiteralPath $WsManPluginRoot) {
    foreach ($PluginKey in @(Get-ChildItem -LiteralPath $WsManPluginRoot -ErrorAction SilentlyContinue)) {
      if ($PluginKey.PSChildName -ieq $RemotingEndpointName -or
          $PluginKey.PSChildName.StartsWith("$RemotingEndpointName.", [System.StringComparison]::OrdinalIgnoreCase)) {
        if (-not $SavedWsManPlugins.ContainsKey($PluginKey.PSChildName)) {
          Remove-Item -LiteralPath $PluginKey.PSPath -Recurse -Force -ErrorAction SilentlyContinue
        }
      }
    }
  }
  foreach ($SavedEntry in $SavedWsManPlugins.GetEnumerator()) {
    $RestoreKeyPath = Join-Path $WsManPluginRoot $SavedEntry.Key
    if (-not (Test-Path -LiteralPath $RestoreKeyPath)) {
      New-Item -Path $RestoreKeyPath -Force | Out-Null
    }
    Set-ItemProperty -LiteralPath $RestoreKeyPath -Name ConfigXML -Value $SavedEntry.Value
  }
  $WinRmService = Get-Service -Name 'winrm' -ErrorAction SilentlyContinue
  if ($null -ne $WinRmService -and $WinRmService.Status -eq 'Running') {
    Restart-Service -Name 'winrm' -Force -Confirm:$false -ErrorAction SilentlyContinue
  }
  if ($Succeeded -and $CleanupFailures.Count -eq 0) {
    Remove-Item -LiteralPath $LogDirectory -Recurse -Force
  } else {
    Write-Warning "MSI logs retained for diagnosis: $LogDirectory"
  }
  if ($CleanupFailures.Count -gt 0) {
    throw $CleanupFailures -join "`n"
  }
}
