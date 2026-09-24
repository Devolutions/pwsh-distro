[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $PayloadDirectory,

  [Parameter(Mandatory)]
  [ValidatePattern('^\d+\.\d+\.\d+\.\d+$')]
  [string] $PackageVersion,

  [Parameter(Mandatory)]
  [ValidateSet('x64', 'arm64')]
  [string] $Architecture,

  [Parameter(Mandatory)]
  [string] $OutputDirectory
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$Version = [version] $PackageVersion
if ($Version.Revision -gt 0) {
  $LegacyVersion = "$($Version.Major).$($Version.Minor).$($Version.Build).$($Version.Revision - 1)"
} elseif ($Version.Build -gt 0) {
  $LegacyVersion = "$($Version.Major).$($Version.Minor).$($Version.Build - 1).0"
} else {
  throw "No prior MSI version can be generated for $PackageVersion."
}

$Work = Join-Path ([System.IO.Path]::GetTempPath()) "pwsh-distro-legacy-msi-$([guid]::NewGuid().ToString('N'))"
$LegacySource = Join-Path $Work 'msi'
try {
  New-Item -ItemType Directory -Path $Work | Out-Null
  Copy-Item -LiteralPath $PSScriptRoot -Destination $LegacySource -Recurse
  $WxsPath = Join-Path $LegacySource 'assets\wix\Product.wxs'
  $Source = [System.IO.File]::ReadAllText($WxsPath)
  $DirectoryPattern = [regex]::Escape('Name="$(var.SimpleProductVersion)">')
  $GuardPattern = '(?ms)^    <\?ifdef OppositeArchitectureUpgradeCode\?>\r?\n.*?^    <\?endif\?>\r?\n'
  if ([regex]::Matches($Source, $DirectoryPattern).Count -ne 1 -or
      [regex]::Matches($Source, $GuardPattern).Count -ne 1) {
    throw 'The current WiX source no longer matches the pre-shared-directory MSI layout.'
  }
  $Source = [regex]::Replace($Source, $DirectoryPattern, 'Name="$(var.SimpleProductVersion)-$(sys.BUILDARCH)">')
  $Source = [regex]::Replace($Source, $GuardPattern, '')
  [System.IO.File]::WriteAllText($WxsPath, $Source)

  & (Join-Path $LegacySource 'New-PowerShellDistroMsi.ps1') `
    -PayloadDirectory $PayloadDirectory -PackageVersion $LegacyVersion `
    -Architecture $Architecture -OutputDirectory $OutputDirectory
} finally {
  if (Test-Path -LiteralPath $Work) {
    Remove-Item -LiteralPath $Work -Recurse -Force
  }
}
