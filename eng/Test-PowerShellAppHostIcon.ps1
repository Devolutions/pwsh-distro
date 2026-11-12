[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $AppHostPath
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
  throw 'Windows apphost icon validation requires Windows.'
}

$AppHost = (Resolve-Path -LiteralPath $AppHostPath -ErrorAction Stop).Path
$IconPath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\package\msi\assets\Powershell_black.ico')).Path
$SetIcon = Join-Path $PSScriptRoot 'Set-PowerShellAppHostIcon.ps1'

if (-not ('PowerShellDistro.TestResourceReader' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace PowerShellDistro
{
    public static class TestResourceReader
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr LoadLibraryEx(string path, IntPtr file, uint flags);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool FreeLibrary(IntPtr module);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr FindResource(IntPtr module, IntPtr name, IntPtr type);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint SizeofResource(IntPtr module, IntPtr resource);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr LoadResource(IntPtr module, IntPtr resource);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr LockResource(IntPtr resource);

        public static byte[] Read(string path, int type, int name)
        {
            IntPtr module = LoadLibraryEx(path, IntPtr.Zero, 0x22);
            if (module == IntPtr.Zero)
                throw new Win32Exception(Marshal.GetLastWin32Error());
            try
            {
                IntPtr resource = FindResource(module, new IntPtr(name), new IntPtr(type));
                if (resource == IntPtr.Zero)
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                int length = checked((int)SizeofResource(module, resource));
                IntPtr loaded = LoadResource(module, resource);
                IntPtr data = loaded == IntPtr.Zero ? IntPtr.Zero : LockResource(loaded);
                if (data == IntPtr.Zero)
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                byte[] result = new byte[length];
                Marshal.Copy(data, result, 0, length);
                return result;
            }
            finally
            {
                FreeLibrary(module);
            }
        }
    }
}
'@
}

function Get-BytesHash {
  param([byte[]] $Bytes)
  return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($Bytes))
}

function Assert-Throws {
  param([scriptblock] $Action, [string] $Message)

  try {
    & $Action | Out-Null
  } catch {
    if ($_.Exception.Message -like "*$Message*") {
      return
    }
    throw "Expected an error containing '$Message', got: $_"
  }
  throw "Expected an error containing '$Message'."
}

function Assert-IconMatches {
  param([string] $Executable, [byte[]] $Icon)

  $Group = [PowerShellDistro.TestResourceReader]::Read($Executable, 14, 1)
  $Count = [BitConverter]::ToUInt16($Icon, 4)
  if ([BitConverter]::ToUInt16($Group, 4) -ne $Count -or $Group.Length -ne 6 + 14 * $Count) {
    throw 'The embedded icon group does not contain every ICO image.'
  }
  for ($Index = 0; $Index -lt $Count; $Index++) {
    $IconEntry = 6 + 16 * $Index
    $GroupEntry = 6 + 14 * $Index
    $ExpectedHeader = [byte[]]::new(12)
    $ActualHeader = [byte[]]::new(12)
    [Array]::Copy($Icon, $IconEntry, $ExpectedHeader, 0, 12)
    [Array]::Copy($Group, $GroupEntry, $ActualHeader, 0, 12)
    if ((Get-BytesHash $ExpectedHeader) -ne (Get-BytesHash $ActualHeader)) {
      throw "Embedded icon metadata differs for image $Index."
    }

    $ImageLength = [int] [BitConverter]::ToUInt32($Icon, $IconEntry + 8)
    $ImageOffset = [int] [BitConverter]::ToUInt32($Icon, $IconEntry + 12)
    $ExpectedImage = [byte[]]::new($ImageLength)
    [Array]::Copy($Icon, $ImageOffset, $ExpectedImage, 0, $ImageLength)
    $ImageId = [int] [BitConverter]::ToUInt16($Group, $GroupEntry + 12)
    $ActualImage = [PowerShellDistro.TestResourceReader]::Read($Executable, 3, $ImageId)
    if ((Get-BytesHash $ExpectedImage) -ne (Get-BytesHash $ActualImage)) {
      throw "Embedded icon pixels differ for image $Index."
    }
  }
}

$Work = Join-Path ([System.IO.Path]::GetTempPath()) "pwsh-icon-test-$([guid]::NewGuid().ToString('N'))"
try {
  $OriginalDirectory = Join-Path $Work 'original'
  $ModifiedDirectory = Join-Path $Work 'modified'
  New-Item -ItemType Directory -Path $OriginalDirectory, $ModifiedDirectory -Force | Out-Null
  $Original = Join-Path $OriginalDirectory 'multi-pwsh.exe'
  $Modified = Join-Path $ModifiedDirectory 'multi-pwsh.exe'
  Copy-Item -LiteralPath $AppHost -Destination $Original
  Copy-Item -LiteralPath $AppHost -Destination $Modified
  $OriginalHash = (Get-FileHash -LiteralPath $Modified).Hash
  $Icon = [System.IO.File]::ReadAllBytes($IconPath)

  $InvalidIcon = Join-Path $Work 'invalid.ico'
  [System.IO.File]::WriteAllBytes($InvalidIcon, [byte[]](0, 1, 2))
  Assert-Throws { & $SetIcon -ExecutablePath $Modified -IconPath $InvalidIcon } 'valid ICO'

  $TruncatedIcon = Join-Path $Work 'truncated.ico'
  $Truncated = [byte[]] $Icon.Clone()
  [Array]::Copy([BitConverter]::GetBytes([uint32]::MaxValue), 0, $Truncated, 18, 4)
  [System.IO.File]::WriteAllBytes($TruncatedIcon, $Truncated)
  Assert-Throws { & $SetIcon -ExecutablePath $Modified -IconPath $TruncatedIcon } 'invalid image range'
  if ((Get-FileHash -LiteralPath $Modified).Hash -ne $OriginalHash) {
    throw 'Invalid icons must not change the apphost or its signature.'
  }
  Write-Host 'PASS InvalidIconsLeaveAppHostUnchanged'

  & $SetIcon -ExecutablePath $Modified
  Assert-IconMatches -Executable $Modified -Icon $Icon
  if ((Get-AuthenticodeSignature -LiteralPath $Modified).Status -ne 'NotSigned') {
    throw 'The modified apphost must be unsigned before release signing.'
  }
  foreach ($ResourceType in 16, 24) {
    $Before = [PowerShellDistro.TestResourceReader]::Read($Original, $ResourceType, 1)
    $After = [PowerShellDistro.TestResourceReader]::Read($Modified, $ResourceType, 1)
    if ((Get-BytesHash $Before) -ne (Get-BytesHash $After)) {
      throw "Apphost resource type $ResourceType changed."
    }
  }
  Write-Host 'PASS RebrandedIconPreservesOtherResources'

  $ShortIcon = [byte[]] $Icon.Clone()
  $ShortIcon[4]--
  $ShortIconPath = Join-Path $Work 'fewer-sizes.ico'
  [System.IO.File]::WriteAllBytes($ShortIconPath, $ShortIcon)
  & $SetIcon -ExecutablePath $Modified -IconPath $ShortIconPath
  Assert-IconMatches -Executable $Modified -Icon $ShortIcon
  & $SetIcon -ExecutablePath $Modified
  Assert-IconMatches -Executable $Modified -Icon $Icon
  Write-Host 'PASS RebrandingDifferentIconCounts'

  & $SetIcon -ExecutablePath $Modified
  Assert-IconMatches -Executable $Modified -Icon $Icon
  if ((Get-AuthenticodeSignature -LiteralPath $Modified).Status -ne 'NotSigned') {
    throw 'Reapplying the icon must leave the apphost unsigned.'
  }
  Write-Host 'PASS RebrandingUnsignedAppHost'

  $ExecutableBytes = [System.IO.File]::ReadAllBytes($Original)
  $PeOffset = [BitConverter]::ToInt32($ExecutableBytes, 0x3c)
  $Machine = [BitConverter]::ToUInt16($ExecutableBytes, $PeOffset + 4)
  $HostArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture
  if (($Machine -eq 0x8664 -and $HostArchitecture -eq 'X64') -or
      ($Machine -eq 0xaa64 -and $HostArchitecture -eq 'Arm64')) {
    $BeforeVersion = (& $Original --version) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw 'The original apphost version command failed.' }
    $AfterVersion = (& $Modified --version) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $AfterVersion -ne $BeforeVersion) {
      throw 'The modified apphost did not preserve its version command.'
    }
    Write-Host 'PASS RebrandedAppHostRuns'
  }
} finally {
  if (Test-Path -LiteralPath $Work) {
    [System.IO.Directory]::Delete($Work, $true)
  }
}
