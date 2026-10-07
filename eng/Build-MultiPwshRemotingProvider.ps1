[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $PowerShellSdkAssemblyPath,

  [Parameter(Mandatory)]
  [string] $TargetFramework,

  [Parameter(Mandatory)]
  [string] $OutputDirectory,

  [string] $SourceRoot,

  [string] $Configuration = 'Release'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path $PSScriptRoot -Parent
if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
  $SourceRoot = Join-Path $RepositoryRoot 'pwsh-src'
}
$ProjectRoot = Join-Path $SourceRoot 'src\Devolutions.MultiPwsh.Remoting.WSMan'
$ProjectPath = Join-Path $ProjectRoot 'Devolutions.MultiPwsh.Remoting.WSMan.csproj'
if (-not (Test-Path -LiteralPath $ProjectPath -PathType Leaf)) {
  throw "The pinned PowerShell source is missing the devolutions.wsman provider project: $ProjectPath"
}
$ResolvedSdkAssemblyPath = (Resolve-Path -LiteralPath $PowerShellSdkAssemblyPath).Path

dotnet build $ProjectPath `
  --configuration $Configuration `
  --nologo `
  -p:AdapterTargetFramework=$TargetFramework `
  -p:PowerShellSdkVendor=Devolutions `
  -p:PowerShellSdkAssemblyPath=$ResolvedSdkAssemblyPath
if ($LASTEXITCODE -ne 0) {
  throw "Building the devolutions.wsman provider failed with exit code $LASTEXITCODE."
}

$BuildOutput = Join-Path $ProjectRoot "bin\$Configuration\$TargetFramework"
$RequiredFiles = @(
  'Devolutions.MultiPwsh.Remoting.WSMan.dll',
  'Devolutions.MultiPwsh.Remoting.Provider.json',
  'Devolutions.MultiPwsh.Remoting.Provider.options.schema.json'
)

New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
foreach ($FileName in $RequiredFiles) {
  $SourcePath = Join-Path $BuildOutput $FileName
  if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
    throw "The devolutions.wsman provider build did not produce '$SourcePath'."
  }

  Copy-Item -LiteralPath $SourcePath -Destination (Join-Path $OutputDirectory $FileName) -Force
}
