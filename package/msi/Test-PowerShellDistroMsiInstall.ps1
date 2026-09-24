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
if ([System.IO.Path]::GetFileName($LegacyMsi) -notmatch $NamePattern -or
    [version] $Matches.version -ge $Version) {
  throw 'The legacy MSI must have an earlier version of the same architecture.'
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
$LegacyPath = "$SharedPath-$Architecture"
$LegacyOppositePath = "$SharedPath-x64"
$LogDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "pwsh-distro-msi-install-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $LogDirectory | Out-Null
$Succeeded = $false

function Invoke-Msi {
  param(
    [string] $Action,
    [string] $Msi,
    [int[]] $ExpectedExitCodes = @(0),
    [switch] $ExpectArchitectureBlock
  )

  $Log = Join-Path $LogDirectory "$([guid]::NewGuid().ToString('N')).log"
  $Arguments = "$Action `"$Msi`" /qn /norestart /l*v `"$Log`""
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

try {
  if (Test-Path -LiteralPath $SharedPath) {
    throw "Expected a clean runner, but the MSI directory already exists: $SharedPath"
  }

  Invoke-Msi '/i' $CurrentMsi
  Assert-PowerShell $SharedPath
  Invoke-Msi '/x' $CurrentMsi
  if (Test-Path -LiteralPath (Join-Path $SharedPath 'pwsh.exe')) {
    throw 'Fresh-install removal left PowerShell at the shared path.'
  }

  Invoke-Msi '/i' $LegacyMsi
  Assert-PowerShell $LegacyPath
  Invoke-Msi '/i' $CurrentMsi
  Assert-PowerShell $SharedPath
  if (Test-Path -LiteralPath (Join-Path $LegacyPath 'pwsh.exe')) {
    throw "The prior MSI's $LegacyPath installation was not removed on upgrade."
  }
  Remove-Item -LiteralPath (Join-Path $SharedPath 'pwsh.exe')
  Invoke-Msi '/fa' $CurrentProductCode
  Assert-PowerShell $SharedPath

  if ($OppositeMsi) {
    Invoke-Msi '/i' $OppositeMsi -ExpectedExitCodes @(1603) -ExpectArchitectureBlock
    Assert-PowerShell $SharedPath
    Invoke-Msi '/i' $LegacyOppositeMsi
    Assert-PowerShell $LegacyOppositePath
    Invoke-Msi '/i' $OppositeMsi -ExpectedExitCodes @(1603) -ExpectArchitectureBlock
    Invoke-Msi '/fa' $CurrentProductCode
    Invoke-Msi '/x' $CurrentMsi
    if (Test-Path -LiteralPath (Join-Path $SharedPath 'pwsh.exe')) {
      throw 'Uninstall left the new PowerShell executable at the shared path.'
    }
    Assert-PowerShell $LegacyOppositePath
    Invoke-Msi '/x' $LegacyOppositeMsi
  } else {
    Invoke-Msi '/x' $CurrentMsi
  }

  if (Test-Path -LiteralPath (Join-Path $SharedPath 'pwsh.exe')) {
    throw 'Uninstall left the new PowerShell executable at the shared path.'
  }
  $Succeeded = $true
  Write-Host "Passed $Architecture fresh install, same-architecture upgrade, repair, and uninstall tests."
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
  if ($Succeeded -and $CleanupFailures.Count -eq 0) {
    Remove-Item -LiteralPath $LogDirectory -Recurse -Force
  } else {
    Write-Warning "MSI logs retained for diagnosis: $LogDirectory"
  }
  if ($CleanupFailures.Count -gt 0) {
    throw $CleanupFailures -join "`n"
  }
}
