#Requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $MsiPath,
  [Parameter(Mandatory)] [string] $PreviousMsiPath,
  [Parameter(Mandatory)] [ValidateSet('x64', 'arm64')] [string] $Architecture,
  [Parameter(Mandatory)] [string] $PackageVersion,
  [string] $OppositeMsiPath,
  [switch] $RequireSignature,
  [switch] $WindowsSandbox
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# This test replaces installed PowerShell. Keep it confined to verified disposable environments and Windows PowerShell.
$DisposableRunner = $Env:GITHUB_ACTIONS -eq 'true' -and $Env:RUNNER_ENVIRONMENT -eq 'github-hosted'
$VerifiedSandbox = $false
if ($WindowsSandbox -and $PSVersionTable.PSEdition -eq 'Desktop') {
  $VerifiedSandbox = [Environment]::UserName -eq 'WDAGUtilityAccount' -and
    (Get-Item -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control').GetValue('ContainerType') -eq 4
}
if ($PSVersionTable.PSEdition -ne 'Desktop' -or (-not $DisposableRunner -and -not $VerifiedSandbox)) {
  throw 'Microsoft MSI installation tests require Windows PowerShell on a disposable GitHub-hosted runner or verified Windows Sandbox (-WindowsSandbox).'
}
$Msi = (Resolve-Path -LiteralPath $MsiPath).Path
$PreviousMsi = (Resolve-Path -LiteralPath $PreviousMsiPath).Path
$Version = [version] $PackageVersion
$InstallRoot = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) "PowerShell\$($Version.Major)"
$DevolutionsRoot = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) "Devolutions\PowerShell\$($Version.Major)"
$Codes = @{
  x64 = '{31AB5147-9A97-4452-8443-D9709F0516E1}'
  arm64 = '{75C68AB2-09D8-46B8-B697-D829BDD4C94F}'
}
$RegistryPath = "HKLM:\Software\Microsoft\PowerShellCore\InstalledVersions\$($Codes[$Architecture].Trim('{}'))"
$TempRoot = if ($Env:RUNNER_TEMP) { $Env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
$LogRoot = Join-Path $TempRoot "microsoft-msi-tests-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $LogRoot | Out-Null
$Installer = New-Object -ComObject WindowsInstaller.Installer

function Invoke-Msi {
  param([string] $Action, [string] $Path, [int] $ExpectedExitCode = 0, [switch] $ArchitectureBlock, [string] $ExtraArguments)

  $Log = Join-Path $LogRoot "$([guid]::NewGuid().ToString('N')).log"
  $Process = Start-Process msiexec.exe -ArgumentList "$Action `"$Path`" /qn /norestart /l*v `"$Log`" $ExtraArguments" -Wait -PassThru
  if ($Process.ExitCode -notin @($ExpectedExitCode, $(if ($ExpectedExitCode -eq 0) { 3010 } else { $ExpectedExitCode }))) {
    Get-Content -LiteralPath $Log -Tail 60 | Write-Host
    throw "msiexec returned $($Process.ExitCode), expected $ExpectedExitCode. Log: $Log"
  }
  if ($ArchitectureBlock -and -not (Select-String -LiteralPath $Log -SimpleMatch 'Uninstall the other architecture of Microsoft PowerShell' -Quiet)) {
    throw "Expected the Microsoft cross-architecture guard in $Log."
  }
}

function Assert-Installed {
  param([string] $ExpectedRoot = $InstallRoot)

  $Exe = Join-Path $ExpectedRoot 'pwsh.exe'
  $Actual = & $Exe -NoLogo -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()'
  if ($LASTEXITCODE -ne 0 -or $Actual -cne "$($Version.Major).$($Version.Minor).$($Version.Build)") {
    throw "Microsoft PowerShell did not run at the expected MSI location: $ExpectedRoot."
  }
  $RegisteredPath = (Get-ItemProperty -LiteralPath $RegistryPath -Name InstallLocation).InstallLocation
  if ($RegisteredPath.TrimEnd('\') -ine $ExpectedRoot) {
    throw 'Windows Terminal PowerShell discovery does not point to the installed Microsoft payload.'
  }
  foreach ($Name in 'pwsh.exe', 'pwsh.dll', 'System.Management.Automation.dll') {
    $Signature = Get-AuthenticodeSignature -LiteralPath (Join-Path $ExpectedRoot $Name)
    if ($Signature.Status -ne 'Valid' -or $Signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)O=Microsoft Corporation(?:,|$)') {
      throw "Installed $Name no longer has a valid Microsoft signature."
    }
  }
}

try {
  if (Test-Path -LiteralPath $DevolutionsRoot) {
    throw "Expected no source-built Devolutions installation on this clean runner: $DevolutionsRoot."
  }
  if ($RequireSignature -and (Get-AuthenticodeSignature -LiteralPath $Msi).Status -ne 'Valid') {
    throw 'Microsoft-payload MSI does not have a valid installer signature.'
  }
  # Remove only registered Microsoft stable products; fail rather than delete an unowned installation directory.
  foreach ($Code in $Codes.Values) {
    foreach ($Product in @($Installer.RelatedProducts($Code))) {
      Invoke-Msi '/x' $Product
    }
  }
  if (Test-Path -LiteralPath (Join-Path $InstallRoot 'pwsh.exe')) {
    throw "An unmanaged PowerShell installation remains at $InstallRoot."
  }
  $SavedPropertiesPath = 'HKLM:\Software\Microsoft\PowerShellCore\InstallerProperties'
  if ((Test-Path -LiteralPath $SavedPropertiesPath) -and
      'InstallFolder' -in (Get-Item -LiteralPath $SavedPropertiesPath).GetValueNames()) {
    Remove-ItemProperty -LiteralPath $SavedPropertiesPath -Name InstallFolder
  }

  Invoke-Msi '/i' $Msi
  Assert-Installed
  Invoke-Msi '/x' $Msi
  if (Test-Path -LiteralPath (Join-Path $InstallRoot 'pwsh.exe')) {
    throw 'Fresh Microsoft MSI uninstall left pwsh.exe behind.'
  }
  Write-Host 'PASS MicrosoftMsiFreshInstallUsesOriginalPath'

  Invoke-Msi '/i' $PreviousMsi
  $PreviousProducts = @($Installer.RelatedProducts($Codes[$Architecture]))
  if ($PreviousProducts.Count -ne 1) {
    throw 'Expected one original Microsoft MSI product before upgrade.'
  }
  Invoke-Msi '/i' $Msi
  Assert-Installed
  $CurrentProducts = @($Installer.RelatedProducts($Codes[$Architecture]))
  if ($CurrentProducts.Count -ne 1 -or $CurrentProducts[0] -eq $PreviousProducts[0]) {
    throw 'Upgrade did not replace the original Microsoft MSI product.'
  }
  Write-Host 'PASS MicrosoftMsiUpgradesOriginalMicrosoftProduct'

  Remove-Item -LiteralPath (Join-Path $InstallRoot 'pwsh.exe')
  Invoke-Msi '/fa' $CurrentProducts[0]
  Assert-Installed
  Write-Host 'PASS MicrosoftMsiRepairRestoresPayload'
  if ($OppositeMsiPath) {
    $Before = (Get-FileHash -LiteralPath (Join-Path $InstallRoot 'pwsh.exe')).Hash
    Invoke-Msi '/i' (Resolve-Path -LiteralPath $OppositeMsiPath).Path -ExpectedExitCode 1603 -ArchitectureBlock
    if ((Get-FileHash -LiteralPath (Join-Path $InstallRoot 'pwsh.exe')).Hash -ne $Before) {
      throw 'Cross-architecture rejection modified the installed executable.'
    }
    Write-Host 'PASS MicrosoftMsiBlocksOppositeArchitecture'
  }
  Invoke-Msi '/x' $Msi
  if (@($Installer.RelatedProducts($Codes[$Architecture])).Count -ne 0 -or
      (Test-Path -LiteralPath (Join-Path $InstallRoot 'pwsh.exe')) -or
      (Test-Path -LiteralPath $RegistryPath) -or (Test-Path -LiteralPath $DevolutionsRoot)) {
    throw 'Microsoft MSI uninstall left owned files/registration or touched the Devolutions installation path.'
  }
  Write-Host 'PASS MicrosoftMsiUninstallRemovesOwnedFilesAndRegistration'

  $CustomRoot = Join-Path $LogRoot 'custom PowerShell'
  $CustomInstall = Join-Path $CustomRoot "$($Version.Major)"
  Invoke-Msi '/i' $PreviousMsi -ExtraArguments "INSTALLFOLDER=`"$CustomRoot`""
  Invoke-Msi '/i' $Msi
  Assert-Installed -ExpectedRoot $CustomInstall
  if (Test-Path -LiteralPath (Join-Path $InstallRoot 'pwsh.exe')) {
    throw 'Upgrading a custom Microsoft install unexpectedly populated the default path.'
  }
  Invoke-Msi '/x' $Msi
  if (Test-Path -LiteralPath (Join-Path $CustomInstall 'pwsh.exe')) {
    throw 'Uninstall left the custom Microsoft installation behind.'
  }
  Write-Host 'PASS MicrosoftMsiUpgradePreservesOriginalCustomRoot'
} finally {
  foreach ($Product in @($Installer.RelatedProducts($Codes[$Architecture]))) {
    Invoke-Msi '/x' $Product
  }
  [void] [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($Installer)
}
