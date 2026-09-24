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
