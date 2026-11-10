function Get-LinuxElfInfo {
  param(
    [Parameter(Mandatory)]
    [string] $Path
  )

  $ResolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
  $Stream = [System.IO.File]::OpenRead($ResolvedPath)
  try {
    $Reader = [System.IO.BinaryReader]::new($Stream)
    if ($Stream.Length -lt 64 -or $Reader.ReadUInt32() -ne 0x464C457F -or $Reader.ReadByte() -ne 2 -or $Reader.ReadByte() -ne 1) {
      throw "Not a little-endian 64-bit ELF file: $ResolvedPath"
    }

    $Stream.Position = 0x10
    $Type = $Reader.ReadUInt16()
    $Machine = $Reader.ReadUInt16()
    $Stream.Position = 0x20
    $ProgramHeaderOffset = $Reader.ReadUInt64()
    $Stream.Position = 0x36
    $ProgramHeaderSize = $Reader.ReadUInt16()
    $ProgramHeaderCount = $Reader.ReadUInt16()
    if ($ProgramHeaderSize -lt 56 -or $ProgramHeaderCount -eq 0 -or
        $ProgramHeaderOffset -gt $Stream.Length -or
        $ProgramHeaderCount * $ProgramHeaderSize -gt $Stream.Length - $ProgramHeaderOffset) {
      throw "Invalid ELF program headers: $ResolvedPath"
    }

    $Interpreter = $null
    for ($Index = 0; $Index -lt $ProgramHeaderCount; $Index++) {
      $Stream.Position = [long] $ProgramHeaderOffset + ($Index * $ProgramHeaderSize)
      if ($Reader.ReadUInt32() -ne 3) {
        continue
      }

      $Stream.Position += 4
      $InterpreterOffset = $Reader.ReadUInt64()
      $Stream.Position += 16
      $InterpreterSize = $Reader.ReadUInt64()
      if ($InterpreterSize -eq 0 -or $InterpreterSize -gt 512 -or
          $InterpreterOffset -gt $Stream.Length -or $InterpreterSize -gt $Stream.Length - $InterpreterOffset) {
        throw "Invalid ELF interpreter: $ResolvedPath"
      }
      $Stream.Position = [long] $InterpreterOffset
      $Interpreter = [System.Text.Encoding]::ASCII.GetString($Reader.ReadBytes([int] $InterpreterSize)).TrimEnd([char] 0)
      break
    }

    return [pscustomobject] @{
      Path = $ResolvedPath
      Type = $Type
      Machine = $Machine
      Interpreter = $Interpreter
    }
  } finally {
    $Stream.Dispose()
  }
}

function Assert-LinuxElfArchitecture {
  param(
    [Parameter(Mandatory)]
    [psobject] $Elf,

    [Parameter(Mandatory)]
    [ValidateSet('x64', 'arm64')]
    [string] $Architecture
  )

  $ExpectedMachine = if ($Architecture -eq 'x64') { 0x3E } else { 0xB7 }
  if ($Elf.Machine -ne $ExpectedMachine) {
    throw "ELF architecture does not match '$Architecture': $($Elf.Path)"
  }
}
