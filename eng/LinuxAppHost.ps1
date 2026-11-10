function Set-LinuxAppHost {
  param(
    [Parameter(Mandatory)]
    [string] $PackageRoot,

    [Parameter(Mandatory)]
    [string] $Rid,

    [Parameter(Mandatory)]
    [string] $AppHostPath
  )

  if ($Rid -notmatch '^linux(?<musl>-musl)?-(?<arch>x64|arm64)$') {
    throw "A Linux apphost cannot be used with runtime identifier '$Rid'."
  }
  $IsMusl = $Matches.ContainsKey('musl')
  $Architecture = $Matches.arch
  $ExpectedInterpreter = if ($IsMusl) {
    if ($Architecture -eq 'x64') { 'ld-musl-x86_64.so.1' } else { 'ld-musl-aarch64.so.1' }
  } elseif ($Architecture -eq 'x64') {
    'ld-linux-x86-64.so.2'
  } else {
    'ld-linux-aarch64.so.1'
  }

  $Elf = Get-LinuxElfInfo -Path $AppHostPath
  Assert-LinuxElfArchitecture -Elf $Elf -Architecture $Architecture
  if ($Elf.Type -notin 2, 3 -or [System.IO.Path]::GetFileName($Elf.Interpreter) -ne $ExpectedInterpreter) {
    throw "Linux apphost interpreter '$($Elf.Interpreter)' does not match '$Rid' (expected $ExpectedInterpreter): $($Elf.Path)"
  }

  $SourceRid = if ($IsMusl) { "linux-$Architecture" } else { $Rid }
  $SourceAppHostDirectory = Join-Path $PackageRoot "tools/apphost/$SourceRid"
  $AppHostDirectory = Join-Path $PackageRoot "tools/apphost/$Rid"
  foreach ($File in 'pwsh', 'pwsh.dll', 'pwsh.runtimeconfig.json') {
    if (-not (Test-Path -LiteralPath (Join-Path $SourceAppHostDirectory $File) -PathType Leaf)) {
      throw "SDK package is missing apphost payload '$File' for '$SourceRid': $SourceAppHostDirectory"
    }
  }

  if ($IsMusl) {
    $SourceDistroPayload = Join-Path $PackageRoot "buildTransitive/powershell-distro-payload/$SourceRid"
    $DistroPayload = Join-Path $PackageRoot "buildTransitive/powershell-distro-payload/$Rid"
    if (-not (Test-Path -LiteralPath (Join-Path $SourceDistroPayload 'pwsh.xml') -PathType Leaf)) {
      throw "SDK package is missing the distro payload for '$SourceRid': $SourceDistroPayload"
    }
    New-Item -ItemType Directory -Path $AppHostDirectory, $DistroPayload -Force | Out-Null
    Copy-Item -Path (Join-Path $SourceAppHostDirectory '*') -Destination $AppHostDirectory -Recurse -Force
    Copy-Item -Path (Join-Path $SourceDistroPayload '*') -Destination $DistroPayload -Recurse -Force
  }

  Copy-Item -LiteralPath $Elf.Path -Destination (Join-Path $AppHostDirectory 'pwsh') -Force
}
