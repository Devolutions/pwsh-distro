[CmdletBinding()]
param(
  [string] $WorkRoot = (Join-Path ([System.IO.Path]::GetTempPath()) "pwsh-archive-test-$([guid]::NewGuid().ToString('N'))")
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function New-TestArchive {
  param([string] $Path, [bool] $IncludeSigningTarget)

  $File = [System.IO.File]::Create($Path)
  $Gzip = [System.IO.Compression.GZipStream]::new($File, [System.IO.Compression.CompressionLevel]::Optimal)
  $Writer = [System.Formats.Tar.TarWriter]::new($Gzip)
  try {
    $Files = @(
      @{ Name = './pwsh'; Content = 'unchanged executable'; Mode = 493 },
      @{ Name = './Modules/example.psm1'; Content = 'unchanged module'; Mode = 420 }
    )
    if ($IncludeSigningTarget) {
      $Files = @(@{ Name = './pwsh.dll'; Content = 'unsigned'; Mode = 420 }) + $Files
    }
    foreach ($Fixture in $Files) {
      $Entry = [System.Formats.Tar.PaxTarEntry]::new([System.Formats.Tar.TarEntryType]::RegularFile, $Fixture.Name)
      $Entry.Mode = [System.IO.UnixFileMode] $Fixture.Mode
      $Entry.Uid = 123
      $Entry.Gid = 456
      $Entry.ModificationTime = [DateTimeOffset]::Parse('2026-01-01T00:00:00Z')
      $Data = [System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes($Fixture.Content))
      try {
        $Entry.DataStream = $Data
        $Writer.WriteEntry($Entry)
      } finally {
        $Data.Dispose()
      }
    }
    $Link = [System.Formats.Tar.PaxTarEntry]::new([System.Formats.Tar.TarEntryType]::SymbolicLink, './pwsh-link')
    $Link.LinkName = 'pwsh'
    $Link.Mode = [System.IO.UnixFileMode] 511
    $Writer.WriteEntry($Link)
  } finally {
    $Writer.Dispose()
    $Gzip.Dispose()
    $File.Dispose()
  }
}

$WorkRoot = [System.IO.Path]::GetFullPath($WorkRoot)
New-Item -ItemType Directory -Path $WorkRoot | Out-Null
try {
  $ToolPath = Join-Path $WorkRoot 'fake-psign.ps1'
  Set-Content -LiteralPath $ToolPath -Value @'
if ($args[0] -eq 'portable') { exit 0 }
[System.IO.File]::WriteAllText($args[-1], 'signed-by-test-tool-with-a-longer-payload')
exit 0
'@
  $FailingToolPath = Join-Path $WorkRoot 'failing-psign.ps1'
  Set-Content -LiteralPath $FailingToolPath -Value 'exit 7'
  $Signer = Join-Path $PSScriptRoot 'Sign-PowerShellDistroArchive.ps1'
  $Arguments = @{
    AzureKeyVaultUrl = 'https://test.invalid'
    AzureTenantId = 'test-tenant'
    AzureClientId = 'test-client'
    AzureClientSecret = 'test-only-placeholder'
    AzureCertificateName = 'test-certificate'
    TimestampServer = 'https://test.invalid/timestamp'
  }

  $ArchivePath = Join-Path $WorkRoot 'signed.tar.gz'
  New-TestArchive -Path $ArchivePath -IncludeSigningTarget $true
  & $Signer -ArchivePath $ArchivePath -PsignToolPath $ToolPath `
    -WorkRoot (Join-Path $WorkRoot 'signing') @Arguments
  $File = [System.IO.File]::OpenRead($ArchivePath)
  $Gzip = [System.IO.Compression.GZipStream]::new($File, [System.IO.Compression.CompressionMode]::Decompress)
  $Reader = [System.Formats.Tar.TarReader]::new($Gzip)
  $Entries = @{}
  try {
    while ($Entry = $Reader.GetNextEntry()) {
      $Content = ''
      if ($Entry.DataStream) {
        $Buffer = [System.IO.MemoryStream]::new()
        try {
          $Entry.DataStream.CopyTo($Buffer)
          $Content = [System.Text.Encoding]::UTF8.GetString($Buffer.ToArray())
        } finally {
          $Buffer.Dispose()
        }
      }
      $Entries[$Entry.Name] = @{
        Content = $Content; Mode = [int] $Entry.Mode; Uid = $Entry.Uid; Gid = $Entry.Gid
        LinkName = $Entry.LinkName; Type = $Entry.EntryType; Modified = $Entry.ModificationTime
      }
    }
  } finally {
    $Reader.Dispose()
    $Gzip.Dispose()
    $File.Dispose()
  }
  if ($Entries.Count -ne 4 -or $Entries['./pwsh.dll'].Content -ne 'signed-by-test-tool-with-a-longer-payload' -or
      $Entries['./pwsh.dll'].Mode -ne 420 -or $Entries['./pwsh.dll'].Uid -ne 123 -or
      $Entries['./pwsh.dll'].Gid -ne 456 -or
      $Entries['./pwsh.dll'].Modified -ne [DateTimeOffset]::Parse('2026-01-01T00:00:00Z')) {
    throw 'Signing_ReplacesPayloadPreservesMetadata failed.'
  }
  Write-Host 'PASS Signing_ReplacesPayloadPreservesMetadata'
  if ($Entries['./pwsh'].Content -ne 'unchanged executable' -or $Entries['./pwsh'].Mode -ne 493 -or
      $Entries['./Modules/example.psm1'].Content -ne 'unchanged module' -or $Entries['./Modules/example.psm1'].Mode -ne 420 -or
      $Entries['./pwsh-link'].Type -ne [System.Formats.Tar.TarEntryType]::SymbolicLink -or
      $Entries['./pwsh-link'].LinkName -ne 'pwsh' -or $Entries['./pwsh-link'].Mode -ne 511) {
    throw 'Signing_PreservesUnixExecutableAndSymlink failed.'
  }
  Write-Host 'PASS Signing_PreservesUnixExecutableAndSymlink'

  $ArchivePath = Join-Path $WorkRoot 'no-targets.tar.gz'
  New-TestArchive -Path $ArchivePath -IncludeSigningTarget $false
  $OriginalHash = (Get-FileHash -LiteralPath $ArchivePath).Hash
  try {
    & $Signer -ArchivePath $ArchivePath -PsignToolPath $ToolPath `
      -WorkRoot (Join-Path $WorkRoot 'no-targets') @Arguments
    throw 'Signing_NoTargetsRejectsArchive failed.'
  } catch {
    if ($_.Exception.Message -notlike 'No CLI PE signing targets were found in *') { throw }
  }
  if ((Get-FileHash -LiteralPath $ArchivePath).Hash -ne $OriginalHash) {
    throw 'Signing_NoTargetsRejectsArchive changed the archive.'
  }
  Write-Host 'PASS Signing_NoTargetsRejectsArchive'

  $ArchivePath = Join-Path $WorkRoot 'signing-failure.tar.gz'
  New-TestArchive -Path $ArchivePath -IncludeSigningTarget $true
  $OriginalHash = (Get-FileHash -LiteralPath $ArchivePath).Hash
  try {
    & $Signer -ArchivePath $ArchivePath -PsignToolPath $FailingToolPath `
      -WorkRoot (Join-Path $WorkRoot 'failure') @Arguments
    throw 'Signing_ToolFailurePreservesArchive failed.'
  } catch {
    if ($_.Exception.Message -notlike '*failed with exit code 7') { throw }
  }
  if ((Get-FileHash -LiteralPath $ArchivePath).Hash -ne $OriginalHash) {
    throw 'Signing_ToolFailurePreservesArchive changed the archive.'
  }
  Write-Host 'PASS Signing_ToolFailurePreservesArchive'
} finally {
  Remove-Item -LiteralPath $WorkRoot -Recurse -Force
}

exit 0
