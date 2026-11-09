[CmdletBinding()]
param(
  [string] $WorkRoot = (Join-Path ([System.IO.Path]::GetTempPath()) "powershell-sdk-profile-test-$([guid]::NewGuid().ToString('N'))")
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'PowerShellSdkDependencyProfile.ps1')
Add-Type -AssemblyName System.IO.Compression.FileSystem

function New-FixturePackage {
  param(
    [Parameter(Mandatory)]
    [string] $Id,

    [Parameter(Mandatory)]
    [string] $Nuspec,

    [Parameter(Mandatory)]
    [string] $PackageDirectory,

    [string] $StageName = "stage-$Id",

    [string] $AssetPath,

    [string] $AssetContent
  )

  $Stage = Join-Path $WorkRoot $StageName
  New-Item -ItemType Directory -Path $Stage -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $Stage "$Id.nuspec") -Value $Nuspec -Encoding utf8
  if ($AssetPath) {
    $Asset = Join-Path $Stage ($AssetPath -replace '\\', [System.IO.Path]::DirectorySeparatorChar)
    New-Item -ItemType Directory -Path (Split-Path $Asset -Parent) -Force | Out-Null
    Set-Content -LiteralPath $Asset -Value $AssetContent -Encoding utf8NoBOM -NoNewline
  }
  [System.IO.Compression.ZipFile]::CreateFromDirectory($Stage, (Join-Path $PackageDirectory "$Id.7.6.9.nupkg"))
}

function Get-FixtureDependencyMap {
  param(
    [Parameter(Mandatory)]
    [xml] $Nuspec,

    [Parameter(Mandatory)]
    [string] $TargetFramework
  )

  $Namespace = [System.Xml.XmlNamespaceManager]::new($Nuspec.NameTable)
  $Namespace.AddNamespace('n', $Nuspec.DocumentElement.NamespaceURI)
  $Nodes = @($Nuspec.SelectNodes("/n:package/n:metadata/n:dependencies/n:group[@targetFramework='$TargetFramework']/n:dependency", $Namespace))
  $Dependencies = @{}
  foreach ($Node in $Nodes) {
    $Dependencies[$Node.GetAttribute('id')] = $Node.GetAttribute('version')
  }
  return $Dependencies
}

function Assert-FixtureThrows {
  param(
    [Parameter(Mandatory)]
    [scriptblock] $Action,

    [Parameter(Mandatory)]
    [string] $ExpectedMessage
  )

  try {
    & $Action
  } catch {
    if ($_.Exception.Message -like $ExpectedMessage) {
      return
    }
    throw
  }
  throw "Expected an error matching '$ExpectedMessage'."
}

$WorkRoot = [System.IO.Path]::GetFullPath($WorkRoot)
if (Test-Path -LiteralPath $WorkRoot) {
  throw "Test work directory already exists: $WorkRoot"
}
New-Item -ItemType Directory -Path $WorkRoot | Out-Null
try {
  $OptionalIds = @(
    'System.ComponentModel.Composition',
    'System.ComponentModel.Composition.Registration',
    'System.Data.Odbc',
    'System.Data.OleDb',
    'System.Data.SqlClient',
    'System.DirectoryServices.AccountManagement',
    'System.DirectoryServices.Protocols',
    'System.IO.Ports',
    'System.Net.Http.WinHttpHandler',
    'System.Reflection.Context',
    'System.Runtime.Caching',
    'System.Security.Cryptography.Xml',
    'System.ServiceModel.Http',
    'System.ServiceModel.NetFramingBase',
    'System.ServiceModel.NetTcp',
    'System.ServiceModel.Primitives',
    'System.ServiceModel.Syndication',
    'System.Speech',
    'runtime.linux-arm64.runtime.native.System.IO.Ports',
    'runtime.native.System.IO.Ports'
  )
  $OptionalNuspecEntries = @(
    foreach ($Id in $OptionalIds) {
      "      <dependency id=`"$Id`" version=`"1.0.0`" />"
    }
  ) -join "`n"
  $OptionalProjectEntries = @(
    foreach ($Id in $OptionalIds) {
      $Version = switch ($Id) {
        'System.Data.SqlClient' { '4.9.1'; break }
        'System.ServiceModel.Http' { '10.0.652802'; break }
        default { '10.0.14' }
      }
      if ($Id -eq 'System.ServiceModel.Http') {
        "    <PackageReference Include=`"$Id`"><Version>$Version</Version></PackageReference>"
      } else {
        "    <PackageReference Include=`"$Id`" Version=`"$Version`" />"
      }
    }
  ) -join "`n"

  $SourceProject = Join-Path $WorkRoot 'Microsoft.PowerShell.SDK.csproj'
  $SourceProjectXml = @"
<Project>
  <ItemGroup>
    <PackageReference Include="Microsoft.Windows.Compatibility" Version="10.0.14" />
    <PackageReference Include="System.Security.Cryptography.ProtectedData" Version="10.0.14" />
$OptionalProjectEntries
  </ItemGroup>
</Project>
"@
  Set-Content -LiteralPath $SourceProject -Value $SourceProjectXml -Encoding utf8
  $SourcePackages = Join-Path $WorkRoot 'source-packages'
  New-Item -ItemType Directory -Path $SourcePackages | Out-Null
  $SdkNuspec = @"
<package xmlns="http://schemas.microsoft.com/packaging/2013/05/nuspec.xsd">
  <metadata>
    <id>Microsoft.PowerShell.SDK</id>
    <version>7.6.9</version>
    <authors>Microsoft</authors>
    <description>Fixture SDK</description>
    <dependencies>
      <group targetFramework=".NETCoreApp10.0">
        <dependency id="Microsoft.PowerShell.Commands.Utility" version="7.6.9" />
        <dependency id="Microsoft.PowerShell.Native" version="1.0.0" />
        <dependency id="Microsoft.Windows.Compatibility" version="1.0.0" />
        <dependency id="System.Security.Cryptography.ProtectedData" version="1.0.0" />
        <dependency id="System.Text.Json" version="9.0.0" />
$OptionalNuspecEntries
      </group>
      <group targetFramework=".NETCoreApp9.0">
        <dependency id="Microsoft.Windows.Compatibility" version="1.0.0" />
        <dependency id="System.Security.Cryptography.ProtectedData" version="1.0.0" />
        <dependency id="runtime.foo.System.IO.Ports.Extra" version="1.2.3" />
$OptionalNuspecEntries
      </group>
    </dependencies>
  </metadata>
</package>
"@
  $UtilityNuspec = @'
<package xmlns="http://schemas.microsoft.com/packaging/2013/05/nuspec.xsd">
  <metadata>
    <id>Microsoft.PowerShell.Commands.Utility</id>
    <version>7.6.9</version>
    <authors>Microsoft</authors>
    <description>Fixture utility assembly</description>
    <dependencies>
      <group targetFramework=".NETCoreApp10.0">
        <dependency id="Unrelated.Dependency" version="2.3.4" />
        <dependency id="System.Data.SqlClient" version="1.0.0" />
      </group>
    </dependencies>
  </metadata>
</package>
'@
  $CatalogPath = 'contentFiles\any\any\runtimes\unix\lib\net10.0\PowerShellTypeCatalog.bin' -replace '\\', [System.IO.Path]::DirectorySeparatorChar
  New-FixturePackage -Id 'Microsoft.PowerShell.SDK' -Nuspec $SdkNuspec -PackageDirectory $SourcePackages -AssetPath $CatalogPath -AssetContent 'unchanged-type-catalog'
  New-FixturePackage -Id 'Microsoft.PowerShell.Commands.Utility' -Nuspec $UtilityNuspec -PackageDirectory $SourcePackages -AssetPath 'ref\net10.0\TestRuntimeAssembly.dll' -AssetContent 'fixture-assembly'

  $PackageRoot = Join-Path $WorkRoot 'vendored-sdk'
  & (Join-Path $PSScriptRoot 'Vendor-PowerShellSdkPackage.ps1') `
    -PackageRoot $PackageRoot `
    -PowerShellVersion '7.6.9' `
    -PackageVersion '7.6.9.2' `
    -SourcePackageDirectory $SourcePackages `
    -SourceBuiltAssemblyNames @('TestRuntimeAssembly') `
    -SourceBuiltSdkProjectPath $SourceProject

  $NuspecFiles = @(Get-ChildItem -LiteralPath $PackageRoot -Filter '*.nuspec' -File)
  if ($NuspecFiles.Count -ne 1 -or $NuspecFiles[0].Name -ne 'Devolutions.PowerShell.SDK.nuspec') {
    throw 'Vendoring_UsesExistingSdkIdentity failed: expected exactly the existing SDK package identity.'
  }
  [xml] $VendoredNuspec = Get-Content -LiteralPath $NuspecFiles[0].FullName -Raw
  $Namespace = [System.Xml.XmlNamespaceManager]::new($VendoredNuspec.NameTable)
  $Namespace.AddNamespace('n', $VendoredNuspec.DocumentElement.NamespaceURI)
  if ($VendoredNuspec.SelectSingleNode('/n:package/n:metadata/n:id', $Namespace).InnerText -ne 'Devolutions.PowerShell.SDK' -or
      $VendoredNuspec.SelectSingleNode('/n:package/n:metadata/n:version', $Namespace).InnerText -ne '7.6.9.2') {
    throw 'Vendoring_UsesExistingSdkIdentity failed: package metadata changed unexpectedly.'
  }
  Write-Host 'PASS Vendoring_UsesExistingSdkIdentity'

  foreach ($Framework in @('.NETCoreApp10.0', '.NETCoreApp9.0')) {
    $Dependencies = Get-FixtureDependencyMap -Nuspec $VendoredNuspec -TargetFramework $Framework
    foreach ($Id in $OptionalIds + @('Microsoft.Windows.Compatibility')) {
      if ($Dependencies.ContainsKey($Id)) {
        throw "Vendoring_FiltersOptionalDependencies failed: '$Id' remains in '$Framework'."
      }
    }
    if ($Dependencies['System.Security.Cryptography.ProtectedData'] -ne '10.0.14') {
      throw "Vendoring_FiltersOptionalDependencies failed: ProtectedData was removed or its version changed in '$Framework'."
    }
  }
  $Net10Dependencies = Get-FixtureDependencyMap -Nuspec $VendoredNuspec -TargetFramework '.NETCoreApp10.0'
  $Net9Dependencies = Get-FixtureDependencyMap -Nuspec $VendoredNuspec -TargetFramework '.NETCoreApp9.0'
  if ($Net10Dependencies.Count -ne 4 -or $Net10Dependencies['System.Text.Json'] -ne '9.0.0' -or
      $Net10Dependencies['Microsoft.PowerShell.Native'] -ne '1.0.0' -or $Net10Dependencies['Unrelated.Dependency'] -ne '2.3.4' -or
      $Net9Dependencies.Count -ne 2 -or $Net9Dependencies['runtime.foo.System.IO.Ports.Extra'] -ne '1.2.3') {
    throw 'Vendoring_FiltersOptionalDependencies failed: retained dependency metadata changed.'
  }
  Write-Host 'PASS Vendoring_FiltersOptionalDependencies'

  $ExpectedCatalog = Join-Path (Join-Path $WorkRoot 'stage-Microsoft.PowerShell.SDK') $CatalogPath
  $VendoredCatalog = Join-Path $PackageRoot $CatalogPath
  if ((Get-FileHash -LiteralPath $ExpectedCatalog).Hash -ne (Get-FileHash -LiteralPath $VendoredCatalog).Hash) {
    throw 'Vendoring_PreservesTypeCatalog failed: the PowerShell payload changed.'
  }
  Write-Host 'PASS Vendoring_PreservesTypeCatalog'

  $MissingProtectedDataPackages = Join-Path $WorkRoot 'missing-protected-data'
  New-Item -ItemType Directory -Path $MissingProtectedDataPackages | Out-Null
  $MissingProtectedDataNuspec = $SdkNuspec -replace '(?m)^\s*<dependency id="System\.Security\.Cryptography\.ProtectedData"[^>]+/>\s*\r?\n', ''
  New-FixturePackage -Id 'Microsoft.PowerShell.SDK' -Nuspec $MissingProtectedDataNuspec -PackageDirectory $MissingProtectedDataPackages -StageName 'stage-missing-protected-data'
  Copy-Item -LiteralPath (Join-Path $SourcePackages 'Microsoft.PowerShell.Commands.Utility.7.6.9.nupkg') -Destination $MissingProtectedDataPackages
  Assert-FixtureThrows -Action {
    & (Join-Path $PSScriptRoot 'Vendor-PowerShellSdkPackage.ps1') `
      -PackageRoot (Join-Path $WorkRoot 'sdk-missing-protected-data') `
      -PowerShellVersion '7.6.9' `
      -SourcePackageDirectory $MissingProtectedDataPackages `
      -SourceBuiltAssemblyNames @('TestRuntimeAssembly')
  } -ExpectedMessage '*must retain System.Security.Cryptography.ProtectedData*'
  Write-Host 'PASS Vendoring_RejectsMissingProtectedData'

  $NoOptionalPackages = Join-Path $WorkRoot 'no-optional-dependencies'
  New-Item -ItemType Directory -Path $NoOptionalPackages | Out-Null
  New-FixturePackage -Id 'Microsoft.PowerShell.SDK' -Nuspec $SdkNuspec.Replace($OptionalNuspecEntries, '') -PackageDirectory $NoOptionalPackages -StageName 'stage-no-optional-sdk'
  $NoOptionalUtilityNuspec = $UtilityNuspec -replace '(?m)^\s*<dependency id="System\.Data\.SqlClient"[^>]+/>\s*\r?\n', ''
  New-FixturePackage -Id 'Microsoft.PowerShell.Commands.Utility' -Nuspec $NoOptionalUtilityNuspec -PackageDirectory $NoOptionalPackages -StageName 'stage-no-optional-utility' -AssetPath 'ref\net10.0\TestRuntimeAssembly.dll' -AssetContent 'fixture-assembly'
  Assert-FixtureThrows -Action {
    & (Join-Path $PSScriptRoot 'Vendor-PowerShellSdkPackage.ps1') `
      -PackageRoot (Join-Path $WorkRoot 'sdk-no-optional-dependencies') `
      -PowerShellVersion '7.6.9' `
      -SourcePackageDirectory $NoOptionalPackages `
      -SourceBuiltAssemblyNames @('TestRuntimeAssembly')
  } -ExpectedMessage '*No optional SDK dependencies were found*'
  Write-Host 'PASS Vendoring_RejectsMissingOptionalDependencies'

  $CliDependencies = Get-PowerShellCliDependencyVersions -SdkProjectPath $SourceProject
  if ($CliDependencies.Count -ne ($OptionalIds.Count + 1) -or
      $CliDependencies['Microsoft.Windows.Compatibility'] -ne '10.0.14' -or
      $CliDependencies['System.Data.SqlClient'] -ne '4.9.1' -or
      $CliDependencies['System.ServiceModel.Http'] -ne '10.0.652802' -or
      $CliDependencies['System.Security.Cryptography.Xml'] -ne '10.0.14' -or
      $CliDependencies.Contains('System.Security.Cryptography.ProtectedData')) {
    throw 'CliDependencies_RestoreOmittedPackagesAtSourceVersions failed.'
  }
  foreach ($Id in $OptionalIds) {
    if (-not $CliDependencies.Contains($Id)) {
      throw "CliDependencies_RestoreOmittedPackagesAtSourceVersions failed: '$Id' is missing."
    }
  }
  Write-Host 'PASS CliDependencies_RestoreOmittedPackagesAtSourceVersions'

  $InvalidProject = Join-Path $WorkRoot 'invalid.csproj'
  Set-Content -LiteralPath $InvalidProject -Value '<Project><ItemGroup><PackageReference Include="System.Data.SqlClient" Version="4.9.1" /></ItemGroup></Project>' -Encoding utf8
  Assert-FixtureThrows -Action { Get-PowerShellCliDependencyVersions -SdkProjectPath $InvalidProject } -ExpectedMessage '*does not reference Microsoft.Windows.Compatibility*'
  Set-Content -LiteralPath $InvalidProject -Value '<Project><ItemGroup><PackageReference Include="Microsoft.Windows.Compatibility" Version="10.0.14" /><PackageReference Include="System.Data.SqlClient" Version="$(SqlVersion)" /></ItemGroup></Project>' -Encoding utf8
  Assert-FixtureThrows -Action { Get-PowerShellCliDependencyVersions -SdkProjectPath $InvalidProject } -ExpectedMessage '*System.Data.SqlClient must have an explicit version*'
  Set-Content -LiteralPath $InvalidProject -Value '<Project><ItemGroup><PackageReference Include="Microsoft.Windows.Compatibility" Version="10.0.14" /></ItemGroup></Project>' -Encoding utf8
  Assert-FixtureThrows -Action { Get-PowerShellCliDependencyVersions -SdkProjectPath $InvalidProject } -ExpectedMessage '*does not reference any optional SDK dependencies*'
  Write-Host 'PASS CliDependencies_RejectMissingOrUnpinnedReferences'
} finally {
  Remove-Item -LiteralPath $WorkRoot -Recurse -Force
}
