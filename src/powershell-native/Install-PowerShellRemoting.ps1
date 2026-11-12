# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

#####################################################################################################
#
# Registers the WinRM endpoint for this instance of PowerShell.
#
# If the parameters '-PowerShellHome' were specified, it means that the script will be registering
# an instance of PowerShell from another instance of PowerShell.
#
# If no parameter is specified, it means that this instance of PowerShell is registering itself.
#
# Assumptions:
#     1. The CoreCLR and the PowerShell assemblies are side-by-side in $PSHOME
#     2. Plugins are registered by version number. Only one plugin can be automatically registered
#        per PowerShell version. However, multiple endpoints may be manually registered for a given
#        plugin.
#
#####################################################################################################
[CmdletBinding(DefaultParameterSetName = "NotByPath")]
param
(
    [parameter(Mandatory = $true, ParameterSetName = "ByPath")]
    [switch]$Force,
    [string]
    $PowerShellHome
)

Set-StrictMode -Version 3.0

if (! ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator"))
{
    Write-Error "WinRM registration requires Administrator rights. To run this cmdlet, start PowerShell with the `"Run as administrator`" option."
    return
}
function Format-WinRmPluginPath
{
    param
    (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $PsHomePath
    )

    $trimmedPsHome = $PsHomePath.Trim().TrimEnd('\', '/')
    $programFiles = $env:ProgramFiles
    if (-not [string]::IsNullOrWhiteSpace($programFiles))
    {
        $trimmedProgramFiles = $programFiles.Trim().TrimEnd('\', '/')
        if ($trimmedPsHome.Equals($trimmedProgramFiles, [System.StringComparison]::OrdinalIgnoreCase))
        {
            $trimmedPsHome = '%ProgramFiles%'
        }
        elseif ($trimmedPsHome.Length -gt $trimmedProgramFiles.Length -and
                $trimmedPsHome.StartsWith($trimmedProgramFiles, [System.StringComparison]::OrdinalIgnoreCase) -and
                ($trimmedPsHome[$trimmedProgramFiles.Length] -eq '\' -or $trimmedPsHome[$trimmedProgramFiles.Length] -eq '/'))
        {
            $trimmedPsHome = '%ProgramFiles%' + $trimmedPsHome.Substring($trimmedProgramFiles.Length)
        }
    }

    return Join-Path $trimmedPsHome 'pwrshplugin.dll'
}

function Test-DevolutionsOrMissingInstallDirectory
{
    param
    (
        [string] $TargetDirectory,
        [string] $CurrentPsHome
    )

    if ([string]::IsNullOrWhiteSpace($TargetDirectory))
    {
        return $false
    }

    try
    {
        $expandedTarget = [System.IO.Path]::GetFullPath([System.Environment]::ExpandEnvironmentVariables($TargetDirectory.Trim())).TrimEnd('\', '/')
    }
    catch
    {
        return $true
    }

    if (-not [string]::IsNullOrWhiteSpace($CurrentPsHome))
    {
        try
        {
            $normalizedCurrent = [System.IO.Path]::GetFullPath([System.Environment]::ExpandEnvironmentVariables($CurrentPsHome.Trim())).TrimEnd('\', '/')
            if ($expandedTarget.Equals($normalizedCurrent, [System.StringComparison]::OrdinalIgnoreCase))
            {
                return $true
            }
        }
        catch
        {
        }
    }

    $normalizedSeparators = $expandedTarget.Replace('/', '\')
    if ($normalizedSeparators -match '(?i)\\Devolutions\\PowerShell($|\\)')
    {
        return $true
    }

    $smaPath = Join-Path $expandedTarget 'System.Management.Automation.dll'
    if (-not (Test-Path -LiteralPath $expandedTarget -PathType Container) -or
        -not (Test-Path -LiteralPath $smaPath -PathType Leaf))
    {
        return $true
    }

    return $false
}

function Get-PsHomeFromPluginConfig
{
    param
    (
        [string] $ConfigFilePath
    )

    if ([string]::IsNullOrWhiteSpace($ConfigFilePath) -or -not (Test-Path -LiteralPath $ConfigFilePath -PathType Leaf))
    {
        return $null
    }

    foreach ($line in (Get-Content -LiteralPath $ConfigFilePath -ErrorAction SilentlyContinue))
    {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith('#'))
        {
            continue
        }

        if ($trimmed.StartsWith('PSHOMEDIR=', [System.StringComparison]::OrdinalIgnoreCase))
        {
            $value = $trimmed.Substring(10).Trim()
            if (-not [string]::IsNullOrWhiteSpace($value))
            {
                return $value
            }
        }
    }

    return $null
}

function Register-WinRmPlugin
{
    param
    (
        [string]
        [parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        $pluginAbsolutePath,

        [string]
        [parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        $pluginEndpointName,

        [string]
        [parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        $pluginPsVersion
    )

    $regKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WSMAN\Plugin\$pluginEndpointName"

    if (Test-Path -LiteralPath $regKey)
    {
        $existingProp = Get-ItemProperty -LiteralPath $regKey -Name ConfigXML -ErrorAction SilentlyContinue
        if ($null -ne $existingProp -and -not [string]::IsNullOrWhiteSpace($existingProp.ConfigXML))
        {
            try
            {
                $doc = [xml]$existingProp.ConfigXML
                $doc.PlugInConfiguration.SetAttribute('Filename', $pluginAbsolutePath)
                $ns = $doc.PlugInConfiguration.NamespaceURI
                $initParams = $doc.PlugInConfiguration['InitializationParameters']
                if ($null -eq $initParams)
                {
                    $initParams = $doc.CreateElement('InitializationParameters', $ns)
                    $null = $doc.PlugInConfiguration.PrependChild($initParams)
                }

                $psVersionNode = $null
                foreach ($paramNode in @($initParams.ChildNodes))
                {
                    if ($paramNode.LocalName -eq 'Param' -and $paramNode.GetAttribute('Name') -ieq 'PSVersion')
                    {
                        $psVersionNode = $paramNode
                        break
                    }
                }

                if ($null -eq $psVersionNode)
                {
                    $psVersionNode = $doc.CreateElement('Param', $ns)
                    $psVersionNode.SetAttribute('Name', 'PSVersion')
                    $null = $initParams.AppendChild($psVersionNode)
                }

                $psVersionNode.SetAttribute('Value', $pluginPsVersion)
                Set-ItemProperty -LiteralPath $regKey -Name ConfigXML -Value $doc.OuterXml
                return
            }
            catch
            {
            }
        }
    }

    $pluginArchitecture = "64"
    if ($env:PROCESSOR_ARCHITECTURE -match "x86" -or $env:PROCESSOR_ARCHITECTURE -eq "ARM")
    {
        $pluginArchitecture = "32"
    }
    $regKeyValueFormatString = @"
<PlugInConfiguration xmlns="http://schemas.microsoft.com/wbem/wsman/1/config/PluginConfiguration" Name="{0}" Filename="{1}"
    SDKVersion="2" XmlRenderingType="text" Enabled="True" OutputBufferingMode="Block" ProcessIdleTimeoutSec="0" Architecture="{2}"
    UseSharedProcess="false" RunAsUser="" RunAsPassword="" AutoRestart="false">
    <InitializationParameters>
        <Param Name="PSVersion" Value="{3}"/>
    </InitializationParameters>
    <Resources>
        <Resource ResourceUri="http://schemas.microsoft.com/powershell/{0}" SupportsOptions="true" ExactMatch="true">
            <Security Uri="http://schemas.microsoft.com/powershell/{0}" ExactMatch="true"
            Sddl="O:NSG:BAD:P(A;;GA;;;BA)(A;;GA;;;RM)(A;;GA;;;IU)S:P(AU;FA;GA;;;WD)(AU;SA;GXGW;;;WD)"/>
            <Capability Type="Shell"/>
        </Resource>
    </Resources>
    <Quotas IdleTimeoutms="7200000" MaxConcurrentUsers="5" MaxProcessesPerShell="15" MaxMemoryPerShellMB="1024" MaxShellsPerUser="25"
    MaxConcurrentCommandsPerShell="1000" MaxShells="25" MaxIdleTimeoutms="43200000"/>
</PlugInConfiguration>
"@
    $valueString = $regKeyValueFormatString -f $pluginEndpointName, $pluginAbsolutePath, $pluginArchitecture, $pluginPsVersion

    New-Item $regKey -Force > $null
    New-ItemProperty -Path $regKey -Name ConfigXML -Value $valueString -Force > $null
}

function Remove-LegacyEndpointsAndPluginCopies
{
    param
    (
        [Parameter(Mandatory = $true)]
        [string] $MajorVersion,

        [Parameter(Mandatory = $true)]
        [string] $TargetPsHome
    )

    $wsmanPluginRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WSMAN\Plugin'
    $windowsDir = if ($PSVersionTable.PSVersion -lt '6.0') { 'C:\Windows' } else { [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::Windows) }
    $system32PsRoot = Join-Path (Join-Path $windowsDir 'System32') 'PowerShell'
    $legacyPrefix = "PowerShell.$MajorVersion."

    if (Test-Path -LiteralPath $wsmanPluginRoot)
    {
        foreach ($key in @(Get-ChildItem -LiteralPath $wsmanPluginRoot -ErrorAction SilentlyContinue))
        {
            $name = $key.PSChildName
            if (-not $name.StartsWith($legacyPrefix, [System.StringComparison]::OrdinalIgnoreCase))
            {
                continue
            }

            $prop = Get-ItemProperty -LiteralPath $key.PSPath -Name ConfigXML -ErrorAction SilentlyContinue
            if ($null -eq $prop -or [string]::IsNullOrWhiteSpace($prop.ConfigXML))
            {
                continue
            }

            $fileNameValue = $null
            try
            {
                $fileNameValue = ([xml]$prop.ConfigXML).PlugInConfiguration.Filename
            }
            catch
            {
                continue
            }

            if ([string]::IsNullOrWhiteSpace($fileNameValue))
            {
                continue
            }

            $shouldRemove = $false
            try
            {
                $expandedFile = [System.IO.Path]::GetFullPath([System.Environment]::ExpandEnvironmentVariables($fileNameValue.Trim()))
            }
            catch
            {
                $expandedFile = $null
                $shouldRemove = $true
            }

            if (-not $shouldRemove)
            {
                if (-not (Test-Path -LiteralPath $expandedFile -PathType Leaf))
                {
                    $shouldRemove = $true
                }
                else
                {
                    $pluginDir = Split-Path -Parent $expandedFile
                    $configPath = Join-Path $pluginDir 'RemotePowerShellConfig.txt'
                    $configuredPsHome = Get-PsHomeFromPluginConfig -ConfigFilePath $configPath
                    if (-not [string]::IsNullOrWhiteSpace($configuredPsHome))
                    {
                        $shouldRemove = Test-DevolutionsOrMissingInstallDirectory -TargetDirectory $configuredPsHome -CurrentPsHome $TargetPsHome
                    }
                    elseif ($pluginDir.StartsWith($system32PsRoot + '\', [System.StringComparison]::OrdinalIgnoreCase))
                    {
                        $shouldRemove = $true
                    }
                    else
                    {
                        $shouldRemove = Test-DevolutionsOrMissingInstallDirectory -TargetDirectory $pluginDir -CurrentPsHome $TargetPsHome
                    }
                }
            }

            if ($shouldRemove)
            {
                Remove-Item -LiteralPath $key.PSPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if (-not (Test-Path -LiteralPath $system32PsRoot -PathType Container))
    {
        return
    }

    $activeDirs = @{}
    if (Test-Path -LiteralPath $wsmanPluginRoot)
    {
        foreach ($key in @(Get-ChildItem -LiteralPath $wsmanPluginRoot -ErrorAction SilentlyContinue))
        {
            $prop = Get-ItemProperty -LiteralPath $key.PSPath -Name ConfigXML -ErrorAction SilentlyContinue
            if ($null -eq $prop -or [string]::IsNullOrWhiteSpace($prop.ConfigXML))
            {
                continue
            }

            try
            {
                $fn = ([xml]$prop.ConfigXML).PlugInConfiguration.Filename
                if (-not [string]::IsNullOrWhiteSpace($fn))
                {
                    $expanded = [System.IO.Path]::GetFullPath([System.Environment]::ExpandEnvironmentVariables($fn.Trim()))
                    $dir = (Split-Path -Parent $expanded).TrimEnd('\', '/')
                    $activeDirs[$dir.ToLowerInvariant()] = $true
                }
            }
            catch
            {
            }
        }
    }

    foreach ($candidate in @(Get-ChildItem -LiteralPath $system32PsRoot -Directory -ErrorAction SilentlyContinue))
    {
        $leaf = $candidate.Name
        if ($leaf -ine $MajorVersion -and
            $leaf -ine "$MajorVersion-preview" -and
            -not $leaf.StartsWith("$MajorVersion.", [System.StringComparison]::OrdinalIgnoreCase))
        {
            continue
        }

        $candidateFull = $candidate.FullName.TrimEnd('\', '/')
        if ($activeDirs.ContainsKey($candidateFull.ToLowerInvariant()))
        {
            continue
        }

        $configPath = Join-Path $candidateFull 'RemotePowerShellConfig.txt'
        $configuredPsHome = Get-PsHomeFromPluginConfig -ConfigFilePath $configPath
        if (-not [string]::IsNullOrWhiteSpace($configuredPsHome) -and
            -not (Test-DevolutionsOrMissingInstallDirectory -TargetDirectory $configuredPsHome -CurrentPsHome $TargetPsHome))
        {
            continue
        }

        foreach ($fileName in @('pwrshplugin.dll', 'RemotePowerShellConfig.txt'))
        {
            $filePath = Join-Path $candidateFull $fileName
            if (Test-Path -LiteralPath $filePath -PathType Leaf)
            {
                Remove-Item -LiteralPath $filePath -Force -ErrorAction SilentlyContinue
            }
        }

        if (@(Get-ChildItem -LiteralPath $candidateFull -Force -ErrorAction SilentlyContinue).Count -eq 0)
        {
            Remove-Item -LiteralPath $candidateFull -Force -ErrorAction SilentlyContinue
        }
    }
}

function Install-PluginEndpoint {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact="Medium")]
    param (
        [Parameter()] [bool] $Force
    )

    if (-not [String]::IsNullOrEmpty($PowerShellHome))
    {
        $targetPsHome = (Resolve-Path -LiteralPath $PowerShellHome -ErrorAction Stop).Path
        $targetPsVersion = (& "$targetPsHome\pwsh" -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' | Select-Object -Last 1).Trim()
    }
    else
    {
        $targetPsHome = (Resolve-Path -LiteralPath $PSHOME -ErrorAction Stop).Path
        $targetPsVersion = $PSVersionTable.PSVersion.ToString()
    }
    Write-Verbose "PowerShellHome: $targetPsHome" -Verbose

    $sourcePluginDll = Join-Path $targetPsHome "pwrshplugin.dll"
    if (-not (Test-Path -LiteralPath $sourcePluginDll -PathType Leaf))
    {
        throw "WinRM Plugin DLL missing. Expected = $sourcePluginDll"
    }

    $isPreview = $targetPsVersion.Contains("-")
    $dotPos = $targetPsVersion.IndexOf(".")
    $targetMajorVersion = if ($dotPos -ne -1) { $targetPsVersion.Substring(0, $dotPos) } else { $targetPsVersion }
    $endpointSuffix = if ($isPreview) { "$targetMajorVersion-preview" } else { $targetMajorVersion }
    $pluginEndpointName = "PowerShell.$endpointSuffix"

    Write-Verbose "Using PowerShell Endpoint: $pluginEndpointName (PSVersion=$targetMajorVersion)" -Verbose

    $regKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WSMAN\Plugin\$pluginEndpointName"
    $endPointExists = Test-Path -LiteralPath $regKey

    if ($endPointExists -and !$Force)
    {
        Write-Error -Category ResourceExists -ErrorId "PSSessionConfigurationExists" -Message "Endpoint $pluginEndpointName already exists."
        return
    }

    if (!$PSCmdlet.ShouldProcess($pluginEndpointName)) {
        return
    }

    $pluginPath = Format-WinRmPluginPath -PsHomePath $targetPsHome
    Register-WinRmPlugin -pluginAbsolutePath $pluginPath -pluginEndpointName $pluginEndpointName -pluginPsVersion $targetMajorVersion
    Remove-LegacyEndpointsAndPluginCopies -MajorVersion $targetMajorVersion -TargetPsHome $targetPsHome

    if ($PSVersionTable.PSVersion -ge '6.0')
    {
        try
        {
            Write-Host "`nGet-PSSessionConfiguration $pluginEndpointName" -ForegroundColor "green"
            Get-PSSessionConfiguration $pluginEndpointName -ErrorAction Stop
        }
        catch [Microsoft.PowerShell.Commands.WriteErrorException]
        {
            throw "No remoting session configuration matches the name $pluginEndpointName."
        }
    }
}

Install-PluginEndpoint -Force $Force

Write-Host "Restarting WinRM to ensure that the plugin configuration change takes effect.`nThis is required for WinRM running on Windows SKUs prior to Windows 10." -ForegroundColor Magenta
Restart-Service winrm -Force -Confirm:$false

