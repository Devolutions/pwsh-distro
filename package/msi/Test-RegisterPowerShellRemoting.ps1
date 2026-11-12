[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
  throw 'Register-PowerShellRemoting tests require Windows.'
}

$ScriptPath = Join-Path $PSScriptRoot 'Register-PowerShellRemoting.ps1'
if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
  throw "Script under test was not found: $ScriptPath"
}

$TestId = [guid]::NewGuid().ToString('N')
$BaseTemp = if ($Env:RUNNER_TEMP) {
  $Env:RUNNER_TEMP
} elseif ($Env:LOCALAPPDATA -and (Test-Path -LiteralPath (Join-Path $Env:LOCALAPPDATA 'Temp') -PathType Container)) {
  Join-Path $Env:LOCALAPPDATA 'Temp'
} else {
  [System.IO.Path]::GetTempPath()
}
$TempRoot = Join-Path $BaseTemp "pwsh-distro-remoting-test-$TestId"
$RegRoot = "HKCU:\Software\Devolutions\PowerShellRemotingTests\$TestId\Plugin"

function Assert-PluginConfig {
  param(
    [Parameter(Mandatory)] [string] $EndpointName,
    [Parameter(Mandatory)] [string] $ExpectedFilename,
    [Parameter(Mandatory)] [string] $ExpectedPsVersion,
    [string] $ExpectedSddlSubstring,
    [string] $ExpectedMaxShellsPerUser
  )

  $KeyPath = Join-Path $RegRoot $EndpointName
  if (-not (Test-Path -LiteralPath $KeyPath)) {
    throw "Expected WSMan plugin key was not found: $KeyPath"
  }

  $Doc = [xml] (Get-ItemProperty -LiteralPath $KeyPath -Name ConfigXML).ConfigXML
  if ($Doc.PlugInConfiguration.Filename -cne $ExpectedFilename) {
    throw "Endpoint '$EndpointName' Filename was '$($Doc.PlugInConfiguration.Filename)', expected '$ExpectedFilename'."
  }

  $PsVersionNode = @($Doc.PlugInConfiguration.InitializationParameters.Param | Where-Object { $_.Name -ieq 'PSVersion' })
  if ($PsVersionNode.Count -ne 1 -or $PsVersionNode[0].Value -cne $ExpectedPsVersion) {
    throw "Endpoint '$EndpointName' PSVersion was not '$ExpectedPsVersion'."
  }

  if ($ExpectedSddlSubstring -and $Doc.OuterXml -notlike "*$ExpectedSddlSubstring*") {
    throw "Endpoint '$EndpointName' did not preserve custom SDDL '$ExpectedSddlSubstring'."
  }

  if ($ExpectedMaxShellsPerUser -and $Doc.PlugInConfiguration.Quotas.MaxShellsPerUser -ne $ExpectedMaxShellsPerUser) {
    throw "Endpoint '$EndpointName' did not preserve custom quota MaxShellsPerUser='$ExpectedMaxShellsPerUser'."
  }
}

$ReviewRegressionFailures = [System.Collections.Generic.List[string]]::new()

function Invoke-ReviewRegressionCase {
  param(
    [Parameter(Mandatory)] [string] $Name,
    [Parameter(Mandatory)] [scriptblock] $Body,
    [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.List[string]] $Failures
  )

  try {
    & $Body
    Write-Host "PASS $Name"
  } catch {
    $Failure = "$Name`: $($_.Exception.Message) $($_.ScriptStackTrace)"
    $Failures.Add($Failure)
    Write-Host "FAIL $Failure"
  }
}

function Set-TestPluginConfig {
  param(
    [Parameter(Mandatory)] [string] $RegistryRoot,
    [Parameter(Mandatory)] [string] $EndpointName,
    [Parameter(Mandatory)] [string] $Filename,
    [Parameter(Mandatory)] [string] $PsVersion
  )

  $KeyPath = Join-Path $RegistryRoot $EndpointName
  New-Item -Path $KeyPath -Force | Out-Null
  $Document = [xml] @'
<PlugInConfiguration xmlns="http://schemas.microsoft.com/wbem/wsman/1/config/PluginConfiguration" Name="" Filename="" SDKVersion="2" XmlRenderingType="text" Enabled="True">
  <InitializationParameters>
    <Param Name="PSVersion" Value="" />
  </InitializationParameters>
</PlugInConfiguration>
'@
  $Document.PlugInConfiguration.SetAttribute('Name', $EndpointName)
  $Document.PlugInConfiguration.SetAttribute('Filename', $Filename)
  $Document.PlugInConfiguration.InitializationParameters.Param.SetAttribute('Value', $PsVersion)
  Set-ItemProperty -LiteralPath $KeyPath -Name ConfigXML -Value $Document.OuterXml
}

function Assert-DefaultNetworkProfileCheck {
  $ProductPath = Join-Path $PSScriptRoot 'assets\wix\Product.wxs'
  [xml] $Product = Get-Content -LiteralPath $ProductPath -Raw
  $CommandSetters = @($Product.SelectNodes("//*[local-name()='SetProperty' and @Id='EnablePSRemoting']"))
  if ($CommandSetters.Count -ne 1) {
    throw "Expected one EnablePSRemoting deferred-command setter, found $($CommandSetters.Count)."
  }

  $Command = [string] $CommandSetters[0].GetAttribute('Value')
  if ($Command -match '(?i)SkipNetworkProfileCheck|SKIP_NETWORK_PROFILE_CHECK') {
    throw 'The MSI deferred command must preserve the default network-profile check behavior.'
  }
  if (@($Product.SelectNodes("//*[local-name()='Property' and @Id='SKIP_NETWORK_PROFILE_CHECK']")).Count -gt 0) {
    throw 'The MSI must not expose SKIP_NETWORK_PROFILE_CHECK as a public property.'
  }
}

try {
  $FakeProgramFiles = Join-Path $TempRoot 'Program Files'
  $DevolutionsShared = Join-Path $FakeProgramFiles 'Devolutions\PowerShell\7'
  $DevolutionsLegacy = Join-Path $FakeProgramFiles 'Devolutions\PowerShell\7-x64'
  $MicrosoftInstall = Join-Path $FakeProgramFiles 'PowerShell\7'
  $FakeSystem32Ps = Join-Path $TempRoot 'Windows\System32\PowerShell'

  foreach ($Dir in @($DevolutionsShared, $DevolutionsLegacy, $MicrosoftInstall, $FakeSystem32Ps)) {
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
  }
  foreach ($Dir in @($DevolutionsShared, $DevolutionsLegacy, $MicrosoftInstall)) {
    Set-Content -LiteralPath (Join-Path $Dir 'pwrshplugin.dll') -Value 'stub' -Encoding ascii
    Set-Content -LiteralPath (Join-Path $Dir 'System.Management.Automation.dll') -Value 'stub' -Encoding ascii
  }
  New-Item -Path $RegRoot -Force | Out-Null

  # 1. Fresh install with EnableRemoting=0 does nothing and preserves Microsoft's PowerShell.7
  & $ScriptPath `
    -InstallLocation $DevolutionsShared `
    -Mode Install `
    -EnableRemoting '0' `
    -MajorVersion '7' `
    -PreReleaseLabel '' `
    -WsManPluginRegistryPath $RegRoot `
    -System32PowerShellDirectory $FakeSystem32Ps `
    -ProgramFilesDirectory $FakeProgramFiles `
    -SkipServiceControl
  if (Test-Path -LiteralPath (Join-Path $RegRoot 'PowerShell.7')) {
    throw 'EnableRemoting=0 created PowerShell.7 unexpectedly.'
  }
  Write-Host 'PASS InstallWithRemotingDisabledDoesNotCreateEndpoint'

  # 2. Seed legacy System32 copies + endpoints (Devolutions 7.6.8, missing 7.2.17, and active Microsoft 7.4.6)
  $DevoSys32 = Join-Path $FakeSystem32Ps '7.6.8'
  $MissingSys32 = Join-Path $FakeSystem32Ps '7.2.17'
  $MsftSys32 = Join-Path $FakeSystem32Ps '7.4.6'
  $OrphanMajorSys32 = Join-Path $FakeSystem32Ps '7'
  foreach ($Dir in @($DevoSys32, $MissingSys32, $MsftSys32, $OrphanMajorSys32)) {
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $Dir 'pwrshplugin.dll') -Value 'stub' -Encoding ascii
  }
  Set-Content -LiteralPath (Join-Path $DevoSys32 'RemotePowerShellConfig.txt') -Value "PSHOMEDIR=$DevolutionsLegacy`r`nCORECLRDIR=$DevolutionsLegacy" -Encoding utf8
  Set-Content -LiteralPath (Join-Path $MissingSys32 'RemotePowerShellConfig.txt') -Value "PSHOMEDIR=$TempRoot\Removed\PowerShell\7`r`nCORECLRDIR=$TempRoot\Removed\PowerShell\7" -Encoding utf8
  Set-Content -LiteralPath (Join-Path $MsftSys32 'RemotePowerShellConfig.txt') -Value "PSHOMEDIR=$MicrosoftInstall`r`nCORECLRDIR=$MicrosoftInstall" -Encoding utf8

  foreach ($Entry in @(
    @{ Name = 'PowerShell.7'; File = (Join-Path $DevoSys32 'pwrshplugin.dll'); Version = '7.6'; Sddl = 'O:NSG:BAD:P(A;;GA;;;BA)(A;;GA;;;S-1-5-21-999)'; Quota = '42' },
    @{ Name = 'PowerShell.7.6.8'; File = (Join-Path $DevoSys32 'pwrshplugin.dll'); Version = '7.6'; Sddl = 'O:NSG:BAD:P(A;;GA;;;BA)'; Quota = '25' },
    @{ Name = 'PowerShell.7.2.17'; File = (Join-Path $MissingSys32 'pwrshplugin.dll'); Version = '7.2'; Sddl = 'O:NSG:BAD:P(A;;GA;;;BA)'; Quota = '25' },
    @{ Name = 'PowerShell.7.4.6'; File = (Join-Path $MsftSys32 'pwrshplugin.dll'); Version = '7.4'; Sddl = 'O:NSG:BAD:P(A;;GA;;;BA)'; Quota = '25' }
  )) {
    $EntryKey = Join-Path $RegRoot $Entry.Name
    New-Item -Path $EntryKey -Force | Out-Null
    $Xml = @"
<PlugInConfiguration xmlns="http://schemas.microsoft.com/wbem/wsman/1/config/PluginConfiguration" Name="$($Entry.Name)" Filename="$($Entry.File)" SDKVersion="2" XmlRenderingType="text" Enabled="false">
  <InitializationParameters>
    <Param Name="PSVersion" Value="$($Entry.Version)" />
  </InitializationParameters>
  <Resources>
    <Resource ResourceUri="http://schemas.microsoft.com/powershell/$($Entry.Name)" SupportsOptions="true" ExactMatch="false">
      <Security Uri="http://schemas.microsoft.com/powershell/$($Entry.Name)" ExactMatch="false" Sddl="$($Entry.Sddl)" />
      <Capability Type="Shell" />
    </Resource>
  </Resources>
  <Quotas MaxShellsPerUser="$($Entry.Quota)" />
</PlugInConfiguration>
"@
    Set-ItemProperty -LiteralPath $EntryKey -Name ConfigXML -Value $Xml
  }

  # 3. Install with EnableRemoting=1 refreshes PowerShell.7 in place (preserving custom SDDL + Quotas)
  #    and cleans only Devolutions/missing legacy endpoints and System32 directories
  & $ScriptPath `
    -InstallLocation $DevolutionsShared `
    -Mode Install `
    -EnableRemoting '1' `
    -MajorVersion '7' `
    -PreReleaseLabel '' `
    -WsManPluginRegistryPath $RegRoot `
    -System32PowerShellDirectory $FakeSystem32Ps `
    -ProgramFilesDirectory $FakeProgramFiles `
    -SkipServiceControl

  Assert-PluginConfig `
    -EndpointName 'PowerShell.7' `
    -ExpectedFilename '%ProgramFiles%\Devolutions\PowerShell\7\pwrshplugin.dll' `
    -ExpectedPsVersion '7' `
    -ExpectedSddlSubstring 'S-1-5-21-999' `
    -ExpectedMaxShellsPerUser '42'

  if ((Test-Path -LiteralPath (Join-Path $RegRoot 'PowerShell.7.6.8')) -or
      (Test-Path -LiteralPath (Join-Path $RegRoot 'PowerShell.7.2.17'))) {
    throw 'Devolutions or missing legacy PowerShell.7.* endpoints were not removed.'
  }
  if (-not (Test-Path -LiteralPath (Join-Path $RegRoot 'PowerShell.7.4.6'))) {
    throw 'Valid side-by-side Microsoft PowerShell.7.4.6 endpoint was unexpectedly removed.'
  }
  if ((Test-Path -LiteralPath $DevoSys32) -or
      (Test-Path -LiteralPath $MissingSys32) -or
      (Test-Path -LiteralPath $OrphanMajorSys32)) {
    throw 'Devolutions or orphaned System32\PowerShell directories were not cleaned up.'
  }
  if (-not (Test-Path -LiteralPath (Join-Path $MsftSys32 'pwrshplugin.dll'))) {
    throw 'Referenced Microsoft System32\PowerShell\7.4.6 directory was unexpectedly removed.'
  }
  Write-Host 'PASS EnableRemotingRefreshesInPlaceAndCleansTargetedLegacyArtifacts'

  # 4. Upgrade with EnableRemoting=0 still migrates an existing Devolutions PowerShell.7 from 7-x64 to 7
  $LegacyKey = Join-Path $RegRoot 'PowerShell.7'
  $LegacyXml = ([xml] (Get-ItemProperty -LiteralPath $LegacyKey -Name ConfigXML).ConfigXML)
  $LegacyXml.PlugInConfiguration.SetAttribute('Filename', '%ProgramFiles%\Devolutions\PowerShell\7-x64\pwrshplugin.dll')
  $LegacyXml.PlugInConfiguration.InitializationParameters.Param.SetAttribute('Value', '7.6')
  Set-ItemProperty -LiteralPath $LegacyKey -Name ConfigXML -Value $LegacyXml.OuterXml

  & $ScriptPath `
    -InstallLocation $DevolutionsShared `
    -Mode Install `
    -EnableRemoting '0' `
    -MajorVersion '7' `
    -PreReleaseLabel '' `
    -WsManPluginRegistryPath $RegRoot `
    -System32PowerShellDirectory $FakeSystem32Ps `
    -ProgramFilesDirectory $FakeProgramFiles `
    -SkipServiceControl

  Assert-PluginConfig `
    -EndpointName 'PowerShell.7' `
    -ExpectedFilename '%ProgramFiles%\Devolutions\PowerShell\7\pwrshplugin.dll' `
    -ExpectedPsVersion '7'
  Write-Host 'PASS UpgradeWithSavedZeroStillMigratesManuallyRegisteredDevolutionsEndpoint'

  # 5. Uninstall removes PowerShell.7 when owned by Devolutions, but preserves PowerShell.7 when owned by Microsoft
  & $ScriptPath `
    -InstallLocation $DevolutionsShared `
    -Mode Uninstall `
    -MajorVersion '7' `
    -PreReleaseLabel '' `
    -WsManPluginRegistryPath $RegRoot `
    -System32PowerShellDirectory $FakeSystem32Ps `
    -ProgramFilesDirectory $FakeProgramFiles `
    -SkipServiceControl

  if (Test-Path -LiteralPath (Join-Path $RegRoot 'PowerShell.7')) {
    throw 'Uninstall did not remove Devolutions-owned PowerShell.7 endpoint.'
  }
  if (-not (Test-Path -LiteralPath (Join-Path $RegRoot 'PowerShell.7.4.6'))) {
    throw 'Uninstall removed non-Devolutions PowerShell.7.4.6 endpoint.'
  }

  # Point PowerShell.7 at Microsoft PowerShell and verify Devolutions uninstall leaves it untouched
  New-Item -Path $LegacyKey -Force | Out-Null
  $MsftDefaultXml = @"
<PlugInConfiguration xmlns="http://schemas.microsoft.com/wbem/wsman/1/config/PluginConfiguration" Name="PowerShell.7" Filename="%ProgramFiles%\PowerShell\7\pwrshplugin.dll" SDKVersion="2" XmlRenderingType="text" Enabled="True">
  <InitializationParameters>
    <Param Name="PSVersion" Value="7" />
  </InitializationParameters>
</PlugInConfiguration>
"@
  Set-ItemProperty -LiteralPath $LegacyKey -Name ConfigXML -Value $MsftDefaultXml

  & $ScriptPath `
    -InstallLocation $DevolutionsShared `
    -Mode Uninstall `
    -MajorVersion '7' `
    -PreReleaseLabel '' `
    -WsManPluginRegistryPath $RegRoot `
    -System32PowerShellDirectory $FakeSystem32Ps `
    -ProgramFilesDirectory $FakeProgramFiles `
    -SkipServiceControl

  Assert-PluginConfig `
    -EndpointName 'PowerShell.7' `
    -ExpectedFilename '%ProgramFiles%\PowerShell\7\pwrshplugin.dll' `
    -ExpectedPsVersion '7'
  Write-Host 'PASS UninstallRemovesDevolutionsEndpointAndPreservesMicrosoftEndpoint'

  Invoke-ReviewRegressionCase -Name 'MsiPreservesDefaultNetworkProfileCheck' -Failures $ReviewRegressionFailures -Body {
    Assert-DefaultNetworkProfileCheck
  }

  Invoke-ReviewRegressionCase -Name 'UpgradeMigratesOnlyEndpointForPreviousCustomInstallPath' -Failures $ReviewRegressionFailures -Body {
    $CaseRoot = Join-Path $TempRoot 'custom-upgrade'
    $CaseRegistry = Join-Path $RegRoot 'CustomUpgrade'
    $OldInstall = Join-Path $CaseRoot 'Tools\PowerShell\7-x64'
    $NewInstall = Join-Path $CaseRoot 'Tools\PowerShell\7'
    $OtherInstall = Join-Path $CaseRoot 'OtherPowerShell\7'
    foreach ($Directory in @($OldInstall, $NewInstall, $OtherInstall)) {
      New-Item -ItemType Directory -Path $Directory -Force | Out-Null
      Set-Content -LiteralPath (Join-Path $Directory 'pwrshplugin.dll') -Value 'stub' -Encoding ascii
      Set-Content -LiteralPath (Join-Path $Directory 'System.Management.Automation.dll') -Value 'stub' -Encoding ascii
    }
    New-Item -Path $CaseRegistry -Force | Out-Null
    Set-TestPluginConfig -RegistryRoot $CaseRegistry -EndpointName 'PowerShell.7' `
      -Filename (Join-Path $OldInstall 'pwrshplugin.dll') -PsVersion '7.6'
    Set-TestPluginConfig -RegistryRoot $CaseRegistry -EndpointName 'PowerShell.7.6.8' `
      -Filename (Join-Path $OtherInstall 'pwrshplugin.dll') -PsVersion '7.6'
    $OtherConfigBefore = (Get-ItemProperty -LiteralPath (Join-Path $CaseRegistry 'PowerShell.7.6.8') -Name ConfigXML).ConfigXML

    Remove-Item -LiteralPath $OldInstall -Recurse -Force
    if (Test-Path -LiteralPath $OldInstall) {
      throw 'The previous custom install directory was not removed before simulating the upgrade.'
    }

    & $ScriptPath `
      -InstallLocation $NewInstall `
      -Mode Install `
      -EnableRemoting '0' `
      -MajorVersion '7' `
      -PreReleaseLabel '' `
      -WsManPluginRegistryPath $CaseRegistry `
      -System32PowerShellDirectory (Join-Path $CaseRoot 'System32\PowerShell') `
      -ProgramFilesDirectory (Join-Path $CaseRoot 'Program Files') `
      -SkipServiceControl

    $Migrated = [xml] (Get-ItemProperty -LiteralPath (Join-Path $CaseRegistry 'PowerShell.7') -Name ConfigXML).ConfigXML
    if ($Migrated.PlugInConfiguration.Filename -cne (Join-Path $NewInstall 'pwrshplugin.dll') -or
        $Migrated.PlugInConfiguration.InitializationParameters.Param.GetAttribute('Value') -cne '7') {
      throw 'The endpoint targeting the previous custom install was not migrated to the new custom path and major version.'
    }
    $OtherConfigAfter = (Get-ItemProperty -LiteralPath (Join-Path $CaseRegistry 'PowerShell.7.6.8') -Name ConfigXML).ConfigXML
    if ($OtherConfigAfter -cne $OtherConfigBefore) {
      throw 'An endpoint targeting a different install was changed during migration.'
    }
  }

  Invoke-ReviewRegressionCase -Name 'NewEndpointEscapesAmpersandInFilenameAndProducesValidConfigXml' -Failures $ReviewRegressionFailures -Body {
    $CaseRoot = Join-Path $TempRoot 'xml-special'
    $CaseRegistry = Join-Path $RegRoot 'XmlSpecial'
    $SpecialInstall = Join-Path $CaseRoot 'A&B\PowerShell\7'
    New-Item -ItemType Directory -Path $SpecialInstall -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $SpecialInstall 'pwrshplugin.dll') -Value 'stub' -Encoding ascii
    Set-Content -LiteralPath (Join-Path $SpecialInstall 'System.Management.Automation.dll') -Value 'stub' -Encoding ascii
    New-Item -Path $CaseRegistry -Force | Out-Null

    & $ScriptPath `
      -InstallLocation $SpecialInstall `
      -Mode Install `
      -EnableRemoting '1' `
      -MajorVersion '7' `
      -PreReleaseLabel '' `
      -WsManPluginRegistryPath $CaseRegistry `
      -System32PowerShellDirectory (Join-Path $CaseRoot 'System32\PowerShell') `
      -ProgramFilesDirectory (Join-Path $CaseRoot 'Program Files') `
      -SkipServiceControl

    $StoredXml = (Get-ItemProperty -LiteralPath (Join-Path $CaseRegistry 'PowerShell.7') -Name ConfigXML).ConfigXML
    try {
      $Document = [xml] $StoredXml
    } catch {
      throw "New endpoint ConfigXML is not well-formed XML: $($_.Exception.Message)"
    }
    $ExpectedFilename = Join-Path $SpecialInstall 'pwrshplugin.dll'
    if ($Document.PlugInConfiguration.Filename -cne $ExpectedFilename) {
      throw "New endpoint Filename was '$($Document.PlugInConfiguration.Filename)', expected '$ExpectedFilename'."
    }
  }

  Invoke-ReviewRegressionCase -Name 'CleanupRemovesNumericGeneratedEndpointsAndPreservesCustomJEA' -Failures $ReviewRegressionFailures -Body {
    $CaseRoot = Join-Path $TempRoot 'endpoint-names'
    $CaseRegistry = Join-Path $RegRoot 'EndpointNames'
    $OldInstall = Join-Path $CaseRoot 'Devolutions\PowerShell\7-x64'
    $NewInstall = Join-Path $CaseRoot 'Devolutions\PowerShell\7'
    foreach ($Directory in @($OldInstall, $NewInstall)) {
      New-Item -ItemType Directory -Path $Directory -Force | Out-Null
      Set-Content -LiteralPath (Join-Path $Directory 'pwrshplugin.dll') -Value 'stub' -Encoding ascii
      Set-Content -LiteralPath (Join-Path $Directory 'System.Management.Automation.dll') -Value 'stub' -Encoding ascii
    }
    New-Item -Path $CaseRegistry -Force | Out-Null
    foreach ($Endpoint in @('PowerShell.7.6.8', 'PowerShell.7.6.8.9')) {
      Set-TestPluginConfig -RegistryRoot $CaseRegistry -EndpointName $Endpoint `
        -Filename (Join-Path $OldInstall 'pwrshplugin.dll') -PsVersion '7.6'
    }
    Set-TestPluginConfig -RegistryRoot $CaseRegistry -EndpointName 'PowerShell.7.JEA' `
      -Filename (Join-Path $OldInstall 'pwrshplugin.dll') -PsVersion '7.6'
    $JeaConfigBefore = (Get-ItemProperty -LiteralPath (Join-Path $CaseRegistry 'PowerShell.7.JEA') -Name ConfigXML).ConfigXML

    & $ScriptPath `
      -InstallLocation $NewInstall `
      -Mode Install `
      -EnableRemoting '1' `
      -MajorVersion '7' `
      -PreReleaseLabel '' `
      -WsManPluginRegistryPath $CaseRegistry `
      -System32PowerShellDirectory (Join-Path $CaseRoot 'System32\PowerShell') `
      -ProgramFilesDirectory (Join-Path $CaseRoot 'Program Files') `
      -SkipServiceControl

    foreach ($Endpoint in @('PowerShell.7.6.8', 'PowerShell.7.6.8.9')) {
      if (Test-Path -LiteralPath (Join-Path $CaseRegistry $Endpoint)) {
        throw "Automatically generated endpoint '$Endpoint' was not cleaned up."
      }
    }
    $JeaKey = Join-Path $CaseRegistry 'PowerShell.7.JEA'
    if (-not (Test-Path -LiteralPath $JeaKey)) {
      throw 'Custom endpoint PowerShell.7.JEA was removed by generated-endpoint cleanup.'
    }
    $JeaConfigAfter = (Get-ItemProperty -LiteralPath $JeaKey -Name ConfigXML).ConfigXML
    if ($JeaConfigAfter -cne $JeaConfigBefore) {
      throw 'Custom endpoint PowerShell.7.JEA was modified by generated-endpoint cleanup.'
    }
  }

  Invoke-ReviewRegressionCase -Name 'RollbackRestoresEndpointConfigLegacyFilesAndReloadsWinRm' -Failures $ReviewRegressionFailures -Body {
    $CaseRoot = Join-Path $TempRoot 'rollback'
    $OldInstall = Join-Path $CaseRoot 'Devolutions\PowerShell\7-x64'
    $NewInstall = Join-Path $CaseRoot 'Devolutions\PowerShell\7'
    foreach ($Directory in @($OldInstall, $NewInstall)) {
      New-Item -ItemType Directory -Path $Directory -Force | Out-Null
      Set-Content -LiteralPath (Join-Path $Directory 'pwrshplugin.dll') -Value 'stub' -Encoding ascii
      Set-Content -LiteralPath (Join-Path $Directory 'System.Management.Automation.dll') -Value 'stub' -Encoding ascii
    }

    $ProductPath = Join-Path $PSScriptRoot 'assets\wix\Product.wxs'
    [xml] $Product = Get-Content -LiteralPath $ProductPath -Raw
    foreach ($Pair in @(
      @{ Forward = 'EnablePSRemoting'; Rollback = 'RollbackEnablePSRemoting' },
      @{ Forward = 'DisablePSRemotingOnUninstall'; Rollback = 'RollbackDisablePSRemotingOnUninstall' }
    )) {
      $ForwardAction = @($Product.SelectNodes("//*[local-name()='CustomAction']") |
        Where-Object { $_.GetAttribute('Id') -eq $Pair.Forward })
      $RollbackAction = @($Product.SelectNodes("//*[local-name()='CustomAction']") |
        Where-Object { $_.GetAttribute('Id') -eq $Pair.Rollback })
      $RollbackCommand = @($Product.SelectNodes("//*[local-name()='SetProperty']") |
        Where-Object { $_.GetAttribute('Id') -eq $Pair.Rollback })
      if ($ForwardAction.Count -ne 1 -or $ForwardAction[0].GetAttribute('Execute') -ine 'deferred' -or
          $RollbackAction.Count -ne 1 -or $RollbackAction[0].GetAttribute('Execute') -ine 'rollback' -or
          $RollbackCommand.Count -ne 1 -or $RollbackCommand[0].GetAttribute('Value') -notmatch '(?i)-Mode Rollback\s+.*-(?:SnapshotId|Snap)\s+') {
        throw "Deferred action '$($Pair.Forward)' does not have a rollback action using the remoting snapshot."
      }
    }

    $PriorGetService = Get-Item Function:\Get-Service -ErrorAction SilentlyContinue
    $PriorRestartService = Get-Item Function:\Restart-Service -ErrorAction SilentlyContinue
    $WinRmServiceState = [pscustomobject]@{ RestartCount = 0 }
    $GetServiceMock = {
      param([string] $Name)
      [pscustomobject]@{ Status = 'Running' }
    }.GetNewClosure()
    $RestartServiceMock = {
      param([string] $Name, [switch] $Force, [switch] $Confirm, [string] $ErrorAction)
      $WinRmServiceState.RestartCount++
    }.GetNewClosure()
    Set-Item Function:\Get-Service -Value $GetServiceMock
    Set-Item Function:\Restart-Service -Value $RestartServiceMock

    try {
      foreach ($Operation in @('Install', 'Uninstall')) {
        $CaseRegistry = Join-Path $RegRoot "Rollback$Operation"
        $CaseSystem32 = Join-Path $CaseRoot "$Operation\System32\PowerShell"
        $LegacySys32 = Join-Path $CaseSystem32 '7.6.8'
        $SnapshotId = [guid]::NewGuid().ToString()
        $SnapshotRoot = Join-Path $CaseRoot "$Operation\Snapshots"
        New-Item -ItemType Directory -Path $LegacySys32 -Force | Out-Null
        $LegacyDll = Join-Path $LegacySys32 'pwrshplugin.dll'
        $LegacyConfig = Join-Path $LegacySys32 'RemotePowerShellConfig.txt'
        Set-Content -LiteralPath $LegacyDll -Value "legacy-$Operation" -Encoding ascii
        Set-Content -LiteralPath $LegacyConfig -Value "PSHOMEDIR=$OldInstall`r`nCORECLRDIR=$OldInstall" -Encoding utf8
        New-Item -Path $CaseRegistry -Force | Out-Null
        Set-TestPluginConfig -RegistryRoot $CaseRegistry -EndpointName 'PowerShell.7' `
          -Filename (Join-Path $OldInstall 'pwrshplugin.dll') -PsVersion '7.6'
        Set-TestPluginConfig -RegistryRoot $CaseRegistry -EndpointName 'PowerShell.7.6.8' `
          -Filename $LegacyDll -PsVersion '7.6'
        $DefaultConfigBefore = (Get-ItemProperty -LiteralPath (Join-Path $CaseRegistry 'PowerShell.7') -Name ConfigXML).ConfigXML
        $VersionConfigBefore = (Get-ItemProperty -LiteralPath (Join-Path $CaseRegistry 'PowerShell.7.6.8') -Name ConfigXML).ConfigXML
        $LegacyDllBefore = Get-Content -LiteralPath $LegacyDll -Raw
        $LegacyConfigBefore = Get-Content -LiteralPath $LegacyConfig -Raw

        if ($Operation -eq 'Install') {
          & $ScriptPath `
            -InstallLocation $NewInstall `
            -Mode Install `
            -EnableRemoting '1' `
            -MajorVersion '7' `
            -PreReleaseLabel '' `
            -SnapshotId $SnapshotId `
            -SnapshotRoot $SnapshotRoot `
            -WsManPluginRegistryPath $CaseRegistry `
            -System32PowerShellDirectory $CaseSystem32 `
            -ProgramFilesDirectory (Join-Path $CaseRoot 'Program Files') `
            -SkipServiceControl
        } else {
          & $ScriptPath `
            -InstallLocation $OldInstall `
            -Mode Uninstall `
            -MajorVersion '7' `
            -PreReleaseLabel '' `
            -SnapshotId $SnapshotId `
            -SnapshotRoot $SnapshotRoot `
            -WsManPluginRegistryPath $CaseRegistry `
            -System32PowerShellDirectory $CaseSystem32 `
            -ProgramFilesDirectory (Join-Path $CaseRoot 'Program Files') `
            -SkipServiceControl
        }

        if ((Test-Path -LiteralPath (Join-Path $CaseRegistry 'PowerShell.7.6.8')) -or
            (Test-Path -LiteralPath $LegacySys32)) {
          throw "$Operation did not remove the seeded legacy endpoint and System32 copy before rollback."
        }
        if ($Operation -eq 'Install') {
          $Installed = [xml] (Get-ItemProperty -LiteralPath (Join-Path $CaseRegistry 'PowerShell.7') -Name ConfigXML).ConfigXML
          if ($Installed.PlugInConfiguration.Filename -cne (Join-Path $NewInstall 'pwrshplugin.dll')) {
            throw 'The install action did not change the default endpoint before rollback.'
          }
        } elseif (Test-Path -LiteralPath (Join-Path $CaseRegistry 'PowerShell.7')) {
          throw 'The uninstall action did not remove the seeded default endpoint before rollback.'
        }

        & $ScriptPath `
          -InstallLocation $OldInstall `
          -Mode Rollback `
          -MajorVersion '7' `
          -PreReleaseLabel '' `
          -SnapshotId $SnapshotId `
          -SnapshotRoot $SnapshotRoot `
          -WsManPluginRegistryPath $CaseRegistry `
          -System32PowerShellDirectory $CaseSystem32 `
          -ProgramFilesDirectory (Join-Path $CaseRoot 'Program Files')

        $DefaultConfigAfter = (Get-ItemProperty -LiteralPath (Join-Path $CaseRegistry 'PowerShell.7') -Name ConfigXML).ConfigXML
        $VersionConfigAfter = (Get-ItemProperty -LiteralPath (Join-Path $CaseRegistry 'PowerShell.7.6.8') -Name ConfigXML).ConfigXML
        if ($DefaultConfigAfter -cne $DefaultConfigBefore -or $VersionConfigAfter -cne $VersionConfigBefore) {
          throw "$Operation rollback did not restore the affected endpoint ConfigXML exactly."
        }
        if ((Get-Content -LiteralPath $LegacyDll -Raw) -cne $LegacyDllBefore -or
            (Get-Content -LiteralPath $LegacyConfig -Raw) -cne $LegacyConfigBefore) {
          throw "$Operation rollback did not restore the legacy System32 files exactly."
        }
      }
      if ($WinRmServiceState.RestartCount -ne 2) {
        throw "Expected WinRM to reload once after each rollback, observed $($WinRmServiceState.RestartCount) restart(s)."
      }
    } finally {
      if ($null -eq $PriorGetService) {
        Remove-Item Function:\Get-Service -ErrorAction SilentlyContinue
      } else {
        Set-Item Function:\Get-Service -Value $PriorGetService.ScriptBlock
      }
      if ($null -eq $PriorRestartService) {
        Remove-Item Function:\Restart-Service -ErrorAction SilentlyContinue
      } else {
        Set-Item Function:\Restart-Service -Value $PriorRestartService.ScriptBlock
      }
    }
  }
} finally {
  if (Test-Path -LiteralPath "HKCU:\Software\Devolutions\PowerShellRemotingTests\$TestId") {
    Remove-Item -LiteralPath "HKCU:\Software\Devolutions\PowerShellRemotingTests\$TestId" -Recurse -Force -ErrorAction SilentlyContinue
  }
  if (Test-Path -LiteralPath $TempRoot) {
    Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

if ($ReviewRegressionFailures.Count -gt 0) {
  throw "Review regression tests failed:`n$($ReviewRegressionFailures -join "`n")"
}
