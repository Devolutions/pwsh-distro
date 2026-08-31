[CmdletBinding()]
param(
  [string] $PackageId = 'Devolutions.PowerShell.SDK',

  [Parameter(Mandatory)]
  [string] $PackageVersion,

  [string] $PackageSource = 'https://api.nuget.org/v3/index.json',

  [Parameter(Mandatory)]
  [string] $PowerShellVersion,

  [Parameter(Mandatory)]
  [string] $RuntimeIdentifier,

  [Parameter(Mandatory)]
  [string] $OutputDirectory,

  [string] $ArchivePath,

  [string] $RepositoryRoot,

  [switch] $ReadyToRun,

  [string[]] $ReadyToRunIncludeFilter,

  [switch] $ReadyToRunUseCache,

  [string] $ReadyToRunCachePath,

  [string] $CustomRuntimeSource,

  [string] $CustomRuntimePackageVersion
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Invoke-NativeCommand {
  param(
    [Parameter(Mandatory)]
    [string] $FilePath,

    [Parameter(ValueFromRemainingArguments)]
    [string[]] $Arguments
  )

  & $FilePath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "$FilePath $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
  }
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

function Get-EffectiveCustomRuntimePackageVersion {
  param(
    [Parameter(Mandatory)]
    [string] $PackageVersion
  )

  if ($PackageVersion -match '^(?<stable>\d+(?:\.\d+)+)-') {
    return $Matches['stable']
  }

  return $PackageVersion
}

function New-CustomRuntimeFeed {
  param(
    [Parameter(Mandatory)]
    [string] $SourceRoot,

    [Parameter(Mandatory)]
    [string] $DestinationRoot,

    [Parameter(Mandatory)]
    [string] $RuntimeIdentifier,

    [Parameter(Mandatory)]
    [string] $PackageVersion,

    [Parameter(Mandatory)]
    [string] $EffectivePackageVersion
  )

  $SourceRootPath = (Resolve-Path -LiteralPath $SourceRoot).Path
  Remove-Item -LiteralPath $DestinationRoot -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -Path $DestinationRoot -ItemType Directory -Force | Out-Null

  $RuntimePackPattern = '^Microsoft\.NETCore\.App\.(Ref|Runtime\.' + [regex]::Escape($RuntimeIdentifier) + ')\.' + [regex]::Escape($PackageVersion) + '\.nupkg$'
  $RuntimePacks = @(Get-ChildItem -LiteralPath $SourceRootPath -Filter '*.nupkg' -File | Where-Object {
    $_.Name -match $RuntimePackPattern -and $_.Name -notmatch '\.symbols\.nupkg$'
  })
  if ($RuntimePacks.Count -eq 0) {
    throw "No runtime/ref packages matching version '$PackageVersion' for RID '$RuntimeIdentifier' were found in $SourceRootPath"
  }

  Add-Type -AssemblyName System.IO.Compression.FileSystem

  foreach ($RuntimePack in $RuntimePacks) {
    if ($EffectivePackageVersion -eq $PackageVersion) {
      Copy-Item -LiteralPath $RuntimePack.FullName -Destination $DestinationRoot -Force
      continue
    }

    $PackageExtractRoot = Join-Path $DestinationRoot ([System.IO.Path]::GetFileNameWithoutExtension($RuntimePack.Name))
    Remove-Item -LiteralPath $PackageExtractRoot -Recurse -Force -ErrorAction SilentlyContinue
    [System.IO.Compression.ZipFile]::ExtractToDirectory($RuntimePack.FullName, $PackageExtractRoot)

    $NuspecPath = Get-ChildItem -LiteralPath $PackageExtractRoot -Filter '*.nuspec' -File | Select-Object -First 1 -ExpandProperty FullName
    if (-not $NuspecPath) {
      throw "Could not find a nuspec inside custom runtime package: $($RuntimePack.FullName)"
    }

    $NuspecContent = Get-Content -LiteralPath $NuspecPath -Raw
    $UpdatedNuspecContent = $NuspecContent -replace '<version>[^<]+</version>', "<version>$EffectivePackageVersion</version>"
    Set-Content -LiteralPath $NuspecPath -Value $UpdatedNuspecContent -Encoding utf8

    $RepackedName = $RuntimePack.Name -replace [regex]::Escape(".$PackageVersion.nupkg"), ".$EffectivePackageVersion.nupkg"
    $RepackedPath = Join-Path $DestinationRoot $RepackedName
    Remove-Item -LiteralPath $RepackedPath -Force -ErrorAction SilentlyContinue
    [System.IO.Compression.ZipFile]::CreateFromDirectory($PackageExtractRoot, $RepackedPath)
    Remove-Item -LiteralPath $PackageExtractRoot -Recurse -Force
  }

  return (Resolve-Path -LiteralPath $DestinationRoot).Path
}

function Get-PowerShellTargetFramework {
  param(
    [Parameter(Mandatory)]
    [string] $Root
  )

  $CommonPropsPath = Join-Path $Root 'pwsh-src\PowerShell.Common.props'
  if (-not (Test-Path -LiteralPath $CommonPropsPath -PathType Leaf)) {
    throw "PowerShell.Common.props was not found. Initialize the pwsh-src submodule first: $CommonPropsPath"
  }

  [xml] $CommonProps = Get-Content -LiteralPath $CommonPropsPath -Raw
  $TargetFramework = $CommonProps.Project.PropertyGroup |
    ForEach-Object { $_.TargetFramework } |
    Where-Object { $_ } |
    Select-Object -First 1

  if ([string]::IsNullOrWhiteSpace($TargetFramework)) {
    throw "Unable to determine PowerShell TargetFramework from $CommonPropsPath"
  }

  return [string] $TargetFramework
}

function Get-PowerShellExecutableName {
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
    [string] $ExpectedPowerShellVersion,

    [Parameter(Mandatory)]
    [string] $ActualPackageVersion
  )

  if ($ActualPackageVersion -notmatch '^\d+\.\d+\.\d+\.\d+$') {
    throw "SDK package version '$ActualPackageVersion' must use X.Y.Z.R."
  }

  if (($ActualPackageVersion -replace '\.\d+$', '') -ne $ExpectedPowerShellVersion) {
    throw "SDK package version '$ActualPackageVersion' must start with PowerShell version '$ExpectedPowerShellVersion'."
  }
}

function Get-NormalizedNuGetPackageVersion {
  param(
    [Parameter(Mandatory)]
    [string] $Version
  )

  $ParsedVersion = [version]::Parse($Version)
  if ($ParsedVersion.Revision -eq 0) {
    return "$($ParsedVersion.Major).$($ParsedVersion.Minor).$($ParsedVersion.Build)"
  }

  return $Version
}

function Get-RestoredSdkPackageRoot {
  param(
    [Parameter(Mandatory)]
    [string] $PackagesDirectory,

    [Parameter(Mandatory)]
    [string] $PackageId,

    [Parameter(Mandatory)]
    [string] $PackageVersion
  )

  $NormalizedPackageVersion = Get-NormalizedNuGetPackageVersion -Version $PackageVersion
  $PackageRoot = Join-Path $PackagesDirectory (Join-Path $PackageId.ToLowerInvariant() $NormalizedPackageVersion)
  if (-not (Test-Path -LiteralPath $PackageRoot -PathType Container)) {
    throw "Restored SDK package directory was not found: $PackageRoot"
  }

  return $PackageRoot
}

function Get-PackageRuntimeGroup {
  param(
    [Parameter(Mandatory)]
    [string] $Rid
  )

  if ($Rid -like 'win-*') {
    return 'win'
  }

  return 'unix'
}

function Get-CurrentRuntimeIdentifier {
  $Architecture = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
    'X64' { 'x64'; break }
    'Arm64' { 'arm64'; break }
    default { return $null }
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

  return $null
}

function Assert-RequiredFile {
  param(
    [Parameter(Mandatory)]
    [string] $Root,

    [Parameter(Mandatory)]
    [string] $RelativePath
  )

  $Path = Join-Path $Root ($RelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "PowerShell distro is missing required file: $Path"
  }
}

function Remove-DisposableHostFiles {
  param(
    [Parameter(Mandatory)]
    [string] $Root,

    [Parameter(Mandatory)]
    [string] $HostBaseName
  )

  $HostFileNames = @(
    $HostBaseName,
    "$HostBaseName.exe",
    "$HostBaseName.dll",
    "$HostBaseName.deps.json",
    "$HostBaseName.runtimeconfig.json",
    "$HostBaseName.pdb"
  )

  foreach ($HostFileName in $HostFileNames) {
    $HostPath = Join-Path $Root $HostFileName
    Remove-Item -LiteralPath $HostPath -Force -ErrorAction SilentlyContinue
  }

  foreach ($HostFileName in $HostFileNames) {
    $HostPath = Join-Path $Root $HostFileName
    if (Test-Path -LiteralPath $HostPath) {
      throw "Disposable host file was not removed from the PowerShell distro: $HostPath"
    }
  }
}

function Remove-UnneededDistroFiles {
  param(
    [Parameter(Mandatory)]
    [string] $Root
  )

  Get-ChildItem -LiteralPath $Root -Filter 'Microsoft.DiaSymReader.Native.*.dll' -File -ErrorAction SilentlyContinue |
    Remove-Item -Force

  $RemainingDiaSymReaderFiles = @(Get-ChildItem -LiteralPath $Root -Filter 'Microsoft.DiaSymReader.Native.*.dll' -File -ErrorAction SilentlyContinue)
  if ($RemainingDiaSymReaderFiles.Count -gt 0) {
    throw "Unneeded DIA symbol reader file was not removed from the PowerShell distro: $($RemainingDiaSymReaderFiles[0].FullName)"
  }
}

function Optimize-PowerShellDistroReadyToRun {
  param(
    [Parameter(Mandatory)]
    [string] $Root,

    [Parameter(Mandatory)]
    [string] $Rid,

    [Parameter(Mandatory)]
    [string] $TargetFramework,

    [AllowEmptyCollection()]
    [string[]] $IncludeFilter,

    [switch] $UseCache,

    [string] $CachePath
  )

  $ReadyToRunScript = Join-Path $PSScriptRoot 'Optimize-PowerShellDistroReadyToRun.ps1'
  if (-not (Test-Path -LiteralPath $ReadyToRunScript -PathType Leaf)) {
    throw "ReadyToRun script was not found: $ReadyToRunScript"
  }

  $ReadyToRunArguments = @{
    InputPath = $Root
    RuntimeIdentifier = $Rid
    TargetFramework = $TargetFramework
  }
  if ($IncludeFilter) {
    $ReadyToRunArguments.IncludeFilter = $IncludeFilter
  }
  if ($UseCache) {
    $ReadyToRunArguments.UseCache = $true
  }
  if (-not [string]::IsNullOrWhiteSpace($CachePath)) {
    $ReadyToRunArguments.CachePath = $CachePath
  }

  & $ReadyToRunScript @ReadyToRunArguments
}

function Copy-FileIfPresent {
  param(
    [Parameter(Mandatory)]
    [string] $SourcePath,

    [Parameter(Mandatory)]
    [string] $DestinationPath
  )

  if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
    return
  }

  $DestinationDirectory = Split-Path -Parent $DestinationPath
  if ($DestinationDirectory) {
    New-Item -Path $DestinationDirectory -ItemType Directory -Force | Out-Null
  }

  Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force
}

function Copy-DirectoryIfPresent {
  param(
    [Parameter(Mandatory)]
    [string] $SourcePath,

    [Parameter(Mandatory)]
    [string] $DestinationPath
  )

  if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) {
    return
  }

  Remove-Item -LiteralPath $DestinationPath -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -Path (Split-Path -Parent $DestinationPath) -ItemType Directory -Force | Out-Null
  Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Recurse -Force
}

function Get-IncludedFrameworkVersion {
  param(
    [Parameter(Mandatory)]
    [string] $RuntimeConfigPath,

    [Parameter(Mandatory)]
    [string] $FrameworkName
  )

  if (-not (Test-Path -LiteralPath $RuntimeConfigPath -PathType Leaf)) {
    throw "Runtime config was not found: $RuntimeConfigPath"
  }

  $RuntimeConfig = Get-Content -LiteralPath $RuntimeConfigPath -Raw | ConvertFrom-Json
  $IncludedFramework = @($RuntimeConfig.runtimeOptions.includedFrameworks) |
    Where-Object { [string] $_.name -eq $FrameworkName } |
    Select-Object -First 1
  if (-not $IncludedFramework -or [string]::IsNullOrWhiteSpace([string] $IncludedFramework.version)) {
    throw "Runtime config '$RuntimeConfigPath' does not include framework '$FrameworkName'."
  }

  return [string] $IncludedFramework.version
}

function Restore-WindowsDesktopRuntimePack {
  param(
    [Parameter(Mandatory)]
    [string] $RuntimeIdentifier,

    [Parameter(Mandatory)]
    [string] $TargetFramework,

    [Parameter(Mandatory)]
    [string] $RuntimePackVersion,

    [Parameter(Mandatory)]
    [string] $PackagesDirectory,

    [Parameter(Mandatory)]
    [string] $NuGetConfigPath,

    [Parameter(Mandatory)]
    [string] $WorkRoot
  )

  $PackageId = "Microsoft.WindowsDesktop.App.Runtime.$RuntimeIdentifier"
  $PackageRoot = Join-Path $PackagesDirectory (Join-Path $PackageId.ToLowerInvariant() $RuntimePackVersion)
  $RuntimePackRoot = Join-Path $PackageRoot "runtimes\$RuntimeIdentifier"
  if (Test-Path -LiteralPath $RuntimePackRoot -PathType Container) {
    return $RuntimePackRoot
  }

  $RestoreDirectory = Join-Path $WorkRoot "windowsdesktop-runtime-$RuntimeIdentifier"
  New-Item -Path $RestoreDirectory -ItemType Directory -Force | Out-Null
  $ProjectPath = Join-Path $RestoreDirectory 'WindowsDesktopRuntimeResolver.csproj'
  $WindowsTargetFramework = "$TargetFramework-windows"
  $EscapedTargetFramework = ConvertTo-XmlAttributeValue $WindowsTargetFramework
  $EscapedRuntimeIdentifier = ConvertTo-XmlAttributeValue $RuntimeIdentifier
  $EscapedRuntimePackVersion = ConvertTo-XmlAttributeValue $RuntimePackVersion
  @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>$EscapedTargetFramework</TargetFramework>
    <RuntimeIdentifier>$EscapedRuntimeIdentifier</RuntimeIdentifier>
    <SelfContained>true</SelfContained>
    <UseWPF>true</UseWPF>
    <UseWindowsForms>true</UseWindowsForms>
    <RuntimeFrameworkVersion>$EscapedRuntimePackVersion</RuntimeFrameworkVersion>
    <EnableDefaultItems>false</EnableDefaultItems>
  </PropertyGroup>
  <ItemGroup>
    <FrameworkReference Include="Microsoft.WindowsDesktop.App" />
  </ItemGroup>
</Project>
"@ | Set-Content -LiteralPath $ProjectPath -Encoding utf8

  Invoke-NativeCommand dotnet @('restore', $ProjectPath, '--configfile', $NuGetConfigPath, '--verbosity', 'minimal', '-r', $RuntimeIdentifier, '/p:SelfContained=true')
  if (-not (Test-Path -LiteralPath $RuntimePackRoot -PathType Container)) {
    throw "WindowsDesktop runtime pack '$PackageId' version '$RuntimePackVersion' was not restored to: $RuntimePackRoot"
  }

  return $RuntimePackRoot
}

function Add-WindowsDesktopRuntimePayload {
  param(
    [Parameter(Mandatory)]
    [string] $Root,

    [Parameter(Mandatory)]
    [string] $RuntimeIdentifier,

    [Parameter(Mandatory)]
    [string] $TargetFramework,

    [Parameter(Mandatory)]
    [string] $PackagesDirectory,

    [Parameter(Mandatory)]
    [string] $NuGetConfigPath,

    [Parameter(Mandatory)]
    [string] $WorkRoot
  )

  if ($RuntimeIdentifier -notlike 'win-*') {
    return
  }

  $RuntimePackVersion = Get-IncludedFrameworkVersion `
    -RuntimeConfigPath (Join-Path $Root 'pwsh.runtimeconfig.json') `
    -FrameworkName 'Microsoft.WindowsDesktop.App'
  $RuntimePackRoot = Restore-WindowsDesktopRuntimePack `
    -RuntimeIdentifier $RuntimeIdentifier `
    -TargetFramework $TargetFramework `
    -RuntimePackVersion $RuntimePackVersion `
    -PackagesDirectory $PackagesDirectory `
    -NuGetConfigPath $NuGetConfigPath `
    -WorkRoot $WorkRoot

  foreach ($PayloadRoot in @(
      (Join-Path $RuntimePackRoot "lib\$TargetFramework"),
      (Join-Path $RuntimePackRoot 'native'))) {
    if (Test-Path -LiteralPath $PayloadRoot -PathType Container) {
      Copy-Item -Path (Join-Path $PayloadRoot '*') -Destination $Root -Recurse -Force
    }
  }

  foreach ($BookkeepingFile in @('Microsoft.WindowsDesktop.App.deps.json', 'Microsoft.WindowsDesktop.App.runtimeconfig.json')) {
    Remove-Item -LiteralPath (Join-Path $Root $BookkeepingFile) -Force -ErrorAction SilentlyContinue
  }
}

function Add-PowerShellDistroAncillaryFiles {
  param(
    [Parameter(Mandatory)]
    [string] $Root,

    [Parameter(Mandatory)]
    [string] $RepositoryRoot,

    [Parameter(Mandatory)]
    [string] $PackagesDirectory,

    [Parameter(Mandatory)]
    [string] $PackageId,

    [Parameter(Mandatory)]
    [string] $PackageVersion,

    [Parameter(Mandatory)]
    [string] $TargetFramework,

    [Parameter(Mandatory)]
    [string] $RuntimeIdentifier
  )

  $PowerShellSourceRoot = Join-Path $RepositoryRoot 'pwsh-src'
  Copy-FileIfPresent -SourcePath (Join-Path $PowerShellSourceRoot 'LICENSE.txt') -DestinationPath (Join-Path $Root 'LICENSE.txt')
  Copy-FileIfPresent -SourcePath (Join-Path $PowerShellSourceRoot 'ThirdPartyNotices.txt') -DestinationPath (Join-Path $Root 'ThirdPartyNotices.txt')
  Copy-FileIfPresent -SourcePath (Join-Path $PowerShellSourceRoot 'assets\default.help.txt') -DestinationPath (Join-Path $Root 'en-US\default.help.txt')
  if ($RuntimeIdentifier -like 'win-*') {
    Copy-FileIfPresent -SourcePath (Join-Path $PowerShellSourceRoot 'src\powershell-native\Install-PowerShellRemoting.ps1') -DestinationPath (Join-Path $Root 'Install-PowerShellRemoting.ps1')
    Copy-FileIfPresent -SourcePath (Join-Path $PowerShellSourceRoot 'src\PowerShell.Core.Instrumentation\PowerShell.Core.Instrumentation.man') -DestinationPath (Join-Path $Root 'PowerShell.Core.Instrumentation.man')
    Copy-FileIfPresent -SourcePath (Join-Path $PowerShellSourceRoot 'src\PowerShell.Core.Instrumentation\RegisterManifest.ps1') -DestinationPath (Join-Path $Root 'RegisterManifest.ps1')
    Copy-FileIfPresent -SourcePath (Join-Path $PowerShellSourceRoot 'assets\MicrosoftUpdate\RegisterMicrosoftUpdate.ps1') -DestinationPath (Join-Path $Root 'RegisterMicrosoftUpdate.ps1')
    Copy-FileIfPresent -SourcePath (Join-Path $PowerShellSourceRoot 'assets\GroupPolicy\InstallPSCorePolicyDefinitions.ps1') -DestinationPath (Join-Path $Root 'InstallPSCorePolicyDefinitions.ps1')
    Copy-FileIfPresent -SourcePath (Join-Path $PowerShellSourceRoot 'assets\GroupPolicy\PowerShellCoreExecutionPolicy.adml') -DestinationPath (Join-Path $Root 'PowerShellCoreExecutionPolicy.adml')
    Copy-FileIfPresent -SourcePath (Join-Path $PowerShellSourceRoot 'assets\GroupPolicy\PowerShellCoreExecutionPolicy.admx') -DestinationPath (Join-Path $Root 'PowerShellCoreExecutionPolicy.admx')
    Copy-FileIfPresent -SourcePath (Join-Path $PowerShellSourceRoot 'src\powershell-win-core\pwsh-preview.cmd') -DestinationPath (Join-Path $Root 'preview\pwsh-preview.cmd')
    Copy-FileIfPresent -SourcePath (Join-Path $PowerShellSourceRoot 'dsc\pwsh.profile.dsc.resource.json') -DestinationPath (Join-Path $Root 'pwsh.profile.dsc.resource.json')
    Copy-FileIfPresent -SourcePath (Join-Path $PowerShellSourceRoot 'dsc\pwsh.profile.resource.ps1') -DestinationPath (Join-Path $Root 'pwsh.profile.resource.ps1')
  }
  Copy-DirectoryIfPresent -SourcePath (Join-Path $PowerShellSourceRoot 'src\Schemas\PSMaml') -DestinationPath (Join-Path $Root 'Schemas\PSMaml')
  Copy-DirectoryIfPresent -SourcePath (Join-Path $PowerShellSourceRoot 'src\Modules\Shared\Microsoft.PowerShell.Host') -DestinationPath (Join-Path $Root 'Modules\Microsoft.PowerShell.Host')

  $PackageRoot = Get-RestoredSdkPackageRoot -PackagesDirectory $PackagesDirectory -PackageId $PackageId -PackageVersion $PackageVersion

  $RuntimeGroup = Get-PackageRuntimeGroup -Rid $RuntimeIdentifier
  $DistroPayloadPackageRoot = Join-Path $PackageRoot "buildTransitive\powershell-distro-payload\$RuntimeIdentifier"
  Copy-FileIfPresent -SourcePath (Join-Path $DistroPayloadPackageRoot 'pwsh.xml') -DestinationPath (Join-Path $Root 'pwsh.xml')
  if ($RuntimeIdentifier -like 'win-*') {
    $WindowsDesktopPayloadRoot = Join-Path $PackageRoot "buildTransitive\windows-desktop-payload\win\lib\$TargetFramework"
    Copy-FileIfPresent -SourcePath (Join-Path $WindowsDesktopPayloadRoot 'Microsoft.PowerShell.GraphicalHost.dll') -DestinationPath (Join-Path $Root 'Microsoft.PowerShell.GraphicalHost.dll')
    Copy-FileIfPresent -SourcePath (Join-Path $WindowsDesktopPayloadRoot 'Microsoft.PowerShell.GraphicalHost.dll.config') -DestinationPath (Join-Path $Root 'Microsoft.PowerShell.GraphicalHost.dll.config')
    Copy-FileIfPresent -SourcePath (Join-Path $WindowsDesktopPayloadRoot 'Microsoft.PowerShell.GraphicalHost.xml') -DestinationPath (Join-Path $Root 'Microsoft.PowerShell.GraphicalHost.xml')
  }
  foreach ($XmlSourceRoot in @(
      (Join-Path $PackageRoot "ref\$TargetFramework"),
      (Join-Path $PackageRoot "runtimes\$RuntimeGroup\lib\$TargetFramework"))) {
    if (-not (Test-Path -LiteralPath $XmlSourceRoot -PathType Container)) {
      continue
    }

    Get-ChildItem -LiteralPath $XmlSourceRoot -Filter '*.xml' -File |
      ForEach-Object {
        $AssemblyName = [System.IO.Path]::ChangeExtension($_.Name, '.dll')
        if (Test-Path -LiteralPath (Join-Path $Root $AssemblyName) -PathType Leaf) {
          Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $Root $_.Name) -Force
        }
      }
  }
}

function Get-RequiredDistroRelativePaths {
  param(
    [Parameter(Mandatory)]
    [string] $Rid
  )

  $ExecutableName = Get-PowerShellExecutableName -Rid $Rid
  $RequiredPaths = @(
    $ExecutableName,
    'LICENSE.txt',
    'ThirdPartyNotices.txt',
    'en-US/default.help.txt',
    'pwsh.dll',
    'pwsh.runtimeconfig.json',
    'pwsh.xml',
    'System.Management.Automation.dll',
    'System.Management.Automation.xml',
    'Microsoft.PowerShell.Commands.Management.xml',
    'Microsoft.PowerShell.ConsoleHost.dll',
    'Schemas/PSMaml/Maml.xsd'
  )
  if ($Rid -like 'win-*') {
    $RequiredPaths += @(
      'Microsoft.PowerShell.GraphicalHost.dll',
      'Microsoft.PowerShell.GraphicalHost.dll.config',
      'Microsoft.PowerShell.GraphicalHost.xml',
      'PowerShell.Core.Instrumentation.man',
      'PowerShellCoreExecutionPolicy.adml',
      'PowerShellCoreExecutionPolicy.admx',
      'PresentationFramework.dll',
      'RegisterManifest.ps1',
      'RegisterMicrosoftUpdate.ps1',
      'System.Windows.Forms.dll',
      'WindowsBase.dll',
      'powershell.config.json',
      'preview/pwsh-preview.cmd',
      'pwsh.profile.dsc.resource.json',
      'pwsh.profile.resource.ps1'
    )
  }

  foreach ($ModuleName in @(
      'Microsoft.PowerShell.Management',
      'Microsoft.PowerShell.Host',
      'Microsoft.PowerShell.Utility',
      'Microsoft.PowerShell.Security',
      'Microsoft.PowerShell.Archive',
      'Microsoft.PowerShell.PSResourceGet',
      'Microsoft.PowerShell.ThreadJob',
      'PackageManagement',
      'PowerShellGet',
      'PSReadLine')) {
    $RequiredPaths += "Modules/$ModuleName/$ModuleName.psd1"
  }
  foreach ($SignedModuleName in @(
      'Microsoft.PowerShell.PSResourceGet',
      'Microsoft.PowerShell.ThreadJob',
      'PSReadLine')) {
    $RequiredPaths += "Modules/$SignedModuleName/.signature.p7s"
  }

  return $RequiredPaths
}

function Test-PowerShellDistroLayout {
  param(
    [Parameter(Mandatory)]
    [string] $Root,

    [Parameter(Mandatory)]
    [string] $Rid,

    [Parameter(Mandatory)]
    [string] $ExpectedVersion
  )

  $ExecutableName = Get-PowerShellExecutableName -Rid $Rid
  foreach ($RelativePath in (Get-RequiredDistroRelativePaths -Rid $Rid)) {
    Assert-RequiredFile -Root $Root -RelativePath $RelativePath
  }

  $CurrentRid = Get-CurrentRuntimeIdentifier
  if ($CurrentRid -ne $Rid) {
    Write-Host "Skipping execution probe for $Rid on $CurrentRid."
    return
  }

  $PwshPath = Join-Path $Root $ExecutableName
  $PwshOutput = & $PwshPath -NoLogo -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()'
  if ($LASTEXITCODE -ne 0) {
    throw "$PwshPath failed with exit code $LASTEXITCODE"
  }

  $ActualVersion = [string] ($PwshOutput | Select-Object -Last 1)
  if ($ActualVersion.Trim() -ne $ExpectedVersion) {
    throw "$PwshPath reported PowerShell version '$ActualVersion', expected '$ExpectedVersion'"
  }

  if ($Rid -like 'win-*') {
    $WindowsDesktopProbe = @'
$ErrorActionPreference = 'Stop'
$pshomePath = [System.IO.Path]::GetFullPath($PSHOME).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
foreach ($assemblyName in 'PresentationFramework', 'System.Windows.Forms', 'WindowsBase') {
  $assembly = [System.Reflection.Assembly]::Load($assemblyName)
  if ([string]::IsNullOrWhiteSpace($assembly.Location)) {
    throw "Assembly '$assemblyName' loaded without a file location."
  }

  $assemblyPath = [System.IO.Path]::GetFullPath($assembly.Location)
  if (-not $assemblyPath.StartsWith($pshomePath, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Assembly '$assemblyName' loaded from '$assemblyPath' instead of '$PSHOME'."
  }
}
'@
    $PreviousDotNetRoot = $Env:DOTNET_ROOT
    $PreviousDotNetRootX64 = $Env:DOTNET_ROOT_X64
    $PreviousMultiLevelLookup = $Env:DOTNET_MULTILEVEL_LOOKUP
    try {
      $Env:DOTNET_ROOT = 'Z:\missing-dotnet-root'
      $Env:DOTNET_ROOT_X64 = 'Z:\missing-dotnet-root-x64'
      $Env:DOTNET_MULTILEVEL_LOOKUP = '0'
      & $PwshPath -NoLogo -NoProfile -NonInteractive -Command $WindowsDesktopProbe
      if ($LASTEXITCODE -ne 0) {
        throw "$PwshPath failed WindowsDesktop self-contained probe with exit code $LASTEXITCODE"
      }
    } finally {
      $Env:DOTNET_ROOT = $PreviousDotNetRoot
      $Env:DOTNET_ROOT_X64 = $PreviousDotNetRootX64
      $Env:DOTNET_MULTILEVEL_LOOKUP = $PreviousMultiLevelLookup
    }
  }
}

function Test-PowerShellDistroArchive {
  param(
    [Parameter(Mandatory)]
    [string] $ArchivePath,

    [Parameter(Mandatory)]
    [string] $Rid,

    [Parameter(Mandatory)]
    [string] $HostBaseName
  )

  $ArchiveEntries = & tar -tf $ArchivePath
  if ($LASTEXITCODE -ne 0) {
    throw "tar -tf $ArchivePath failed with exit code $LASTEXITCODE"
  }

  $NormalizedEntries = @(
    $ArchiveEntries | ForEach-Object {
      $Entry = ([string] $_) -replace '\\', '/'
      $Entry = $Entry -replace '^\./', ''
      $Entry.TrimEnd('/')
    }
  )

  foreach ($RelativePath in (Get-RequiredDistroRelativePaths -Rid $Rid)) {
    if ($NormalizedEntries -notcontains $RelativePath) {
      throw "PowerShell distro archive is missing required entry: $RelativePath"
    }
  }

  foreach ($HostFileName in @(
      $HostBaseName,
      "$HostBaseName.exe",
      "$HostBaseName.dll",
      "$HostBaseName.deps.json",
      "$HostBaseName.runtimeconfig.json",
      "$HostBaseName.pdb")) {
    if ($NormalizedEntries -contains $HostFileName) {
      throw "PowerShell distro archive contains disposable host entry: $HostFileName"
    }
  }
}

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
  $RepositoryRoot = Split-Path -Parent $PSScriptRoot
}

$RepositoryRootPath = (Resolve-Path -LiteralPath $RepositoryRoot).Path
Assert-SdkPackageVersion -ExpectedPowerShellVersion $PowerShellVersion -ActualPackageVersion $PackageVersion
$TargetFramework = Get-PowerShellTargetFramework -Root $RepositoryRootPath
$ExecutableName = Get-PowerShellExecutableName -Rid $RuntimeIdentifier
$OutputDirectoryPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
if ([string]::IsNullOrWhiteSpace($ArchivePath)) {
  $ArchivePath = "$OutputDirectoryPath.tar.gz"
}
$ArchiveFullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ArchivePath)
$ArchiveDirectory = Split-Path -Parent $ArchiveFullPath
if ($ArchiveDirectory) {
  New-Item -Path $ArchiveDirectory -ItemType Directory -Force | Out-Null
}

$TempRoot = if ($Env:RUNNER_TEMP) { $Env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
$WorkRoot = Join-Path $TempRoot "powershell-distro-$([Guid]::NewGuid().ToString('N'))"
$ProjectDirectory = Join-Path $WorkRoot 'project'
$PublishDirectory = Join-Path $WorkRoot 'publish'
$ArchiveValidationDirectory = Join-Path $WorkRoot 'archive-validation'
$PackagesDirectory = Join-Path $WorkRoot 'packages'
$ProjectPath = Join-Path $ProjectDirectory 'PowerShellDistroPackagerHost.csproj'
$NuGetConfigPath = Join-Path $ProjectDirectory 'nuget.config'
$ProgramPath = Join-Path $ProjectDirectory 'Program.cs'
$HostBaseName = 'PowerShellDistroPackagerHost'

$PreviousNuGetPackages = $Env:NUGET_PACKAGES
try {
  New-Item $ProjectDirectory, $PublishDirectory, $PackagesDirectory -ItemType Directory -Force | Out-Null
  $Env:NUGET_PACKAGES = $PackagesDirectory

  $EscapedPackageId = ConvertTo-XmlAttributeValue $PackageId
  $EscapedPackageVersion = ConvertTo-XmlAttributeValue $PackageVersion
  $EscapedPackageSource = ConvertTo-XmlAttributeValue $PackageSource
  $EscapedTargetFramework = ConvertTo-XmlAttributeValue $TargetFramework
  $EscapedRuntimeIdentifier = ConvertTo-XmlAttributeValue $RuntimeIdentifier
  $EscapedHostBaseName = ConvertTo-XmlAttributeValue $HostBaseName
  $EscapedConfigMode = if ($RuntimeIdentifier -like 'win-*') { 'Copy' } else { 'None' }

  $ProjectXml = @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>$EscapedTargetFramework</TargetFramework>
    <RuntimeIdentifier>$EscapedRuntimeIdentifier</RuntimeIdentifier>
    <SelfContained>true</SelfContained>
    <AssemblyName>$EscapedHostBaseName</AssemblyName>
    <PowerShellSDKAppHostLayout>Root</PowerShellSDKAppHostLayout>
    <PowerShellSDKAppHostRuntimeIdentifier>$EscapedRuntimeIdentifier</PowerShellSDKAppHostRuntimeIdentifier>
    <PowerShellSDKPSGalleryModules>All</PowerShellSDKPSGalleryModules>
    <PowerShellSDKXmlDocumentation>Copy</PowerShellSDKXmlDocumentation>
    <PowerShellSDKConfig>$EscapedConfigMode</PowerShellSDKConfig>
    <PowerShellSDKConfigExecutionPolicy>Bypass</PowerShellSDKConfigExecutionPolicy>
    <PowerShellSDKConfigOverwriteExisting>true</PowerShellSDKConfigOverwriteExisting>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="$EscapedPackageId" Version="$EscapedPackageVersion" />
  </ItemGroup>
</Project>
"@
  Set-Content -LiteralPath $ProjectPath -Value $ProjectXml -Encoding utf8
  $Program = @'
using System;
using System.Management.Automation;

Console.WriteLine(typeof(PowerShell).Assembly.GetName().Name);
'@
  Set-Content -LiteralPath $ProgramPath -Value $Program -Encoding utf8

  $NuGetOrgSource = 'https://api.nuget.org/v3/index.json'
  $PackageSourceMatchesNuGetOrg = $PackageSource.TrimEnd('/') -eq $NuGetOrgSource.TrimEnd('/')

  # When a source-built .NET runtime pack is supplied, inject a local folder feed that takes
  # precedence over nuget.org for the Microsoft.NETCore.App ref/runtime packs for this RID.
  # Combined with the stable RuntimeFrameworkVersion passed to restore/publish below, this makes
  # the self-contained publish consume the custom runtime pack without hijacking unrelated host
  # or AspNetCore runtime packs from nuget.org. When the source-built pack version is prerelease
  # (for example 10.0.4-dev), repack it locally as the corresponding stable patch version solely
  # for restore so the SDK can still resolve the stable host/framework packs it needs.
  $UseCustomRuntime = -not [string]::IsNullOrWhiteSpace($CustomRuntimeSource)
  $EffectiveCustomRuntimeSource = $null
  $EffectiveCustomRuntimePackageVersion = $null
  if ($UseCustomRuntime) {
    $EffectiveCustomRuntimePackageVersion = Get-EffectiveCustomRuntimePackageVersion -PackageVersion $CustomRuntimePackageVersion
    $EffectiveCustomRuntimeSource = New-CustomRuntimeFeed `
      -SourceRoot $CustomRuntimeSource `
      -DestinationRoot (Join-Path $WorkRoot 'custom-runtime-feed') `
      -RuntimeIdentifier $RuntimeIdentifier `
      -PackageVersion $CustomRuntimePackageVersion `
      -EffectivePackageVersion $EffectiveCustomRuntimePackageVersion
    $CustomRuntimeSourcePath = (Resolve-Path -LiteralPath $EffectiveCustomRuntimeSource).Path
    $EscapedCustomRuntimeSource = ConvertTo-XmlAttributeValue $CustomRuntimeSourcePath
    $CustomRuntimeSourceLine = "    <add key=`"custom-runtime`" value=`"$EscapedCustomRuntimeSource`" />"
    $CustomRuntimeMappingBlock = @"
    <packageSource key="custom-runtime">
      <package pattern="Microsoft.NETCore.App.Ref" />
      <package pattern="Microsoft.NETCore.App.Runtime.$EscapedRuntimeIdentifier" />
    </packageSource>
"@
    if ($EffectiveCustomRuntimePackageVersion -ne $CustomRuntimePackageVersion) {
      Write-Host "Normalizing custom runtime restore version from $CustomRuntimePackageVersion to $EffectiveCustomRuntimePackageVersion"
    }
  } else {
    $CustomRuntimeSourceLine = $null
    $CustomRuntimeMappingBlock = $null
  }

  if ($PackageSourceMatchesNuGetOrg) {
    if ($UseCustomRuntime) {
      $NuGetConfig = @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    $CustomRuntimeSourceLine
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />
  </packageSources>
  <packageSourceMapping>
$CustomRuntimeMappingBlock
    <packageSource key="nuget.org">
      <package pattern="$EscapedPackageId" />
      <package pattern="*" />
    </packageSource>
  </packageSourceMapping>
</configuration>
"@
    } else {
      $NuGetConfig = @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />
  </packageSources>
  <packageSourceMapping>
    <packageSource key="nuget.org">
      <package pattern="$EscapedPackageId" />
      <package pattern="*" />
    </packageSource>
  </packageSourceMapping>
</configuration>
"@
    }
  } else {
    if ($UseCustomRuntime) {
      $NuGetConfig = @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    $CustomRuntimeSourceLine
    <add key="powershell-sdk" value="$EscapedPackageSource" />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />
  </packageSources>
  <packageSourceMapping>
$CustomRuntimeMappingBlock
    <packageSource key="powershell-sdk">
      <package pattern="$EscapedPackageId" />
    </packageSource>
    <packageSource key="nuget.org">
      <package pattern="*" />
    </packageSource>
  </packageSourceMapping>
</configuration>
"@
    } else {
      $NuGetConfig = @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="powershell-sdk" value="$EscapedPackageSource" />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />
  </packageSources>
  <packageSourceMapping>
    <packageSource key="powershell-sdk">
      <package pattern="$EscapedPackageId" />
    </packageSource>
    <packageSource key="nuget.org">
      <package pattern="*" />
    </packageSource>
  </packageSourceMapping>
</configuration>
"@
    }
  }
  Set-Content -LiteralPath $NuGetConfigPath -Value $NuGetConfig -Encoding utf8

  $RestoreArguments = @('restore', $ProjectPath, '--configfile', $NuGetConfigPath, '--verbosity', 'minimal', '-r', $RuntimeIdentifier, '/p:SelfContained=true')
  if ($UseCustomRuntime) {
    $RestoreArguments += "/p:RuntimeFrameworkVersion=$EffectiveCustomRuntimePackageVersion"
  }
  Invoke-NativeCommand dotnet @RestoreArguments
  $PackageRoot = Get-RestoredSdkPackageRoot -PackagesDirectory $PackagesDirectory -PackageId $PackageId -PackageVersion $PackageVersion
  $RuntimeGroup = Get-PackageRuntimeGroup -Rid $RuntimeIdentifier
  $LocalizedResourceRoot = Join-Path $PackageRoot "buildTransitive\localized-resources\$RuntimeGroup\lib\$TargetFramework"
  $PublishArguments = @(
    'publish',
    $ProjectPath,
    '--no-restore',
    '--nologo',
    '--verbosity',
    'minimal',
    '-c',
    'Release',
    '-r',
    $RuntimeIdentifier,
    '--self-contained',
    'true',
    '-o',
    $PublishDirectory
  )
  if ($UseCustomRuntime) {
    $PublishArguments += "/p:RuntimeFrameworkVersion=$EffectiveCustomRuntimePackageVersion"
  }
  if (Test-Path -LiteralPath $LocalizedResourceRoot -PathType Container) {
    $PublishArguments += '/p:PowerShellSDKLocalizedResources=Copy'
  }
  Invoke-NativeCommand dotnet @PublishArguments

  Remove-Item -LiteralPath $OutputDirectoryPath -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -Path $OutputDirectoryPath -ItemType Directory -Force | Out-Null
  Copy-Item -Path (Join-Path $PublishDirectory '*') -Destination $OutputDirectoryPath -Recurse -Force

  Remove-Item -LiteralPath (Join-Path $OutputDirectoryPath 'runtimes') -Recurse -Force -ErrorAction SilentlyContinue
  Add-WindowsDesktopRuntimePayload `
    -Root $OutputDirectoryPath `
    -RuntimeIdentifier $RuntimeIdentifier `
    -TargetFramework $TargetFramework `
    -PackagesDirectory $PackagesDirectory `
    -NuGetConfigPath $NuGetConfigPath `
    -WorkRoot $WorkRoot
  Add-PowerShellDistroAncillaryFiles `
    -Root $OutputDirectoryPath `
    -RepositoryRoot $RepositoryRootPath `
    -PackagesDirectory $PackagesDirectory `
    -PackageId $PackageId `
    -PackageVersion $PackageVersion `
    -TargetFramework $TargetFramework `
    -RuntimeIdentifier $RuntimeIdentifier

  Remove-DisposableHostFiles -Root $OutputDirectoryPath -HostBaseName $HostBaseName
  Remove-UnneededDistroFiles -Root $OutputDirectoryPath
  if ($ReadyToRun) {
    Optimize-PowerShellDistroReadyToRun `
      -Root $OutputDirectoryPath `
      -Rid $RuntimeIdentifier `
      -TargetFramework $TargetFramework `
      -IncludeFilter $ReadyToRunIncludeFilter `
      -UseCache:$ReadyToRunUseCache `
      -CachePath $ReadyToRunCachePath
  }
  Test-PowerShellDistroLayout -Root $OutputDirectoryPath -Rid $RuntimeIdentifier -ExpectedVersion $PowerShellVersion

  Remove-Item -LiteralPath $ArchiveFullPath -Force -ErrorAction SilentlyContinue
  Invoke-NativeCommand tar @('-czf', $ArchiveFullPath, '-C', $OutputDirectoryPath, '.')
  if (-not (Test-Path -LiteralPath $ArchiveFullPath -PathType Leaf)) {
    throw "PowerShell distro archive was not created: $ArchiveFullPath"
  }
  Test-PowerShellDistroArchive -ArchivePath $ArchiveFullPath -Rid $RuntimeIdentifier -HostBaseName $HostBaseName
  New-Item -Path $ArchiveValidationDirectory -ItemType Directory -Force | Out-Null
  Invoke-NativeCommand tar @('-xzf', $ArchiveFullPath, '-C', $ArchiveValidationDirectory)
  Test-PowerShellDistroLayout -Root $ArchiveValidationDirectory -Rid $RuntimeIdentifier -ExpectedVersion $PowerShellVersion

  Write-Output "Archive=$ArchiveFullPath"
  Write-Output "OutputDirectory=$OutputDirectoryPath"
  Write-Output "RuntimeIdentifier=$RuntimeIdentifier"
  Write-Output "TargetFramework=$TargetFramework"
  Write-Output "Executable=$ExecutableName"
} finally {
  $Env:NUGET_PACKAGES = $PreviousNuGetPackages
  Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
}
