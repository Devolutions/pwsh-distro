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
} finally {
  if (Test-Path -LiteralPath "HKCU:\Software\Devolutions\PowerShellRemotingTests\$TestId") {
    Remove-Item -LiteralPath "HKCU:\Software\Devolutions\PowerShellRemotingTests\$TestId" -Recurse -Force -ErrorAction SilentlyContinue
  }
  if (Test-Path -LiteralPath $TempRoot) {
    Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
