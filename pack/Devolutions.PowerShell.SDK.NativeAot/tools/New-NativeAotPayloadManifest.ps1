[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $PayloadDirectory,

  [Parameter(Mandatory)]
  [string] $WorkerBridgePath,

  [ValidateSet('win-x64', 'win-arm64', 'linux-x64')]
  [string] $RuntimeIdentifier,

  [string] $ManifestPath
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$payloadRoot = (Resolve-Path -LiteralPath $PayloadDirectory -ErrorAction Stop).Path
$bridge = Get-Item -LiteralPath $WorkerBridgePath -ErrorAction Stop
if ($bridge.LinkType) {
  throw 'WorkerBridgePath must not be a symbolic link.'
}

if (-not $RuntimeIdentifier) {
  if ($IsWindows -and [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -eq [System.Runtime.InteropServices.Architecture]::X64) {
    $RuntimeIdentifier = 'win-x64'
  }
  elseif ($IsLinux -and [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -eq [System.Runtime.InteropServices.Architecture]::X64) {
    $RuntimeIdentifier = 'linux-x64'
  }
  else {
    throw 'Specify -RuntimeIdentifier when staging a payload for a different architecture.'
  }
}

switch ($RuntimeIdentifier) {
  'win-x64' {
    $architecture = 'x64'
    $hostfxrName = 'hostfxr.dll'
  }
  'win-arm64' {
    $architecture = 'arm64'
    $hostfxrName = 'hostfxr.dll'
  }
  'linux-x64' {
    $architecture = 'x64'
    $hostfxrName = 'libhostfxr.so'
  }
}

if (-not $ManifestPath) {
  $ManifestPath = Join-Path $payloadRoot 'devolutions-pwsh-payload.json'
}

if (Get-ChildItem -LiteralPath $payloadRoot -Directory -Recurse -Force | Where-Object LinkType) {
  throw 'Payload directories must not contain symbolic links.'
}

$files = foreach ($item in Get-ChildItem -LiteralPath $payloadRoot -File -Recurse -Force | Sort-Object FullName) {
  if ($item.LinkType) {
    throw "Payload file must not be a symbolic link: $($item.FullName)"
  }
  $relativePath = [System.IO.Path]::GetRelativePath($payloadRoot, $item.FullName)
  if ($relativePath -eq 'devolutions-pwsh-payload.json') {
    continue
  }
  [ordered]@{
    path = $relativePath
    sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $item.FullName).Hash.ToLowerInvariant()
  }
}

foreach ($requiredPath in 'pwsh.dll', 'pwsh.runtimeconfig.json', $hostfxrName) {
  if ($files.path -notcontains $requiredPath) {
    throw "Payload is missing required file: $requiredPath"
  }
}

[ordered]@{
  schema_version = 1
  rid = $RuntimeIdentifier
  architecture = $architecture
  files = $files
  worker_bridge_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $bridge.FullName).Hash.ToLowerInvariant()
} | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $ManifestPath -Encoding utf8NoBOM
