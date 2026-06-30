[CmdletBinding()]
param(
  [string] $PowerShellVersion = '7.6.3',

  [string] $PowerShellReleaseTag = 'v7.6.3',

  [string] $PackageId = 'Devolutions.PowerShell.SDK',

  [string] $SdkPackageVersion,

  [string] $VendorName = 'Devolutions',

  [string] $MultiPwshPackageId = 'Devolutions.MultiPwsh.Cli',

  [string] $MultiPwshPackageVersion = '0.14.0',

  [string] $MultiPwshPackageSource = 'https://api.nuget.org/v3/index.json',

  [string] $RuntimeIdentifier,

  [string] $OutputRoot = 'output\local-sdk',

  [string] $NuGetExe,

  [switch] $Validate
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Invoke-Native {
  param(
    [Parameter(Mandatory)]
    [string] $FilePath,

    [string[]] $Arguments
  )

  & $FilePath @Arguments | ForEach-Object { Write-Host $_ }
  if ($LASTEXITCODE -ne 0) {
    throw "$FilePath $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
  }
}

function Invoke-GitOutput {
  param(
    [Parameter(Mandatory, ValueFromRemainingArguments)]
    [string[]] $Arguments
  )

  $Output = & git @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
  }

  return $Output
}

function Get-DefaultRuntimeIdentifier {
  $Architecture = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
    'X64' { 'x64'; break }
    'Arm64' { 'arm64'; break }
    default { throw "Unsupported architecture for local SDK build: $_" }
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

  throw 'Unsupported operating system for local SDK build.'
}

function Get-PSBuildRuntime {
  param(
    [Parameter(Mandatory)]
    [string] $Rid
  )

  switch ($Rid) {
    'win-x64' { return 'fxdependent-win-desktop' }
    'linux-x64' { return 'fxdependent-linux-x64' }
    'linux-arm64' { return 'fxdependent-linux-arm64' }
    'osx-x64' { return 'fxdependent' }
    'osx-arm64' { return 'fxdependent' }
    default { throw "Unsupported local SDK runtime identifier: $Rid" }
  }
}

function Get-AppHostExecutableName {
  param(
    [Parameter(Mandatory)]
    [string] $Rid
  )

  if ($Rid -like 'win-*') {
    return 'pwsh.exe'
  }

  return 'pwsh'
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

function Get-DotNetSdkBasePath {
  $DotNetInfo = & dotnet --info
  if ($LASTEXITCODE -ne 0) {
    throw "dotnet --info failed with exit code $LASTEXITCODE"
  }

  $BasePathLine = $DotNetInfo | Where-Object { $_ -match '^\s*Base Path:\s*(.+)$' } | Select-Object -First 1
  if (-not $BasePathLine -or $BasePathLine -notmatch '^\s*Base Path:\s*(.+)$') {
    throw 'Unable to determine .NET SDK base path from dotnet --info.'
  }

  return $Matches[1].Trim()
}

function Get-DotNetAppHostTemplate {
  param(
    [Parameter(Mandatory)]
    [string] $Rid
  )

  $SdkBasePath = Get-DotNetSdkBasePath
  $DotNetRoot = Split-Path (Split-Path $SdkBasePath -Parent) -Parent
  $HostPackRoot = Join-Path $DotNetRoot "packs\Microsoft.NETCore.App.Host.$Rid"
  if (-not (Test-Path $HostPackRoot -PathType Container)) {
    throw "The .NET SDK host pack for '$Rid' was not found at $HostPackRoot"
  }

  $TemplateName = if ($Rid -like 'win-*') { 'apphost.exe' } else { 'apphost' }
  $Template = Get-ChildItem -LiteralPath $HostPackRoot -Recurse -Filter $TemplateName |
    Sort-Object FullName |
    Select-Object -Last 1
  if (-not $Template) {
    throw "The .NET SDK host pack for '$Rid' does not contain $TemplateName"
  }

  return $Template.FullName
}

function New-SharedPayloadAppHost {
  param(
    [Parameter(Mandatory)]
    [string] $Rid,

    [Parameter(Mandatory)]
    [string] $DestinationPath,

    [Parameter(Mandatory)]
    [string] $ResourceAssemblyPath
  )

  $SdkBasePath = Get-DotNetSdkBasePath
  $HostModelPath = Join-Path $SdkBasePath 'Microsoft.NET.HostModel.dll'
  if (-not (Test-Path $HostModelPath -PathType Leaf)) {
    throw "Microsoft.NET.HostModel.dll was not found in the .NET SDK: $HostModelPath"
  }

  if (-not ([System.Management.Automation.PSTypeName]'Microsoft.NET.HostModel.AppHost.HostWriter').Type) {
    Add-Type -Path $HostModelPath
  }
  $TemplatePath = Get-DotNetAppHostTemplate -Rid $Rid
  New-Item (Split-Path $DestinationPath -Parent) -ItemType Directory -Force | Out-Null
  [Microsoft.NET.HostModel.AppHost.HostWriter]::CreateAppHost(
    $TemplatePath,
    $DestinationPath,
    '../../../pwsh.dll',
    $false,
    $ResourceAssemblyPath,
    $false,
    $false,
    $null)
}

function ConvertTo-XmlAttributeValue {
  param(
    [AllowNull()]
    [string] $Value
  )

  if ($null -eq $Value) {
    return ''
  }

  return [System.Security.SecurityElement]::Escape($Value)
}

function Get-NuGetCommand {
  param(
    [Parameter(Mandatory)]
    [string] $ToolDirectory
  )

  if ($NuGetExe) {
    $ResolvedNuGetExe = (Resolve-Path -LiteralPath $NuGetExe).Path
    if (-not (Test-Path -LiteralPath $ResolvedNuGetExe -PathType Leaf)) {
      throw "NuGet CLI was not found at $ResolvedNuGetExe"
    }

    return $ResolvedNuGetExe
  }

  $NuGetCommand = Get-Command nuget -ErrorAction SilentlyContinue
  if ($NuGetCommand) {
    return $NuGetCommand.Source
  }

  if (-not $IsWindows) {
    throw 'NuGet CLI was not found on PATH. Install nuget, or pass -NuGetExe.'
  }

  New-Item -Path $ToolDirectory -ItemType Directory -Force | Out-Null
  $DownloadedNuGetExe = Join-Path $ToolDirectory 'nuget.exe'
  if (-not (Test-Path -LiteralPath $DownloadedNuGetExe -PathType Leaf)) {
    Invoke-WebRequest 'https://dist.nuget.org/win-x86-commandline/latest/nuget.exe' -OutFile $DownloadedNuGetExe
  }

  return $DownloadedNuGetExe
}

function Resolve-MultiPwshAppHostAsset {
  param(
    [Parameter(Mandatory)]
    [string] $TargetFramework,

    [Parameter(Mandatory)]
    [string] $Rid
  )

  $ResolveRoot = Join-Path ([System.IO.Path]::GetTempPath()) "multi-pwsh-apphost-resolve-$([Guid]::NewGuid().ToString('N'))"
  $ProjectPath = Join-Path $ResolveRoot 'MultiPwshAppHostResolver.csproj'
  $NuGetConfigPath = Join-Path $ResolveRoot 'nuget.config'
  $AssetListPath = Join-Path $ResolveRoot 'multi-pwsh-apphost-assets.tsv'
  $InfoPath = Join-Path $ResolveRoot 'multi-pwsh-apphost-info.txt'

  New-Item $ResolveRoot -ItemType Directory -Force | Out-Null
  try {
    $PackageSourceXml = ConvertTo-XmlAttributeValue $MultiPwshPackageSource
    @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="multiPwsh" value="$PackageSourceXml" />
  </packageSources>
</configuration>
"@ | Set-Content -Path $NuGetConfigPath -Encoding utf8

    $PackageIdXml = ConvertTo-XmlAttributeValue $MultiPwshPackageId
    $PackageVersionXml = ConvertTo-XmlAttributeValue $MultiPwshPackageVersion
    $TargetFrameworkXml = ConvertTo-XmlAttributeValue $TargetFramework
    @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>$TargetFrameworkXml</TargetFramework>
    <MultiPwshRuntimeNativeContentCopyEnabled>false</MultiPwshRuntimeNativeContentCopyEnabled>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="$PackageIdXml" Version="$PackageVersionXml" PrivateAssets="all" GeneratePathProperty="true" />
  </ItemGroup>
  <Target Name="WriteMultiPwshAppHostAssets" DependsOnTargets="ResolveMultiPwshAppHostAssets">
    <WriteLinesToFile File="`$(MultiPwshAppHostAssetOutputPath)"
                      Lines="@(MultiPwshAppHostAsset->'%(RuntimeIdentifier)|%(NativeFileName)|%(AppHostFileName)|%(PackageRelativePath)|%(PackageId)|%(FullPath)')"
                      Overwrite="true" />
    <WriteLinesToFile File="`$(MultiPwshAppHostInfoPath)"
                      Lines="PackageRoot=`$(PkgDevolutions_MultiPwsh_Cli)|ManifestPath=`$(MultiPwshAppHostManifestPath)"
                      Overwrite="true" />
  </Target>
</Project>
"@ | Set-Content -Path $ProjectPath -Encoding utf8

    Invoke-Native dotnet @('restore', $ProjectPath, '--configfile', $NuGetConfigPath, '--verbosity', 'minimal')
    Invoke-Native dotnet @('msbuild', $ProjectPath, '-nologo', '-v:minimal', '-t:WriteMultiPwshAppHostAssets', "/p:MultiPwshAppHostAssetOutputPath=$AssetListPath", "/p:MultiPwshAppHostInfoPath=$InfoPath")

    $PackageInfo = @{}
    if (Test-Path $InfoPath -PathType Leaf) {
      foreach ($InfoField in ((Get-Content -LiteralPath $InfoPath -Raw) -split '\|')) {
        $Pair = $InfoField -split '=', 2
        if ($Pair.Count -eq 2) {
          $PackageInfo[$Pair[0]] = $Pair[1].Trim()
        }
      }
    }

    foreach ($Line in Get-Content -LiteralPath $AssetListPath) {
      if ([string]::IsNullOrWhiteSpace($Line)) {
        continue
      }

      $Fields = $Line -split '\|', 6
      if ($Fields.Count -ne 6) {
        throw "Unexpected multi-pwsh apphost asset record: $Line"
      }
      if ($Fields[0] -ne $Rid) {
        continue
      }
      if ($Fields[4] -ne $MultiPwshPackageId) {
        throw "Resolved apphost from package '$($Fields[4])', expected '$MultiPwshPackageId'"
      }

      $SourcePath = $Fields[5]
      if ([string]::IsNullOrWhiteSpace($SourcePath) -or -not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        $PackageRoot = $PackageInfo['PackageRoot']
        if (-not [string]::IsNullOrWhiteSpace($PackageRoot) -and -not [string]::IsNullOrWhiteSpace($Fields[3])) {
          $SourcePath = Join-Path $PackageRoot ($Fields[3] -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        }
      }
      if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        throw "Resolved apphost asset for '$Rid' does not exist at '$SourcePath'"
      }

      return [pscustomobject]@{
        RuntimeIdentifier = $Fields[0]
        AppHostFileName = $Fields[2]
        SourcePath = $SourcePath
      }
    }

    throw "No $MultiPwshPackageId apphost asset found for '$Rid'."
  } finally {
    Remove-Item $ResolveRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Add-OverlayFile {
  param(
    [Parameter(Mandatory)]
    [hashtable] $OverlayPathMap,

    [Parameter(Mandatory)]
    [string] $PackageRelativePath,

    [Parameter(Mandatory)]
    [string] $SourcePath,

    [bool] $Required = $true
  )

  if (Test-Path $SourcePath -PathType Leaf) {
    $OverlayPathMap[$PackageRelativePath] = $SourcePath
    return
  }

  if ($Required) {
    throw "Missing source-built package file for $PackageRelativePath`: $SourcePath"
  }
}

function Get-NuGetGlobalPackagesPath {
  $Output = & dotnet nuget locals global-packages --list
  if ($LASTEXITCODE -ne 0) {
    throw "dotnet nuget locals global-packages --list failed with exit code $LASTEXITCODE"
  }

  $GlobalPackagesLine = $Output | Where-Object { $_ -match '^\s*global-packages:\s*(.+)$' } | Select-Object -First 1
  if (-not $GlobalPackagesLine -or $GlobalPackagesLine -notmatch '^\s*global-packages:\s*(.+)$') {
    throw 'Unable to determine NuGet global packages path.'
  }

  return $Matches[1].Trim()
}

function Get-NuGetCacheVersion {
  param(
    [Parameter(Mandatory)]
    [string] $Version
  )

  if ($Version -match '^(\d+\.\d+\.\d+)\.0$') {
    return $Matches[1]
  }
  if ($Version -match '^\d+\.\d+$') {
    return "$Version.0"
  }

  return $Version
}

function Copy-PSGalleryModulesToPackage {
  param(
    [Parameter(Mandatory)]
    [string] $ProjectPath,

    [Parameter(Mandatory)]
    [string] $DestinationRoot
  )

  if (-not (Test-Path -LiteralPath $ProjectPath -PathType Leaf)) {
    throw "PSGallery module project was not found: $ProjectPath"
  }

  $ProjectDirectory = Split-Path -Parent $ProjectPath
  $NuGetConfigPath = Join-Path $ProjectDirectory 'nuget.config'
  $RestoreArguments = @('restore', $ProjectPath, '--verbosity', 'minimal')
  if (Test-Path -LiteralPath $NuGetConfigPath -PathType Leaf) {
    $RestoreArguments += @('--configfile', $NuGetConfigPath)
  }

  Invoke-Native dotnet $RestoreArguments

  [xml] $PSGalleryProject = Get-Content -LiteralPath $ProjectPath -Raw
  $PackageReferences = @($PSGalleryProject.Project.ItemGroup.PackageReference)
  if (-not $PackageReferences) {
    throw "PSGallery module project contains no PackageReference items: $ProjectPath"
  }

  $NuGetGlobalPackagesPath = Get-NuGetGlobalPackagesPath
  Remove-Item -LiteralPath $DestinationRoot -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -Path $DestinationRoot -ItemType Directory -Force | Out-Null

  foreach ($PackageReference in $PackageReferences) {
    $ModuleName = [string] $PackageReference.Include
    $ModuleVersion = [string] $PackageReference.Version
    if ([string]::IsNullOrWhiteSpace($ModuleName) -or [string]::IsNullOrWhiteSpace($ModuleVersion)) {
      throw "Invalid PSGallery module PackageReference in $ProjectPath"
    }

    $CacheVersion = Get-NuGetCacheVersion -Version $ModuleVersion
    $SourcePath = Join-Path $NuGetGlobalPackagesPath (Join-Path $ModuleName.ToLowerInvariant() $CacheVersion)
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) {
      throw "Restored PSGallery module package was not found: $SourcePath"
    }

    $DestinationPath = Join-Path $DestinationRoot $ModuleName
    Remove-Item -LiteralPath $DestinationPath -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -Path $DestinationPath -ItemType Directory -Force | Out-Null
    Copy-Item -Path (Join-Path $SourcePath '*') -Destination $DestinationPath -Recurse -Force

    $ExcludedNames = @('fullclr', 'System.Runtime.InteropServices.RuntimeInformation.dll')
    $ExcludedPatterns = @('*.nupkg', '*.nupkg.metadata', '*.nupkg.sha512', '*.nuspec')
    Get-ChildItem -LiteralPath $DestinationPath -Recurse -Force |
      Sort-Object FullName -Descending |
      Where-Object {
        $ItemName = $_.Name
        $ExcludedNames -contains $_.Name -or
        (@($ExcludedPatterns | Where-Object { $ItemName -like $_ }).Count -gt 0)
      } |
      Remove-Item -Recurse -Force
  }
}

if (-not $RuntimeIdentifier) {
  $RuntimeIdentifier = Get-DefaultRuntimeIdentifier
}
if ([string]::IsNullOrWhiteSpace($SdkPackageVersion)) {
  $SdkPackageVersion = "$PowerShellVersion.0"
}
Assert-SdkPackageVersion -PowerShellVersion $PowerShellVersion -PackageVersion $SdkPackageVersion
$NormalizedSdkPackageVersion = Get-NormalizedNuGetPackageVersion -PackageVersion $SdkPackageVersion

$RepositoryRoot = (Invoke-GitOutput rev-parse --show-toplevel | Select-Object -First 1).Trim()
if (-not $RepositoryRoot) {
  throw 'Unable to determine git repository root.'
}

$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$PwshSourceRoot = Join-Path $RepositoryRoot 'pwsh-src'
if (-not (Test-Path (Join-Path $PwshSourceRoot 'PowerShell.Common.props') -PathType Leaf)) {
  throw 'pwsh-src is not initialized. Run scripts\Initialize-Repository.ps1 first.'
}

$OutputRootPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath((Join-Path $RepositoryRoot (Join-Path $OutputRoot $RuntimeIdentifier)))
$AppHostOutputPath = Join-Path $OutputRootPath 'PowerShell-AppHost'
$PackageRuntimePath = Join-Path $OutputRootPath 'package-runtime'
$PackageOutputPath = Join-Path $OutputRootPath 'package'
$PackageStageRoot = Join-Path $OutputRootPath 'nupkg-stage'

Remove-Item $OutputRootPath -Recurse -Force -ErrorAction SilentlyContinue
New-Item $OutputRootPath, $PackageRuntimePath, $PackageOutputPath, $PackageStageRoot -ItemType Directory -Force | Out-Null
$NuGetCommand = Get-NuGetCommand -ToolDirectory (Join-Path $OutputRootPath 'tools')
$env:PATH = "$(Split-Path -Parent $NuGetCommand);$env:PATH"

$ModuleNugetConfigPath = Join-Path $PwshSourceRoot 'src\Modules\nuget.config'
$HadModuleNugetConfig = Test-Path $ModuleNugetConfigPath -PathType Leaf
$OriginalModuleNugetConfig = if ($HadModuleNugetConfig) { Get-Content -LiteralPath $ModuleNugetConfigPath -Raw } else { $null }

Push-Location $PwshSourceRoot
try {
  Import-Module .\build.psm1 -Force
  Start-PSBootstrap -Scenario DotNet
  if ($IsWindows) {
    Switch-PSNugetConfig -Source Public
    $ModuleNugetConfig = @(
      '<?xml version="1.0" encoding="utf-8"?>',
      '<configuration>',
      '  <packageSources>',
      '    <clear />',
      '    <add key="powershell" value="https://pkgs.dev.azure.com/powershell/PowerShell/_packaging/PowerShell/nuget/v3/index.json" />',
      '  </packageSources>',
      '  <disabledPackageSources>',
      '    <clear />',
      '  </disabledPackageSources>',
      '</configuration>'
    )
    Set-Content -Path $ModuleNugetConfigPath -Value $ModuleNugetConfig -Encoding utf8
  }

  [xml] $CommonProps = Get-Content .\PowerShell.Common.props
  $TargetFramework = $CommonProps.Project.PropertyGroup |
    ForEach-Object { $_.TargetFramework } |
    Where-Object { $_ } |
    Select-Object -First 1
  if (-not $TargetFramework) {
    throw 'Unable to determine PowerShell TargetFramework from PowerShell.Common.props'
  }

  $RuntimeGroup = if ($RuntimeIdentifier -like 'win-*') { 'win' } else { 'unix' }
  $ExecutableName = Get-AppHostExecutableName -Rid $RuntimeIdentifier
  $AppHostRuntimeIdentifiers = if ($RuntimeGroup -eq 'win') { @('win-x64', 'win-arm64') } else { @($RuntimeIdentifier) }
  $AppHostAssets = @{}
  foreach ($AppHostRuntimeIdentifier in $AppHostRuntimeIdentifiers) {
    $AppHostAssets[$AppHostRuntimeIdentifier] = Resolve-MultiPwshAppHostAsset -TargetFramework $TargetFramework -Rid $AppHostRuntimeIdentifier
  }

  $PSBuildParams = @{
    Configuration = 'Release'
    Runtime = Get-PSBuildRuntime -Rid $RuntimeIdentifier
    Output = $AppHostOutputPath
    Clean = $true
    ReleaseTag = $PowerShellReleaseTag
    NoPSModuleRestore = $true
    SkipExperimentalFeatureGeneration = $true
  }
  if (-not $IsWindows) {
    $PSBuildParams.UseNuGetOrg = $true
  }
  Start-PSBuild @PSBuildParams

  Invoke-Native dotnet @('build', '.\src\Microsoft.PowerShell.SDK\Microsoft.PowerShell.SDK.csproj', '-c', 'Release', "/p:ReleaseTag=$PowerShellVersion")

  $CommonAssemblyDefinitions = @(
    @{ AssemblyName = 'Microsoft.PowerShell.SDK'; ProjectDirectory = 'Microsoft.PowerShell.SDK' },
    @{ AssemblyName = 'System.Management.Automation'; ProjectDirectory = 'System.Management.Automation' },
    @{ AssemblyName = 'Microsoft.PowerShell.Commands.Management'; ProjectDirectory = 'Microsoft.PowerShell.Commands.Management' },
    @{ AssemblyName = 'Microsoft.PowerShell.Commands.Utility'; ProjectDirectory = 'Microsoft.PowerShell.Commands.Utility' },
    @{ AssemblyName = 'Microsoft.PowerShell.ConsoleHost'; ProjectDirectory = 'Microsoft.PowerShell.ConsoleHost' },
    @{ AssemblyName = 'Microsoft.PowerShell.Security'; ProjectDirectory = 'Microsoft.PowerShell.Security' }
  )
  $WindowsAssemblyDefinitions = @(
    @{ AssemblyName = 'Microsoft.PowerShell.Commands.Diagnostics'; ProjectDirectory = 'Microsoft.PowerShell.Commands.Diagnostics' },
    @{ AssemblyName = 'Microsoft.Management.Infrastructure.CimCmdlets'; ProjectDirectory = 'Microsoft.Management.Infrastructure.CimCmdlets' },
    @{ AssemblyName = 'Microsoft.WSMan.Management'; ProjectDirectory = 'Microsoft.WSMan.Management' },
    @{ AssemblyName = 'Microsoft.PowerShell.CoreCLR.Eventing'; ProjectDirectory = 'Microsoft.PowerShell.CoreCLR.Eventing' },
    @{ AssemblyName = 'Microsoft.WSMan.Runtime'; ProjectDirectory = 'Microsoft.WSMan.Runtime' }
  )
  $AssemblyDefinitions = if ($RuntimeGroup -eq 'win') { $CommonAssemblyDefinitions + $WindowsAssemblyDefinitions } else { $CommonAssemblyDefinitions }

  foreach ($AssemblyDefinition in $AssemblyDefinitions) {
    $AssemblyName = $AssemblyDefinition.AssemblyName
    $SourceDirectory = if ($AssemblyName -eq 'Microsoft.PowerShell.SDK') {
      Join-Path $PwshSourceRoot "src\$($AssemblyDefinition.ProjectDirectory)\bin\Release\$TargetFramework"
    } else {
      $AppHostOutputPath
    }
    $AssemblyPath = Join-Path $SourceDirectory "$AssemblyName.dll"
    if (-not (Test-Path $AssemblyPath -PathType Leaf)) {
      throw "PowerShell build did not produce package runtime assembly: $AssemblyPath"
    }
    Copy-Item $AssemblyPath $PackageRuntimePath -Force
    $XmlPath = [System.IO.Path]::ChangeExtension($AssemblyPath, '.xml')
    if (Test-Path $XmlPath -PathType Leaf) {
      Copy-Item $XmlPath $PackageRuntimePath -Force
    }
  }

  $SdkStagePath = Join-Path $PackageStageRoot $PackageId
  $SdkOverlayPathMap = @{}
  foreach ($AssemblyDefinition in $AssemblyDefinitions) {
    $AssemblyName = $AssemblyDefinition.AssemblyName
    $LocalAssemblyPath = Join-Path $PwshSourceRoot "src\$($AssemblyDefinition.ProjectDirectory)\bin\Release\$TargetFramework"
    $RefSourcePath = Join-Path $LocalAssemblyPath "$AssemblyName.dll"
    if (-not (Test-Path $RefSourcePath -PathType Leaf)) {
      $RefSourcePath = Join-Path $PackageRuntimePath "$AssemblyName.dll"
    }

    Add-OverlayFile $SdkOverlayPathMap "ref/$TargetFramework/$AssemblyName.dll" $RefSourcePath
    Add-OverlayFile $SdkOverlayPathMap "ref/$TargetFramework/$AssemblyName.xml" ([System.IO.Path]::ChangeExtension($RefSourcePath, '.xml')) $false
    Add-OverlayFile $SdkOverlayPathMap "runtimes/$RuntimeGroup/lib/$TargetFramework/$AssemblyName.dll" (Join-Path $PackageRuntimePath "$AssemblyName.dll")
  }

  & (Join-Path $RepositoryRoot 'eng\Vendor-PowerShellSdkPackage.ps1') `
    -PackageRoot $SdkStagePath `
    -PowerShellVersion $PowerShellVersion `
    -PackageVersion $SdkPackageVersion `
    -PackageId $PackageId `
    -VendorName $VendorName `
    -OverlayPathMap $SdkOverlayPathMap

  $AnyAnyRuntimesDir = Join-Path $SdkStagePath 'contentFiles\any\any\runtimes'
  Remove-Item $AnyAnyRuntimesDir -Recurse -Force -ErrorAction SilentlyContinue
  New-Item $AnyAnyRuntimesDir -ItemType Directory -Force | Out-Null
  $ModuleSourceRoot = if ($RuntimeGroup -eq 'win') { '.\src\Modules\Windows' } else { '.\src\Modules\Unix' }
  Get-Item "$ModuleSourceRoot\*\*.ps*" | ForEach-Object {
    $ModuleName = Split-Path (Split-Path $_.FullName -Parent) -Leaf
    $DestinationDir = Join-Path $AnyAnyRuntimesDir "$RuntimeGroup\lib\$TargetFramework\Modules\$ModuleName"
    New-Item $DestinationDir -ItemType Directory -Force | Out-Null
    Copy-Item $_ $DestinationDir -Force
  }

  Copy-PSGalleryModulesToPackage `
    -ProjectPath (Join-Path $PwshSourceRoot 'src\Modules\PSGalleryModules.csproj') `
    -DestinationRoot (Join-Path $SdkStagePath 'buildTransitive\psgallery-modules')

  foreach ($AppHostRuntimeIdentifier in $AppHostRuntimeIdentifiers) {
    $AppHostAsset = $AppHostAssets[$AppHostRuntimeIdentifier]
    $ExpectedExecutableName = Get-AppHostExecutableName -Rid $AppHostRuntimeIdentifier
    if ($AppHostAsset.AppHostFileName -ne $ExpectedExecutableName) {
      throw "Resolved apphost file '$($AppHostAsset.AppHostFileName)' for '$AppHostRuntimeIdentifier', expected '$ExpectedExecutableName'"
    }

    $AppHostPackageRoot = Join-Path $SdkStagePath "tools\apphost\$AppHostRuntimeIdentifier"
    New-Item $AppHostPackageRoot -ItemType Directory -Force | Out-Null
    Copy-Item -LiteralPath $AppHostAsset.SourcePath -Destination (Join-Path $AppHostPackageRoot $AppHostAsset.AppHostFileName) -Force

    $NativeAppHostPackageRoot = Join-Path $SdkStagePath "runtimes\$AppHostRuntimeIdentifier\native"
    New-Item $NativeAppHostPackageRoot -ItemType Directory -Force | Out-Null
    $SharedPayloadAppHostPath = Join-Path $NativeAppHostPackageRoot $AppHostAsset.AppHostFileName
    New-SharedPayloadAppHost -Rid $AppHostRuntimeIdentifier -DestinationPath $SharedPayloadAppHostPath -ResourceAssemblyPath (Join-Path $AppHostOutputPath 'pwsh.dll')

    foreach ($FileName in @('pwsh.dll', 'pwsh.runtimeconfig.json')) {
      $SourcePath = Join-Path $AppHostOutputPath $FileName
      if (-not (Test-Path $SourcePath -PathType Leaf)) {
        throw "Missing apphost file: $SourcePath"
      }
      Copy-Item $SourcePath $AppHostPackageRoot -Force
    }
  }

  $BuildTransitivePath = Join-Path $SdkStagePath 'buildTransitive'
  New-Item $BuildTransitivePath -ItemType Directory -Force | Out-Null
  Copy-Item (Join-Path $RepositoryRoot 'eng\Microsoft.PowerShell.SDK.targets') (Join-Path $BuildTransitivePath "$PackageId.targets") -Force

  Push-Location $SdkStagePath
  try {
    Invoke-Native $NuGetCommand @('pack', '-OutputDirectory', $PackageOutputPath, '-NonInteractive')
  } finally {
    Pop-Location
  }

  $Package = Get-ChildItem -LiteralPath $PackageOutputPath -Filter "$PackageId.$NormalizedSdkPackageVersion*.nupkg" |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
  if (-not $Package) {
    throw "Failed to create $PackageId.$SdkPackageVersion package in $PackageOutputPath"
  }

  if ($Validate) {
    & (Join-Path $RepositoryRoot 'eng\Validate-PowerShellSdkPackage.ps1') `
      -PackageDirectory $PackageOutputPath `
      -PowerShellVersion $PowerShellVersion `
      -PackageVersion $SdkPackageVersion `
      -TargetFramework $TargetFramework `
      -RuntimeIdentifier $RuntimeIdentifier `
      -PackageId $PackageId `
      -PackageVendorName $VendorName
  }

  Write-Output "Package=$($Package.FullName)"
  Write-Output "RuntimeIdentifier=$RuntimeIdentifier"
  Write-Output "TargetFramework=$TargetFramework"
} finally {
  if ($IsWindows) {
    if ($HadModuleNugetConfig) {
      Set-Content -Path $ModuleNugetConfigPath -Value $OriginalModuleNugetConfig -Encoding utf8NoBOM
    } else {
      Remove-Item $ModuleNugetConfigPath -Force -ErrorAction SilentlyContinue
    }
  }
  Pop-Location
}
