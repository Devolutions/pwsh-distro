[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $PackageDirectory,

  [Parameter(Mandatory)]
  [string] $PowerShellVersion,

  [string] $PackageVersion,

  [Parameter(Mandatory)]
  [string] $TargetFramework,

  [string] $RuntimeIdentifier,

  [string] $PackageId = 'Devolutions.PowerShell.SDK',

  [string] $PackageVendorName = 'Devolutions',

  [switch] $SkipRuntimeExecution
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Get-DefaultRuntimeIdentifier {
  $Architecture = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
    'X64' { 'x64'; break }
    'Arm64' { 'arm64'; break }
    default { throw "Unsupported architecture for PowerShell SDK apphost validation: $_" }
  }

  if ($IsWindows) {
    return "win-$Architecture"
  }
  if ($IsLinux) {
    return "linux-$Architecture"
  }
  if ($IsMacOS) {
    return "osx-$Architecture"
  }

  throw "Unsupported operating system for PowerShell SDK apphost validation"
}

function Invoke-DotNet {
  param(
    [Parameter(Mandatory)]
    [string[]] $Arguments
  )

  & dotnet @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "dotnet $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
  }
}

function Add-ProjectProperty {
  param(
    [Parameter(Mandatory)]
    [xml] $Project,

    [Parameter(Mandatory)]
    [System.Xml.XmlElement] $PropertyGroup,

    [Parameter(Mandatory)]
    [string] $Name,

    [Parameter(Mandatory)]
    [string] $Value
  )

  $Element = $Project.CreateElement($Name)
  $Element.InnerText = $Value
  [void] $PropertyGroup.AppendChild($Element)
}

function Add-RuntimeNativePublishDuplicateProbeTarget {
  param(
    [Parameter(Mandatory)]
    [xml] $Project,

    [Parameter(Mandatory)]
    [string] $PackageId,

    [Parameter(Mandatory)]
    [string] $PackageVersion,

    [Parameter(Mandatory)]
    [string[]] $RuntimeIdentifiers
  )

  $PackageDirectoryName = $PackageId.ToLowerInvariant()
  $Target = $Project.CreateElement('Target')
  $Target.SetAttribute('Name', 'InjectPowerShellSDKRuntimeNativePublishDuplicateProbe')
  $Target.SetAttribute('BeforeTargets', '_PowerShellSDKRemoveAutomaticRuntimeNativePublishItems')
  $ItemGroup = $Project.CreateElement('ItemGroup')
  foreach ($RuntimeIdentifier in $RuntimeIdentifiers) {
    $ExecutableName = if ($RuntimeIdentifier -like 'win-*') { 'pwsh.exe' } else { 'pwsh' }
    $PackageRelativePath = "runtimes/$RuntimeIdentifier/native/$ExecutableName"
    $PackagePath = "`$(NuGetPackageRoot)$PackageDirectoryName/$PackageVersion/$PackageRelativePath"
    $ResolvedFileToPublish = $Project.CreateElement('ResolvedFileToPublish')
    $ResolvedFileToPublish.SetAttribute('Include', $PackagePath)
    $ResolvedFileToPublish.SetAttribute('Condition', "Exists('$PackagePath')")

    foreach ($Metadata in @(
        @{ Name = 'RelativePath'; Value = $PackageRelativePath },
        @{ Name = 'CopyToPublishDirectory'; Value = 'PreserveNewest' },
        @{ Name = 'NuGetPackageId'; Value = $PackageId },
        @{ Name = 'PathInPackage'; Value = $PackageRelativePath })) {
      $MetadataElement = $Project.CreateElement($Metadata.Name)
      $MetadataElement.InnerText = $Metadata.Value
      [void] $ResolvedFileToPublish.AppendChild($MetadataElement)
    }

    [void] $ItemGroup.AppendChild($ResolvedFileToPublish)
  }

  [void] $Target.AppendChild($ItemGroup)
  [void] $Project.Project.AppendChild($Target)
}

function Add-PowerShellStandardPublishDuplicateProbeTarget {
  param(
    [Parameter(Mandatory)]
    [xml] $Project,

    [Parameter(Mandatory)]
    [string] $PackageId,

    [Parameter(Mandatory)]
    [string] $PackageVersion,

    [Parameter(Mandatory)]
    [string] $SdkPackageId,

    [Parameter(Mandatory)]
    [string] $SdkPackageVersion,

    [Parameter(Mandatory)]
    [string] $RuntimeAssetGroup,

    [Parameter(Mandatory)]
    [string] $TargetFramework
  )

  $PackageDirectoryName = $PackageId.ToLowerInvariant()
  $SdkPackageDirectoryName = $SdkPackageId.ToLowerInvariant()
  $Target = $Project.CreateElement('Target')
  $Target.SetAttribute('Name', 'InjectPowerShellStandardPublishDuplicateProbe')
  $Target.SetAttribute('BeforeTargets', '_PowerShellSDKRemoveAutomaticRuntimeNativePublishItems')

  $PropertyGroup = $Project.CreateElement('PropertyGroup')
  foreach ($Property in @(
      @{ Name = '_PowerShellStandardProbePath'; Value = "`$(NuGetPackageRoot)$PackageDirectoryName/$PackageVersion/lib/netstandard2.0/System.Management.Automation.dll" },
      @{ Name = '_PowerShellStandardProbeSourcePath'; Value = "`$(NuGetPackageRoot)$SdkPackageDirectoryName/$SdkPackageVersion/runtimes/$RuntimeAssetGroup/lib/$TargetFramework/System.Management.Automation.dll" })) {
    $Element = $Project.CreateElement($Property.Name)
    $Element.InnerText = $Property.Value
    [void] $PropertyGroup.AppendChild($Element)
  }
  [void] $Target.AppendChild($PropertyGroup)

  $MakeDir = $Project.CreateElement('MakeDir')
  $MakeDir.SetAttribute('Directories', "`$(NuGetPackageRoot)$PackageDirectoryName/$PackageVersion/lib/netstandard2.0")
  $MakeDir.SetAttribute('Condition', "Exists('`$(_PowerShellStandardProbeSourcePath)')")
  [void] $Target.AppendChild($MakeDir)

  $Copy = $Project.CreateElement('Copy')
  $Copy.SetAttribute('SourceFiles', '$(_PowerShellStandardProbeSourcePath)')
  $Copy.SetAttribute('DestinationFiles', '$(_PowerShellStandardProbePath)')
  $Copy.SetAttribute('Condition', "Exists('`$(_PowerShellStandardProbeSourcePath)')")
  [void] $Target.AppendChild($Copy)

  $ItemGroup = $Project.CreateElement('ItemGroup')
  $ResolvedFileToPublish = $Project.CreateElement('ResolvedFileToPublish')
  $ResolvedFileToPublish.SetAttribute('Include', '$(_PowerShellStandardProbePath)')
  $ResolvedFileToPublish.SetAttribute('Condition', "Exists('`$(_PowerShellStandardProbePath)')")
  foreach ($Metadata in @(
      @{ Name = 'RelativePath'; Value = 'System.Management.Automation.dll' },
      @{ Name = 'CopyToPublishDirectory'; Value = 'PreserveNewest' },
      @{ Name = 'NuGetPackageId'; Value = $PackageId },
      @{ Name = 'PathInPackage'; Value = 'lib/netstandard2.0/System.Management.Automation.dll' })) {
    $MetadataElement = $Project.CreateElement($Metadata.Name)
    $MetadataElement.InnerText = $Metadata.Value
    [void] $ResolvedFileToPublish.AppendChild($MetadataElement)
  }
  [void] $ItemGroup.AppendChild($ResolvedFileToPublish)
  [void] $Target.AppendChild($ItemGroup)

  [void] $Project.Project.AppendChild($Target)
}

function Assert-AppHostOutput {
  param(
    [Parameter(Mandatory)]
    [string] $Directory,

    [Parameter(Mandatory)]
    [string] $ExecutableName,

    [Parameter(Mandatory)]
    [string] $Description
  )

  foreach ($FileName in @($ExecutableName, 'pwsh.dll', 'pwsh.runtimeconfig.json')) {
    $OutputPath = Join-Path $Directory $FileName
    if (-not (Test-Path $OutputPath -PathType Leaf)) {
      throw "$Description is missing expected apphost file: $OutputPath"
    }
  }

  foreach ($RelativeModulePath in @(
      'Modules/Microsoft.PowerShell.Management/Microsoft.PowerShell.Management.psd1',
      'Modules/Microsoft.PowerShell.Utility/Microsoft.PowerShell.Utility.psd1',
      'Modules/Microsoft.PowerShell.Security/Microsoft.PowerShell.Security.psd1')) {
    $OutputPath = Join-Path $Directory ($RelativeModulePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path $OutputPath -PathType Leaf)) {
      throw "$Description is missing expected apphost module file: $OutputPath"
    }
  }
}

function Assert-RuntimeNativeAppHostOutput {
  param(
    [Parameter(Mandatory)]
    [string] $Directory,

    [Parameter(Mandatory)]
    [string] $RuntimeIdentifier,

    [Parameter(Mandatory)]
    [string] $ExecutableName,

    [Parameter(Mandatory)]
    [bool] $SelfContained,

    [Parameter(Mandatory)]
    [string] $Description
  )

  $NativeDirectory = Join-Path $Directory "runtimes/$RuntimeIdentifier/native"
  $ExecutablePath = Join-Path $NativeDirectory $ExecutableName
  if (-not (Test-Path $ExecutablePath -PathType Leaf)) {
    throw "$Description is missing expected runtime-native apphost file: $ExecutablePath"
  }

  $UnexpectedPayloadFiles = @(
    'pwsh.dll',
    'pwsh.runtimeconfig.json',
    'System.Management.Automation.dll',
    'Microsoft.PowerShell.ConsoleHost.dll',
    'Microsoft.Management.Infrastructure.dll',
    'Newtonsoft.Json.dll',
    'Modules/Microsoft.PowerShell.Management/Microsoft.PowerShell.Management.psd1'
  )
  foreach ($RelativePayloadPath in $UnexpectedPayloadFiles) {
    $PayloadPath = Join-Path $NativeDirectory ($RelativePayloadPath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    if (Test-Path $PayloadPath) {
      throw "$Description unexpectedly duplicated shared PowerShell payload under runtime-native apphost directory: $PayloadPath"
    }
  }

  return $ExecutablePath
}

function Assert-NoRootRuntimeNativeAppHostOutput {
  param(
    [Parameter(Mandatory)]
    [string] $Directory,

    [Parameter(Mandatory)]
    [string] $ExecutableName,

    [Parameter(Mandatory)]
    [string] $Description
  )

  $RootExecutablePath = Join-Path $Directory $ExecutableName
  if (Test-Path $RootExecutablePath -PathType Leaf) {
    throw "$Description unexpectedly copied the runtime-native apphost to the app root: $RootExecutablePath"
  }
}

function Assert-SharedPowerShellOutput {
  param(
    [Parameter(Mandatory)]
    [string] $Directory,

    [Parameter(Mandatory)]
    [bool] $SelfContained,

    [Parameter(Mandatory)]
    [string] $Description
  )

  foreach ($FileName in @('pwsh.dll', 'pwsh.runtimeconfig.json', 'Microsoft.PowerShell.ConsoleHost.dll', 'System.Management.Automation.dll')) {
    $OutputPath = Join-Path $Directory $FileName
    if (-not (Test-Path $OutputPath -PathType Leaf)) {
      throw "$Description is missing expected shared PowerShell payload file: $OutputPath"
    }
  }

  foreach ($RelativeModulePath in @(
      'Modules/Microsoft.PowerShell.Management/Microsoft.PowerShell.Management.psd1',
      'Modules/Microsoft.PowerShell.Utility/Microsoft.PowerShell.Utility.psd1',
      'Modules/Microsoft.PowerShell.Security/Microsoft.PowerShell.Security.psd1')) {
    $OutputPath = Join-Path $Directory ($RelativeModulePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path $OutputPath -PathType Leaf)) {
      throw "$Description is missing expected shared PowerShell module file: $OutputPath"
    }
  }

  Assert-RuntimeConfigMode -RuntimeConfigPath (Join-Path $Directory 'pwsh.runtimeconfig.json') -SelfContained $SelfContained -Description $Description
}

function Get-SourceBuiltRuntimePackageAsset {
  param(
    [Parameter(Mandatory)]
    [string[]] $SourceBuiltPackageAssetEntries,

    [Parameter(Mandatory)]
    [string] $RuntimeAssetGroup,

    [Parameter(Mandatory)]
    [string] $TargetFramework
  )

  $RuntimeAssetPrefix = "runtimes/$RuntimeAssetGroup/lib/$TargetFramework/"
  return @(
    $SourceBuiltPackageAssetEntries |
      Where-Object {
        $_.StartsWith($RuntimeAssetPrefix, [System.StringComparison]::OrdinalIgnoreCase) -and
        $_.EndsWith('.dll', [System.StringComparison]::OrdinalIgnoreCase)
      } |
      Sort-Object -Unique
  )
}

function Get-SourceBuiltRuntimePackagePayload {
  param(
    [Parameter(Mandatory)]
    [string[]] $SourceBuiltPackageAssetEntries,

    [Parameter(Mandatory)]
    [string] $RuntimeAssetGroup,

    [Parameter(Mandatory)]
    [string] $TargetFramework
  )

  $RuntimeAssetPrefix = "runtimes/$RuntimeAssetGroup/lib/$TargetFramework/"
  return @(
    $SourceBuiltPackageAssetEntries |
      Where-Object {
        $_.StartsWith($RuntimeAssetPrefix, [System.StringComparison]::OrdinalIgnoreCase) -and
        $_.EndsWith('.dll', [System.StringComparison]::OrdinalIgnoreCase)
      } |
      Sort-Object -Unique
  )
}

function Assert-SharedPowerShellRuntimeLibPreserved {
  param(
    [Parameter(Mandatory)]
    [string] $RestoredSdkPath,

    [Parameter(Mandatory)]
    [string] $Directory,

    [Parameter(Mandatory)]
    [string[]] $SourceBuiltPackageAssetEntries,

    [Parameter(Mandatory)]
    [string] $RuntimeAssetGroup,

    [Parameter(Mandatory)]
    [string] $TargetFramework,

    [Parameter(Mandatory)]
    [string] $Description
  )

  foreach ($RelativePayloadPath in Get-SourceBuiltRuntimePackagePayload -SourceBuiltPackageAssetEntries $SourceBuiltPackageAssetEntries -RuntimeAssetGroup $RuntimeAssetGroup -TargetFramework $TargetFramework) {
    $ExpectedPath = Join-Path $RestoredSdkPath ($RelativePayloadPath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    $ActualPath = Join-Path $Directory ($RelativePayloadPath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    Assert-FileContentMatches -ExpectedPath $ExpectedPath -ActualPath $ActualPath -Description "$Description runtime lib $RelativePayloadPath"
  }

  foreach ($RelativeModulePath in @(
      "runtimes/$RuntimeAssetGroup/lib/$TargetFramework/Modules/Microsoft.PowerShell.Management/Microsoft.PowerShell.Management.psd1",
      "runtimes/$RuntimeAssetGroup/lib/$TargetFramework/Modules/Microsoft.PowerShell.Utility/Microsoft.PowerShell.Utility.psd1",
      "runtimes/$RuntimeAssetGroup/lib/$TargetFramework/Modules/Microsoft.PowerShell.Security/Microsoft.PowerShell.Security.psd1")) {
    $ModulePayloadPath = Join-Path $Directory ($RelativeModulePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path $ModulePayloadPath -PathType Leaf)) {
      throw "$Description is missing shared PowerShell module payload under runtime lib asset directory: $ModulePayloadPath"
    }
  }
}

function Assert-PSGalleryModulesAbsent {
  param(
    [Parameter(Mandatory)]
    [string] $Directory,

    [Parameter(Mandatory)]
    [string[]] $ModuleNames,

    [Parameter(Mandatory)]
    [string] $Description
  )

  foreach ($ModuleName in $ModuleNames) {
    $ModulePath = Join-Path $Directory "Modules/$ModuleName"
    if (Test-Path $ModulePath) {
      throw "$Description unexpectedly contains PSGallery module '$ModuleName': $ModulePath"
    }
  }
}

function Assert-PSGalleryModulesPresent {
  param(
    [Parameter(Mandatory)]
    [string] $Directory,

    [Parameter(Mandatory)]
    [string[]] $ModuleNames,

    [Parameter(Mandatory)]
    [string] $Description
  )

  foreach ($ModuleName in $ModuleNames) {
    $ManifestPath = Join-Path $Directory "Modules/$ModuleName/$ModuleName.psd1"
    if (-not (Test-Path $ManifestPath -PathType Leaf)) {
      throw "$Description is missing expected PSGallery module manifest: $ManifestPath"
    }
  }
}

function Assert-PowerShellConfig {
  param(
    [Parameter(Mandatory)]
    [string] $Directory,

    [Parameter(Mandatory)]
    [string] $ExpectedExecutionPolicy,

    [Parameter(Mandatory)]
    [string] $Description
  )

  $ConfigPath = Join-Path $Directory 'powershell.config.json'
  if (-not (Test-Path $ConfigPath -PathType Leaf)) {
    throw "$Description is missing expected PowerShell config file: $ConfigPath"
  }

  $Config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
  $ExecutionPolicy = [string] $Config.'Microsoft.PowerShell:ExecutionPolicy'
  if ($ExecutionPolicy -ne $ExpectedExecutionPolicy) {
    throw "$Description has PowerShell config execution policy '$ExecutionPolicy', expected '$ExpectedExecutionPolicy': $ConfigPath"
  }
}

function Set-PowerShellConfig {
  param(
    [Parameter(Mandatory)]
    [string] $Directory,

    [Parameter(Mandatory)]
    [string] $ExecutionPolicy
  )

  $ConfigPath = Join-Path $Directory 'powershell.config.json'
  @"
{
  "Microsoft.PowerShell:ExecutionPolicy": "$ExecutionPolicy"
}
"@ | Set-Content -LiteralPath $ConfigPath -Encoding utf8
}

function Assert-FileContentMatches {
  param(
    [Parameter(Mandatory)]
    [string] $ExpectedPath,

    [Parameter(Mandatory)]
    [string] $ActualPath,

    [Parameter(Mandatory)]
    [string] $Description
  )

  if (-not (Test-Path $ExpectedPath -PathType Leaf)) {
    throw "$Description expected file does not exist: $ExpectedPath"
  }
  if (-not (Test-Path $ActualPath -PathType Leaf)) {
    throw "$Description actual file does not exist: $ActualPath"
  }

  $ExpectedHash = (Get-FileHash -LiteralPath $ExpectedPath -Algorithm SHA256).Hash
  $ActualHash = (Get-FileHash -LiteralPath $ActualPath -Algorithm SHA256).Hash
  if ($ActualHash -ne $ExpectedHash) {
    throw "$Description file content mismatch. Expected '$ExpectedPath' ($ExpectedHash), got '$ActualPath' ($ActualHash)."
  }
}

function Assert-OutputContainsPath {
  param(
    [Parameter(Mandatory)]
    [object[]] $Output,

    [Parameter(Mandatory)]
    [string] $ExpectedPath,

    [Parameter(Mandatory)]
    [string] $Description
  )

  $ResolvedExpectedPath = (Resolve-Path -LiteralPath $ExpectedPath).Path.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
  foreach ($Line in @($Output)) {
    $NormalizedLine = ([string] $Line).Trim().TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    if ([System.String]::Equals($NormalizedLine, $ResolvedExpectedPath, [System.StringComparison]::OrdinalIgnoreCase)) {
      return
    }
  }

  throw "$Description output did not contain expected path '$ResolvedExpectedPath'. Output: $($Output -join [Environment]::NewLine)"
}

function Assert-AppDepsRuntimeTargetsPreserved {
  param(
    [Parameter(Mandatory)]
    [string] $Directory,

    [Parameter(Mandatory)]
    [string] $AssemblyName,

    [Parameter(Mandatory)]
    [string] $RuntimeAssetGroup,

    [Parameter(Mandatory)]
    [string] $TargetFramework,

    [Parameter(Mandatory)]
    [string] $Description
  )

  $DepsPath = Join-Path $Directory "$AssemblyName.deps.json"
  if (-not (Test-Path $DepsPath -PathType Leaf)) {
    throw "$Description is missing application deps file: $DepsPath"
  }

  $DepsText = Get-Content -LiteralPath $DepsPath -Raw
  foreach ($RelativeRuntimePath in @(
      "runtimes/$RuntimeAssetGroup/lib/$TargetFramework/System.Management.Automation.dll",
      "runtimes/$RuntimeAssetGroup/lib/$TargetFramework/Microsoft.PowerShell.Security.dll",
      "runtimes/$RuntimeAssetGroup/lib/$TargetFramework/Microsoft.PowerShell.Commands.Management.dll")) {
    if ($DepsText -notmatch [regex]::Escape($RelativeRuntimePath)) {
      throw "$Description deps file does not reference expected runtime target '$RelativeRuntimePath': $DepsPath"
    }

    $PhysicalPath = Join-Path $Directory ($RelativeRuntimePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path $PhysicalPath -PathType Leaf)) {
      throw "$Description deps file references '$RelativeRuntimePath', but the copied file is missing: $PhysicalPath"
    }
  }
}

function Assert-SourceBuiltPackagePayloadPreserved {
  param(
    [Parameter(Mandatory)]
    [string] $RestoredSdkPath,

    [Parameter(Mandatory)]
    [string] $Directory,

    [Parameter(Mandatory)]
    [string[]] $SourceBuiltPackageAssetEntries,

    [Parameter(Mandatory)]
    [string] $RuntimeAssetGroup,

    [Parameter(Mandatory)]
    [string] $TargetFramework,

    [Parameter(Mandatory)]
    [string] $Description
  )

  foreach ($RelativePath in Get-SourceBuiltRuntimePackageAsset -SourceBuiltPackageAssetEntries $SourceBuiltPackageAssetEntries -RuntimeAssetGroup $RuntimeAssetGroup -TargetFramework $TargetFramework) {
    $FileName = Split-Path $RelativePath -Leaf
    $ExpectedPath = Join-Path $RestoredSdkPath ($RelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    $ActualPath = Join-Path $Directory $FileName
    Assert-FileContentMatches -ExpectedPath $ExpectedPath -ActualPath $ActualPath -Description "$Description shared $FileName"
  }
}

function Get-RepresentativeLocalizedResourcePath {
  param(
    [Parameter(Mandatory)]
    [string] $RestoredSdkPath,

    [Parameter(Mandatory)]
    [string] $RuntimeAssetGroup,

    [Parameter(Mandatory)]
    [string] $TargetFramework
  )

  $LocalizedResourceRoot = Join-Path $RestoredSdkPath "buildTransitive/localized-resources/$RuntimeAssetGroup/lib/$TargetFramework"
  if (-not (Test-Path $LocalizedResourceRoot -PathType Container)) {
    return $null
  }

  $LocalizedResourceFile = Get-ChildItem -LiteralPath $LocalizedResourceRoot -Recurse -File -Filter '*.resources.dll' |
    Sort-Object FullName |
    Select-Object -First 1
  if (-not $LocalizedResourceFile) {
    return $null
  }

  return $LocalizedResourceFile.FullName.Substring($LocalizedResourceRoot.Length + 1)
}

function Assert-LocalizedResourceAbsent {
  param(
    [Parameter(Mandatory)]
    [string] $Directory,

    [Parameter(Mandatory)]
    [string] $RelativePath,

    [Parameter(Mandatory)]
    [string] $Description
  )

  $Path = Join-Path $Directory $RelativePath
  if (Test-Path $Path -PathType Leaf) {
    throw "$Description unexpectedly contains localized resource: $Path"
  }
}

function Assert-LocalizedResourcePresent {
  param(
    [Parameter(Mandatory)]
    [string] $Directory,

    [Parameter(Mandatory)]
    [string] $RelativePath,

    [Parameter(Mandatory)]
    [string] $Description
  )

  $Path = Join-Path $Directory $RelativePath
  if (-not (Test-Path $Path -PathType Leaf)) {
    throw "$Description is missing expected localized resource: $Path"
  }
}

function Get-LocalizedResourceFileSnapshot {
  param(
    [Parameter(Mandatory)]
    [string] $Directory
  )

  return @(
    Get-ChildItem -LiteralPath $Directory -Recurse -File -Filter '*.resources.dll' |
      Sort-Object FullName |
      ForEach-Object {
        $RelativePath = $_.FullName.Substring($Directory.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
        "$RelativePath|$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)"
      }
  )
}

function Assert-LocalizedResourceFilesUnchanged {
  param(
    [Parameter(Mandatory)]
    [string[]] $ExpectedSnapshot,

    [Parameter(Mandatory)]
    [string[]] $ActualSnapshot,

    [Parameter(Mandatory)]
    [string] $Description
  )

  $Difference = @(Compare-Object -ReferenceObject $ExpectedSnapshot -DifferenceObject $ActualSnapshot)
  if ($Difference.Count -ne 0) {
    throw "$Description changed localized resource files: $($Difference.InputObject -join ', ')"
  }
}

function Get-XmlDocumentationFileNames {
  param(
    [Parameter(Mandatory)]
    [string] $RestoredSdkPath,

    [Parameter(Mandatory)]
    [string] $RuntimeAssetGroup,

    [Parameter(Mandatory)]
    [string] $TargetFramework
  )

  $RuntimeXmlRoot = Join-Path $RestoredSdkPath "runtimes/$RuntimeAssetGroup/lib/$TargetFramework"
  if (-not (Test-Path -LiteralPath $RuntimeXmlRoot -PathType Container)) {
    throw "SDK package is missing expected XML documentation directory $RuntimeXmlRoot"
  }

  $Found = @(
    Get-ChildItem -LiteralPath $RuntimeXmlRoot -Filter '*.xml' -File |
      Where-Object {
        $_.Extension -eq '.xml' -and
        $_.Name -notlike '*-Help.xml'
      } |
      Select-Object -ExpandProperty Name |
      Sort-Object
  )
  if ($Found.Count -eq 0) {
    throw "SDK package is missing expected XML documentation files under $RuntimeXmlRoot"
  }

  return $Found
}

function Get-XmlDocumentationOutputRelativePaths {
  param(
    [Parameter(Mandatory)]
    [string[]] $FileNames,

    [string] $RuntimeAssetGroup,

    [string] $TargetFramework,

    [bool] $IncludeRuntimeLib = $false
  )

  $RelativePaths = @($FileNames)
  if ($IncludeRuntimeLib) {
    foreach ($Name in $FileNames) {
      $RelativePaths += "runtimes/$RuntimeAssetGroup/lib/$TargetFramework/$Name"
    }
  }

  return $RelativePaths
}

function Assert-XmlDocumentationFiles {
  param(
    [Parameter(Mandatory)]
    [string] $Directory,

    [Parameter(Mandatory)]
    [string[]] $RelativePaths,

    [Parameter(Mandatory)]
    [bool] $Present,

    [Parameter(Mandatory)]
    [string] $Description
  )

  foreach ($RelativePath in $RelativePaths) {
    $Path = Join-Path $Directory ($RelativePath -replace '/', [IO.Path]::DirectorySeparatorChar)
    if ($Present) {
      if (-not (Test-Path $Path -PathType Leaf)) {
        throw "$Description is missing expected XML documentation file: $Path"
      }
    }
    elseif (Test-Path $Path -PathType Leaf) {
      throw "$Description unexpectedly contains XML documentation file: $Path"
    }
  }
}

function Assert-XmlDocumentationContentMatches {
  param(
    [Parameter(Mandatory)]
    [string] $RestoredSdkPath,

    [Parameter(Mandatory)]
    [string] $Directory,

    [Parameter(Mandatory)]
    [string] $RuntimeAssetGroup,

    [Parameter(Mandatory)]
    [string] $TargetFramework,

    [Parameter(Mandatory)]
    [string[]] $RelativePaths,

    [Parameter(Mandatory)]
    [string] $Description
  )

  foreach ($RelativePath in $RelativePaths) {
    $FileName = Split-Path $RelativePath -Leaf
    $ExpectedPath = Join-Path $RestoredSdkPath "runtimes/$RuntimeAssetGroup/lib/$TargetFramework/$FileName"
    $ActualPath = Join-Path $Directory ($RelativePath -replace '/', [IO.Path]::DirectorySeparatorChar)
    Assert-FileContentMatches -ExpectedPath $ExpectedPath -ActualPath $ActualPath -Description "$Description ($RelativePath)"
  }
}

function Invoke-RuntimeNativeOverwriteProbe {
  param(
    [Parameter(Mandatory)]
    [string] $ProjectPath,

    [Parameter(Mandatory)]
    [string] $Directory,

    [Parameter(Mandatory)]
    [string] $RestoredSdkPath,

    [Parameter(Mandatory)]
    [string[]] $SourceBuiltPackageAssetEntries,

    [Parameter(Mandatory)]
    [string[]] $RuntimeIdentifiers,

    [Parameter(Mandatory)]
    [string] $CurrentRuntimeIdentifier,

    [Parameter(Mandatory)]
    [string] $TargetName,

    [string] $PublishDirectory,

    [Parameter(Mandatory)]
    [string] $Description
  )

  $RootPayloadPath = Join-Path $Directory 'System.Management.Automation.dll'
  $CollisionPayloadPath = Join-Path $Directory (Split-Path $ProjectPath -LeafBase)
  $CollisionPayloadPath = [System.IO.Path]::ChangeExtension($CollisionPayloadPath, '.dll')
  if (-not (Test-Path $RootPayloadPath -PathType Leaf) -or -not (Test-Path $CollisionPayloadPath -PathType Leaf)) {
    return
  }

  $BackupPath = "$RootPayloadPath.sdkvalidation.bak"
  Copy-Item -LiteralPath $RootPayloadPath -Destination $BackupPath -Force
  try {
    Copy-Item -LiteralPath $CollisionPayloadPath -Destination $RootPayloadPath -Force

    $RuntimeIdentifiersPropertyValue = $RuntimeIdentifiers -join '%3B'
    $Arguments = @(
      'msbuild',
      $ProjectPath,
      '-nologo',
      '-verbosity:minimal',
      "-t:$TargetName",
      "/p:RuntimeIdentifier=$CurrentRuntimeIdentifier",
      "/p:PowerShellSDKAppHostLayout=RuntimeNative",
      "/p:PowerShellSDKRuntimeNativeAppHostRuntimeIdentifiers=$RuntimeIdentifiersPropertyValue"
    )
    if ($PublishDirectory) {
      $PublishDirectoryProperty = $PublishDirectory
      if (-not $PublishDirectoryProperty.EndsWith([System.IO.Path]::DirectorySeparatorChar) -and
          -not $PublishDirectoryProperty.EndsWith([System.IO.Path]::AltDirectorySeparatorChar)) {
        $PublishDirectoryProperty = "$PublishDirectoryProperty$([System.IO.Path]::DirectorySeparatorChar)"
      }
      $Arguments += "/p:PublishDir=$PublishDirectoryProperty"
    }

    Invoke-DotNet $Arguments

    $RuntimeAssetGroup = if ($CurrentRuntimeIdentifier -like 'win-*') { 'win' } else { 'unix' }
    Assert-SourceBuiltPackagePayloadPreserved -RestoredSdkPath $RestoredSdkPath -Directory $Directory -SourceBuiltPackageAssetEntries $SourceBuiltPackageAssetEntries -RuntimeAssetGroup $RuntimeAssetGroup -TargetFramework $TargetFramework -Description $Description
  } finally {
    Copy-Item -LiteralPath $BackupPath -Destination $RootPayloadPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $BackupPath -Force -ErrorAction SilentlyContinue
  }
}

function Invoke-RuntimeNativeNoRuntimeIdentifierInProcessProbe {
  param(
    [Parameter(Mandatory)]
    [string] $ValidationRoot,

    [Parameter(Mandatory)]
    [string] $PackageDirectoryPath,

    [Parameter(Mandatory)]
    [string] $PackageId,

    [Parameter(Mandatory)]
    [string] $PackageVersion,

    [Parameter(Mandatory)]
    [string] $SampleTargetFramework,

    [Parameter(Mandatory)]
    [string] $TargetFramework,

    [Parameter(Mandatory)]
    [string] $RuntimeAssetGroup,

    [Parameter(Mandatory)]
    [string[]] $RuntimeNativeValidationRids,

    [Parameter(Mandatory)]
    [string] $RestoredSdkPath,

    [Parameter(Mandatory)]
    [string[]] $SourceBuiltPackageAssetEntries,

    [Parameter(Mandatory)]
    [string[]] $PSGalleryProbeModuleNames
  )

  $ProbeDirectory = Join-Path $ValidationRoot 'sample-runtime-native-no-rid'
  New-Item $ProbeDirectory -ItemType Directory -Force | Out-Null

  $PreviousLocation = Get-Location
  try {
    Push-Location $ProbeDirectory

    Invoke-DotNet @('new', 'console', '--framework', $TargetFramework, '--no-restore')
    $ProjectPath = (Get-ChildItem -LiteralPath $ProbeDirectory -Filter '*.csproj' | Select-Object -First 1).FullName
    if (-not $ProjectPath) {
      throw "No no-RID RuntimeNative sample project was generated in $ProbeDirectory"
    }

    $EscapedPackageDirectoryPath = [System.Security.SecurityElement]::Escape($PackageDirectoryPath)
    $NuGetConfig = @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="ci-nupkg" value="$EscapedPackageDirectoryPath" />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />
  </packageSources>
  <packageSourceMapping>
    <packageSource key="ci-nupkg">
      <package pattern="$PackageId" />
    </packageSource>
    <packageSource key="nuget.org">
      <package pattern="*" />
    </packageSource>
  </packageSourceMapping>
</configuration>
"@
    Set-Content -Path (Join-Path $ProbeDirectory 'nuget.config') -Value $NuGetConfig -Encoding utf8

    $Program = @'
using System;
using System.Management.Automation;

using PowerShell ps = PowerShell.Create();
ps.AddScript(@"
$ErrorActionPreference = 'Stop'
    Import-Module Microsoft.PowerShell.Security -ErrorAction Stop
    [void] (Get-Command Set-ExecutionPolicy -ErrorAction Stop)
    if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
        Set-ExecutionPolicy Bypass -Scope Process -ErrorAction Stop
    }
    Import-Module Microsoft.PowerShell.Management -ErrorAction Stop
    [void] (Get-Command Get-Process -ErrorAction Stop)
    $process = Get-Process | Select-Object -First 1
    if ($null -eq $process) {
        throw 'Get-Process returned no process'
    }
    $securityModulePath = Join-Path $PSHOME 'Modules/Microsoft.PowerShell.Security/Microsoft.PowerShell.Security.psd1'
    $managementModulePath = Join-Path $PSHOME 'Modules/Microsoft.PowerShell.Management/Microsoft.PowerShell.Management.psd1'
    if (-not (Test-Path -LiteralPath $securityModulePath -PathType Leaf)) {
        throw ('Microsoft.PowerShell.Security module manifest is not under PSHOME: {0}' -f $securityModulePath)
    }
    if (-not (Test-Path -LiteralPath $managementModulePath -PathType Leaf)) {
        throw ('Microsoft.PowerShell.Management module manifest is not under PSHOME: {0}' -f $managementModulePath)
    }
    $PSHOME
    $securityModulePath
    $managementModulePath
    ");

foreach (PSObject result in ps.Invoke())
{
    Console.WriteLine(result);
}

foreach (ErrorRecord error in ps.Streams.Error)
{
    Console.Error.WriteLine(error.ToString());
}

if (ps.HadErrors)
{
    Environment.Exit(2);
}
'@
    Set-Content -Path (Join-Path $ProbeDirectory 'Program.cs') -Value $Program -Encoding utf8

    [xml] $Project = Get-Content -LiteralPath $ProjectPath
    $PropertyGroup = @($Project.Project.PropertyGroup)[0]
    $TargetFrameworkElement = $PropertyGroup.SelectSingleNode('TargetFramework')
    if ($TargetFrameworkElement) {
      $TargetFrameworkElement.InnerText = $SampleTargetFramework
    } else {
      Add-ProjectProperty -Project $Project -PropertyGroup $PropertyGroup -Name 'TargetFramework' -Value $SampleTargetFramework
    }
    Add-ProjectProperty -Project $Project -PropertyGroup $PropertyGroup -Name 'PowerShellSDKAppHostLayout' -Value 'RuntimeNative'
    Add-ProjectProperty -Project $Project -PropertyGroup $PropertyGroup -Name 'PowerShellSDKAppHostImplementation' -Value 'MultiPwsh'
    Add-ProjectProperty -Project $Project -PropertyGroup $PropertyGroup -Name 'PowerShellSDKRuntimeNativeAppHostRuntimeIdentifiers' -Value ($RuntimeNativeValidationRids -join ';')
    Add-ProjectProperty -Project $Project -PropertyGroup $PropertyGroup -Name 'PowerShellSDKPSGalleryModules' -Value 'All'
    $Project.Save($ProjectPath)

    Invoke-DotNet @('add', $ProjectPath, 'package', $PackageId, '--version', $PackageVersion, '--no-restore')
    Invoke-DotNet @('restore', $ProjectPath, '--configfile', (Join-Path $ProbeDirectory 'nuget.config'), '--verbosity', 'minimal')
    Invoke-DotNet @('build', $ProjectPath, '--no-restore', '--nologo', '--verbosity', 'minimal')

    $ProbeOutputDirectory = Join-Path $ProbeDirectory (Join-Path 'bin' (Join-Path 'Debug' $SampleTargetFramework))
    Assert-SharedPowerShellOutput -Directory $ProbeOutputDirectory -SelfContained $false -Description 'No-RID RuntimeNative sample output'
    Assert-PowerShellConfig -Directory $ProbeOutputDirectory -ExpectedExecutionPolicy 'Bypass' -Description 'No-RID RuntimeNative sample output'
    Assert-SharedPowerShellRuntimeLibPreserved -RestoredSdkPath $RestoredSdkPath -Directory $ProbeOutputDirectory -SourceBuiltPackageAssetEntries $SourceBuiltPackageAssetEntries -RuntimeAssetGroup $RuntimeAssetGroup -TargetFramework $TargetFramework -Description 'No-RID RuntimeNative sample output'
    Assert-SourceBuiltPackagePayloadPreserved -RestoredSdkPath $RestoredSdkPath -Directory $ProbeOutputDirectory -SourceBuiltPackageAssetEntries $SourceBuiltPackageAssetEntries -RuntimeAssetGroup $RuntimeAssetGroup -TargetFramework $TargetFramework -Description 'No-RID RuntimeNative sample output'
    Assert-PSGalleryModulesPresent -Directory $ProbeOutputDirectory -ModuleNames $PSGalleryProbeModuleNames -Description 'No-RID RuntimeNative sample output'
    foreach ($RuntimeNativeRid in $RuntimeNativeValidationRids) {
      $RuntimeNativeExecutableName = if ($RuntimeNativeRid -like 'win-*') { 'pwsh.exe' } else { 'pwsh' }
      Assert-NoRootRuntimeNativeAppHostOutput -Directory $ProbeOutputDirectory -ExecutableName $RuntimeNativeExecutableName -Description "No-RID RuntimeNative sample output [$RuntimeNativeRid]"
      [void] (Assert-RuntimeNativeAppHostOutput -Directory $ProbeOutputDirectory -RuntimeIdentifier $RuntimeNativeRid -ExecutableName $RuntimeNativeExecutableName -SelfContained $false -Description "No-RID RuntimeNative sample output [$RuntimeNativeRid]")
    }

    $ProbeOutput = & dotnet run --project $ProjectPath --no-build
    if ($LASTEXITCODE -ne 0) {
      throw "No-RID RuntimeNative sample failed with exit code $LASTEXITCODE"
    }

    $ExpectedPSHome = Join-Path $ProbeOutputDirectory "runtimes/$RuntimeAssetGroup/lib/$TargetFramework"
    Assert-OutputContainsPath -Output $ProbeOutput -ExpectedPath $ExpectedPSHome -Description 'No-RID RuntimeNative sample'
    Assert-OutputContainsPath -Output $ProbeOutput -ExpectedPath (Join-Path $ExpectedPSHome 'Modules/Microsoft.PowerShell.Security/Microsoft.PowerShell.Security.psd1') -Description 'No-RID RuntimeNative sample'
    Assert-OutputContainsPath -Output $ProbeOutput -ExpectedPath (Join-Path $ExpectedPSHome 'Modules/Microsoft.PowerShell.Management/Microsoft.PowerShell.Management.psd1') -Description 'No-RID RuntimeNative sample'
  } finally {
    Set-Location $PreviousLocation
  }
}

function Invoke-AppHostLayoutMatrixProbe {
  param(
    [Parameter(Mandatory)]
    [string] $ValidationRoot,

    [Parameter(Mandatory)]
    [string] $PackageDirectoryPath,

    [Parameter(Mandatory)]
    [string] $PackageId,

    [Parameter(Mandatory)]
    [string] $PackageVersion,

    [Parameter(Mandatory)]
    [string] $SampleTargetFramework,

    [Parameter(Mandatory)]
    [string] $TargetFramework,

    [Parameter(Mandatory)]
    [string] $RuntimeAssetGroup,

    [Parameter(Mandatory)]
    [string] $CurrentRuntimeIdentifier,

    [Parameter(Mandatory)]
    [string[]] $RuntimeNativeValidationRids,

    [Parameter(Mandatory)]
    [string] $ExecutableName,

    [Parameter(Mandatory)]
    [string] $PowerShellVersion,

    [Parameter(Mandatory)]
    [string] $RestoredSdkPath,

    [Parameter(Mandatory)]
    [string[]] $SourceBuiltPackageAssetEntries,

    [Parameter(Mandatory)]
    [string[]] $PSGalleryProbeModuleNames
  )

  $Layouts = @(
    [pscustomobject]@{ Name = 'None'; AppHostLayout = ''; ExpectRootAppHost = $false; ExpectRuntimeNativeAppHost = $false; CopyPSGalleryModules = $false; CopyLocalizedResources = $false; CopyXmlDocumentation = $false },
    [pscustomobject]@{ Name = 'Root'; AppHostLayout = 'Root'; ExpectRootAppHost = $true; ExpectRuntimeNativeAppHost = $false; CopyPSGalleryModules = $false; CopyLocalizedResources = $true; CopyXmlDocumentation = $true },
    [pscustomobject]@{ Name = 'RuntimeNative'; AppHostLayout = 'RuntimeNative'; ExpectRootAppHost = $false; ExpectRuntimeNativeAppHost = $true; CopyPSGalleryModules = $true; CopyLocalizedResources = $false; CopyXmlDocumentation = $false },
    [pscustomobject]@{ Name = 'Both'; AppHostLayout = 'Both'; ExpectRootAppHost = $true; ExpectRuntimeNativeAppHost = $true; CopyPSGalleryModules = $true; CopyLocalizedResources = $false; CopyXmlDocumentation = $false }
  )

  $XmlDocumentationFileNames = Get-XmlDocumentationFileNames -RestoredSdkPath $RestoredSdkPath -RuntimeAssetGroup $RuntimeAssetGroup -TargetFramework $TargetFramework
  $XmlDocumentationRootRelativePaths = Get-XmlDocumentationOutputRelativePaths -FileNames $XmlDocumentationFileNames

  foreach ($Layout in $Layouts) {
    $ProbeDirectory = Join-Path $ValidationRoot "sample-layout-$($Layout.Name.ToLowerInvariant())"
    New-Item $ProbeDirectory -ItemType Directory -Force | Out-Null

    $PreviousLocation = Get-Location
    try {
      Push-Location $ProbeDirectory

      Invoke-DotNet @('new', 'console', '--framework', $TargetFramework, '--no-restore')
      $ProjectPath = (Get-ChildItem -LiteralPath $ProbeDirectory -Filter '*.csproj' | Select-Object -First 1).FullName
      if (-not $ProjectPath) {
        throw "No $($Layout.Name) layout sample project was generated in $ProbeDirectory"
      }

      $EscapedPackageDirectoryPath = [System.Security.SecurityElement]::Escape($PackageDirectoryPath)
      $NuGetConfig = @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="ci-nupkg" value="$EscapedPackageDirectoryPath" />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />
  </packageSources>
  <packageSourceMapping>
    <packageSource key="ci-nupkg">
      <package pattern="$PackageId" />
    </packageSource>
    <packageSource key="nuget.org">
      <package pattern="*" />
    </packageSource>
  </packageSourceMapping>
</configuration>
"@
      Set-Content -Path (Join-Path $ProbeDirectory 'nuget.config') -Value $NuGetConfig -Encoding utf8

      $Program = @'
using System;
using System.Management.Automation;

using PowerShell ps = PowerShell.Create();
ps.AddScript(@"
$ErrorActionPreference = 'Stop'
$env:PSModulePath = ''
[void] (Get-Command Set-ExecutionPolicy -ErrorAction Stop)
if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
    Set-ExecutionPolicy Bypass -Scope Process -ErrorAction Stop
}
[void] (Get-Command Get-Process -ErrorAction Stop)
$process = Get-Process | Select-Object -First 1
if ($null -eq $process) {
    throw 'Get-Process returned no process'
}
$securityModulePath = Join-Path $PSHOME 'Modules/Microsoft.PowerShell.Security/Microsoft.PowerShell.Security.psd1'
$managementModulePath = Join-Path $PSHOME 'Modules/Microsoft.PowerShell.Management/Microsoft.PowerShell.Management.psd1'
if (-not (Test-Path -LiteralPath $securityModulePath -PathType Leaf)) {
    throw ('Microsoft.PowerShell.Security module manifest is not under PSHOME: {0}' -f $securityModulePath)
}
if (-not (Test-Path -LiteralPath $managementModulePath -PathType Leaf)) {
    throw ('Microsoft.PowerShell.Management module manifest is not under PSHOME: {0}' -f $managementModulePath)
}
$PSHOME
$securityModulePath
$managementModulePath
");

foreach (PSObject result in ps.Invoke())
{
    Console.WriteLine(result);
}

foreach (ErrorRecord error in ps.Streams.Error)
{
    Console.Error.WriteLine(error.ToString());
}

if (ps.HadErrors)
{
    Environment.Exit(2);
}
'@
      Set-Content -Path (Join-Path $ProbeDirectory 'Program.cs') -Value $Program -Encoding utf8

      [xml] $Project = Get-Content -LiteralPath $ProjectPath
      $PropertyGroup = @($Project.Project.PropertyGroup)[0]
      $TargetFrameworkElement = $PropertyGroup.SelectSingleNode('TargetFramework')
      if ($TargetFrameworkElement) {
        $TargetFrameworkElement.InnerText = $SampleTargetFramework
      } else {
        Add-ProjectProperty -Project $Project -PropertyGroup $PropertyGroup -Name 'TargetFramework' -Value $SampleTargetFramework
      }
      if ($Layout.AppHostLayout) {
        Add-ProjectProperty -Project $Project -PropertyGroup $PropertyGroup -Name 'PowerShellSDKAppHostLayout' -Value $Layout.AppHostLayout
        Add-ProjectProperty -Project $Project -PropertyGroup $PropertyGroup -Name 'PowerShellSDKAppHostImplementation' -Value 'MultiPwsh'
      }
      if ($Layout.ExpectRuntimeNativeAppHost) {
        Add-ProjectProperty -Project $Project -PropertyGroup $PropertyGroup -Name 'PowerShellSDKRuntimeNativeAppHostRuntimeIdentifiers' -Value ($RuntimeNativeValidationRids -join ';')
      }
      if ($Layout.CopyPSGalleryModules) {
        Add-ProjectProperty -Project $Project -PropertyGroup $PropertyGroup -Name 'PowerShellSDKPSGalleryModules' -Value 'All'
      }
      $Project.Save($ProjectPath)

      Invoke-DotNet @('add', $ProjectPath, 'package', $PackageId, '--version', $PackageVersion, '--no-restore')
      Invoke-DotNet @('restore', $ProjectPath, '--configfile', (Join-Path $ProbeDirectory 'nuget.config'), '--verbosity', 'minimal')
      Invoke-DotNet @('build', $ProjectPath, '--no-restore', '--nologo', '--verbosity', 'minimal')

      $AssemblyName = Split-Path $ProjectPath -LeafBase
      $ProbeOutputDirectory = Join-Path $ProbeDirectory (Join-Path 'bin' (Join-Path 'Debug' $SampleTargetFramework))
      $Description = "$($Layout.Name) layout sample output"
      $ExpectedPSHome = Join-Path $ProbeOutputDirectory "runtimes/$RuntimeAssetGroup/lib/$TargetFramework"

      Assert-SharedPowerShellRuntimeLibPreserved -RestoredSdkPath $RestoredSdkPath -Directory $ProbeOutputDirectory -SourceBuiltPackageAssetEntries $SourceBuiltPackageAssetEntries -RuntimeAssetGroup $RuntimeAssetGroup -TargetFramework $TargetFramework -Description $Description
      Assert-AppDepsRuntimeTargetsPreserved -Directory $ProbeOutputDirectory -AssemblyName $AssemblyName -RuntimeAssetGroup $RuntimeAssetGroup -TargetFramework $TargetFramework -Description $Description
      Assert-XmlDocumentationFiles -Directory $ProbeOutputDirectory -RelativePaths $XmlDocumentationRootRelativePaths -Present $false -Description "$Description before XML documentation opt-in"

      if ($Layout.AppHostLayout) {
        Assert-PowerShellConfig -Directory $ProbeOutputDirectory -ExpectedExecutionPolicy 'Bypass' -Description $Description
      }
      if ($Layout.CopyPSGalleryModules) {
        Assert-PSGalleryModulesPresent -Directory $ProbeOutputDirectory -ModuleNames $PSGalleryProbeModuleNames -Description $Description
      }
      if ($Layout.CopyLocalizedResources) {
        $LocalizedResourceOutputBefore = @(Get-LocalizedResourceFileSnapshot -Directory $ProbeOutputDirectory)
        Invoke-DotNet @(
          'msbuild',
          $ProjectPath,
          '-nologo',
          '-verbosity:minimal',
          '-t:PowerShellSDKCopyAppHostLocalizedResourcesToOutput',
          '/p:PowerShellSDKLocalizedResources=Copy'
        )
        $LocalizedResourceOutputAfter = @(Get-LocalizedResourceFileSnapshot -Directory $ProbeOutputDirectory)
        Assert-LocalizedResourceFilesUnchanged -ExpectedSnapshot $LocalizedResourceOutputBefore -ActualSnapshot $LocalizedResourceOutputAfter -Description "$Description localized resources output opt-in"
      }
      if ($Layout.CopyXmlDocumentation) {
        Invoke-DotNet @(
          'msbuild',
          $ProjectPath,
          '-nologo',
          '-verbosity:minimal',
          '-t:PowerShellSDKCopyAppHostXmlDocumentationToOutput',
          '/p:PowerShellSDKXmlDocumentation=Copy'
        )
        Assert-XmlDocumentationFiles -Directory $ProbeOutputDirectory -RelativePaths $XmlDocumentationRootRelativePaths -Present $true -Description "$Description with XML documentation opt-in"
        Assert-XmlDocumentationContentMatches -RestoredSdkPath $RestoredSdkPath -Directory $ProbeOutputDirectory -RuntimeAssetGroup $RuntimeAssetGroup -TargetFramework $TargetFramework -RelativePaths $XmlDocumentationRootRelativePaths -Description "$Description XML documentation opt-in"
      }
      if ($Layout.ExpectRootAppHost) {
        Assert-AppHostOutput -Directory $ProbeOutputDirectory -ExecutableName $ExecutableName -Description $Description
        if (-not $SkipRuntimeExecution) {
          $RootPwshPath = Join-Path $ProbeOutputDirectory $ExecutableName
          [void] (Invoke-PwshVersionCheck -PwshPath $RootPwshPath -ExpectedVersion $PowerShellVersion)
          Invoke-PwshModuleProbe -PwshPath $RootPwshPath -ModuleRoot (Join-Path $ProbeOutputDirectory 'Modules')
        }
      }
      if ($Layout.ExpectRuntimeNativeAppHost) {
        foreach ($RuntimeNativeRid in $RuntimeNativeValidationRids) {
          $RuntimeNativeExecutableName = if ($RuntimeNativeRid -like 'win-*') { 'pwsh.exe' } else { 'pwsh' }
          $RuntimeNativePwshPath = Assert-RuntimeNativeAppHostOutput -Directory $ProbeOutputDirectory -RuntimeIdentifier $RuntimeNativeRid -ExecutableName $RuntimeNativeExecutableName -SelfContained $false -Description "$Description [$RuntimeNativeRid]"
          if ($RuntimeNativeRid -eq $CurrentRuntimeIdentifier -and -not $SkipRuntimeExecution) {
            [void] (Invoke-PwshVersionCheck -PwshPath $RuntimeNativePwshPath -ExpectedVersion $PowerShellVersion)
            Invoke-PwshModuleProbe -PwshPath $RuntimeNativePwshPath -ModuleRoot (Join-Path $ProbeOutputDirectory 'Modules')
          }
        }
      }

      if ($Layout.CopyLocalizedResources) {
        $LocalizedPublishDirectory = Join-Path $ProbeDirectory (Join-Path 'bin' (Join-Path 'Release' (Join-Path $SampleTargetFramework (Join-Path $CurrentRuntimeIdentifier 'publish-localized'))))
        Remove-Item -LiteralPath $LocalizedPublishDirectory -Recurse -Force -ErrorAction SilentlyContinue
        Invoke-DotNet @(
          'publish',
          $ProjectPath,
          '--nologo',
          '--verbosity',
          'minimal',
          '-c',
          'Release',
          '-r',
          $CurrentRuntimeIdentifier,
          '--self-contained',
          'false',
          '-o',
          $LocalizedPublishDirectory
        )
        $LocalizedResourcePublishBefore = @(Get-LocalizedResourceFileSnapshot -Directory $LocalizedPublishDirectory)
        Invoke-DotNet @(
          'publish',
          $ProjectPath,
          '--nologo',
          '--verbosity',
          'minimal',
          '-c',
          'Release',
          '-r',
          $CurrentRuntimeIdentifier,
          '--self-contained',
          'false',
          '-o',
          $LocalizedPublishDirectory,
          '/p:PowerShellSDKLocalizedResources=Copy'
        )
        $LocalizedResourcePublishAfter = @(Get-LocalizedResourceFileSnapshot -Directory $LocalizedPublishDirectory)
        Assert-AppHostOutput -Directory $LocalizedPublishDirectory -ExecutableName $ExecutableName -Description "$($Layout.Name) layout localized resource publish output"
        Assert-LocalizedResourceFilesUnchanged -ExpectedSnapshot $LocalizedResourcePublishBefore -ActualSnapshot $LocalizedResourcePublishAfter -Description "$($Layout.Name) layout localized resource publish opt-in"
      }

      if ($Layout.CopyXmlDocumentation) {
        $XmlPublishDirectory = Join-Path $ProbeDirectory (Join-Path 'bin' (Join-Path 'Release' (Join-Path $SampleTargetFramework (Join-Path $CurrentRuntimeIdentifier 'publish-xml-documentation'))))
        Remove-Item -LiteralPath $XmlPublishDirectory -Recurse -Force -ErrorAction SilentlyContinue
        Invoke-DotNet @(
          'publish',
          $ProjectPath,
          '--nologo',
          '--verbosity',
          'minimal',
          '-c',
          'Release',
          '-r',
          $CurrentRuntimeIdentifier,
          '--self-contained',
          'false',
          '-o',
          $XmlPublishDirectory
        )
        Assert-XmlDocumentationFiles -Directory $XmlPublishDirectory -RelativePaths $XmlDocumentationRootRelativePaths -Present $false -Description "$($Layout.Name) layout publish output before XML documentation opt-in"
        Invoke-DotNet @(
          'publish',
          $ProjectPath,
          '--nologo',
          '--verbosity',
          'minimal',
          '-c',
          'Release',
          '-r',
          $CurrentRuntimeIdentifier,
          '--self-contained',
          'false',
          '-o',
          $XmlPublishDirectory,
          '/p:PowerShellSDKXmlDocumentation=Copy'
        )
        Assert-AppHostOutput -Directory $XmlPublishDirectory -ExecutableName $ExecutableName -Description "$($Layout.Name) layout XML documentation publish output"
        Assert-XmlDocumentationFiles -Directory $XmlPublishDirectory -RelativePaths $XmlDocumentationRootRelativePaths -Present $true -Description "$($Layout.Name) layout XML documentation publish output"
        Assert-XmlDocumentationContentMatches -RestoredSdkPath $RestoredSdkPath -Directory $XmlPublishDirectory -RuntimeAssetGroup $RuntimeAssetGroup -TargetFramework $TargetFramework -RelativePaths $XmlDocumentationRootRelativePaths -Description "$($Layout.Name) layout XML documentation publish output"
      }

      $ProbeOutput = & dotnet run --project $ProjectPath --no-build
      if ($LASTEXITCODE -ne 0) {
        throw "$($Layout.Name) layout sample failed with exit code $LASTEXITCODE"
      }

      Assert-OutputContainsPath -Output $ProbeOutput -ExpectedPath $ExpectedPSHome -Description "$($Layout.Name) layout sample"
      Assert-OutputContainsPath -Output $ProbeOutput -ExpectedPath (Join-Path $ExpectedPSHome 'Modules/Microsoft.PowerShell.Security/Microsoft.PowerShell.Security.psd1') -Description "$($Layout.Name) layout sample"
      Assert-OutputContainsPath -Output $ProbeOutput -ExpectedPath (Join-Path $ExpectedPSHome 'Modules/Microsoft.PowerShell.Management/Microsoft.PowerShell.Management.psd1') -Description "$($Layout.Name) layout sample"
    } finally {
      Set-Location $PreviousLocation
    }
  }
}

function Assert-RuntimeConfigMode {
  param(
    [Parameter(Mandatory)]
    [string] $RuntimeConfigPath,

    [Parameter(Mandatory)]
    [bool] $SelfContained,

    [Parameter(Mandatory)]
    [string] $Description
  )

  $RuntimeConfig = Get-Content -LiteralPath $RuntimeConfigPath -Raw
  if ($SelfContained) {
    if ($RuntimeConfig -notmatch '"includedFrameworks"\s*:') {
      throw "$Description runtimeconfig is not self-contained; missing includedFrameworks: $RuntimeConfigPath"
    }
    if ($RuntimeConfig -match '"frameworks?"\s*:') {
      throw "$Description runtimeconfig still contains framework-dependent entries: $RuntimeConfigPath"
    }
    return
  }

  if ($RuntimeConfig -match '"includedFrameworks"\s*:') {
    throw "$Description runtimeconfig was unexpectedly rewritten as self-contained: $RuntimeConfigPath"
  }
  if ($RuntimeConfig -notmatch '"frameworks?"\s*:') {
    throw "$Description runtimeconfig does not contain framework-dependent entries: $RuntimeConfigPath"
  }
}

function Test-RuntimeConfigSelfContained {
  param(
    [Parameter(Mandatory)]
    [string] $RuntimeConfigPath
  )

  if (-not (Test-Path $RuntimeConfigPath -PathType Leaf)) {
    throw "Runtimeconfig file does not exist: $RuntimeConfigPath"
  }

  $RuntimeConfig = Get-Content -LiteralPath $RuntimeConfigPath -Raw
  return $RuntimeConfig -match '"includedFrameworks"\s*:'
}

function Invoke-PwshVersionCheck {
  param(
    [Parameter(Mandatory)]
    [string] $PwshPath,

    [Parameter(Mandatory)]
    [string] $ExpectedVersion
  )

  $PwshOutput = & $PwshPath -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
  if ($LASTEXITCODE -ne 0) {
    throw "$PwshPath failed with exit code $LASTEXITCODE"
  }
  $PwshVersion = [string] ($PwshOutput | Select-Object -Last 1)
  if ($PwshVersion.Trim() -ne $ExpectedVersion) {
    throw "$PwshPath reported PowerShell version '$PwshVersion', expected '$ExpectedVersion'"
  }

  return $PwshVersion.Trim()
}

function Invoke-PwshModuleProbe {
  param(
    [Parameter(Mandatory)]
    [string] $PwshPath,

    [Parameter(Mandatory)]
    [string] $ModuleRoot
  )

  $PreviousPSModulePath = $Env:PSModulePath
  $PreviousExpectedModuleRoot = $Env:PowerShellSDKExpectedModuleRoot
  try {
    $Env:PSModulePath = ''
    $Env:PowerShellSDKExpectedModuleRoot = $ModuleRoot
    $ModuleProbe = @'
$ErrorActionPreference = 'Stop'
$expectedModuleRoot = $env:PowerShellSDKExpectedModuleRoot
foreach ($moduleName in 'Microsoft.PowerShell.Management', 'Microsoft.PowerShell.Utility', 'Microsoft.PowerShell.Security') {
  $module = $null
  foreach ($candidate in Get-Module -ListAvailable $moduleName) {
    $module = $candidate
    break
  }
  if ($null -eq $module) {
    throw "Module '$moduleName' is not available"
  }

  if (-not $module.Path.StartsWith($expectedModuleRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Module '$moduleName' was loaded from '$($module.Path)' instead of '$expectedModuleRoot'"
  }
}

$getProcess = Get-Command Get-Process -ErrorAction Stop
if ($getProcess.Source -ne 'Microsoft.PowerShell.Management') {
  throw "Get-Process resolved from '$($getProcess.Source)' instead of Microsoft.PowerShell.Management"
}

$selectObject = Get-Command Select-Object -ErrorAction Stop
if ($selectObject.Source -ne 'Microsoft.PowerShell.Utility') {
  throw "Select-Object resolved from '$($selectObject.Source)' instead of Microsoft.PowerShell.Utility"
}

$setExecutionPolicy = Get-Command Set-ExecutionPolicy -ErrorAction Stop
if ($setExecutionPolicy.Source -ne 'Microsoft.PowerShell.Security') {
  throw "Set-ExecutionPolicy resolved from '$($setExecutionPolicy.Source)' instead of Microsoft.PowerShell.Security"
}
'@
    $PwshModuleProbeOutput = & $PwshPath -NoLogo -NoProfile -NonInteractive -Command $ModuleProbe
    if ($LASTEXITCODE -ne 0) {
      throw "$PwshPath failed module probe with exit code $LASTEXITCODE"
    }
  } finally {
    $Env:PSModulePath = $PreviousPSModulePath
    $Env:PowerShellSDKExpectedModuleRoot = $PreviousExpectedModuleRoot
  }
}

function Invoke-PwshStartJobProbe {
  param(
    [Parameter(Mandatory)]
    [string] $PwshPath
  )

  $StartJobProbe = @'
$ErrorActionPreference = 'Stop'
$job = Start-Job -ScriptBlock { 21 * 2 }
try {
  $completedJob = Wait-Job -Job $job -Timeout 30
  if ($null -eq $completedJob) {
    throw "Start-Job probe did not complete before the timeout"
  }

  $result = Receive-Job -Job $job -ErrorAction Stop
  if ($result -ne 42) {
    throw "Start-Job probe returned '$result' instead of 42"
  }
} finally {
  Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
}
'@
  $StartJobProbeOutput = & $PwshPath -NoLogo -NoProfile -NonInteractive -Command $StartJobProbe
  if ($LASTEXITCODE -ne 0) {
    throw "$PwshPath failed Start-Job probe with exit code $LASTEXITCODE"
  }
}

function Invoke-PwshPSGalleryModuleProbe {
  param(
    [Parameter(Mandatory)]
    [string] $PwshPath,

    [Parameter(Mandatory)]
    [string] $ModuleRoot,

    [Parameter(Mandatory)]
    [string[]] $ModuleNames
  )

  $PreviousPSModulePath = $Env:PSModulePath
  $PreviousExpectedModuleRoot = $Env:PowerShellSDKExpectedModuleRoot
  $PreviousExpectedPSGalleryModules = $Env:PowerShellSDKExpectedPSGalleryModules
  try {
    $Env:PSModulePath = ''
    $Env:PowerShellSDKExpectedModuleRoot = $ModuleRoot
    $Env:PowerShellSDKExpectedPSGalleryModules = $ModuleNames -join ';'
    $ModuleProbe = @'
$ErrorActionPreference = 'Stop'
$expectedModuleRoot = $env:PowerShellSDKExpectedModuleRoot
$moduleNames = $env:PowerShellSDKExpectedPSGalleryModules -split ';'
foreach ($moduleName in $moduleNames) {
  $module = $null
  foreach ($candidate in Get-Module -ListAvailable $moduleName) {
    $module = $candidate
    break
  }
  if ($null -eq $module) {
    throw "PSGallery module '$moduleName' is not available"
  }

  if (-not $module.Path.StartsWith($expectedModuleRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "PSGallery module '$moduleName' was loaded from '$($module.Path)' instead of '$expectedModuleRoot'"
  }

  Import-Module $moduleName -ErrorAction Stop
}

$compressArchive = Get-Command Compress-Archive -ErrorAction Stop
if ($compressArchive.Source -ne 'Microsoft.PowerShell.Archive') {
  throw "Compress-Archive resolved from '$($compressArchive.Source)' instead of Microsoft.PowerShell.Archive"
}

$startThreadJob = Get-Command Start-ThreadJob -ErrorAction Stop
if ($startThreadJob.Source -ne 'Microsoft.PowerShell.ThreadJob') {
  throw "Start-ThreadJob resolved from '$($startThreadJob.Source)' instead of Microsoft.PowerShell.ThreadJob"
}
'@
    $PwshModuleProbeOutput = & $PwshPath -NoLogo -NoProfile -NonInteractive -Command $ModuleProbe
    if ($LASTEXITCODE -ne 0) {
      throw "$PwshPath failed PSGallery module probe with exit code $LASTEXITCODE"
    }
  } finally {
    $Env:PSModulePath = $PreviousPSModulePath
    $Env:PowerShellSDKExpectedModuleRoot = $PreviousExpectedModuleRoot
    $Env:PowerShellSDKExpectedPSGalleryModules = $PreviousExpectedPSGalleryModules
  }
}

function Read-ZipEntryText {
  param(
    [Parameter(Mandatory)]
    [System.IO.Compression.ZipArchiveEntry] $Entry
  )

  $Stream = $Entry.Open()
  $Reader = [System.IO.StreamReader]::new($Stream)
  try {
    return $Reader.ReadToEnd()
  } finally {
    $Reader.Dispose()
    $Stream.Dispose()
  }
}

function Get-NuspecMetadataValue {
  param(
    [Parameter(Mandatory)]
    [xml] $Nuspec,

    [Parameter(Mandatory)]
    [System.Xml.XmlNamespaceManager] $NamespaceManager,

    [Parameter(Mandatory)]
    [string] $Name
  )

  $Element = $Nuspec.SelectSingleNode("/n:package/n:metadata/n:$Name", $NamespaceManager)
  if (-not $Element) {
    throw "SDK package nuspec is missing required metadata element '$Name'"
  }

  return $Element.InnerText
}

function Read-ZipTextFileLines {
  param(
    [Parameter(Mandatory)]
    [System.IO.Compression.ZipArchive] $Zip,

    [Parameter(Mandatory)]
    [string] $EntryName
  )

  $Entry = $Zip.Entries | Where-Object FullName -EQ $EntryName | Select-Object -First 1
  if (-not $Entry) {
    return @()
  }

  return @(
    (Read-ZipEntryText -Entry $Entry) -split '\r?\n' |
      ForEach-Object { $_.Trim() } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  )
}

function Assert-SdkPackageVersion {
  param(
    [Parameter(Mandatory)]
    [string] $PowerShellVersion,

    [Parameter(Mandatory)]
    [string] $PackageVersion
  )

  $PowerShellVersionParts = $PowerShellVersion -split '\.'
  $PackageVersionParts = $PackageVersion -split '\.'
  if ($PowerShellVersionParts.Count -ne 3 -or $PackageVersionParts.Count -ne 4) {
    throw "SDK package version '$PackageVersion' must use '$PowerShellVersion.<revision>'."
  }

  if (($PackageVersionParts[0..2] -join '.') -ne $PowerShellVersion) {
    throw "SDK package version '$PackageVersion' must use PowerShell upstream version '$PowerShellVersion' as its first three elements."
  }

  if ($PackageVersionParts[3] -notmatch '^\d+$') {
    throw "SDK package version '$PackageVersion' must use a numeric fourth-element revision."
  }
}

function Get-NormalizedNuGetPackageVersion {
  param(
    [Parameter(Mandatory)]
    [string] $PackageVersion
  )

  $Version = [version]::Parse($PackageVersion)
  if ($Version.Revision -eq 0) {
    return "$($Version.Major).$($Version.Minor).$($Version.Build)"
  }

  return $PackageVersion
}

if (-not $RuntimeIdentifier) {
  $RuntimeIdentifier = Get-DefaultRuntimeIdentifier
}
if ([string]::IsNullOrWhiteSpace($PackageVersion)) {
  $PackageVersion = "$PowerShellVersion.0"
}
Assert-SdkPackageVersion -PowerShellVersion $PowerShellVersion -PackageVersion $PackageVersion
$NormalizedPackageVersion = Get-NormalizedNuGetPackageVersion -PackageVersion $PackageVersion

$PackageDirectoryPath = (Resolve-Path -LiteralPath $PackageDirectory).Path
$Package = Get-ChildItem -LiteralPath $PackageDirectoryPath -Filter "$PackageId.$NormalizedPackageVersion*.nupkg" |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1
if (-not $Package) {
  throw "Unable to find $PackageId.$PackageVersion nupkg in $PackageDirectoryPath"
}

$FallbackEmbeddedPowerShellPackageIds = @(
  'Microsoft.PowerShell.SDK',
  'System.Management.Automation',
  'Microsoft.PowerShell.Commands.Management',
  'Microsoft.PowerShell.Commands.Utility',
  'Microsoft.PowerShell.ConsoleHost',
  'Microsoft.PowerShell.Security',
  'Microsoft.PowerShell.Commands.Diagnostics',
  'Microsoft.Management.Infrastructure.CimCmdlets',
  'Microsoft.WSMan.Management',
  'Microsoft.PowerShell.CoreCLR.Eventing',
  'Microsoft.WSMan.Runtime'
)
$EmbeddedPowerShellPackageIds = $FallbackEmbeddedPowerShellPackageIds
$SourceBuiltPackageAssetEntries = @()
$EmbeddedPowerShellPackageIdsManifestEntry = 'buildTransitive/embedded-powershell-package-ids.txt'
$SourceBuiltPackageAssetsManifestEntry = 'buildTransitive/source-built-package-assets.txt'

$PSGalleryModulePackageIds = @(
  'PowerShellGet',
  'PackageManagement',
  'Microsoft.PowerShell.PSResourceGet',
  'Microsoft.PowerShell.Archive',
  'PSReadLine',
  'Microsoft.PowerShell.ThreadJob'
)
$PSGalleryProbeModuleNames = @(
  'Microsoft.PowerShell.Archive',
  'Microsoft.PowerShell.ThreadJob'
)
$PSGallerySubsetModuleNames = @(
  'Microsoft.PowerShell.Archive'
)

$ExecutableName = if ($RuntimeIdentifier -like 'win-*') { 'pwsh.exe' } else { 'pwsh' }
$RuntimeAssetGroup = if ($RuntimeIdentifier -like 'win-*') { 'win' } else { 'unix' }
$RuntimeNativeValidationRids = if ($RuntimeAssetGroup -eq 'win') { @('win-x64', 'win-arm64') } else { @($RuntimeIdentifier) }
$SampleTargetFramework = if ($RuntimeAssetGroup -eq 'win') { "$TargetFramework-windows10.0.19041" } else { $TargetFramework }
$PowerShellStandardPackageId = 'PowerShellStandard.Library'
$PowerShellStandardPackageVersion = '5.1.0'
$ExpectedPackageEntries = @(
  "buildTransitive/$PackageId.targets",
  $EmbeddedPowerShellPackageIdsManifestEntry,
  $SourceBuiltPackageAssetsManifestEntry,
  "tools/apphost/$RuntimeIdentifier/$ExecutableName",
  "tools/apphost/$RuntimeIdentifier/pwsh.dll",
  "tools/apphost/$RuntimeIdentifier/pwsh.runtimeconfig.json",
  "ref/$TargetFramework/System.Management.Automation.dll",
  "ref/$TargetFramework/Microsoft.PowerShell.Commands.Management.dll",
  "ref/$TargetFramework/Microsoft.PowerShell.Commands.Utility.dll",
  "ref/$TargetFramework/Microsoft.PowerShell.ConsoleHost.dll",
  "ref/$TargetFramework/Microsoft.PowerShell.Security.dll",
  "runtimes/$RuntimeAssetGroup/lib/$TargetFramework/Microsoft.PowerShell.SDK.dll",
  "runtimes/$RuntimeAssetGroup/lib/$TargetFramework/System.Management.Automation.dll",
  "runtimes/$RuntimeAssetGroup/lib/$TargetFramework/Microsoft.PowerShell.Commands.Management.dll",
  "runtimes/$RuntimeAssetGroup/lib/$TargetFramework/Microsoft.PowerShell.Commands.Utility.dll",
  "runtimes/$RuntimeAssetGroup/lib/$TargetFramework/Microsoft.PowerShell.ConsoleHost.dll",
  "runtimes/$RuntimeAssetGroup/lib/$TargetFramework/Microsoft.PowerShell.Security.dll"
)
foreach ($RuntimeNativeRid in $RuntimeNativeValidationRids) {
  $RuntimeNativeExecutableName = if ($RuntimeNativeRid -like 'win-*') { 'pwsh.exe' } else { 'pwsh' }
  $ExpectedPackageEntries += @(
    "tools/apphost/$RuntimeNativeRid/$RuntimeNativeExecutableName",
    "tools/apphost/$RuntimeNativeRid/pwsh.dll",
    "tools/apphost/$RuntimeNativeRid/pwsh.runtimeconfig.json",
    "buildTransitive/powershell-distro-payload/$RuntimeNativeRid/pwsh.xml",
    "runtimes/$RuntimeNativeRid/native/$RuntimeNativeExecutableName"
  )
}
foreach ($PSGalleryModulePackageId in $PSGalleryModulePackageIds) {
  $ExpectedPackageEntries += "buildTransitive/psgallery-modules/$PSGalleryModulePackageId/$PSGalleryModulePackageId.psd1"
}
if ($RuntimeAssetGroup -eq 'win') {
  $ExpectedPackageEntries += @(
    "ref/$TargetFramework/Microsoft.PowerShell.Commands.Diagnostics.dll",
    "ref/$TargetFramework/Microsoft.Management.Infrastructure.CimCmdlets.dll",
    "ref/$TargetFramework/Microsoft.WSMan.Management.dll",
    "ref/$TargetFramework/Microsoft.PowerShell.CoreCLR.Eventing.dll",
    "ref/$TargetFramework/Microsoft.WSMan.Runtime.dll",
    "runtimes/win/lib/$TargetFramework/Microsoft.PowerShell.Commands.Diagnostics.dll",
    "runtimes/win/lib/$TargetFramework/Microsoft.Management.Infrastructure.CimCmdlets.dll",
    "runtimes/win/lib/$TargetFramework/Microsoft.WSMan.Management.dll",
    "runtimes/win/lib/$TargetFramework/Microsoft.PowerShell.CoreCLR.Eventing.dll",
    "runtimes/win/lib/$TargetFramework/Microsoft.WSMan.Runtime.dll",
    "buildTransitive/windows-desktop-payload/win/lib/$TargetFramework/Microsoft.PowerShell.GraphicalHost.dll"
  )
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$Zip = [System.IO.Compression.ZipFile]::OpenRead($Package.FullName)
try {
  $ManifestEmbeddedPackageIds = @(Read-ZipTextFileLines -Zip $Zip -EntryName $EmbeddedPowerShellPackageIdsManifestEntry)
  if ($ManifestEmbeddedPackageIds.Count -gt 0) {
    $EmbeddedPowerShellPackageIds = $ManifestEmbeddedPackageIds
  }

  $SourceBuiltPackageAssetEntries = @(Read-ZipTextFileLines -Zip $Zip -EntryName $SourceBuiltPackageAssetsManifestEntry)
  if ($SourceBuiltPackageAssetEntries.Count -eq 0) {
    $SourceBuiltPackageAssetEntries = @(
      $ExpectedPackageEntries |
        Where-Object { $_ -match '^(ref/[^/]+|runtimes/[^/]+/lib/[^/]+)/[^/]+\.dll$' }
    )
  }
  $ExpectedPackageEntries += $SourceBuiltPackageAssetEntries

  foreach ($EntryName in $ExpectedPackageEntries) {
    if (-not ($Zip.Entries | Where-Object FullName -EQ $EntryName)) {
      throw "SDK package is missing expected entry: $EntryName"
    }
  }

  if ($PackageVendorName) {
    $NuspecEntry = $Zip.Entries |
      Where-Object { $_.FullName -like '*.nuspec' -and $_.FullName -notlike '*/*' } |
      Select-Object -First 1
    if (-not $NuspecEntry) {
      throw "SDK package is missing a root nuspec"
    }

    [xml] $Nuspec = Read-ZipEntryText -Entry $NuspecEntry
    $NamespaceManager = [System.Xml.XmlNamespaceManager]::new($Nuspec.NameTable)
    $NamespaceManager.AddNamespace('n', $Nuspec.DocumentElement.NamespaceURI)

    $NuspecPackageId = Get-NuspecMetadataValue -Nuspec $Nuspec -NamespaceManager $NamespaceManager -Name 'id'
    if ($NuspecPackageId -ne $PackageId) {
      throw "SDK package nuspec id is '$NuspecPackageId', expected '$PackageId'"
    }

    $NuspecPackageVersion = Get-NuspecMetadataValue -Nuspec $Nuspec -NamespaceManager $NamespaceManager -Name 'version'
    if ($NuspecPackageVersion -ne $NormalizedPackageVersion) {
      throw "SDK package nuspec version is '$NuspecPackageVersion', expected normalized version '$NormalizedPackageVersion'"
    }

    foreach ($ElementName in @('authors', 'owners', 'copyright')) {
      $Value = Get-NuspecMetadataValue -Nuspec $Nuspec -NamespaceManager $NamespaceManager -Name $ElementName
      if ($Value -notlike "*$PackageVendorName*") {
        throw "SDK package nuspec metadata '$ElementName' does not contain '$PackageVendorName': $Value"
      }
      if ($PackageVendorName -ne 'Microsoft' -and $Value -like '*Microsoft*') {
        throw "SDK package nuspec metadata '$ElementName' still contains 'Microsoft': $Value"
      }
    }

    $OriginalDependencies = @(
      $Nuspec.SelectNodes('/n:package/n:metadata/n:dependencies//n:dependency', $NamespaceManager) |
        Where-Object { $EmbeddedPowerShellPackageIds -contains [string] $_.id } |
        ForEach-Object { [string] $_.id }
    )
    if ($OriginalDependencies) {
      throw "SDK package nuspec still references original PowerShell package dependencies: $($OriginalDependencies -join ', ')"
    }
  }
} finally {
  $Zip.Dispose()
}

$TempRoot = if ($Env:RUNNER_TEMP) { $Env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
$ValidationRoot = Join-Path $TempRoot "powershell-sdk-validation-$([Guid]::NewGuid().ToString('N'))"
$SampleDirectory = Join-Path $ValidationRoot 'sample'
$PackagesDirectory = Join-Path $ValidationRoot 'packages'

New-Item $SampleDirectory -ItemType Directory -Force | Out-Null
New-Item $PackagesDirectory -ItemType Directory -Force | Out-Null

$PreviousNuGetPackages = $Env:NUGET_PACKAGES
$Env:NUGET_PACKAGES = $PackagesDirectory
$PreviousLocation = Get-Location

try {
  Push-Location $SampleDirectory

  Invoke-DotNet @('new', 'console', '--framework', $TargetFramework, '--no-restore')
  $ProjectPath = (Get-ChildItem -LiteralPath $SampleDirectory -Filter '*.csproj' | Select-Object -First 1).FullName
  if (-not $ProjectPath) {
    throw "No sample project was generated in $SampleDirectory"
  }

  $EscapedPackageDirectoryPath = [System.Security.SecurityElement]::Escape($PackageDirectoryPath)
  $NuGetConfig = @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="ci-nupkg" value="$EscapedPackageDirectoryPath" />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />
  </packageSources>
  <packageSourceMapping>
    <packageSource key="ci-nupkg">
      <package pattern="$PackageId" />
    </packageSource>
    <packageSource key="nuget.org">
      <package pattern="*" />
    </packageSource>
  </packageSourceMapping>
</configuration>
"@
  Set-Content -Path (Join-Path $SampleDirectory 'nuget.config') -Value $NuGetConfig -Encoding utf8

  $Program = @'
using System;
using System.Management.Automation;

using PowerShell ps = PowerShell.Create();
ps.AddScript("$PSVersionTable.PSVersion.ToString()");
foreach (PSObject result in ps.Invoke())
{
    Console.WriteLine(result);
}
'@
  Set-Content -Path (Join-Path $SampleDirectory 'Program.cs') -Value $Program -Encoding utf8

  [xml] $Project = Get-Content -LiteralPath $ProjectPath
  $PropertyGroup = @($Project.Project.PropertyGroup)[0]
  $TargetFrameworkElement = $PropertyGroup.SelectSingleNode('TargetFramework')
  if ($TargetFrameworkElement) {
    $TargetFrameworkElement.InnerText = $SampleTargetFramework
  } else {
    Add-ProjectProperty -Project $Project -PropertyGroup $PropertyGroup -Name 'TargetFramework' -Value $SampleTargetFramework
  }
  Add-ProjectProperty -Project $Project -PropertyGroup $PropertyGroup -Name 'RuntimeIdentifier' -Value $RuntimeIdentifier
  Add-ProjectProperty -Project $Project -PropertyGroup $PropertyGroup -Name 'PowerShellSDKAppHostLayout' -Value 'RuntimeNative'
  Add-ProjectProperty -Project $Project -PropertyGroup $PropertyGroup -Name 'PowerShellSDKAppHostImplementation' -Value 'MultiPwsh'
  Add-ProjectProperty -Project $Project -PropertyGroup $PropertyGroup -Name 'PowerShellSDKRuntimeNativeAppHostRuntimeIdentifiers' -Value ($RuntimeNativeValidationRids -join ';')
  Add-RuntimeNativePublishDuplicateProbeTarget -Project $Project -PackageId $PackageId -PackageVersion $NormalizedPackageVersion -RuntimeIdentifiers $RuntimeNativeValidationRids
  if ($RuntimeAssetGroup -eq 'win') {
    Add-PowerShellStandardPublishDuplicateProbeTarget -Project $Project -PackageId $PowerShellStandardPackageId -PackageVersion $PowerShellStandardPackageVersion -SdkPackageId $PackageId -SdkPackageVersion $NormalizedPackageVersion -RuntimeAssetGroup $RuntimeAssetGroup -TargetFramework $TargetFramework
  }
  $Project.Save($ProjectPath)

  Invoke-DotNet @('add', $ProjectPath, 'package', $PackageId, '--version', $PackageVersion, '--no-restore')
  Invoke-DotNet @('restore', $ProjectPath, '--configfile', (Join-Path $SampleDirectory 'nuget.config'), '--verbosity', 'minimal')

  $AssetsPath = Join-Path (Split-Path $ProjectPath -Parent) 'obj/project.assets.json'
  $Assets = Get-Content -LiteralPath $AssetsPath -Raw | ConvertFrom-Json
  $RestoredPackageIds = @(
    $Assets.libraries.PSObject.Properties.Name |
      ForEach-Object { ($_ -split '/', 2)[0] }
  )
  $RestoredOriginalPowerShellPackageIds = @(
    $RestoredPackageIds |
      Where-Object { $EmbeddedPowerShellPackageIds -contains $_ }
  )
  if ($RestoredOriginalPowerShellPackageIds) {
    throw "Restore imported original PowerShell package IDs instead of vendored IDs: $($RestoredOriginalPowerShellPackageIds -join ', ')"
  }

  $RestoredSdkPackageDirectoryName = $PackageId.ToLowerInvariant()
  $RestoredSdkPath = Join-Path $PackagesDirectory (Join-Path $RestoredSdkPackageDirectoryName $NormalizedPackageVersion)
  foreach ($RelativePath in $ExpectedPackageEntries) {
    $RestoredPath = Join-Path $RestoredSdkPath ($RelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path $RestoredPath -PathType Leaf)) {
      throw "Restored SDK package is missing expected file: $RestoredPath"
    }
  }
  $FrameworkDependentAppHostSelfContained = Test-RuntimeConfigSelfContained -RuntimeConfigPath (Join-Path $RestoredSdkPath "tools/apphost/$RuntimeIdentifier/pwsh.runtimeconfig.json")
  $RepresentativeLocalizedResourcePath = Get-RepresentativeLocalizedResourcePath -RestoredSdkPath $RestoredSdkPath -RuntimeAssetGroup $RuntimeAssetGroup -TargetFramework $TargetFramework
  $RepresentativeLocalizedResourcePackagePath = $null
  if ($RepresentativeLocalizedResourcePath) {
    $RepresentativeLocalizedResourcePackagePath = Join-Path $RestoredSdkPath "buildTransitive/localized-resources/$RuntimeAssetGroup/lib/$TargetFramework/$RepresentativeLocalizedResourcePath"
  } else {
    Write-Host "SDK package does not include localized resources for '$RuntimeAssetGroup/$TargetFramework'; validating PowerShellSDKLocalizedResources=Copy as a no-op."
  }
  $XmlDocumentationFileNames = Get-XmlDocumentationFileNames -RestoredSdkPath $RestoredSdkPath -RuntimeAssetGroup $RuntimeAssetGroup -TargetFramework $TargetFramework
  $XmlDocumentationOutputRelativePaths = Get-XmlDocumentationOutputRelativePaths -FileNames $XmlDocumentationFileNames -RuntimeAssetGroup $RuntimeAssetGroup -TargetFramework $TargetFramework -IncludeRuntimeLib $true

  Invoke-DotNet @('build', $ProjectPath, '--no-restore', '--nologo', '--verbosity', 'minimal')

  $OutputDirectory = Join-Path $SampleDirectory (Join-Path 'bin' (Join-Path 'Debug' (Join-Path $SampleTargetFramework $RuntimeIdentifier)))
  Assert-SharedPowerShellOutput -Directory $OutputDirectory -SelfContained $FrameworkDependentAppHostSelfContained -Description 'Sample app output'
  Assert-XmlDocumentationFiles -Directory $OutputDirectory -RelativePaths $XmlDocumentationOutputRelativePaths -Present $false -Description 'Sample app output before XML documentation opt-in'
  Assert-PowerShellConfig -Directory $OutputDirectory -ExpectedExecutionPolicy 'Bypass' -Description 'Sample app output'
  Assert-NoRootRuntimeNativeAppHostOutput -Directory $OutputDirectory -ExecutableName $ExecutableName -Description 'Sample app output'
  Assert-SharedPowerShellRuntimeLibPreserved -RestoredSdkPath $RestoredSdkPath -Directory $OutputDirectory -SourceBuiltPackageAssetEntries $SourceBuiltPackageAssetEntries -RuntimeAssetGroup $RuntimeAssetGroup -TargetFramework $TargetFramework -Description 'Sample app output'
  Assert-PSGalleryModulesAbsent -Directory $OutputDirectory -ModuleNames $PSGalleryModulePackageIds -Description 'Sample app output'
  Assert-SourceBuiltPackagePayloadPreserved -RestoredSdkPath $RestoredSdkPath -Directory $OutputDirectory -SourceBuiltPackageAssetEntries $SourceBuiltPackageAssetEntries -RuntimeAssetGroup $RuntimeAssetGroup -TargetFramework $TargetFramework -Description 'Sample app output'
  foreach ($RuntimeNativeRid in $RuntimeNativeValidationRids) {
    $RuntimeNativeExecutableName = if ($RuntimeNativeRid -like 'win-*') { 'pwsh.exe' } else { 'pwsh' }
    $RuntimeNativePwshPath = Assert-RuntimeNativeAppHostOutput -Directory $OutputDirectory -RuntimeIdentifier $RuntimeNativeRid -ExecutableName $RuntimeNativeExecutableName -SelfContained $false -Description "Sample app output [$RuntimeNativeRid]"
    if ($RuntimeNativeRid -eq $RuntimeIdentifier -and -not $SkipRuntimeExecution) {
      [void] (Invoke-PwshVersionCheck -PwshPath $RuntimeNativePwshPath -ExpectedVersion $PowerShellVersion)
      Invoke-PwshModuleProbe -PwshPath $RuntimeNativePwshPath -ModuleRoot (Join-Path $OutputDirectory 'Modules')
      Invoke-PwshStartJobProbe -PwshPath $RuntimeNativePwshPath
    }
  }
  Invoke-RuntimeNativeOverwriteProbe -ProjectPath $ProjectPath -Directory $OutputDirectory -RestoredSdkPath $RestoredSdkPath -SourceBuiltPackageAssetEntries $SourceBuiltPackageAssetEntries -RuntimeIdentifiers $RuntimeNativeValidationRids -CurrentRuntimeIdentifier $RuntimeIdentifier -TargetName 'PowerShellSDKCopyRuntimeNativeAppHostsToOutput' -Description 'Sample app output overwrite probe'

  Set-PowerShellConfig -Directory $OutputDirectory -ExecutionPolicy 'RemoteSigned'
  Invoke-DotNet @(
    'msbuild',
    $ProjectPath,
    '-nologo',
    '-verbosity:minimal',
    '-t:PowerShellSDKCopyConfigToOutput',
    '/p:PowerShellSDKConfigExecutionPolicy=Bypass'
  )
  Assert-PowerShellConfig -Directory $OutputDirectory -ExpectedExecutionPolicy 'RemoteSigned' -Description 'Sample app output consumer config preservation probe'
  Invoke-DotNet @(
    'msbuild',
    $ProjectPath,
    '-nologo',
    '-verbosity:minimal',
    '-t:PowerShellSDKCopyConfigToOutput',
    '/p:PowerShellSDKConfigExecutionPolicy=Unrestricted',
    '/p:PowerShellSDKConfigOverwriteExisting=true'
  )
  Assert-PowerShellConfig -Directory $OutputDirectory -ExpectedExecutionPolicy 'Unrestricted' -Description 'Sample app output config overwrite probe'
  Invoke-DotNet @(
    'msbuild',
    $ProjectPath,
    '-nologo',
    '-verbosity:minimal',
    '-t:PowerShellSDKCopyConfigToOutput',
    '/p:PowerShellSDKConfigExecutionPolicy=Bypass',
    '/p:PowerShellSDKConfigOverwriteExisting=true'
  )
  Assert-PowerShellConfig -Directory $OutputDirectory -ExpectedExecutionPolicy 'Bypass' -Description 'Sample app output restored config'

  if ($RepresentativeLocalizedResourcePath) {
    $OutputLocalizedResourcePath = Join-Path $OutputDirectory $RepresentativeLocalizedResourcePath
    Remove-Item -LiteralPath $OutputLocalizedResourcePath -Force -ErrorAction SilentlyContinue
    Assert-LocalizedResourceAbsent -Directory $OutputDirectory -RelativePath $RepresentativeLocalizedResourcePath -Description 'Sample app output before localized resources opt-in'
  }
  Invoke-DotNet @(
    'msbuild',
    $ProjectPath,
    '-nologo',
    '-verbosity:minimal',
    '-t:PowerShellSDKCopyRuntimeNativeLocalizedResourcesToOutput',
    '/p:PowerShellSDKLocalizedResources=Copy'
  )
  if ($RepresentativeLocalizedResourcePath) {
    Assert-LocalizedResourcePresent -Directory $OutputDirectory -RelativePath $RepresentativeLocalizedResourcePath -Description 'Sample app output with localized resources opt-in'
    Assert-FileContentMatches -ExpectedPath $RepresentativeLocalizedResourcePackagePath -ActualPath $OutputLocalizedResourcePath -Description 'Sample app output localized resource opt-in'
  }

  Invoke-DotNet @(
    'msbuild',
    $ProjectPath,
    '-nologo',
    '-verbosity:minimal',
    '-t:PowerShellSDKCopyRuntimeNativeXmlDocumentationToOutput',
    '/p:PowerShellSDKXmlDocumentation=Copy'
  )
  Assert-XmlDocumentationFiles -Directory $OutputDirectory -RelativePaths $XmlDocumentationOutputRelativePaths -Present $true -Description 'Sample app output with XML documentation opt-in'
  Assert-XmlDocumentationContentMatches -RestoredSdkPath $RestoredSdkPath -Directory $OutputDirectory -RuntimeAssetGroup $RuntimeAssetGroup -TargetFramework $TargetFramework -RelativePaths $XmlDocumentationOutputRelativePaths -Description 'Sample app output XML documentation opt-in'

  if (-not $SkipRuntimeExecution) {
    $AppOutput = & dotnet run --project $ProjectPath --no-build
    if ($LASTEXITCODE -ne 0) {
      throw "Sample app failed with exit code $LASTEXITCODE"
    }
    $AppVersion = [string] ($AppOutput | Select-Object -Last 1)
    if ($AppVersion.Trim() -ne $PowerShellVersion) {
      throw "Sample app imported PowerShell SDK version '$AppVersion', expected '$PowerShellVersion'"
    }
  }

  Invoke-AppHostLayoutMatrixProbe -ValidationRoot $ValidationRoot -PackageDirectoryPath $PackageDirectoryPath -PackageId $PackageId -PackageVersion $PackageVersion -SampleTargetFramework $SampleTargetFramework -TargetFramework $TargetFramework -RuntimeAssetGroup $RuntimeAssetGroup -CurrentRuntimeIdentifier $RuntimeIdentifier -RuntimeNativeValidationRids $RuntimeNativeValidationRids -ExecutableName $ExecutableName -PowerShellVersion $PowerShellVersion -RestoredSdkPath $RestoredSdkPath -SourceBuiltPackageAssetEntries $SourceBuiltPackageAssetEntries -PSGalleryProbeModuleNames $PSGalleryProbeModuleNames

  Invoke-DotNet @('publish', $ProjectPath, '--nologo', '--verbosity', 'minimal', '-c', 'Release', '-r', $RuntimeIdentifier, '--self-contained', 'true')

  $PublishDirectory = Join-Path $SampleDirectory (Join-Path 'bin' (Join-Path 'Release' (Join-Path $SampleTargetFramework (Join-Path $RuntimeIdentifier 'publish'))))
  Assert-SharedPowerShellOutput -Directory $PublishDirectory -SelfContained $true -Description 'Sample self-contained publish output'
  Assert-XmlDocumentationFiles -Directory $PublishDirectory -RelativePaths $XmlDocumentationOutputRelativePaths -Present $false -Description 'Sample self-contained publish output before XML documentation opt-in'
  Assert-PowerShellConfig -Directory $PublishDirectory -ExpectedExecutionPolicy 'Bypass' -Description 'Sample self-contained publish output'
  Assert-NoRootRuntimeNativeAppHostOutput -Directory $PublishDirectory -ExecutableName $ExecutableName -Description 'Sample self-contained publish output'
  Assert-SharedPowerShellRuntimeLibPreserved -RestoredSdkPath $RestoredSdkPath -Directory $PublishDirectory -SourceBuiltPackageAssetEntries $SourceBuiltPackageAssetEntries -RuntimeAssetGroup $RuntimeAssetGroup -TargetFramework $TargetFramework -Description 'Sample self-contained publish output'
  Assert-PSGalleryModulesAbsent -Directory $PublishDirectory -ModuleNames $PSGalleryModulePackageIds -Description 'Sample self-contained publish output'
  Assert-SourceBuiltPackagePayloadPreserved -RestoredSdkPath $RestoredSdkPath -Directory $PublishDirectory -SourceBuiltPackageAssetEntries $SourceBuiltPackageAssetEntries -RuntimeAssetGroup $RuntimeAssetGroup -TargetFramework $TargetFramework -Description 'Sample self-contained publish output'
  foreach ($RuntimeNativeRid in $RuntimeNativeValidationRids) {
    $RuntimeNativeExecutableName = if ($RuntimeNativeRid -like 'win-*') { 'pwsh.exe' } else { 'pwsh' }
    $RuntimeNativePwshPath = Assert-RuntimeNativeAppHostOutput -Directory $PublishDirectory -RuntimeIdentifier $RuntimeNativeRid -ExecutableName $RuntimeNativeExecutableName -SelfContained $true -Description "Sample self-contained publish output [$RuntimeNativeRid]"
    if ($RuntimeNativeRid -eq $RuntimeIdentifier -and -not $SkipRuntimeExecution) {
      $PwshVersion = Invoke-PwshVersionCheck -PwshPath $RuntimeNativePwshPath -ExpectedVersion $PowerShellVersion
      Invoke-PwshModuleProbe -PwshPath $RuntimeNativePwshPath -ModuleRoot (Join-Path $PublishDirectory 'Modules')
      Invoke-PwshStartJobProbe -PwshPath $RuntimeNativePwshPath
    }
  }

  $FrameworkDependentPublishDirectory = Join-Path $SampleDirectory (Join-Path 'bin' (Join-Path 'Release' (Join-Path $SampleTargetFramework (Join-Path $RuntimeIdentifier 'publish-framework-dependent'))))
  Remove-Item $FrameworkDependentPublishDirectory -Recurse -Force -ErrorAction SilentlyContinue
  Invoke-DotNet @('publish', $ProjectPath, '--nologo', '--verbosity', 'minimal', '-c', 'Release', '-r', $RuntimeIdentifier, '--self-contained', 'false', '-o', $FrameworkDependentPublishDirectory)
  Assert-SharedPowerShellOutput -Directory $FrameworkDependentPublishDirectory -SelfContained $FrameworkDependentAppHostSelfContained -Description 'Sample framework-dependent publish output'
  Assert-XmlDocumentationFiles -Directory $FrameworkDependentPublishDirectory -RelativePaths $XmlDocumentationOutputRelativePaths -Present $false -Description 'Sample framework-dependent publish output before XML documentation opt-in'
  Assert-PowerShellConfig -Directory $FrameworkDependentPublishDirectory -ExpectedExecutionPolicy 'Bypass' -Description 'Sample framework-dependent publish output'
  Assert-NoRootRuntimeNativeAppHostOutput -Directory $FrameworkDependentPublishDirectory -ExecutableName $ExecutableName -Description 'Sample framework-dependent publish output'
  Assert-SharedPowerShellRuntimeLibPreserved -RestoredSdkPath $RestoredSdkPath -Directory $FrameworkDependentPublishDirectory -SourceBuiltPackageAssetEntries $SourceBuiltPackageAssetEntries -RuntimeAssetGroup $RuntimeAssetGroup -TargetFramework $TargetFramework -Description 'Sample framework-dependent publish output'
  Assert-PSGalleryModulesAbsent -Directory $FrameworkDependentPublishDirectory -ModuleNames $PSGalleryModulePackageIds -Description 'Sample framework-dependent publish output'
  Assert-SourceBuiltPackagePayloadPreserved -RestoredSdkPath $RestoredSdkPath -Directory $FrameworkDependentPublishDirectory -SourceBuiltPackageAssetEntries $SourceBuiltPackageAssetEntries -RuntimeAssetGroup $RuntimeAssetGroup -TargetFramework $TargetFramework -Description 'Sample framework-dependent publish output'
  foreach ($RuntimeNativeRid in $RuntimeNativeValidationRids) {
    $RuntimeNativeExecutableName = if ($RuntimeNativeRid -like 'win-*') { 'pwsh.exe' } else { 'pwsh' }
    $RuntimeNativePwshPath = Assert-RuntimeNativeAppHostOutput -Directory $FrameworkDependentPublishDirectory -RuntimeIdentifier $RuntimeNativeRid -ExecutableName $RuntimeNativeExecutableName -SelfContained $false -Description "Sample framework-dependent publish output [$RuntimeNativeRid]"
    if ($RuntimeNativeRid -eq $RuntimeIdentifier -and -not $SkipRuntimeExecution) {
      [void] (Invoke-PwshVersionCheck -PwshPath $RuntimeNativePwshPath -ExpectedVersion $PowerShellVersion)
      Invoke-PwshStartJobProbe -PwshPath $RuntimeNativePwshPath
    }
  }

  $PSGallerySubsetModuleNamesPropertyValue = $PSGallerySubsetModuleNames -join '%3B'
  $UnexpectedPSGallerySubsetModuleNames = @($PSGalleryModulePackageIds | Where-Object { $PSGallerySubsetModuleNames -notcontains $_ })
  Invoke-DotNet @(
    'msbuild',
    $ProjectPath,
    '-nologo',
    '-verbosity:minimal',
    '-t:PowerShellSDKCopyPSGalleryModulesToOutput',
    "/p:PowerShellSDKPSGalleryModules=$PSGallerySubsetModuleNamesPropertyValue"
  )
  Assert-PSGalleryModulesPresent -Directory $OutputDirectory -ModuleNames $PSGallerySubsetModuleNames -Description 'Sample app output with PSGallery subset opt-in'
  Assert-PSGalleryModulesAbsent -Directory $OutputDirectory -ModuleNames $UnexpectedPSGallerySubsetModuleNames -Description 'Sample app output with PSGallery subset opt-in'

  Invoke-DotNet @(
    'msbuild',
    $ProjectPath,
    '-nologo',
    '-verbosity:minimal',
    '-t:PowerShellSDKCopyPSGalleryModulesToOutput',
    "/p:PowerShellSDKPSGalleryModules=All"
  )
  Assert-PSGalleryModulesPresent -Directory $OutputDirectory -ModuleNames $PSGalleryProbeModuleNames -Description 'Sample app output with PSGallery opt-in'
  if (-not $SkipRuntimeExecution) {
    $OutputRuntimeNativePwshPath = Join-Path $OutputDirectory "runtimes/$RuntimeIdentifier/native/$ExecutableName"
    Invoke-PwshPSGalleryModuleProbe -PwshPath $OutputRuntimeNativePwshPath -ModuleRoot (Join-Path $OutputDirectory 'Modules') -ModuleNames $PSGalleryProbeModuleNames
  }

  $PSGalleryPublishDirectory = Join-Path $SampleDirectory (Join-Path 'bin' (Join-Path 'Release' (Join-Path $SampleTargetFramework (Join-Path $RuntimeIdentifier 'publish-psgallery'))))
  Remove-Item $PSGalleryPublishDirectory -Recurse -Force -ErrorAction SilentlyContinue
  Invoke-DotNet @(
    'publish',
    $ProjectPath,
    '--nologo',
    '--verbosity',
    'minimal',
    '-c',
    'Release',
    '-r',
    $RuntimeIdentifier,
    '--self-contained',
    'false',
    '-o',
    $PSGalleryPublishDirectory,
    "/p:PowerShellSDKPSGalleryModules=$PSGallerySubsetModuleNamesPropertyValue"
  )
  Assert-SharedPowerShellOutput -Directory $PSGalleryPublishDirectory -SelfContained $FrameworkDependentAppHostSelfContained -Description 'Sample PSGallery publish output'
  Assert-PowerShellConfig -Directory $PSGalleryPublishDirectory -ExpectedExecutionPolicy 'Bypass' -Description 'Sample PSGallery publish output'
  Assert-NoRootRuntimeNativeAppHostOutput -Directory $PSGalleryPublishDirectory -ExecutableName $ExecutableName -Description 'Sample PSGallery publish output'
  Assert-SharedPowerShellRuntimeLibPreserved -RestoredSdkPath $RestoredSdkPath -Directory $PSGalleryPublishDirectory -SourceBuiltPackageAssetEntries $SourceBuiltPackageAssetEntries -RuntimeAssetGroup $RuntimeAssetGroup -TargetFramework $TargetFramework -Description 'Sample PSGallery publish output'
  Assert-PSGalleryModulesPresent -Directory $PSGalleryPublishDirectory -ModuleNames $PSGallerySubsetModuleNames -Description 'Sample PSGallery publish output'
  Assert-PSGalleryModulesAbsent -Directory $PSGalleryPublishDirectory -ModuleNames $UnexpectedPSGallerySubsetModuleNames -Description 'Sample PSGallery publish output'
  $PSGalleryPublishRuntimeNativePwshPath = Assert-RuntimeNativeAppHostOutput -Directory $PSGalleryPublishDirectory -RuntimeIdentifier $RuntimeIdentifier -ExecutableName $ExecutableName -SelfContained $false -Description "Sample PSGallery publish output [$RuntimeIdentifier]"
  if (-not $SkipRuntimeExecution) {
    [void] (Invoke-PwshVersionCheck -PwshPath $PSGalleryPublishRuntimeNativePwshPath -ExpectedVersion $PowerShellVersion)
  }

  $LocalizedPublishDirectory = Join-Path $SampleDirectory (Join-Path 'bin' (Join-Path 'Release' (Join-Path $SampleTargetFramework (Join-Path $RuntimeIdentifier 'publish-localized'))))
  Remove-Item $LocalizedPublishDirectory -Recurse -Force -ErrorAction SilentlyContinue
  Invoke-DotNet @(
    'publish',
    $ProjectPath,
    '--nologo',
    '--verbosity',
    'minimal',
    '-c',
    'Release',
    '-r',
    $RuntimeIdentifier,
    '--self-contained',
    'false',
    '-o',
    $LocalizedPublishDirectory,
    '/p:PowerShellSDKLocalizedResources=Copy'
  )
  Assert-SharedPowerShellOutput -Directory $LocalizedPublishDirectory -SelfContained $FrameworkDependentAppHostSelfContained -Description 'Sample localized resource publish output'
  if ($RepresentativeLocalizedResourcePath) {
    Assert-LocalizedResourcePresent -Directory $LocalizedPublishDirectory -RelativePath $RepresentativeLocalizedResourcePath -Description 'Sample localized resource publish output'
    Assert-FileContentMatches -ExpectedPath $RepresentativeLocalizedResourcePackagePath -ActualPath (Join-Path $LocalizedPublishDirectory $RepresentativeLocalizedResourcePath) -Description 'Sample localized resource publish output'
  }

  $XmlPublishDirectory = Join-Path $SampleDirectory (Join-Path 'bin' (Join-Path 'Release' (Join-Path $SampleTargetFramework (Join-Path $RuntimeIdentifier 'publish-xml-documentation'))))
  Remove-Item $XmlPublishDirectory -Recurse -Force -ErrorAction SilentlyContinue
  Invoke-DotNet @(
    'publish',
    $ProjectPath,
    '--nologo',
    '--verbosity',
    'minimal',
    '-c',
    'Release',
    '-r',
    $RuntimeIdentifier,
    '--self-contained',
    'false',
    '-o',
    $XmlPublishDirectory,
    '/p:PowerShellSDKXmlDocumentation=Copy'
  )
  Assert-SharedPowerShellOutput -Directory $XmlPublishDirectory -SelfContained $FrameworkDependentAppHostSelfContained -Description 'Sample XML documentation publish output'
  Assert-XmlDocumentationFiles -Directory $XmlPublishDirectory -RelativePaths $XmlDocumentationOutputRelativePaths -Present $true -Description 'Sample XML documentation publish output'
  Assert-XmlDocumentationContentMatches -RestoredSdkPath $RestoredSdkPath -Directory $XmlPublishDirectory -RuntimeAssetGroup $RuntimeAssetGroup -TargetFramework $TargetFramework -RelativePaths $XmlDocumentationOutputRelativePaths -Description 'Sample XML documentation publish output'

  Write-Host "Validated $PackageId $PackageVersion from $($Package.FullName)"
  if ($SkipRuntimeExecution) {
    Write-Host "Skipped runtime execution probes for $RuntimeIdentifier."
  } else {
    Write-Host "Sample app imported vendored PowerShell SDK $($AppVersion.Trim())"
    Write-Host "Sample self-contained publish runtime-native apphost reported PowerShell $PwshVersion"
    Write-Host "Sample framework-dependent publish runtime-native apphost reported PowerShell $PowerShellVersion"
  }
} finally {
  Set-Location $PreviousLocation
  $Env:NUGET_PACKAGES = $PreviousNuGetPackages
}
