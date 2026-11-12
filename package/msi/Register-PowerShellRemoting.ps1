[CmdletBinding()]
param(
  [string] $InstallLocation = $PSScriptRoot,

  [ValidateSet('Install', 'Uninstall', 'Rollback')]
  [string] $Mode = 'Install',

  [Alias('En')]
  [string] $EnableRemoting = '0',

  [Alias('Net')]
  [string] $SkipNetworkProfileCheck = '0',

  [Alias('Snap')]
  [string] $SnapshotId,

  [string] $SnapshotRoot,

  [string] $MajorVersion = "$($PSVersionTable.PSVersion.Major)",

  [string] $PreReleaseLabel = [string] $PSVersionTable.PSVersion.PreReleaseLabel,

  [string] $WsManPluginRegistryPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WSMAN\Plugin',

  [string] $System32PowerShellDirectory = (Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\PowerShell'),

  [string] $ProgramFilesDirectory = $Env:ProgramFiles,

  [switch] $SkipServiceControl
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Expand-WinRmPluginPath {
  param(
    [AllowNull()]
    [string] $PathValue,

    [AllowNull()]
    [string] $ProgramFilesRoot
  )

  if ([string]::IsNullOrWhiteSpace($PathValue)) {
    return $null
  }

  $Candidate = $PathValue.Trim()
  if (-not [string]::IsNullOrWhiteSpace($ProgramFilesRoot)) {
    $TrimmedProgramFiles = $ProgramFilesRoot.Trim().TrimEnd('\', '/')
    if ($Candidate.Equals('%ProgramFiles%', [System.StringComparison]::OrdinalIgnoreCase)) {
      $Candidate = $TrimmedProgramFiles
    } elseif ($Candidate.StartsWith('%ProgramFiles%\', [System.StringComparison]::OrdinalIgnoreCase) -or
              $Candidate.StartsWith('%ProgramFiles%/', [System.StringComparison]::OrdinalIgnoreCase)) {
      $Candidate = $TrimmedProgramFiles + $Candidate.Substring('%ProgramFiles%'.Length)
    }
  }

  return [System.Environment]::ExpandEnvironmentVariables($Candidate)
}

function Format-WinRmPluginPath {
  param(
    [Parameter(Mandatory)]
    [string] $PsHomePath,

    [AllowNull()]
    [string] $ProgramFilesRoot
  )

  $TrimmedPsHome = $PsHomePath.Trim().TrimEnd('\', '/')
  if (-not [string]::IsNullOrWhiteSpace($ProgramFilesRoot)) {
    $TrimmedProgramFiles = $ProgramFilesRoot.Trim().TrimEnd('\', '/')
    if ($TrimmedPsHome.Equals($TrimmedProgramFiles, [System.StringComparison]::OrdinalIgnoreCase)) {
      $TrimmedPsHome = '%ProgramFiles%'
    } elseif ($TrimmedPsHome.Length -gt $TrimmedProgramFiles.Length -and
              $TrimmedPsHome.StartsWith($TrimmedProgramFiles, [System.StringComparison]::OrdinalIgnoreCase) -and
              ($TrimmedPsHome[$TrimmedProgramFiles.Length] -eq '\' -or $TrimmedPsHome[$TrimmedProgramFiles.Length] -eq '/')) {
      $TrimmedPsHome = '%ProgramFiles%' + $TrimmedPsHome.Substring($TrimmedProgramFiles.Length)
    }
  }

  return Join-Path $TrimmedPsHome 'pwrshplugin.dll'
}

function Get-PsHomeFromPluginConfig {
  param([string] $ConfigFilePath)

  if ([string]::IsNullOrWhiteSpace($ConfigFilePath) -or -not (Test-Path -LiteralPath $ConfigFilePath -PathType Leaf)) {
    return $null
  }

  foreach ($Line in @(Get-Content -LiteralPath $ConfigFilePath -ErrorAction SilentlyContinue)) {
    $Trimmed = $Line.Trim()
    if ($Trimmed.Length -eq 0 -or $Trimmed.StartsWith('#')) {
      continue
    }
    if ($Trimmed.StartsWith('PSHOMEDIR=', [System.StringComparison]::OrdinalIgnoreCase)) {
      $Value = $Trimmed.Substring(10).Trim()
      if (-not [string]::IsNullOrWhiteSpace($Value)) {
        return $Value
      }
    }
  }

  return $null
}

function Test-IsDevolutionsInstallDirectory {
  param(
    [AllowNull()]
    [string] $TargetDirectory,

    [AllowNull()]
    [string] $CurrentInstallDirectory,

    [AllowNull()]
    [string] $ProgramFilesRoot
  )

  if ([string]::IsNullOrWhiteSpace($TargetDirectory)) {
    return $false
  }

  try {
    $ExpandedTarget = [System.IO.Path]::GetFullPath((Expand-WinRmPluginPath -PathValue $TargetDirectory -ProgramFilesRoot $ProgramFilesRoot)).TrimEnd('\', '/')
  } catch {
    return $false
  }

  if (-not [string]::IsNullOrWhiteSpace($CurrentInstallDirectory)) {
    try {
      $NormalizedInstallDirectory = [System.IO.Path]::GetFullPath((Expand-WinRmPluginPath -PathValue $CurrentInstallDirectory -ProgramFilesRoot $ProgramFilesRoot)).TrimEnd('\', '/')
      if ($ExpandedTarget.Equals($NormalizedInstallDirectory, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
      }
    } catch {
    }
  }

  $NormalizedSeparators = $ExpandedTarget.Replace('/', '\')
  return ($NormalizedSeparators -match '(?i)\\Devolutions\\PowerShell($|\\)')
}

function Test-IsDevolutionsOrMissingInstallDirectory {
  param(
    [AllowNull()]
    [string] $TargetDirectory,

    [AllowNull()]
    [string] $CurrentInstallDirectory,

    [AllowNull()]
    [string] $ProgramFilesRoot
  )

  if ([string]::IsNullOrWhiteSpace($TargetDirectory)) {
    return $false
  }

  if (Test-IsDevolutionsInstallDirectory -TargetDirectory $TargetDirectory -CurrentInstallDirectory $CurrentInstallDirectory -ProgramFilesRoot $ProgramFilesRoot) {
    return $true
  }

  try {
    $ExpandedTarget = [System.IO.Path]::GetFullPath((Expand-WinRmPluginPath -PathValue $TargetDirectory -ProgramFilesRoot $ProgramFilesRoot)).TrimEnd('\', '/')
  } catch {
    return $true
  }

  $SmaPath = Join-Path $ExpandedTarget 'System.Management.Automation.dll'
  return (-not (Test-Path -LiteralPath $ExpandedTarget -PathType Container) -or
          -not (Test-Path -LiteralPath $SmaPath -PathType Leaf))
}

function Test-IsUnderSystem32PowerShell {
  param(
    [AllowNull()]
    [string] $DirectoryPath,

    [AllowNull()]
    [string] $System32PsRoot
  )

  if ([string]::IsNullOrWhiteSpace($DirectoryPath) -or [string]::IsNullOrWhiteSpace($System32PsRoot)) {
    return $false
  }

  try {
    $FullDir = [System.IO.Path]::GetFullPath($DirectoryPath).TrimEnd('\', '/')
    $FullRoot = [System.IO.Path]::GetFullPath($System32PsRoot).TrimEnd('\', '/')
    return ($FullDir.Length -gt $FullRoot.Length -and
            $FullDir.StartsWith($FullRoot, [System.StringComparison]::OrdinalIgnoreCase) -and
            $FullDir[$FullRoot.Length] -eq '\')
  } catch {
    return $false
  }
}

function Test-PluginTargetsDevolutions {
  param(
    [AllowNull()]
    [string] $PluginFileValue,

    [AllowNull()]
    [string] $CurrentInstallDirectory,

    [AllowNull()]
    [string] $ProgramFilesRoot,

    [AllowNull()]
    [string] $System32PsRoot,

    [switch] $IncludeMissingTargets
  )

  if ([string]::IsNullOrWhiteSpace($PluginFileValue)) {
    return $false
  }

  $ExpandedFile = $null
  try {
    $ExpandedFile = [System.IO.Path]::GetFullPath((Expand-WinRmPluginPath -PathValue $PluginFileValue -ProgramFilesRoot $ProgramFilesRoot))
  } catch {
    return [bool] $IncludeMissingTargets
  }

  $PluginDirectory = Split-Path -Parent $ExpandedFile
  if ([string]::IsNullOrWhiteSpace($PluginDirectory)) {
    return $false
  }

  $ConfigPath = Join-Path $PluginDirectory 'RemotePowerShellConfig.txt'
  $ConfiguredPsHome = Get-PsHomeFromPluginConfig -ConfigFilePath $ConfigPath
  if (-not [string]::IsNullOrWhiteSpace($ConfiguredPsHome)) {
    if ($IncludeMissingTargets) {
      return Test-IsDevolutionsOrMissingInstallDirectory -TargetDirectory $ConfiguredPsHome -CurrentInstallDirectory $CurrentInstallDirectory -ProgramFilesRoot $ProgramFilesRoot
    }
    return Test-IsDevolutionsInstallDirectory -TargetDirectory $ConfiguredPsHome -CurrentInstallDirectory $CurrentInstallDirectory -ProgramFilesRoot $ProgramFilesRoot
  }

  if (Test-IsUnderSystem32PowerShell -DirectoryPath $PluginDirectory -System32PsRoot $System32PsRoot) {
    return [bool] $IncludeMissingTargets
  }

  if (Test-IsDevolutionsInstallDirectory -TargetDirectory $PluginDirectory -CurrentInstallDirectory $CurrentInstallDirectory -ProgramFilesRoot $ProgramFilesRoot) {
    return $true
  }

  if ($IncludeMissingTargets) {
    if (-not (Test-Path -LiteralPath $ExpandedFile -PathType Leaf)) {
      return $true
    }
    return Test-IsDevolutionsOrMissingInstallDirectory -TargetDirectory $PluginDirectory -CurrentInstallDirectory $CurrentInstallDirectory -ProgramFilesRoot $ProgramFilesRoot
  }

  return $false
}

function Set-WinRmPluginRegistryEntry {
  param(
    [Parameter(Mandatory)]
    [string] $RegistryRoot,

    [Parameter(Mandatory)]
    [string] $EndpointName,

    [Parameter(Mandatory)]
    [string] $PluginFileName,

    [Parameter(Mandatory)]
    [string] $PluginPsVersion,

    [switch] $CreateIfMissing,

    [switch] $ForceEnable
  )

  $KeyPath = Join-Path $RegistryRoot $EndpointName
  if (Test-Path -LiteralPath $KeyPath) {
    $ExistingProp = Get-ItemProperty -LiteralPath $KeyPath -Name ConfigXML -ErrorAction SilentlyContinue
    if ($null -ne $ExistingProp -and -not [string]::IsNullOrWhiteSpace($ExistingProp.ConfigXML)) {
      $Document = [xml] $ExistingProp.ConfigXML
      $Changed = $false

      if ($Document.PlugInConfiguration.Filename -cne $PluginFileName) {
        $Document.PlugInConfiguration.SetAttribute('Filename', $PluginFileName)
        $Changed = $true
      }

      if ($ForceEnable -and $Document.PlugInConfiguration.Enabled -ieq 'false') {
        $Document.PlugInConfiguration.SetAttribute('Enabled', 'True')
        $Changed = $true
      }

      $NamespaceUri = $Document.PlugInConfiguration.NamespaceURI
      $InitParams = $Document.PlugInConfiguration['InitializationParameters']
      if ($null -eq $InitParams) {
        $InitParams = $Document.CreateElement('InitializationParameters', $NamespaceUri)
        $null = $Document.PlugInConfiguration.PrependChild($InitParams)
        $Changed = $true
      }

      $PsVersionNode = $null
      foreach ($Node in @($InitParams.ChildNodes)) {
        if ($Node.LocalName -eq 'Param' -and $Node.GetAttribute('Name') -ieq 'PSVersion') {
          $PsVersionNode = $Node
          break
        }
      }

      if ($null -eq $PsVersionNode) {
        $PsVersionNode = $Document.CreateElement('Param', $NamespaceUri)
        $PsVersionNode.SetAttribute('Name', 'PSVersion')
        $null = $InitParams.AppendChild($PsVersionNode)
        $Changed = $true
      }

      if ($PsVersionNode.GetAttribute('Value') -cne $PluginPsVersion) {
        $PsVersionNode.SetAttribute('Value', $PluginPsVersion)
        $Changed = $true
      }

      if ($Changed) {
        Set-ItemProperty -LiteralPath $KeyPath -Name ConfigXML -Value $Document.OuterXml
      }
      return $Changed
    }
  }

  if (-not $CreateIfMissing) {
    return $false
  }

  $Architecture = if ([System.Environment]::Is64BitOperatingSystem) { '64' } else { '32' }
  $EscapedEndpointName = [System.Security.SecurityElement]::Escape($EndpointName)
  $EscapedPluginFileName = [System.Security.SecurityElement]::Escape($PluginFileName)
  $ConfigXml = @"
<PlugInConfiguration xmlns="http://schemas.microsoft.com/wbem/wsman/1/config/PluginConfiguration" Name="$EscapedEndpointName" Filename="$EscapedPluginFileName" SDKVersion="2" XmlRenderingType="text" Enabled="True" OutputBufferingMode="Block" ProcessIdleTimeoutSec="0" Architecture="$Architecture" UseSharedProcess="false" RunAsUser="" RunAsPassword="" AutoRestart="false">
  <InitializationParameters>
    <Param Name="PSVersion" Value="$PluginPsVersion" />
  </InitializationParameters>
  <Resources>
    <Resource ResourceUri="http://schemas.microsoft.com/powershell/$EndpointName" SupportsOptions="true" ExactMatch="false">
      <Security Uri="http://schemas.microsoft.com/powershell/$EndpointName" ExactMatch="false" Sddl="O:NSG:BAD:P(A;;GA;;;BA)(A;;GA;;;RM)(A;;GA;;;IU)S:P(AU;FA;GA;;;WD)(AU;SA;GXGW;;;WD)" />
      <Capability Type="Shell" />
    </Resource>
  </Resources>
  <Quotas IdleTimeoutms="7200000" MaxConcurrentUsers="2147483647" MaxProcessesPerShell="2147483647" MaxMemoryPerShellMB="2147483647" MaxShellsPerUser="25" MaxConcurrentCommandsPerShell="2147483647" MaxShells="2147483647" MaxIdleTimeoutms="2147483647" />
</PlugInConfiguration>
"@

  if (-not (Test-Path -LiteralPath $KeyPath)) {
    New-Item -Path $KeyPath -Force | Out-Null
  }
  Set-ItemProperty -LiteralPath $KeyPath -Name ConfigXML -Value $ConfigXml
  return $true
}

function Remove-MatchingLegacyEndpointsAndCopies {
  param(
    [Parameter(Mandatory)]
    [string] $RegistryRoot,

    [Parameter(Mandatory)]
    [string] $Major,

    [Parameter(Mandatory)]
    [string] $CurrentInstallDirectory,

    [AllowNull()]
    [string] $ProgramFilesRoot,

    [AllowNull()]
    [string] $System32PsRoot,

    [switch] $IncludeDefaultEndpoint,

    [string] $DefaultEndpointName,

    [switch] $IncludeMissingTargets
  )

  $AnyChanged = $false
  $LegacyPrefix = "PowerShell.$Major."

  if (Test-Path -LiteralPath $RegistryRoot) {
    foreach ($Key in @(Get-ChildItem -LiteralPath $RegistryRoot -ErrorAction SilentlyContinue)) {
      $Name = $Key.PSChildName
      $IsDefaultMatch = ($IncludeDefaultEndpoint -and -not [string]::IsNullOrWhiteSpace($DefaultEndpointName) -and $Name -ieq $DefaultEndpointName)
      $IsLegacyVersionMatch = $Name -match ('^' + [regex]::Escape($LegacyPrefix) + '\d+\.\d+(?:\.\d+)?$')
      if (-not $IsDefaultMatch -and -not $IsLegacyVersionMatch) {
        continue
      }

      $Prop = Get-ItemProperty -LiteralPath $Key.PSPath -Name ConfigXML -ErrorAction SilentlyContinue
      if ($null -eq $Prop -or [string]::IsNullOrWhiteSpace($Prop.ConfigXML)) {
        continue
      }

      $FileNameValue = $null
      try {
        $FileNameValue = ([xml] $Prop.ConfigXML).PlugInConfiguration.Filename
      } catch {
        continue
      }

      $ShouldRemove = Test-PluginTargetsDevolutions `
        -PluginFileValue $FileNameValue `
        -CurrentInstallDirectory $CurrentInstallDirectory `
        -ProgramFilesRoot $ProgramFilesRoot `
        -System32PsRoot $System32PsRoot `
        -IncludeMissingTargets:($IsLegacyVersionMatch -and $IncludeMissingTargets)
      if ($ShouldRemove) {
        Remove-Item -LiteralPath $Key.PSPath -Recurse -Force
        $AnyChanged = $true
      }
    }
  }

  if ([string]::IsNullOrWhiteSpace($System32PsRoot) -or -not (Test-Path -LiteralPath $System32PsRoot -PathType Container)) {
    return $AnyChanged
  }

  $ActiveDirectories = @{}
  if (Test-Path -LiteralPath $RegistryRoot) {
    foreach ($Key in @(Get-ChildItem -LiteralPath $RegistryRoot -ErrorAction SilentlyContinue)) {
      $Prop = Get-ItemProperty -LiteralPath $Key.PSPath -Name ConfigXML -ErrorAction SilentlyContinue
      if ($null -eq $Prop -or [string]::IsNullOrWhiteSpace($Prop.ConfigXML)) {
        continue
      }
      try {
        $FileNameValue = ([xml] $Prop.ConfigXML).PlugInConfiguration.Filename
        if (-not [string]::IsNullOrWhiteSpace($FileNameValue)) {
          $Expanded = [System.IO.Path]::GetFullPath((Expand-WinRmPluginPath -PathValue $FileNameValue -ProgramFilesRoot $ProgramFilesRoot))
          $Dir = (Split-Path -Parent $Expanded).TrimEnd('\', '/')
          $ActiveDirectories[$Dir.ToLowerInvariant()] = $true
        }
      } catch {
      }
    }
  }

  foreach ($Candidate in @(Get-ChildItem -LiteralPath $System32PsRoot -Directory -ErrorAction SilentlyContinue)) {
    $Leaf = $Candidate.Name
    if ($Leaf -ine $Major -and
        $Leaf -ine "$Major-preview" -and
        $Leaf -notmatch ('^' + [regex]::Escape($Major) + '\.\d+\.\d+(?:\.\d+)?$')) {
      continue
    }

    $CandidatePath = $Candidate.FullName.TrimEnd('\', '/')
    if ($ActiveDirectories.ContainsKey($CandidatePath.ToLowerInvariant())) {
      continue
    }

    $ConfigPath = Join-Path $CandidatePath 'RemotePowerShellConfig.txt'
    $ConfiguredPsHome = Get-PsHomeFromPluginConfig -ConfigFilePath $ConfigPath
    $ShouldCleanDir = $false
    if (-not [string]::IsNullOrWhiteSpace($ConfiguredPsHome)) {
      if ($IncludeMissingTargets) {
        $ShouldCleanDir = Test-IsDevolutionsOrMissingInstallDirectory -TargetDirectory $ConfiguredPsHome -CurrentInstallDirectory $CurrentInstallDirectory -ProgramFilesRoot $ProgramFilesRoot
      } else {
        $ShouldCleanDir = Test-IsDevolutionsInstallDirectory -TargetDirectory $ConfiguredPsHome -CurrentInstallDirectory $CurrentInstallDirectory -ProgramFilesRoot $ProgramFilesRoot
      }
    } elseif ($IncludeMissingTargets) {
      $ShouldCleanDir = $true
    }

    if (-not $ShouldCleanDir) {
      continue
    }

    foreach ($FileName in @('pwrshplugin.dll', 'RemotePowerShellConfig.txt')) {
      $FilePath = Join-Path $CandidatePath $FileName
      if (Test-Path -LiteralPath $FilePath -PathType Leaf) {
        Remove-Item -LiteralPath $FilePath -Force -ErrorAction SilentlyContinue
        $AnyChanged = $true
      }
    }

    if (@(Get-ChildItem -LiteralPath $CandidatePath -Force -ErrorAction SilentlyContinue).Count -eq 0) {
      Remove-Item -LiteralPath $CandidatePath -Force -ErrorAction SilentlyContinue
    }
  }

  return $AnyChanged
}

function Restart-WinRmIfRunning {
  if ($SkipServiceControl) {
    return
  }

  $Service = Get-Service -Name 'winrm' -ErrorAction SilentlyContinue
  if ($null -ne $Service -and $Service.Status -eq 'Running') {
    Restart-Service -Name 'winrm' -Force -Confirm:$false -ErrorAction SilentlyContinue
  }
}

function Get-RemotingSnapshotDirectory {
  param([Parameter(Mandatory)] [string] $Id)

  try {
    $SnapshotGuid = [guid]::Parse($Id)
  } catch {
    throw "SnapshotId must be a GUID: $Id"
  }

  $Root = if ([string]::IsNullOrWhiteSpace($SnapshotRoot)) {
    Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Devolutions\PowerShell\RemotingRollback'
  } else {
    $SnapshotRoot
  }
  return Join-Path $Root $SnapshotGuid.ToString('B')
}

function Get-RegistryKeySnapshot {
  param([Parameter(Mandatory)] [string] $KeyPath)

  $Key = Get-Item -LiteralPath $KeyPath -ErrorAction Stop
  $Values = @(
    foreach ($ValueName in $Key.GetValueNames()) {
      $Kind = $Key.GetValueKind($ValueName)
      $Value = $Key.GetValue($ValueName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
      if ($Kind -eq [Microsoft.Win32.RegistryValueKind]::Binary -or $Kind -eq [Microsoft.Win32.RegistryValueKind]::None) {
        $Value = [Convert]::ToBase64String([byte[]] $Value)
      }

      [pscustomobject]@{
        Name = $ValueName
        Kind = $Kind.ToString()
        Value = $Value
      }
    }
  )
  $Children = @(
    foreach ($ChildName in $Key.GetSubKeyNames()) {
      Get-RegistryKeySnapshot -KeyPath (Join-Path $KeyPath $ChildName)
    }
  )

  return [pscustomobject]@{
    Name = Split-Path -Leaf $KeyPath
    Values = $Values
    Children = $Children
  }
}

function Restore-RegistryKeySnapshot {
  param(
    [Parameter(Mandatory)] [string] $ParentPath,
    [Parameter(Mandatory)] $Snapshot
  )

  $KeyPath = Join-Path $ParentPath $Snapshot.Name
  $PathMatch = [regex]::Match($KeyPath, '^(?<Hive>HKLM|HKCU):\\(?<SubKey>.*)$')
  if (-not $PathMatch.Success) {
    throw "Unsupported registry path in remoting snapshot: $KeyPath"
  }
  $Hive = if ($PathMatch.Groups['Hive'].Value -eq 'HKLM') {
    [Microsoft.Win32.RegistryHive]::LocalMachine
  } else {
    [Microsoft.Win32.RegistryHive]::CurrentUser
  }
  $BaseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, [Microsoft.Win32.RegistryView]::Default)
  $Key = $null
  try {
    $Key = $BaseKey.CreateSubKey($PathMatch.Groups['SubKey'].Value.Replace('/', '\'))
    foreach ($Value in @($Snapshot.Values)) {
      $Kind = [Microsoft.Win32.RegistryValueKind] $Value.Kind
      $Data = $Value.Value
      switch ($Kind) {
        ([Microsoft.Win32.RegistryValueKind]::Binary) { $Data = [Convert]::FromBase64String([string] $Data); break }
        ([Microsoft.Win32.RegistryValueKind]::None) { $Data = [Convert]::FromBase64String([string] $Data); break }
        ([Microsoft.Win32.RegistryValueKind]::MultiString) { $Data = [string[]] @($Data); break }
        ([Microsoft.Win32.RegistryValueKind]::DWord) { $Data = [int] $Data; break }
        ([Microsoft.Win32.RegistryValueKind]::QWord) { $Data = [long] $Data; break }
      }
      $Key.SetValue([string] $Value.Name, $Data, $Kind)
    }

    foreach ($Child in @($Snapshot.Children)) {
      Restore-RegistryKeySnapshot -ParentPath $KeyPath -Snapshot $Child
    }
  } finally {
    if ($null -ne $Key) {
      $Key.Dispose()
    }
    $BaseKey.Dispose()
  }
}

function Save-RemotingSnapshot {
  param(
    [Parameter(Mandatory)] [string] $Id,
    [Parameter(Mandatory)] [string] $RegistryRoot,
    [AllowNull()] [string] $System32PsRoot,
    [Parameter(Mandatory)] [string] $Major,
    [Parameter(Mandatory)] [string] $DefaultEndpointName
  )

  $Directory = Get-RemotingSnapshotDirectory -Id $Id
  if (Test-Path -LiteralPath $Directory) {
    Remove-Item -LiteralPath $Directory -Recurse -Force
  }

  $Acl = New-Object System.Security.AccessControl.DirectorySecurity
  $Acl.SetAccessRuleProtection($true, $false)
  $SnapshotSids = @('S-1-5-18', 'S-1-5-32-544', [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value) | Select-Object -Unique
  foreach ($Sid in $SnapshotSids) {
    $Rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
      [System.Security.Principal.SecurityIdentifier]::new($Sid),
      [System.Security.AccessControl.FileSystemRights]::FullControl,
      ([System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit),
      [System.Security.AccessControl.PropagationFlags]::None,
      [System.Security.AccessControl.AccessControlType]::Allow
    )
    $Acl.AddAccessRule($Rule)
  }
  $null = [System.IO.Directory]::CreateDirectory((Split-Path -Parent $Directory))
  New-Item -Path $Directory -ItemType Directory -Force | Out-Null
  Set-Acl -LiteralPath $Directory -AclObject $Acl

  $LegacyPrefix = "PowerShell.$Major."
  $RegistryEntries = @(
    if (Test-Path -LiteralPath $RegistryRoot) {
      foreach ($Key in @(Get-ChildItem -LiteralPath $RegistryRoot -ErrorAction Stop)) {
        if ($Key.PSChildName -ieq $DefaultEndpointName -or
            $Key.PSChildName -match ('^' + [regex]::Escape($LegacyPrefix) + '\d+\.\d+(?:\.\d+)?$')) {
          Get-RegistryKeySnapshot -KeyPath $Key.PSPath
        }
      }
    }
  )

  $DirectoryEntries = @()
  if (-not [string]::IsNullOrWhiteSpace($System32PsRoot) -and (Test-Path -LiteralPath $System32PsRoot -PathType Container)) {
    $Index = 0
    foreach ($Candidate in @(Get-ChildItem -LiteralPath $System32PsRoot -Directory -ErrorAction Stop)) {
      if ($Candidate.Name -ine $Major -and
          $Candidate.Name -ine "$Major-preview" -and
          $Candidate.Name -notmatch ('^' + [regex]::Escape($Major) + '\.\d+\.\d+(?:\.\d+)?$')) {
        continue
      }

      $Files = @()
      foreach ($Name in @('pwrshplugin.dll', 'RemotePowerShellConfig.txt')) {
        $FilePath = Join-Path $Candidate.FullName $Name
        if (Test-Path -LiteralPath $FilePath -PathType Leaf) {
          $BackupName = "$Index-$Name"
          Copy-Item -LiteralPath $FilePath -Destination (Join-Path $Directory $BackupName) -Force
          $Files += [pscustomobject]@{ Name = $Name; BackupName = $BackupName }
        }
      }

      $DirectoryEntries += [pscustomobject]@{
        Path = $Candidate.FullName
        Files = $Files
      }
      $Index++
    }
  }

  [pscustomobject]@{
    RegistryRoot = $RegistryRoot
    RegistryNames = @($DefaultEndpointName, (Get-ChildItem -LiteralPath $RegistryRoot -ErrorAction SilentlyContinue | Where-Object {
      $_.PSChildName -match ('^' + [regex]::Escape($LegacyPrefix) + '\d+\.\d+(?:\.\d+)?$')
    } | ForEach-Object { $_.PSChildName }))
    RegistryEntries = $RegistryEntries
    Directories = $DirectoryEntries
  } | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath (Join-Path $Directory 'state.json') -Encoding utf8
}

function Restore-RemotingSnapshot {
  param([Parameter(Mandatory)] [string] $Id)

  $Directory = Get-RemotingSnapshotDirectory -Id $Id
  $StatePath = Join-Path $Directory 'state.json'
  if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
    return
  }

  $State = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
  foreach ($Name in @($State.RegistryNames)) {
    $KeyPath = Join-Path $State.RegistryRoot $Name
    if (Test-Path -LiteralPath $KeyPath) {
      Remove-Item -LiteralPath $KeyPath -Recurse -Force
    }
  }
  foreach ($Entry in @($State.RegistryEntries)) {
    Restore-RegistryKeySnapshot -ParentPath $State.RegistryRoot -Snapshot $Entry
  }

  foreach ($Entry in @($State.Directories)) {
    if (-not (Test-Path -LiteralPath $Entry.Path -PathType Container)) {
      New-Item -Path $Entry.Path -ItemType Directory -Force | Out-Null
    }
    foreach ($File in @($Entry.Files)) {
      Copy-Item -LiteralPath (Join-Path $Directory $File.BackupName) -Destination (Join-Path $Entry.Path $File.Name) -Force
    }
  }

  Remove-Item -LiteralPath $Directory -Recurse -Force
  Restart-WinRmIfRunning
}

$InstallLocation = $InstallLocation.Trim().TrimEnd('"')
if ([string]::IsNullOrWhiteSpace($InstallLocation)) {
  throw 'InstallLocation is required when configuring PowerShell remoting.'
}
$ResolvedInstallLocation = [System.IO.Path]::GetFullPath($InstallLocation).TrimEnd('\', '/')
$DefaultEndpointName = if ([string]::IsNullOrWhiteSpace($PreReleaseLabel)) {
  "PowerShell.$MajorVersion"
} else {
  "PowerShell.$MajorVersion-preview"
}

if ($Mode -eq 'Rollback') {
  if (-not [string]::IsNullOrWhiteSpace($SnapshotId)) {
    Restore-RemotingSnapshot -Id $SnapshotId
  }
  return
}

if (-not [string]::IsNullOrWhiteSpace($SnapshotId)) {
  Save-RemotingSnapshot `
    -Id $SnapshotId `
    -RegistryRoot $WsManPluginRegistryPath `
    -System32PsRoot $System32PowerShellDirectory `
    -Major $MajorVersion `
    -DefaultEndpointName $DefaultEndpointName
}

if ($Mode -eq 'Uninstall') {
  $Unregistered = Remove-MatchingLegacyEndpointsAndCopies `
    -RegistryRoot $WsManPluginRegistryPath `
    -Major $MajorVersion `
    -CurrentInstallDirectory $ResolvedInstallLocation `
    -ProgramFilesRoot $ProgramFilesDirectory `
    -System32PsRoot $System32PowerShellDirectory `
    -IncludeDefaultEndpoint `
    -DefaultEndpointName $DefaultEndpointName
  if ($Unregistered) {
    Restart-WinRmIfRunning
  }
  return
}

$PluginDllPath = Join-Path $ResolvedInstallLocation 'pwrshplugin.dll'
if (-not (Test-Path -LiteralPath $PluginDllPath -PathType Leaf)) {
  throw "PowerShell WinRM plugin DLL was not found: $PluginDllPath"
}

$ExpectedPluginValue = Format-WinRmPluginPath -PsHomePath $ResolvedInstallLocation -ProgramFilesRoot $ProgramFilesDirectory
$EnableRequested = ($EnableRemoting -eq '1' -or $EnableRemoting -ieq 'true')
$SkipNetCheck = ($SkipNetworkProfileCheck -eq '1' -or $SkipNetworkProfileCheck -ieq 'true')

if ($EnableRequested) {
  if (-not $SkipServiceControl) {
    try {
      Enable-PSRemoting -Force -SkipNetworkProfileCheck:$SkipNetCheck
    } catch {
      Write-Warning "Enable-PSRemoting reported an error; ensuring $DefaultEndpointName plugin registration directly: $($_.Exception.Message)"
    }
  }

  $UpdatedEndpoint = Set-WinRmPluginRegistryEntry `
    -RegistryRoot $WsManPluginRegistryPath `
    -EndpointName $DefaultEndpointName `
    -PluginFileName $ExpectedPluginValue `
    -PluginPsVersion $MajorVersion `
    -CreateIfMissing `
    -ForceEnable
  $CleanedLegacy = Remove-MatchingLegacyEndpointsAndCopies `
    -RegistryRoot $WsManPluginRegistryPath `
    -Major $MajorVersion `
    -CurrentInstallDirectory $ResolvedInstallLocation `
    -ProgramFilesRoot $ProgramFilesDirectory `
    -System32PsRoot $System32PowerShellDirectory `
    -IncludeMissingTargets
  if ($UpdatedEndpoint -or $CleanedLegacy) {
    Restart-WinRmIfRunning
  }
  return
}

# ENABLE_PSREMOTING is off: do not enable remoting from scratch, but if PowerShell.7 already
# points at a Devolutions PowerShell path (for example after manual Enable-PSRemoting followed
# by an MSI upgrade from 7-x64/7-arm64 to 7), refresh its path/version and clean Devolutions leftovers.
$Changed = $false
$DefaultKeyPath = Join-Path $WsManPluginRegistryPath $DefaultEndpointName
if (Test-Path -LiteralPath $DefaultKeyPath) {
  $ExistingProp = Get-ItemProperty -LiteralPath $DefaultKeyPath -Name ConfigXML -ErrorAction SilentlyContinue
  if ($null -ne $ExistingProp -and -not [string]::IsNullOrWhiteSpace($ExistingProp.ConfigXML)) {
    try {
      $CurrentFileName = ([xml] $ExistingProp.ConfigXML).PlugInConfiguration.Filename
      if (Test-PluginTargetsDevolutions `
            -PluginFileValue $CurrentFileName `
            -CurrentInstallDirectory $ResolvedInstallLocation `
            -ProgramFilesRoot $ProgramFilesDirectory `
            -System32PsRoot $System32PowerShellDirectory `
            -IncludeMissingTargets) {
        if (Set-WinRmPluginRegistryEntry `
              -RegistryRoot $WsManPluginRegistryPath `
              -EndpointName $DefaultEndpointName `
              -PluginFileName $ExpectedPluginValue `
              -PluginPsVersion $MajorVersion) {
          $Changed = $true
        }
      }
    } catch {
    }
  }
}

if (Remove-MatchingLegacyEndpointsAndCopies `
      -RegistryRoot $WsManPluginRegistryPath `
      -Major $MajorVersion `
      -CurrentInstallDirectory $ResolvedInstallLocation `
      -ProgramFilesRoot $ProgramFilesDirectory `
      -System32PsRoot $System32PowerShellDirectory) {
  $Changed = $true
}

if ($Changed) {
  Restart-WinRmIfRunning
}
