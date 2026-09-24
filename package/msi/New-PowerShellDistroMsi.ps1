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

if (-not $IsWindows) {
  throw 'WiX 4 MSI packaging requires Windows.'
}

$MsiRoot = $PSScriptRoot
$Payload = (Resolve-Path -LiteralPath $PayloadDirectory -ErrorAction Stop).Path
if (-not (Test-Path -LiteralPath $Payload -PathType Container)) {
  throw "Payload directory was not found: $Payload"
}
foreach ($File in 'pwsh.exe', 'LICENSE.txt', 'ThirdPartyNotices.txt') {
  if (-not (Test-Path -LiteralPath (Join-Path $Payload $File) -PathType Leaf)) {
    throw "MSI payload is missing $File in $Payload"
  }
}

$ExecutablePath = Join-Path $Payload 'pwsh.exe'
$ExpectedMachine = if ($Architecture -eq 'x64') { 0x8664 } else { 0xAA64 }
$Stream = [System.IO.File]::OpenRead($ExecutablePath)
try {
  $Reader = [System.IO.BinaryReader]::new($Stream)
  if ($Stream.Length -lt 0x40 -or $Reader.ReadUInt16() -ne 0x5A4D) {
    throw "MSI payload is not a valid PE executable: $ExecutablePath"
  }
  $Stream.Position = 0x3C
  $PeOffset = $Reader.ReadInt32()
  if ($PeOffset -lt 0x40 -or $PeOffset -gt $Stream.Length - 6) {
    throw "MSI payload has an invalid PE header: $ExecutablePath"
  }
  $Stream.Position = $PeOffset
  if ($Reader.ReadUInt32() -ne 0x00004550) {
    throw "MSI payload is not a valid PE executable: $ExecutablePath"
  }
  $Machine = $Reader.ReadUInt16()
  if ($Machine -ne $ExpectedMachine) {
    throw "MSI payload pwsh.exe machine type 0x$($Machine.ToString('X4')) does not match $Architecture (expected 0x$($ExpectedMachine.ToString('X4')))."
  }
} finally {
  $Stream.Dispose()
}

$Version = [version] $PackageVersion
if ($Version.Revision -gt 99 -or $Version.Build -gt 655 -or
    ($Version.Build * 100 + $Version.Revision) -gt 65535) {
  throw "Package version '$PackageVersion' cannot be represented as an increasing MSI version."
}
$MsiVersion = "$($Version.Major).$($Version.Minor).$($Version.Build * 100 + $Version.Revision)"
$SemanticVersion = "$($Version.Major).$($Version.Minor).$($Version.Build)"
$Output = [System.IO.Path]::GetFullPath($OutputDirectory)
if ($Output.StartsWith($Payload.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase) -or
    $Output -eq $Payload) {
  throw "MSI output must be outside the payload directory: $Output"
}
New-Item -ItemType Directory -Path $Output -Force | Out-Null
$MsiPath = Join-Path $Output "Devolutions-PowerShell-$PackageVersion-win-$Architecture.msi"
if (Test-Path -LiteralPath $MsiPath) {
  throw "MSI output already exists: $MsiPath"
}

$Work = Join-Path ([System.IO.Path]::GetTempPath()) "pwsh-distro-msi-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $Work | Out-Null
try {
  $Packages = Join-Path $Work 'packages'
  $Project = Join-Path $MsiRoot 'PowerShellDistro.wixproj'
  $BuildProperties = @(
    "/p:BaseIntermediateOutputPath=$Work\obj\",
    "/p:OutputPath=$Work\bin\",
    "/p:PayloadDirectory=$Payload",
    "/p:MsiProductVersion=$MsiVersion",
    "/p:SimpleProductVersion=$($Version.Major)",
    "/p:SemanticVersion=$SemanticVersion",
    "/p:InstallerPlatform=$Architecture",
    '/p:Configuration=Release'
  )
  & dotnet restore $Project --source https://api.nuget.org/v3/index.json --packages $Packages --verbosity minimal --disable-build-servers @BuildProperties
  if ($LASTEXITCODE -ne 0) {
    throw "WiX package restore failed with exit code $LASTEXITCODE"
  }

  $Files = Get-ChildItem -LiteralPath $Payload -File -Recurse
  if ($Files.Count -eq 0) {
    throw "MSI payload is empty: $Payload"
  }

  Push-Location $MsiRoot
  try {
    & dotnet build $Project --no-restore --verbosity minimal --disable-build-servers -nr:false @BuildProperties
    if ($LASTEXITCODE -ne 0) { throw "WiX 4 build failed with exit code $LASTEXITCODE" }
  } finally {
    Pop-Location
  }

  $BuiltMsis = @(Get-ChildItem -LiteralPath (Join-Path $Work 'bin') -Filter '*.msi' -File -Recurse)
  if ($BuiltMsis.Count -ne 1) {
    throw "Expected one WiX MSI under $Work, found $($BuiltMsis.Count)."
  }
  Move-Item -LiteralPath $BuiltMsis[0].FullName -Destination $MsiPath
  Write-Host "Built $MsiPath"
} finally {
  Remove-Item -LiteralPath $Work -Recurse -Force
}
