// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

#if !UNIX
using System;
using System.IO;
using System.Runtime.CompilerServices;
using Microsoft.PowerShell.Commands;
using Xunit;

namespace PSTests.Parallel
{
    public static class WinrmPluginUtilitiesTests
    {
        [Fact]
        public static void EnablePSRemotingCommandStaticScriptBlockParsesCleanly()
        {
            RuntimeHelpers.RunClassConstructor(typeof(EnablePSRemotingCommand).TypeHandle);
            RuntimeHelpers.RunClassConstructor(typeof(RegisterPSSessionConfigurationCommand).TypeHandle);
            RuntimeHelpers.RunClassConstructor(typeof(GetPSSessionConfigurationCommand).TypeHandle);
            RuntimeHelpers.RunClassConstructor(typeof(SetPSSessionConfigurationCommand).TypeHandle);
            RuntimeHelpers.RunClassConstructor(typeof(UnregisterPSSessionConfigurationCommand).TypeHandle);
        }

        [Theory]
        [InlineData(7, null, "PowerShell.7")]
        [InlineData(7, "", "PowerShell.7")]
        [InlineData(7, "preview.2", "PowerShell.7-preview")]
        public static void FormatWinrmPluginShellNameUsesMajorVersionAndPreviewSuffix(
            int major,
            string preReleaseLabel,
            string expected)
        {
            Assert.Equal(expected, PSSessionConfigurationCommandUtilities.FormatWinrmPluginShellName(major, preReleaseLabel));
        }

        [Fact]
        public static void FormatWinrmPluginDllPathCollapsesProgramFilesOnDirectoryBoundaryOnly()
        {
            Assert.Equal(
                @"%ProgramFiles%\Devolutions\PowerShell\7\pwrshplugin.dll",
                PSSessionConfigurationCommandUtilities.FormatWinrmPluginDllPath(
                    @"C:\Program Files\Devolutions\PowerShell\7\",
                    @"C:\Program Files"));

            Assert.Equal(
                @"C:\Program Files (x86)\Custom\PowerShell\7\pwrshplugin.dll",
                PSSessionConfigurationCommandUtilities.FormatWinrmPluginDllPath(
                    @"C:\Program Files (x86)\Custom\PowerShell\7",
                    @"C:\Program Files"));

            Assert.Equal(
                @"D:\tools\pwsh-cli\pwrshplugin.dll",
                PSSessionConfigurationCommandUtilities.FormatWinrmPluginDllPath(
                    @"D:\tools\pwsh-cli",
                    @"C:\Program Files"));
        }

        [Fact]
        public static void FormatPSVersionForConfigXmlUsesMajorOnlyForPowerShellSixAndNewer()
        {
            Assert.Equal("7", PSSessionConfigurationCommandUtilities.FormatPSVersionForConfigXml(new Version(7, 6, 10)));
            Assert.Equal("7", PSSessionConfigurationCommandUtilities.FormatPSVersionForConfigXml(new Version(7, 7, 0)));
            Assert.Equal("5.1", PSSessionConfigurationCommandUtilities.FormatPSVersionForConfigXml(new Version(5, 1, 19041)));
        }

        [Fact]
        public static void LegacyCleanupRemovesDevolutionsAndMissingTargetsWhilePreservingOtherValidInstalls()
        {
            string tempRoot = Path.Combine(Path.GetTempPath(), "pwsh-winrm-test-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(tempRoot);
            try
            {
                string currentDevolutionsHome = Path.Combine(tempRoot, "Devolutions", "PowerShell", "7");
                string legacyDevolutionsHome = Path.Combine(tempRoot, "Devolutions", "PowerShell", "7-x64");
                string microsoftHome = Path.Combine(tempRoot, "PowerShell", "7");
                string missingHome = Path.Combine(tempRoot, "Removed", "PowerShell", "7");
                string fakeSystem32Ps = Path.Combine(tempRoot, "System32", "PowerShell");

                Directory.CreateDirectory(currentDevolutionsHome);
                File.WriteAllText(Path.Combine(currentDevolutionsHome, "System.Management.Automation.dll"), string.Empty);

                Directory.CreateDirectory(legacyDevolutionsHome);
                File.WriteAllText(Path.Combine(legacyDevolutionsHome, "System.Management.Automation.dll"), string.Empty);

                Directory.CreateDirectory(microsoftHome);
                File.WriteAllText(Path.Combine(microsoftHome, "System.Management.Automation.dll"), string.Empty);
                File.WriteAllText(Path.Combine(microsoftHome, "pwrshplugin.dll"), string.Empty);

                string devolutionsCopyDir = Path.Combine(fakeSystem32Ps, "7.6.8");
                Directory.CreateDirectory(devolutionsCopyDir);
                string devolutionsCopiedDll = Path.Combine(devolutionsCopyDir, "pwrshplugin.dll");
                File.WriteAllText(devolutionsCopiedDll, string.Empty);
                File.WriteAllText(
                    Path.Combine(devolutionsCopyDir, "RemotePowerShellConfig.txt"),
                    $"PSHOMEDIR={legacyDevolutionsHome}{Environment.NewLine}CORECLRDIR={legacyDevolutionsHome}{Environment.NewLine}");

                string microsoftCopyDir = Path.Combine(fakeSystem32Ps, "7.4.6");
                Directory.CreateDirectory(microsoftCopyDir);
                string microsoftCopiedDll = Path.Combine(microsoftCopyDir, "pwrshplugin.dll");
                File.WriteAllText(microsoftCopiedDll, string.Empty);
                File.WriteAllText(
                    Path.Combine(microsoftCopyDir, "RemotePowerShellConfig.txt"),
                    $"PSHOMEDIR={microsoftHome}{Environment.NewLine}CORECLRDIR={microsoftHome}{Environment.NewLine}");

                string missingHomeCopyDir = Path.Combine(fakeSystem32Ps, "7.2.17");
                Directory.CreateDirectory(missingHomeCopyDir);
                string missingHomeCopiedDll = Path.Combine(missingHomeCopyDir, "pwrshplugin.dll");
                File.WriteAllText(missingHomeCopiedDll, string.Empty);
                File.WriteAllText(
                    Path.Combine(missingHomeCopyDir, "RemotePowerShellConfig.txt"),
                    $"PSHOMEDIR={missingHome}{Environment.NewLine}CORECLRDIR={missingHome}{Environment.NewLine}");

                string orphanMajorDir = Path.Combine(fakeSystem32Ps, "7");
                Directory.CreateDirectory(orphanMajorDir);
                File.WriteAllText(Path.Combine(orphanMajorDir, "pwrshplugin.dll"), string.Empty);

                Assert.True(PSSessionConfigurationCommandUtilities.ShouldRemoveLegacyPluginEndpoint(
                    "PowerShell.7.6.8", 7, devolutionsCopiedDll, currentDevolutionsHome, fakeSystem32Ps));
                Assert.True(PSSessionConfigurationCommandUtilities.ShouldRemoveLegacyPluginEndpoint(
                    "PowerShell.7.2.17", 7, missingHomeCopiedDll, currentDevolutionsHome, fakeSystem32Ps));
                Assert.False(PSSessionConfigurationCommandUtilities.ShouldRemoveLegacyPluginEndpoint(
                    "PowerShell.7.4.6", 7, microsoftCopiedDll, currentDevolutionsHome, fakeSystem32Ps));
                Assert.False(PSSessionConfigurationCommandUtilities.ShouldRemoveLegacyPluginEndpoint(
                    "PowerShell.7", 7, devolutionsCopiedDll, currentDevolutionsHome, fakeSystem32Ps));
                Assert.False(PSSessionConfigurationCommandUtilities.ShouldRemoveLegacyPluginEndpoint(
                    "PowerShell.7-preview", 7, devolutionsCopiedDll, currentDevolutionsHome, fakeSystem32Ps));

                PSSessionConfigurationCommandUtilities.CleanupLegacySystem32PluginDirectories(
                    majorVersion: 7,
                    currentPsHome: currentDevolutionsHome,
                    activePluginFileValues: new[] { microsoftCopiedDll },
                    system32PowerShellRoot: fakeSystem32Ps);

                Assert.False(Directory.Exists(devolutionsCopyDir));
                Assert.False(Directory.Exists(missingHomeCopyDir));
                Assert.False(Directory.Exists(orphanMajorDir));
                Assert.True(Directory.Exists(microsoftCopyDir));
                Assert.True(File.Exists(microsoftCopiedDll));
            }
            finally
            {
                Directory.Delete(tempRoot, recursive: true);
            }
        }
    }
}
#endif
