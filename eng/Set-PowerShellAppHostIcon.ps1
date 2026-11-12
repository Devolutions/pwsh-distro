[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $ExecutablePath,

  [string] $IconPath = (Join-Path $PSScriptRoot '..\package\msi\assets\Powershell_black.ico')
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
  throw 'Windows apphost icon replacement requires Windows.'
}

$Executable = (Resolve-Path -LiteralPath $ExecutablePath -ErrorAction Stop).Path
$Icon = (Resolve-Path -LiteralPath $IconPath -ErrorAction Stop).Path

if (-not ('PowerShellDistro.AppHostIcon' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;

namespace PowerShellDistro
{
    public static class AppHostIcon
    {
        private delegate bool EnumName(IntPtr module, IntPtr type, IntPtr name, IntPtr parameter);
        private delegate bool EnumLanguage(IntPtr module, IntPtr type, IntPtr name, ushort language, IntPtr parameter);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr LoadLibraryEx(string path, IntPtr file, uint flags);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool FreeLibrary(IntPtr module);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool EnumResourceNames(IntPtr module, IntPtr type, EnumName callback, IntPtr parameter);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool EnumResourceLanguages(IntPtr module, IntPtr type, IntPtr name, EnumLanguage callback, IntPtr parameter);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr FindResourceEx(IntPtr module, IntPtr type, IntPtr name, ushort language);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint SizeofResource(IntPtr module, IntPtr resource);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr LoadResource(IntPtr module, IntPtr resource);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr LockResource(IntPtr resource);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr BeginUpdateResource(string path, bool deleteExistingResources);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool UpdateResource(IntPtr update, IntPtr type, IntPtr name, ushort language, byte[] data, uint length);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool EndUpdateResource(IntPtr update, bool discard);
        [DllImport("imagehlp.dll", SetLastError = true)]
        private static extern bool ImageEnumerateCertificates(IntPtr file, ushort typeFilter, out uint count, IntPtr indices, uint indexCount);
        [DllImport("imagehlp.dll", SetLastError = true)]
        private static extern bool ImageRemoveCertificate(IntPtr file, uint index);

        private static readonly IntPtr IconType = new IntPtr(3);
        private static readonly IntPtr GroupIconType = new IntPtr(14);
        private static readonly IntPtr GroupIconName = new IntPtr(1);

        public static void Set(string executablePath, string iconPath)
        {
            byte[] icon = File.ReadAllBytes(iconPath);
            if (icon.Length < 6 || BitConverter.ToUInt16(icon, 0) != 0 || BitConverter.ToUInt16(icon, 2) != 1)
                throw new InvalidDataException("The icon is not a valid ICO file.");

            int count = BitConverter.ToUInt16(icon, 4);
            int directoryEnd = 6 + count * 16;
            if (count == 0 || directoryEnd > icon.Length)
                throw new InvalidDataException("The ICO directory is incomplete.");

            var images = new List<byte[]>();
            for (int i = 0; i < count; i++)
            {
                int entry = 6 + i * 16;
                uint size = BitConverter.ToUInt32(icon, entry + 8);
                uint offset = BitConverter.ToUInt32(icon, entry + 12);
                if (size == 0 || offset < directoryEnd || (long)offset + size > icon.Length)
                    throw new InvalidDataException("The ICO contains an invalid image range.");
                byte[] image = new byte[checked((int)size)];
                Buffer.BlockCopy(icon, checked((int)offset), image, 0, image.Length);
                images.Add(image);
            }

            ushort language;
            ushort[] imageIds;
            IntPtr module = LoadLibraryEx(executablePath, IntPtr.Zero, 0x22);
            if (module == IntPtr.Zero)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to inspect the apphost resources.");
            try
            {
                int groupCount = 0;
                bool hasExpectedGroup = false;
                EnumName onName = (handle, type, name, parameter) =>
                {
                    groupCount++;
                    hasExpectedGroup |= name == GroupIconName;
                    return true;
                };
                if (!EnumResourceNames(module, GroupIconType, onName, IntPtr.Zero))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to enumerate apphost icon groups.");
                if (groupCount != 1 || !hasExpectedGroup)
                    throw new InvalidDataException("The apphost must have exactly one icon group, with ID 1.");

                var languages = new List<ushort>();
                EnumLanguage onLanguage = (handle, type, name, value, parameter) =>
                {
                    languages.Add(value);
                    return true;
                };
                if (!EnumResourceLanguages(module, GroupIconType, GroupIconName, onLanguage, IntPtr.Zero))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to enumerate apphost icon languages.");
                if (languages.Count != 1)
                    throw new InvalidDataException("The apphost icon group must have exactly one language.");
                language = languages[0];

                IntPtr resource = FindResourceEx(module, GroupIconType, GroupIconName, language);
                if (resource == IntPtr.Zero)
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to find the apphost icon group.");
                int length = checked((int)SizeofResource(module, resource));
                IntPtr loaded = LoadResource(module, resource);
                IntPtr data = loaded == IntPtr.Zero ? IntPtr.Zero : LockResource(loaded);
                if (data == IntPtr.Zero)
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to read the apphost icon group.");
                byte[] group = new byte[length];
                Marshal.Copy(data, group, 0, length);
                if (length < 6 || BitConverter.ToUInt16(group, 0) != 0 ||
                    BitConverter.ToUInt16(group, 2) != 1)
                    throw new InvalidDataException("The apphost icon group is invalid.");
                int existingCount = BitConverter.ToUInt16(group, 4);
                if (existingCount == 0 || length != 6 + existingCount * 14)
                    throw new InvalidDataException("The apphost icon group is incomplete.");

                imageIds = new ushort[count];
                var uniqueIds = new HashSet<ushort>();
                for (int i = 0; i < existingCount; i++)
                {
                    ushort id = BitConverter.ToUInt16(group, 6 + i * 14 + 12);
                    if (id == 0 || !uniqueIds.Add(id) || FindResourceEx(module, IconType, new IntPtr(id), language) == IntPtr.Zero)
                        throw new InvalidDataException("The apphost icon group contains an invalid image ID.");
                    if (i < count)
                        imageIds[i] = id;
                }

                if (count > existingCount)
                {
                    var usedIds = new HashSet<ushort>();
                    EnumName onIconName = (handle, type, name, parameter) =>
                    {
                        long value = name.ToInt64();
                        if (value > 0 && value <= ushort.MaxValue)
                            usedIds.Add((ushort)value);
                        return true;
                    };
                    if (!EnumResourceNames(module, IconType, onIconName, IntPtr.Zero))
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to enumerate apphost icon images.");
                    int nextId = 1;
                    for (int i = existingCount; i < count; i++)
                    {
                        while (nextId <= ushort.MaxValue && usedIds.Contains((ushort)nextId))
                            nextId++;
                        if (nextId > ushort.MaxValue)
                            throw new InvalidDataException("The apphost has no unused icon image IDs.");
                        imageIds[i] = (ushort)nextId;
                        usedIds.Add((ushort)nextId);
                    }
                }
            }
            finally
            {
                if (!FreeLibrary(module))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to unload the apphost resources.");
            }

            byte[] newGroup = new byte[6 + count * 14];
            Buffer.BlockCopy(icon, 0, newGroup, 0, 6);
            for (int i = 0; i < count; i++)
            {
                Buffer.BlockCopy(icon, 6 + i * 16, newGroup, 6 + i * 14, 12);
                Buffer.BlockCopy(BitConverter.GetBytes(imageIds[i]), 0, newGroup, 6 + i * 14 + 12, 2);
            }

            // Resource edits invalidate Authenticode; remove it so the release signing stage can re-sign the apphost.
            using (var file = new FileStream(executablePath, FileMode.Open, FileAccess.ReadWrite, FileShare.Read))
            {
                IntPtr handle = file.SafeFileHandle.DangerousGetHandle();
                while (true)
                {
                    uint certificateCount;
                    if (!ImageEnumerateCertificates(handle, 0xff, out certificateCount, IntPtr.Zero, 0))
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to enumerate apphost certificates.");
                    if (certificateCount == 0)
                        break;
                    if (!ImageRemoveCertificate(handle, 0))
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to remove the apphost certificate.");
                }
            }

            IntPtr update = BeginUpdateResource(executablePath, false);
            if (update == IntPtr.Zero)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to open apphost resources for updating.");
            bool committed = false;
            try
            {
                for (int i = 0; i < count; i++)
                {
                    if (!UpdateResource(update, IconType, new IntPtr(imageIds[i]), language, images[i], (uint)images[i].Length))
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to update an apphost icon image.");
                }
                if (!UpdateResource(update, GroupIconType, GroupIconName, language, newGroup, (uint)newGroup.Length))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to update the apphost icon group.");
                if (!EndUpdateResource(update, false))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to commit the apphost icon.");
                committed = true;
            }
            finally
            {
                if (!committed)
                    EndUpdateResource(update, true);
            }
        }
    }
}
'@
}

[PowerShellDistro.AppHostIcon]::Set($Executable, $Icon)
Write-Host "Updated the Windows apphost icon: $Executable"
