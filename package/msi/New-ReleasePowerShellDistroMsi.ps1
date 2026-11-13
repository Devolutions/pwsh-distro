[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $ArchiveDirectory,

  [Parameter(Mandatory)]
  [ValidatePattern('^\d+\.\d+\.\d+\.\d+$')]
  [string] $PackageVersion,

  [switch] $SignMsi
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
  throw 'Release MSI packaging requires Windows.'
}

if ($SignMsi) {
  foreach ($Name in @(
    'CODE_SIGNING_KEYVAULT_URL', 'AZURE_TENANT_ID', 'CODE_SIGNING_CLIENT_ID',
    'CODE_SIGNING_CLIENT_SECRET', 'CODE_SIGNING_CERTIFICATE_NAME', 'CODE_SIGNING_TIMESTAMP_SERVER'
  )) {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($Name))) {
      throw "$Name is required to sign an MSI."
    }
  }
  $SigningArgs = @(
    '--mode', 'portable', 'sign',
    '--azure-key-vault-url', $Env:CODE_SIGNING_KEYVAULT_URL,
    '--azure-key-vault-certificate', $Env:CODE_SIGNING_CERTIFICATE_NAME,
    '--azure-key-vault-client-id', $Env:CODE_SIGNING_CLIENT_ID,
    '--azure-key-vault-client-secret', $Env:CODE_SIGNING_CLIENT_SECRET,
    '--azure-key-vault-tenant-id', $Env:AZURE_TENANT_ID,
    '--timestamp-url', $Env:CODE_SIGNING_TIMESTAMP_SERVER,
    '--timestamp-digest', 'sha256',
    '--digest', 'sha256',
    '--exit-codes', 'azure'
  )
}

$ArchiveRoot = (Resolve-Path -LiteralPath $ArchiveDirectory).Path
$OutputDirectory = Join-Path $PWD 'output\msi'
$LegacyOutputDirectory = Join-Path $PWD 'output\legacy-msi'
$Work = Join-Path $PWD 'output\msi-payload'
& (Join-Path $PSScriptRoot 'Test-RegisterPowerShellRemoting.ps1')
New-Item -ItemType Directory -Path $Work | Out-Null
try {
  foreach ($Architecture in 'x64', 'arm64') {
    $ArchivePath = Join-Path $ArchiveRoot "PowerShell-$PackageVersion-windows-$Architecture.tar.gz"
    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
      throw "Release archive was not found: $ArchivePath"
    }
    $PayloadDirectory = Join-Path $Work $Architecture
    New-Item -ItemType Directory -Path $PayloadDirectory | Out-Null
    & tar -xzf $ArchivePath -C $PayloadDirectory
    if ($LASTEXITCODE -ne 0) {
      throw "Unable to extract $ArchivePath."
    }

    & (Join-Path $PSScriptRoot 'New-PowerShellDistroMsi.ps1') `
      -PayloadDirectory $PayloadDirectory -PackageVersion $PackageVersion `
      -Architecture $Architecture -OutputDirectory $OutputDirectory
    $MsiPath = Join-Path $OutputDirectory "Devolutions.PowerShell-$PackageVersion-win-$Architecture.msi"
    & (Join-Path $PSScriptRoot 'Test-PowerShellDistroMsiTables.ps1') `
      -MsiPath $MsiPath -Architecture $Architecture -PackageVersion $PackageVersion
    & (Join-Path $PSScriptRoot 'New-LegacyPowerShellDistroMsiFixture.ps1') `
      -PayloadDirectory $PayloadDirectory -PackageVersion $PackageVersion `
      -Architecture $Architecture -OutputDirectory $LegacyOutputDirectory

    if ($SignMsi) {
      & psign-tool @SigningArgs $MsiPath
      if ($LASTEXITCODE -ne 0) {
        throw "psign-tool failed to sign the $Architecture MSI with exit code $LASTEXITCODE."
      }
      & psign-tool portable verify-msi $MsiPath
      if ($LASTEXITCODE -ne 0) {
        throw "psign-tool failed to verify the $Architecture MSI with exit code $LASTEXITCODE."
      }
      foreach ($Name in 'pwsh.exe', 'pwsh.dll', 'System.Management.Automation.dll') {
        $Binary = Join-Path $PayloadDirectory $Name
        if (-not (Test-Path -LiteralPath $Binary -PathType Leaf)) {
          throw "Expected a signed PowerShell payload in the MSI: $Binary"
        }
        & psign-tool portable verify-pe $Binary
        if ($LASTEXITCODE -ne 0) {
          throw "psign-tool failed to verify the $Architecture MSI payload $Name with exit code $LASTEXITCODE."
        }
      }
    }
  }
} finally {
  Remove-Item -LiteralPath $Work -Recurse -Force
}
