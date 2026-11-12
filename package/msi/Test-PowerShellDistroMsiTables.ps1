[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $MsiPath,

  [Parameter(Mandatory)]
  [ValidateSet('x64', 'arm64')]
  [string] $Architecture,

  [Parameter(Mandatory)]
  [ValidatePattern('^\d+\.\d+\.\d+\.\d+$')]
  [string] $PackageVersion
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
  throw 'MSI database validation requires Windows.'
}

function Get-MsiRows {
  param(
    [Parameter(Mandatory)] $Database,
    [Parameter(Mandatory)] [string] $Query,
    [Parameter(Mandatory)] [int] $Columns
  )

  $View = $null
  try {
    $View = $Database.OpenView($Query)
    $null = $View.Execute()
    while ($Record = $View.Fetch()) {
      try {
        [pscustomobject]@{
          Fields = @(1..$Columns | ForEach-Object { $Record.StringData($_) })
        }
      } finally {
        [void] [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($Record)
      }
    }
  } finally {
    if ($null -ne $View) {
      try {
        $null = $View.Close()
      } finally {
        [void] [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($View)
      }
    }
  }
}

function Assert-OneRow {
  param([object[]] $Rows, [string] $Description)

  if ($Rows.Count -ne 1) {
    throw "Expected one $Description row, found $($Rows.Count)."
  }
  return $Rows[0].Fields
}

$Codes = @{
  x64 = '{D26B2030-FE59-4BBE-9CFC-8A5F5F934B38}'
  arm64 = '{CEA78373-E1E6-425C-B8D9-CD7E18F6821E}'
}
$Opposite = if ($Architecture -eq 'x64') { 'arm64' } else { 'x64' }
$Version = [version] $PackageVersion
$MsiVersion = "$($Version.Major).$($Version.Minor).$($Version.Build * 100 + $Version.Revision)"
$File = (Resolve-Path -LiteralPath $MsiPath -ErrorAction Stop).Path
$Installer = New-Object -ComObject WindowsInstaller.Installer
$Database = $null
try {
  $Database = $Installer.OpenDatabase($File, 0)

  $Properties = @(Get-MsiRows $Database 'SELECT Property, Value FROM Property' 2)
  $ProductVersion = Assert-OneRow @($Properties | Where-Object { $_.Fields[0] -eq 'ProductVersion' }) 'ProductVersion'
  $UpgradeCode = Assert-OneRow @($Properties | Where-Object { $_.Fields[0] -eq 'UpgradeCode' }) 'UpgradeCode'
  $Secure = Assert-OneRow @($Properties | Where-Object { $_.Fields[0] -eq 'SecureCustomProperties' }) 'SecureCustomProperties'
  $SecureProperties = @($Secure[1] -split ';')
  if ($ProductVersion[1] -ne $MsiVersion -or $UpgradeCode[1] -ine $Codes[$Architecture] -or
      'OPPOSITE_ARCHITECTURE_INSTALLED' -notin $SecureProperties -or
      'ENABLE_PSREMOTING' -notin $SecureProperties -or
      'SKIP_NETWORK_PROFILE_CHECK' -notin $SecureProperties) {
    throw "MSI version, own UpgradeCode, or secure custom properties are incorrect in $File."
  }

  $FileRows = @(Get-MsiRows $Database 'SELECT File, Component_, FileName FROM File' 3)
  $RemotingScriptFile = Assert-OneRow @($FileRows | Where-Object { $_.Fields[0] -eq 'PowerShellRemotingScriptFile' }) 'PowerShell remoting script file'
  if ($RemotingScriptFile[1] -ne 'PowerShellRemotingScript' -or
      ($RemotingScriptFile[2] -split '\|')[-1] -ne 'Register-PowerShellRemoting.ps1') {
    throw "MSI PowerShellRemotingScriptFile row is incorrect in $File."
  }

  $Directories = @(Get-MsiRows $Database 'SELECT Directory, Directory_Parent, DefaultDir FROM Directory' 3)
  foreach ($Expected in @(
    @('INSTALLFOLDER', 'ProgramFiles64Folder', 'Devolutions'),
    @('PowerShellFolder', 'INSTALLFOLDER', 'PowerShell'),
    @('VersionFolder', 'PowerShellFolder', "$($Version.Major)")
  )) {
    $Directory = Assert-OneRow @($Directories | Where-Object { $_.Fields[0] -eq $Expected[0] }) "directory $($Expected[0])"
    if ($Directory[1] -ne $Expected[1] -or ($Directory[2] -split '\|')[-1] -ne $Expected[2]) {
      throw "MSI directory $($Expected[0]) is not below $($Expected[1]) as $($Expected[2])."
    }
  }

  $Upgrades = @(Get-MsiRows $Database 'SELECT UpgradeCode, VersionMin, VersionMax, Attributes, Remove, ActionProperty FROM Upgrade' 6)
  $Guard = Assert-OneRow @($Upgrades | Where-Object { $_.Fields[5] -eq 'OPPOSITE_ARCHITECTURE_INSTALLED' }) 'opposite-architecture upgrade'
  if ($Guard[0] -ine $Codes[$Opposite] -or $Guard[1] -ne '0.0.0' -or $Guard[2] -ne '' -or
      [int] $Guard[3] -ne 258 -or $Guard[4] -ne '') {
    throw "Opposite-architecture detection must cover all versions without removing the product: $File."
  }
  $SameArchitecture = Assert-OneRow @($Upgrades | Where-Object { $_.Fields[5] -eq 'WIX_UPGRADE_DETECTED' }) 'same-architecture upgrade'
  if ($SameArchitecture[0] -ine $Codes[$Architecture] -or $SameArchitecture[2] -ne $MsiVersion) {
    throw "Same-architecture major upgrades are not enabled in $File."
  }

  $Conditions = @(Get-MsiRows $Database 'SELECT Condition, Description FROM LaunchCondition' 2)
  $null = Assert-OneRow @($Conditions | Where-Object { $_.Fields[0] -eq 'Installed OR NOT OPPOSITE_ARCHITECTURE_INSTALLED' }) 'cross-architecture launch condition'
  foreach ($Table in 'InstallUISequence', 'InstallExecuteSequence') {
    $Actions = @(Get-MsiRows $Database "SELECT Action, Sequence FROM $Table" 2)
    $Find = Assert-OneRow @($Actions | Where-Object { $_.Fields[0] -eq 'FindRelatedProducts' }) "$Table FindRelatedProducts"
    $Launch = Assert-OneRow @($Actions | Where-Object { $_.Fields[0] -eq 'LaunchConditions' }) "$Table LaunchConditions"
    if ([int] $Find[1] -ge [int] $Launch[1]) {
      throw "FindRelatedProducts must run before LaunchConditions in $Table."
    }
    if ($Table -eq 'InstallExecuteSequence') {
      $ExecuteConditions = @(Get-MsiRows $Database 'SELECT Action, Condition, Sequence FROM InstallExecuteSequence' 3)
      $EnableRemotingAction = Assert-OneRow @($ExecuteConditions | Where-Object { $_.Fields[0] -eq 'EnablePSRemoting' }) 'EnablePSRemoting action'
      $DisableRemotingAction = Assert-OneRow @($ExecuteConditions | Where-Object { $_.Fields[0] -eq 'DisablePSRemotingOnUninstall' }) 'DisablePSRemotingOnUninstall action'
      $InstallProfile = Assert-OneRow @($Actions | Where-Object { $_.Fields[0] -eq 'InstallWindowsTerminalProfile' }) 'Windows Terminal profile installation action'
      $RollbackProfile = Assert-OneRow @($Actions | Where-Object { $_.Fields[0] -eq 'RollbackWindowsTerminalProfile' }) 'RollbackWindowsTerminalProfile action'
      $InstallFiles = Assert-OneRow @($Actions | Where-Object { $_.Fields[0] -eq 'InstallFiles' }) 'InstallFiles'
      $RemoveFiles = Assert-OneRow @($Actions | Where-Object { $_.Fields[0] -eq 'RemoveFiles' }) 'RemoveFiles'
      if ($EnableRemotingAction[1] -ne 'NOT REMOVE' -or
          [int] $EnableRemotingAction[2] -le [int] $InstallFiles[1]) {
        throw 'EnablePSRemoting must run after InstallFiles whenever the product is not being removed.'
      }
      if ($DisableRemotingAction[1] -ne 'Installed AND (REMOVE="ALL") AND (NOT UPGRADINGPRODUCTCODE)' -or
          [int] $DisableRemotingAction[2] -ge [int] $RemoveFiles[1]) {
        throw 'DisablePSRemotingOnUninstall must run before RemoveFiles only on full uninstall.'
      }
      if ([int] $RollbackProfile[1] -le [int] $InstallFiles[1] -or
          [int] $InstallProfile[1] -le [int] $RollbackProfile[1] -or
          [int] $RemoveFiles[1] -ge [int] $InstallFiles[1]) {
        throw 'Windows Terminal profile actions must schedule rollback before installation and after files are installed.'
      }
      $RemoveFilesRows = @(Get-MsiRows $Database 'SELECT FileKey, Component_, FileName, DirProperty, InstallMode FROM RemoveFile' 5)
      $FragmentRemoveFile = Assert-OneRow @($RemoveFilesRows | Where-Object { $_.Fields[0] -eq 'RemoveWindowsTerminalProfileFile' }) 'Windows Terminal fragment RemoveFile entry'
      $FragmentRemoveFolder = Assert-OneRow @($RemoveFilesRows | Where-Object { $_.Fields[0] -eq 'RemoveWindowsTerminalProfileFragmentDirectory' }) 'Windows Terminal fragment RemoveFolder entry'
      if ($FragmentRemoveFile[1] -ne 'WindowsTerminalProfileCleanup' -or
          ($FragmentRemoveFile[2] -split '\|')[-1] -ne 'profile.json' -or
          $FragmentRemoveFile[3] -ne 'WindowsTerminalProfileFragmentDirectory' -or
          [int] $FragmentRemoveFile[4] -ne 2 -or
          $FragmentRemoveFolder[1] -ne 'WindowsTerminalProfileCleanup' -or
          $FragmentRemoveFolder[2] -ne '' -or
          $FragmentRemoveFolder[3] -ne 'WindowsTerminalProfileFragmentDirectory' -or
          [int] $FragmentRemoveFolder[4] -ne 2) {
        throw 'Windows Terminal fragment removal must use MSI RemoveFile/RemoveFolder on uninstall.'
      }
      $Remove = Assert-OneRow @($Actions | Where-Object { $_.Fields[0] -eq 'RemoveExistingProducts' }) 'RemoveExistingProducts'
      $Initialize = Assert-OneRow @($Actions | Where-Object { $_.Fields[0] -eq 'InstallInitialize' }) 'InstallInitialize'
      if ([int] $Remove[1] -ge [int] $Initialize[1]) {
        throw 'Prior same-architecture installations must be removed before files are installed.'
      }
    }
  }

  Write-Host "Validated $Architecture MSI tables and upgrade guard: $File"
} finally {
  if ($null -ne $Database) {
    [void] [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($Database)
  }
  if ($null -ne $Installer) {
    [void] [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($Installer)
  }
}
