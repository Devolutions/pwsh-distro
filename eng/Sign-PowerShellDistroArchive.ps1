[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $ArchivePath,

  [string] $PsignToolPath = 'psign-tool',

  [string] $WorkRoot,

  [string[]] $IncludeFilter = @(
    'pwsh.dll',
    'pwsh.exe',
    'System.Management.Automation.dll',
    'Microsoft.PowerShell*.dll',
    'Microsoft.Management.Infrastructure.CimCmdlets.dll',
    'Microsoft.WSMan.Management.dll',
    'Microsoft.WSMan.Runtime.dll'
  ),

  [string] $AzureKeyVaultUrl = $Env:CODE_SIGNING_KEYVAULT_URL,

  [string] $AzureTenantId = $Env:AZURE_TENANT_ID,

  [string] $AzureClientId = $Env:CODE_SIGNING_CLIENT_ID,

  [string] $AzureClientSecret = $Env:CODE_SIGNING_CLIENT_SECRET,

  [string] $AzureCertificateName = $Env:CODE_SIGNING_CERTIFICATE_NAME,

  [string] $TimestampServer = $Env:CODE_SIGNING_TIMESTAMP_SERVER
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Invoke-NativeCommand {
  param(
    [Parameter(Mandatory)]
    [string] $FilePath,

    [Parameter(ValueFromRemainingArguments)]
    [string[]] $Arguments
  )

  & $FilePath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "$FilePath $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
  }
}

function Assert-NotEmpty {
  param(
    [Parameter(Mandatory)]
    [string] $Name,

    [AllowNull()]
    [string] $Value
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    throw "$Name is required for CLI archive code signing."
  }
}

Assert-NotEmpty -Name 'CODE_SIGNING_KEYVAULT_URL' -Value $AzureKeyVaultUrl
Assert-NotEmpty -Name 'AZURE_TENANT_ID' -Value $AzureTenantId
Assert-NotEmpty -Name 'CODE_SIGNING_CLIENT_ID' -Value $AzureClientId
Assert-NotEmpty -Name 'CODE_SIGNING_CLIENT_SECRET' -Value $AzureClientSecret
Assert-NotEmpty -Name 'CODE_SIGNING_CERTIFICATE_NAME' -Value $AzureCertificateName
Assert-NotEmpty -Name 'CODE_SIGNING_TIMESTAMP_SERVER' -Value $TimestampServer

$ArchiveFullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ArchivePath)
if (-not (Test-Path -LiteralPath $ArchiveFullPath -PathType Leaf)) {
  throw "PowerShell distro archive was not found: $ArchiveFullPath"
}

if ([string]::IsNullOrWhiteSpace($WorkRoot)) {
  $TempRoot = if ($Env:RUNNER_TEMP) { $Env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
  $WorkRoot = Join-Path $TempRoot "powershell-distro-sign-$([Guid]::NewGuid().ToString('N'))"
}
$WorkRootPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($WorkRoot)
$ExtractRoot = Join-Path $WorkRootPath 'extract'
$SignedArchivePath = Join-Path $WorkRootPath ([System.IO.Path]::GetFileName($ArchiveFullPath))

Remove-Item -LiteralPath $WorkRootPath -Recurse -Force -ErrorAction SilentlyContinue
New-Item -Path $ExtractRoot -ItemType Directory -Force | Out-Null

try {
  Invoke-NativeCommand tar @('-xzf', $ArchiveFullPath, '-C', $ExtractRoot)

  $SigningTargets = @(
    Get-ChildItem -LiteralPath $ExtractRoot -File |
      Where-Object {
        $Name = $_.Name
        $_.Extension.ToLowerInvariant() -in @('.dll', '.exe') -and
          (@($IncludeFilter | Where-Object { $_ -and $Name -like $_ }).Count -gt 0)
      } |
      Sort-Object FullName
  )
  if ($SigningTargets.Count -eq 0) {
    throw "No CLI PE signing targets were found in $ArchiveFullPath."
  }

  $SigningArgs = @(
    '--mode', 'portable',
    'sign',
    '--azure-key-vault-url', $AzureKeyVaultUrl,
    '--azure-key-vault-certificate', $AzureCertificateName,
    '--azure-key-vault-client-id', $AzureClientId,
    '--azure-key-vault-client-secret', $AzureClientSecret,
    '--azure-key-vault-tenant-id', $AzureTenantId,
    '--timestamp-url', $TimestampServer,
    '--timestamp-digest', 'sha256',
    '--digest', 'sha256',
    '--exit-codes', 'azure'
  )

  Write-Host "Signing $($SigningTargets.Count) CLI payload(s) in $([System.IO.Path]::GetFileName($ArchiveFullPath))."
  foreach ($SigningTarget in $SigningTargets) {
    $RelativeTarget = [System.IO.Path]::GetRelativePath($ExtractRoot, $SigningTarget.FullName)
    Write-Host "Signing $RelativeTarget"
    Invoke-NativeCommand $PsignToolPath @($SigningArgs + $SigningTarget.FullName)

    $VerifyOutput = & $PsignToolPath portable verify-pe $SigningTarget.FullName 2>&1
    if ($LASTEXITCODE -ne 0) {
      $VerifyOutput | ForEach-Object { Write-Host $_ }
      throw "Code signing verification failed for CLI payload '$RelativeTarget'."
    }
  }

  Remove-Item -LiteralPath $SignedArchivePath -Force -ErrorAction SilentlyContinue
  Invoke-NativeCommand tar @('-czf', $SignedArchivePath, '-C', $ExtractRoot, '.')
  Move-Item -LiteralPath $SignedArchivePath -Destination $ArchiveFullPath -Force
  Write-Host "Repacked signed CLI archive: $ArchiveFullPath"
} finally {
  Remove-Item -LiteralPath $WorkRootPath -Recurse -Force -ErrorAction SilentlyContinue
}
