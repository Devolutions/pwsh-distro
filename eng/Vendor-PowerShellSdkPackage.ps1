[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $PackageRoot,

  [Parameter(Mandatory)]
  [string] $PowerShellVersion,

  [string] $PackageVersion = $PowerShellVersion,

  [string] $PackageId = 'Devolutions.PowerShell.SDK',

  [string] $VendorName = 'Devolutions',

  [string] $OriginalVendorName = 'Microsoft',

  [hashtable] $OverlayPathMap,

  [string[]] $SourceBuiltAssemblyNames,

  [hashtable] $SourceBuiltAssemblyDirectoriesByPackagePath,

  [string] $SourcePackageDirectory
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$OriginalPackageId = 'Microsoft.PowerShell.SDK'
$DefaultEmbeddedPackageIds = @(
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

function Get-PackageSourcePath {
  param(
    [Parameter(Mandatory)]
    [string] $Id,

    [Parameter(Mandatory)]
    [string] $Version,

    [Parameter(Mandatory)]
    [string] $DestinationDirectory,

    [string] $LocalPackageDirectory
  )

  if ($LocalPackageDirectory) {
    $LocalPackage = Get-ChildItem -LiteralPath $LocalPackageDirectory -Filter "$Id.$Version*.nupkg" -File |
      Sort-Object LastWriteTime -Descending |
      Select-Object -First 1
    if ($LocalPackage) {
      return $LocalPackage.FullName
    }
  }

  $PackagePath = Join-Path $DestinationDirectory "$Id.$Version.nupkg"
  Invoke-WebRequest "https://www.nuget.org/api/v2/package/$Id/$Version" -OutFile $PackagePath
  return $PackagePath
}

function Expand-Package {
  param(
    [Parameter(Mandatory)]
    [string] $PackagePath,

    [Parameter(Mandatory)]
    [string] $DestinationPath
  )

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [System.IO.Compression.ZipFile]::ExtractToDirectory($PackagePath, $DestinationPath)
}

function Copy-PackagePayload {
  param(
    [Parameter(Mandatory)]
    [string] $SourceRoot,

    [Parameter(Mandatory)]
    [string] $DestinationRoot
  )

  $ExcludedRootItems = @('[Content_Types].xml', '_rels', 'package', '.signature.p7s')
  Get-ChildItem -LiteralPath $SourceRoot -Force |
    Where-Object { $ExcludedRootItems -notcontains $_.Name } |
    ForEach-Object {
      Copy-Item -LiteralPath $_.FullName -Destination $DestinationRoot -Recurse -Force
    }
}

function Get-NuspecPath {
  param(
    [Parameter(Mandatory)]
    [string] $PackageRootPath
  )

  $NuspecFiles = @(Get-ChildItem -LiteralPath $PackageRootPath -Filter '*.nuspec' -File)
  if ($NuspecFiles.Count -ne 1) {
    throw "Expected exactly one nuspec in '$PackageRootPath', found $($NuspecFiles.Count)"
  }

  return $NuspecFiles[0].FullName
}

function Get-NuspecMetadataElement {
  param(
    [Parameter(Mandatory)]
    [xml] $Document,

    [Parameter(Mandatory)]
    [System.Xml.XmlNamespaceManager] $NamespaceManager,

    [Parameter(Mandatory)]
    [string] $Name
  )

  $Element = $Document.SelectSingleNode("/n:package/n:metadata/n:$Name", $NamespaceManager)
  if (-not $Element) {
    throw "The package nuspec is missing required metadata element '$Name'"
  }

  return [System.Xml.XmlElement] $Element
}

function Set-NuspecMetadataText {
  param(
    [Parameter(Mandatory)]
    [xml] $Document,

    [Parameter(Mandatory)]
    [System.Xml.XmlNamespaceManager] $NamespaceManager,

    [Parameter(Mandatory)]
    [string] $Name,

    [Parameter(Mandatory)]
    [string] $Value
  )

  $Element = $Document.SelectSingleNode("/n:package/n:metadata/n:$Name", $NamespaceManager)
  if (-not $Element) {
    $Metadata = $Document.SelectSingleNode('/n:package/n:metadata', $NamespaceManager)
    if (-not $Metadata) {
      throw "The package nuspec is missing metadata"
    }

    $Element = $Document.CreateElement($Name, $Document.DocumentElement.NamespaceURI)
    [void] $Metadata.AppendChild($Element)
  }

  $Element.InnerText = $Value
}

function Compare-PackageVersion {
  param(
    [Parameter(Mandatory)]
    [string] $Left,

    [Parameter(Mandatory)]
    [string] $Right
  )

  try {
    return [version]::Parse($Left).CompareTo([version]::Parse($Right))
  } catch {
    return [string]::CompareOrdinal($Left, $Right)
  }
}

function Add-DependencyRecord {
  param(
    [Parameter(Mandatory)]
    [System.Collections.Specialized.OrderedDictionary] $DependencyGroups,

    [AllowEmptyString()]
    [string] $TargetFramework,

    [Parameter(Mandatory)]
    [string] $Id,

    [Parameter(Mandatory)]
    [string] $Version
  )

  if (-not $DependencyGroups.Contains($TargetFramework)) {
    $DependencyGroups[$TargetFramework] = [ordered]@{}
  }

  $Dependencies = $DependencyGroups[$TargetFramework]
  if (-not $Dependencies.Contains($Id) -or (Compare-PackageVersion -Left $Version -Right $Dependencies[$Id]) -gt 0) {
    $Dependencies[$Id] = $Version
  }
}

function Add-ExternalDependenciesFromNuspec {
  param(
    [Parameter(Mandatory)]
    [string] $NuspecPath,

    [Parameter(Mandatory)]
    [string[]] $EmbeddedIds,

    [Parameter(Mandatory)]
    [System.Collections.Specialized.OrderedDictionary] $DependencyGroups
  )

  [xml] $Nuspec = Get-Content -LiteralPath $NuspecPath
  $NamespaceManager = [System.Xml.XmlNamespaceManager]::new($Nuspec.NameTable)
  $NamespaceManager.AddNamespace('n', $Nuspec.DocumentElement.NamespaceURI)

  $DependencyGroupNodes = @($Nuspec.SelectNodes('/n:package/n:metadata/n:dependencies/n:group', $NamespaceManager))
  foreach ($Group in $DependencyGroupNodes) {
    $TargetFramework = [string] $Group.targetFramework
    foreach ($Dependency in @($Group.SelectNodes('n:dependency', $NamespaceManager))) {
      $DependencyId = [string] $Dependency.id
      if ($EmbeddedIds -contains $DependencyId) {
        continue
      }

      Add-DependencyRecord `
        -DependencyGroups $DependencyGroups `
        -TargetFramework $TargetFramework `
        -Id $DependencyId `
        -Version ([string] $Dependency.version)
    }
  }

  foreach ($Dependency in @($Nuspec.SelectNodes('/n:package/n:metadata/n:dependencies/n:dependency', $NamespaceManager))) {
    $DependencyId = [string] $Dependency.id
    if ($EmbeddedIds -contains $DependencyId) {
      continue
    }

    Add-DependencyRecord `
      -DependencyGroups $DependencyGroups `
      -TargetFramework '' `
      -Id $DependencyId `
      -Version ([string] $Dependency.version)
  }
}

function Get-PackageDependenciesFromNuspec {
  param(
    [Parameter(Mandatory)]
    [string] $NuspecPath
  )

  [xml] $Nuspec = Get-Content -LiteralPath $NuspecPath
  $NamespaceManager = [System.Xml.XmlNamespaceManager]::new($Nuspec.NameTable)
  $NamespaceManager.AddNamespace('n', $Nuspec.DocumentElement.NamespaceURI)

  $Dependencies = @()
  foreach ($Dependency in @($Nuspec.SelectNodes('/n:package/n:metadata/n:dependencies//n:dependency', $NamespaceManager))) {
    $DependencyId = [string] $Dependency.id
    $DependencyVersion = [string] $Dependency.version
    if ([string]::IsNullOrWhiteSpace($DependencyId) -or [string]::IsNullOrWhiteSpace($DependencyVersion)) {
      continue
    }

    $Dependencies += [pscustomobject]@{
      Id = $DependencyId
      Version = $DependencyVersion
    }
  }

  return $Dependencies
}

function Test-PackageDependencyVersionMatchesPowerShell {
  param(
    [Parameter(Mandatory)]
    [string] $DependencyVersion,

    [Parameter(Mandatory)]
    [string] $ExpectedVersion
  )

  $NormalizedDependencyVersion = $DependencyVersion.Trim()
  return $NormalizedDependencyVersion -eq $ExpectedVersion -or $NormalizedDependencyVersion -eq "[$ExpectedVersion]"
}

function Get-PackageAssetAssemblyNames {
  param(
    [Parameter(Mandatory)]
    [string] $PackageRootPath
  )

  $AssemblyNames = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
  $PackageRootFullPath = (Resolve-Path -LiteralPath $PackageRootPath).Path
  foreach ($Assembly in Get-ChildItem -LiteralPath $PackageRootFullPath -Recurse -File -Filter '*.dll') {
    $RelativePath = $Assembly.FullName.Substring($PackageRootFullPath.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $PackageRelativePath = $RelativePath -replace '\\', '/'
    if ($PackageRelativePath -notmatch '^(ref/[^/]+|runtimes/[^/]+/lib/[^/]+)/[^/]+\.dll$') {
      continue
    }

    if (-not $AssemblyNames.Contains($Assembly.BaseName)) {
      $AssemblyNames[$Assembly.BaseName] = $true
    }
  }

  return @($AssemblyNames.Keys)
}

function Resolve-EmbeddedPackageRoots {
  param(
    [Parameter(Mandatory)]
    [string] $PowerShellPackageVersion,

    [Parameter(Mandatory)]
    [string] $PackageCachePath,

    [Parameter(Mandatory)]
    [string] $ExtractedPackagesPath,

    [string] $LocalPackageDirectory,

    [string[]] $SourceAssemblyNames
  )

  $SourceAssemblyNameSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($AssemblyName in @($SourceAssemblyNames)) {
    if (-not [string]::IsNullOrWhiteSpace($AssemblyName)) {
      [void] $SourceAssemblyNameSet.Add($AssemblyName)
    }
  }

  if ($SourceAssemblyNameSet.Count -eq 0) {
    $FallbackPackageRoots = [ordered]@{}
    foreach ($EmbeddedPackageId in $DefaultEmbeddedPackageIds) {
      $PackagePath = Get-PackageSourcePath `
        -Id $EmbeddedPackageId `
        -Version $PowerShellPackageVersion `
        -DestinationDirectory $PackageCachePath `
        -LocalPackageDirectory $LocalPackageDirectory

      $ExtractedPackagePath = Join-Path $ExtractedPackagesPath $EmbeddedPackageId
      Expand-Package -PackagePath $PackagePath -DestinationPath $ExtractedPackagePath
      $FallbackPackageRoots[$EmbeddedPackageId] = $ExtractedPackagePath
    }

    return $FallbackPackageRoots
  }

  $Candidates = [ordered]@{}
  $Pending = [System.Collections.Generic.Queue[string]]::new()
  $Pending.Enqueue($OriginalPackageId)

  while ($Pending.Count -gt 0) {
    $CandidatePackageId = $Pending.Dequeue()
    if ($Candidates.Contains($CandidatePackageId)) {
      continue
    }

    $PackagePath = Get-PackageSourcePath `
      -Id $CandidatePackageId `
      -Version $PowerShellPackageVersion `
      -DestinationDirectory $PackageCachePath `
      -LocalPackageDirectory $LocalPackageDirectory

    $ExtractedPackagePath = Join-Path $ExtractedPackagesPath $CandidatePackageId
    Expand-Package -PackagePath $PackagePath -DestinationPath $ExtractedPackagePath

    $PackageAssetAssemblyNames = @(Get-PackageAssetAssemblyNames -PackageRootPath $ExtractedPackagePath)
    $ContainsSourceBuiltAssembly = $CandidatePackageId -eq $OriginalPackageId
    if (-not $ContainsSourceBuiltAssembly) {
      foreach ($PackageAssetAssemblyName in $PackageAssetAssemblyNames) {
        if ($SourceAssemblyNameSet.Contains($PackageAssetAssemblyName)) {
          $ContainsSourceBuiltAssembly = $true
          break
        }
      }
    }

    $Dependencies = @(Get-PackageDependenciesFromNuspec -NuspecPath (Get-NuspecPath -PackageRootPath $ExtractedPackagePath))
    $Candidates[$CandidatePackageId] = [pscustomobject]@{
      Id = $CandidatePackageId
      Path = $ExtractedPackagePath
      Embedded = $ContainsSourceBuiltAssembly
      Dependencies = $Dependencies
    }

    foreach ($Dependency in $Dependencies) {
      if (-not (Test-PackageDependencyVersionMatchesPowerShell -DependencyVersion $Dependency.Version -ExpectedVersion $PowerShellPackageVersion)) {
        continue
      }
      if (-not $Candidates.Contains($Dependency.Id)) {
        $Pending.Enqueue($Dependency.Id)
      }
    }
  }

  $EmbeddedPackageRoots = [ordered]@{}
  foreach ($Candidate in $Candidates.Values) {
    if ($Candidate.Embedded) {
      $EmbeddedPackageRoots[$Candidate.Id] = $Candidate.Path
    }
  }

  if (-not $EmbeddedPackageRoots.Contains($OriginalPackageId)) {
    throw "Embedded package resolution did not include required root package '$OriginalPackageId'."
  }

  return $EmbeddedPackageRoots
}

function Set-NuspecDependencies {
  param(
    [Parameter(Mandatory)]
    [xml] $Document,

    [Parameter(Mandatory)]
    [System.Xml.XmlNamespaceManager] $NamespaceManager,

    [Parameter(Mandatory)]
    [System.Collections.Specialized.OrderedDictionary] $DependencyGroups
  )

  $Metadata = $Document.SelectSingleNode('/n:package/n:metadata', $NamespaceManager)
  if (-not $Metadata) {
    throw "The package nuspec is missing metadata"
  }

  $Dependencies = $Document.SelectSingleNode('/n:package/n:metadata/n:dependencies', $NamespaceManager)
  if (-not $Dependencies) {
    $Dependencies = $Document.CreateElement('dependencies', $Document.DocumentElement.NamespaceURI)
    [void] $Metadata.AppendChild($Dependencies)
  }

  $Dependencies.RemoveAll()

  foreach ($TargetFramework in @($DependencyGroups.Keys | Sort-Object)) {
    $Group = $Document.CreateElement('group', $Document.DocumentElement.NamespaceURI)
    if ($TargetFramework) {
      $TargetFrameworkAttribute = $Document.CreateAttribute('targetFramework')
      $TargetFrameworkAttribute.Value = $TargetFramework
      [void] $Group.Attributes.Append($TargetFrameworkAttribute)
    }

    $GroupDependencies = $DependencyGroups[$TargetFramework]
    foreach ($DependencyId in @($GroupDependencies.Keys | Sort-Object)) {
      $Dependency = $Document.CreateElement('dependency', $Document.DocumentElement.NamespaceURI)

      $IdAttribute = $Document.CreateAttribute('id')
      $IdAttribute.Value = $DependencyId
      [void] $Dependency.Attributes.Append($IdAttribute)

      $VersionAttribute = $Document.CreateAttribute('version')
      $VersionAttribute.Value = $GroupDependencies[$DependencyId]
      [void] $Dependency.Attributes.Append($VersionAttribute)

      [void] $Group.AppendChild($Dependency)
    }

    [void] $Dependencies.AppendChild($Group)
  }
}

function Update-SdkNuspec {
  param(
    [Parameter(Mandatory)]
    [string] $NuspecPath,

    [Parameter(Mandatory)]
    [string] $NewPackageId,

    [Parameter(Mandatory)]
    [string] $PackageVersion,

    [Parameter(Mandatory)]
    [string] $Vendor,

    [Parameter(Mandatory)]
    [string] $OriginalVendor,

    [Parameter(Mandatory)]
    [System.Collections.Specialized.OrderedDictionary] $DependencyGroups
  )

  [xml] $Nuspec = Get-Content -LiteralPath $NuspecPath
  $NamespaceManager = [System.Xml.XmlNamespaceManager]::new($Nuspec.NameTable)
  $NamespaceManager.AddNamespace('n', $Nuspec.DocumentElement.NamespaceURI)

  $Id = Get-NuspecMetadataElement -Document $Nuspec -NamespaceManager $NamespaceManager -Name 'id'
  if ($Id.InnerText -ne $OriginalPackageId -and $Id.InnerText -ne $NewPackageId) {
    throw "Expected SDK nuspec package id '$OriginalPackageId' or '$NewPackageId', found '$($Id.InnerText)'"
  }

  $Id.InnerText = $NewPackageId
  Set-NuspecMetadataText -Document $Nuspec -NamespaceManager $NamespaceManager -Name 'version' -Value $PackageVersion
  Set-NuspecMetadataText -Document $Nuspec -NamespaceManager $NamespaceManager -Name 'authors' -Value $Vendor
  Set-NuspecMetadataText -Document $Nuspec -NamespaceManager $NamespaceManager -Name 'owners' -Value $Vendor

  $Copyright = $Nuspec.SelectSingleNode('/n:package/n:metadata/n:copyright', $NamespaceManager)
  if ($Copyright) {
    $Copyright.InnerText = $Copyright.InnerText.Replace("$OriginalVendor Corporation", $Vendor).Replace($OriginalVendor, $Vendor)
  }

  Set-NuspecDependencies -Document $Nuspec -NamespaceManager $NamespaceManager -DependencyGroups $DependencyGroups

  $WriterSettings = [System.Xml.XmlWriterSettings]::new()
  $WriterSettings.Encoding = [System.Text.UTF8Encoding]::new($false)
  $WriterSettings.Indent = $true

  $Writer = [System.Xml.XmlWriter]::Create($NuspecPath, $WriterSettings)
  try {
    $Nuspec.Save($Writer)
  } finally {
    $Writer.Dispose()
  }
}

function Copy-OverlayFiles {
  param(
    [Parameter(Mandatory)]
    [string] $Root,

    [Parameter(Mandatory)]
    [hashtable] $PathMap
  )

  foreach ($PackageRelativePath in $PathMap.Keys) {
    $SourcePath = (Resolve-Path -LiteralPath $PathMap[$PackageRelativePath]).Path
    if (-not (Test-Path $SourcePath -PathType Leaf)) {
      throw "Overlay source file does not exist: $SourcePath"
    }

    $DestinationPath = Join-Path $Root ($PackageRelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    $DestinationDirectory = Split-Path $DestinationPath -Parent
    New-Item $DestinationDirectory -ItemType Directory -Force | Out-Null
    Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force
  }
}

function Get-NormalizedDirectoryList {
  param(
    [AllowNull()]
    [object] $Value
  )

  $Directories = @()
  foreach ($Directory in @($Value)) {
    if ([string]::IsNullOrWhiteSpace([string] $Directory)) {
      continue
    }

    $Directories += [string] $Directory
  }

  return $Directories
}

function Find-SourceBuiltPackageFile {
  param(
    [Parameter(Mandatory)]
    [string] $FileName,

    [Parameter(Mandatory)]
    [string[]] $Directories
  )

  foreach ($Directory in $Directories) {
    if ([string]::IsNullOrWhiteSpace($Directory) -or -not (Test-Path -LiteralPath $Directory -PathType Container)) {
      continue
    }

    $CandidatePath = Join-Path $Directory $FileName
    if (Test-Path -LiteralPath $CandidatePath -PathType Leaf) {
      return $CandidatePath
    }
  }

  return $null
}

function Copy-SourceBuiltPackageAssets {
  param(
    [Parameter(Mandatory)]
    [string] $Root,

    [Parameter(Mandatory)]
    [System.Collections.IDictionary] $ExtractedPackageRoots,

    [Parameter(Mandatory)]
    [hashtable] $PackagePathDirectories,

    [Parameter(Mandatory)]
    [AllowEmptyCollection()]
    [string[]] $SourceAssemblyNames
  )

  $SourceAssemblyNameSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($AssemblyName in @($SourceAssemblyNames)) {
    if (-not [string]::IsNullOrWhiteSpace($AssemblyName)) {
      [void] $SourceAssemblyNameSet.Add($AssemblyName)
    }
  }

  if ($SourceAssemblyNameSet.Count -eq 0 -or $PackagePathDirectories.Count -eq 0) {
    return @()
  }

  $CopiedPackageAssets = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($PackageId in @($ExtractedPackageRoots.Keys | Sort-Object)) {
    $ExtractedPackageRoot = (Resolve-Path -LiteralPath $ExtractedPackageRoots[$PackageId]).Path
    foreach ($PackageAssembly in Get-ChildItem -LiteralPath $ExtractedPackageRoot -Recurse -File -Filter '*.dll') {
      $RelativePath = $PackageAssembly.FullName.Substring($ExtractedPackageRoot.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
      $PackageRelativePath = $RelativePath -replace '\\', '/'
      if ($PackageRelativePath -notmatch '^(?<assetDirectory>ref/[^/]+|runtimes/[^/]+/lib/[^/]+)/(?<fileName>[^/]+\.dll)$') {
        continue
      }

      $AssetDirectory = $Matches['assetDirectory']
      $AssemblyName = [System.IO.Path]::GetFileNameWithoutExtension($Matches['fileName'])
      if (-not $SourceAssemblyNameSet.Contains($AssemblyName) -or -not $PackagePathDirectories.ContainsKey($AssetDirectory)) {
        continue
      }

      $SourceDirectories = @(Get-NormalizedDirectoryList -Value $PackagePathDirectories[$AssetDirectory])
      $SourceDllPath = Find-SourceBuiltPackageFile -FileName "$AssemblyName.dll" -Directories $SourceDirectories
      if (-not $SourceDllPath) {
        throw "Package asset '$PackageRelativePath' belongs to source-built assembly '$AssemblyName', but no source-built replacement was found in: $($SourceDirectories -join '; ')"
      }

      foreach ($Extension in @('.dll', '.xml', '.config')) {
        $SourceFilePath = Find-SourceBuiltPackageFile -FileName "$AssemblyName$Extension" -Directories $SourceDirectories
        if (-not $SourceFilePath) {
          continue
        }

        $DestinationRelativePath = "$AssetDirectory/$AssemblyName$Extension"
        $DestinationPath = Join-Path $Root ($DestinationRelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        New-Item (Split-Path $DestinationPath -Parent) -ItemType Directory -Force | Out-Null
        Copy-Item -LiteralPath $SourceFilePath -Destination $DestinationPath -Force
        if (-not $CopiedPackageAssets.Contains($DestinationRelativePath)) {
          $CopiedPackageAssets[$DestinationRelativePath] = $true
        }
      }
    }
  }

  return @($CopiedPackageAssets.Keys)
}

function Write-PackageTextList {
  param(
    [Parameter(Mandatory)]
    [string] $Root,

    [Parameter(Mandatory)]
    [string] $PackageRelativePath,

    [Parameter(Mandatory)]
    [AllowEmptyCollection()]
    [string[]] $Value
  )

  $DestinationPath = Join-Path $Root ($PackageRelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
  New-Item (Split-Path $DestinationPath -Parent) -ItemType Directory -Force | Out-Null
  @($Value | Sort-Object -Unique) | Set-Content -LiteralPath $DestinationPath -Encoding utf8
}

$PackageRootPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PackageRoot)
$TempRoot = if ($Env:RUNNER_TEMP) { $Env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
$WorkDirectory = Join-Path $TempRoot "powershell-sdk-vendor-$([Guid]::NewGuid().ToString('N'))"
$PackageCacheDirectory = Join-Path $WorkDirectory 'packages'
$ExtractedPackagesDirectory = Join-Path $WorkDirectory 'extracted'
$DependencyGroups = [System.Collections.Specialized.OrderedDictionary]::new()

Remove-Item $PackageRootPath -Recurse -Force -ErrorAction SilentlyContinue
New-Item $PackageRootPath -ItemType Directory -Force | Out-Null
New-Item $PackageCacheDirectory, $ExtractedPackagesDirectory -ItemType Directory -Force | Out-Null

try {
  $ExtractedPackageRoots = Resolve-EmbeddedPackageRoots `
    -PowerShellPackageVersion $PowerShellVersion `
    -PackageCachePath $PackageCacheDirectory `
    -ExtractedPackagesPath $ExtractedPackagesDirectory `
    -LocalPackageDirectory $SourcePackageDirectory `
    -SourceAssemblyNames $SourceBuiltAssemblyNames
  $EmbeddedPackageIds = @($ExtractedPackageRoots.Keys)

  foreach ($EmbeddedPackageId in $EmbeddedPackageIds) {
    Add-ExternalDependenciesFromNuspec `
      -NuspecPath (Get-NuspecPath -PackageRootPath $ExtractedPackageRoots[$EmbeddedPackageId]) `
      -EmbeddedIds $EmbeddedPackageIds `
      -DependencyGroups $DependencyGroups
  }

  Copy-PackagePayload -SourceRoot $ExtractedPackageRoots[$OriginalPackageId] -DestinationRoot $PackageRootPath

  $OriginalNuspecPath = Get-NuspecPath -PackageRootPath $PackageRootPath
  $VendoredNuspecPath = Join-Path $PackageRootPath "$PackageId.nuspec"
  if ($OriginalNuspecPath -ne $VendoredNuspecPath) {
    Move-Item -LiteralPath $OriginalNuspecPath -Destination $VendoredNuspecPath -Force
  }

  Update-SdkNuspec `
    -NuspecPath $VendoredNuspecPath `
    -NewPackageId $PackageId `
    -PackageVersion $PackageVersion `
    -Vendor $VendorName `
    -OriginalVendor $OriginalVendorName `
    -DependencyGroups $DependencyGroups

  if ($OverlayPathMap) {
    Copy-OverlayFiles -Root $PackageRootPath -PathMap $OverlayPathMap
  }

  $SourceBuiltPackageAssets = @()
  if ($SourceBuiltAssemblyDirectoriesByPackagePath) {
    $SourceBuiltPackageAssets = Copy-SourceBuiltPackageAssets `
      -Root $PackageRootPath `
      -ExtractedPackageRoots $ExtractedPackageRoots `
      -PackagePathDirectories $SourceBuiltAssemblyDirectoriesByPackagePath `
      -SourceAssemblyNames $SourceBuiltAssemblyNames
  }

  Write-PackageTextList `
    -Root $PackageRootPath `
    -PackageRelativePath 'buildTransitive/embedded-powershell-package-ids.txt' `
    -Value $EmbeddedPackageIds
  Write-PackageTextList `
    -Root $PackageRootPath `
    -PackageRelativePath 'buildTransitive/source-built-package-assets.txt' `
    -Value $SourceBuiltPackageAssets

  Write-Host "Vendored $OriginalPackageId $PowerShellVersion as $PackageId $PackageVersion with embedded PowerShell assemblies"
} finally {
  Remove-Item $WorkDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
