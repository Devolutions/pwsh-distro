[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $PackagePath,

  [Parameter(Mandatory)]
  [string] $OutputDirectory,

  [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*$')]
  [string] $PackageId = 'Devolutions.PowerShell.SDK',

  [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*$')]
  [string] $SlimPackageId = "$PackageId.Slim"
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$OptionalDependencyIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($Id in @(
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
    'System.Speech')) {
  [void] $OptionalDependencyIds.Add($Id)
}

function Get-RequiredZipEntry {
  param(
    [Parameter(Mandatory)]
    [System.IO.Compression.ZipArchive] $Zip,

    [Parameter(Mandatory)]
    [string] $Name
  )

  $Entry = $Zip.GetEntry($Name)
  if (-not $Entry) {
    throw "SDK package is missing required entry '$Name'."
  }
  return $Entry
}

function Read-ZipXml {
  param(
    [Parameter(Mandatory)]
    [System.IO.Compression.ZipArchiveEntry] $Entry
  )

  $Document = [System.Xml.XmlDocument]::new()
  $Document.PreserveWhitespace = $true
  $Stream = $Entry.Open()
  try {
    $Document.Load($Stream)
  } finally {
    $Stream.Dispose()
  }
  return $Document
}

function Read-ZipBytes {
  param(
    [Parameter(Mandatory)]
    [System.IO.Compression.ZipArchiveEntry] $Entry
  )

  $Stream = $Entry.Open()
  $Buffer = [System.IO.MemoryStream]::new()
  try {
    $Stream.CopyTo($Buffer)
    return ,$Buffer.ToArray()
  } finally {
    $Buffer.Dispose()
    $Stream.Dispose()
  }
}

function ConvertTo-XmlBytes {
  param(
    [Parameter(Mandatory)]
    [System.Xml.XmlDocument] $Document
  )

  $Buffer = [System.IO.MemoryStream]::new()
  $Settings = [System.Xml.XmlWriterSettings]::new()
  $Settings.Encoding = [System.Text.UTF8Encoding]::new($false)
  $Settings.CloseOutput = $false
  $Writer = [System.Xml.XmlWriter]::Create($Buffer, $Settings)
  try {
    $Document.Save($Writer)
    $Writer.Flush()
    return ,$Buffer.ToArray()
  } finally {
    $Writer.Dispose()
    $Buffer.Dispose()
  }
}

function Set-ZipEntryBytes {
  param(
    [Parameter(Mandatory)]
    [System.IO.Compression.ZipArchive] $Zip,

    [Parameter(Mandatory)]
    [string] $Name,

    [Parameter(Mandatory)]
    [byte[]] $Bytes
  )

  $ExistingEntry = $Zip.GetEntry($Name)
  if ($ExistingEntry) {
    $ExistingEntry.Delete()
  }

  $Entry = $Zip.CreateEntry($Name, [System.IO.Compression.CompressionLevel]::Optimal)
  $Stream = $Entry.Open()
  try {
    $Stream.Write($Bytes, 0, $Bytes.Length)
  } finally {
    $Stream.Dispose()
  }
}

if ($PackageId -eq $SlimPackageId) {
  throw 'The standard and slim SDK package IDs must differ.'
}

$SourcePath = (Resolve-Path -LiteralPath $PackagePath).Path
$OutputPath = (Resolve-Path -LiteralPath $OutputDirectory).Path
Add-Type -AssemblyName System.IO.Compression.FileSystem

$SourceZip = [System.IO.Compression.ZipFile]::OpenRead($SourcePath)
try {
  if ($SourceZip.GetEntry('.signature.p7s')) {
    throw 'The source SDK has a NuGet package signature. Create the slim package before applying a NuGet package signature.'
  }

  $Nuspec = Read-ZipXml -Entry (Get-RequiredZipEntry -Zip $SourceZip -Name "$PackageId.nuspec")
  $NuspecNamespaces = [System.Xml.XmlNamespaceManager]::new($Nuspec.NameTable)
  $NuspecNamespaces.AddNamespace('n', $Nuspec.DocumentElement.NamespaceURI)
  $IdElement = $Nuspec.SelectSingleNode('/n:package/n:metadata/n:id', $NuspecNamespaces)
  $VersionElement = $Nuspec.SelectSingleNode('/n:package/n:metadata/n:version', $NuspecNamespaces)
  $DescriptionElement = $Nuspec.SelectSingleNode('/n:package/n:metadata/n:description', $NuspecNamespaces)
  if (-not $IdElement -or $IdElement.InnerText -ne $PackageId -or -not $VersionElement -or -not $DescriptionElement) {
    throw "Source SDK nuspec does not contain the expected '$PackageId' identity, version, and description."
  }
  $PackageVersion = $VersionElement.InnerText
  if ($PackageVersion -notmatch '^\d+\.\d+\.\d+(?:\.\d+)?$') {
    throw "Unsupported SDK package version '$PackageVersion'."
  }

  $Dependencies = @($Nuspec.SelectNodes('/n:package/n:metadata/n:dependencies//n:dependency', $NuspecNamespaces))
  if (@($Dependencies | Where-Object { $_.GetAttribute('id') -eq 'Microsoft.Windows.Compatibility' }).Count -gt 0) {
    throw 'The source SDK still depends on Microsoft.Windows.Compatibility, which would restore the omitted slim dependencies.'
  }
  $RemovedCount = 0
  foreach ($Dependency in $Dependencies) {
    $DependencyId = $Dependency.GetAttribute('id')
    if ($OptionalDependencyIds.Contains($DependencyId) -or $DependencyId -match '^runtime\..*System\.IO\.Ports$') {
      [void] $Dependency.ParentNode.RemoveChild($Dependency)
      $RemovedCount++
    }
  }
  if ($RemovedCount -eq 0) {
    throw 'No optional SDK dependencies were found to remove from the slim package.'
  }

  $IdElement.InnerText = $SlimPackageId
  $DescriptionElement.InnerText = "$($DescriptionElement.InnerText) Slim variant omitting optional compatibility dependencies."

  $Relationships = Read-ZipXml -Entry (Get-RequiredZipEntry -Zip $SourceZip -Name '_rels/.rels')
  $RelationshipNamespaces = [System.Xml.XmlNamespaceManager]::new($Relationships.NameTable)
  $RelationshipNamespaces.AddNamespace('r', $Relationships.DocumentElement.NamespaceURI)
  $ManifestRelationships = @($Relationships.SelectNodes("/r:Relationships/r:Relationship[@Type='http://schemas.microsoft.com/packaging/2010/07/manifest']", $RelationshipNamespaces))
  $CoreRelationships = @($Relationships.SelectNodes("/r:Relationships/r:Relationship[@Type='http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties']", $RelationshipNamespaces))
  if ($ManifestRelationships.Count -ne 1 -or $ManifestRelationships[0].GetAttribute('Target') -ne "/$PackageId.nuspec" -or $CoreRelationships.Count -ne 1) {
    throw 'Source SDK package relationships do not contain the expected manifest and core-properties entries.'
  }
  $ManifestRelationships[0].SetAttribute('Target', "/$SlimPackageId.nuspec")
  $CorePropertiesPath = $CoreRelationships[0].GetAttribute('Target').TrimStart('/')
  $CoreProperties = Read-ZipXml -Entry (Get-RequiredZipEntry -Zip $SourceZip -Name $CorePropertiesPath)
  $IdentifierElements = @($CoreProperties.SelectNodes("//*[local-name()='identifier' and namespace-uri()='http://purl.org/dc/elements/1.1/']"))
  $CoreDescriptionElements = @($CoreProperties.SelectNodes("//*[local-name()='description' and namespace-uri()='http://purl.org/dc/elements/1.1/']"))
  if ($IdentifierElements.Count -ne 1 -or $IdentifierElements[0].InnerText -ne $PackageId -or $CoreDescriptionElements.Count -ne 1) {
    throw 'Source SDK core properties do not contain the expected identity and description.'
  }
  $IdentifierElements[0].InnerText = $SlimPackageId
  $CoreDescriptionElements[0].InnerText = $DescriptionElement.InnerText
  $TargetsBytes = Read-ZipBytes -Entry (Get-RequiredZipEntry -Zip $SourceZip -Name "buildTransitive/$PackageId.targets")
} finally {
  $SourceZip.Dispose()
}

$DestinationPath = Join-Path $OutputPath "$SlimPackageId.$PackageVersion.nupkg"
if (Test-Path -LiteralPath $DestinationPath) {
  throw "Slim SDK package already exists: $DestinationPath"
}

$Succeeded = $false
$CreatedDestination = $false
try {
  $DestinationStream = [System.IO.File]::Open($DestinationPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
  $CreatedDestination = $true
  try {
    $SourceStream = [System.IO.File]::OpenRead($SourcePath)
    try {
      $SourceStream.CopyTo($DestinationStream)
    } finally {
      $SourceStream.Dispose()
    }
  } finally {
    $DestinationStream.Dispose()
  }
  $Zip = [System.IO.Compression.ZipFile]::Open($DestinationPath, [System.IO.Compression.ZipArchiveMode]::Update)
  try {
    (Get-RequiredZipEntry -Zip $Zip -Name "$PackageId.nuspec").Delete()
    (Get-RequiredZipEntry -Zip $Zip -Name "buildTransitive/$PackageId.targets").Delete()
    Set-ZipEntryBytes -Zip $Zip -Name "$SlimPackageId.nuspec" -Bytes (ConvertTo-XmlBytes -Document $Nuspec)
    Set-ZipEntryBytes -Zip $Zip -Name "buildTransitive/$SlimPackageId.targets" -Bytes $TargetsBytes
    Set-ZipEntryBytes -Zip $Zip -Name '_rels/.rels' -Bytes (ConvertTo-XmlBytes -Document $Relationships)
    Set-ZipEntryBytes -Zip $Zip -Name $CorePropertiesPath -Bytes (ConvertTo-XmlBytes -Document $CoreProperties)
  } finally {
    $Zip.Dispose()
  }
  $Succeeded = $true
} finally {
  if ($CreatedDestination -and -not $Succeeded -and (Test-Path -LiteralPath $DestinationPath)) {
    Remove-Item -LiteralPath $DestinationPath -Force
  }
}

Write-Host "Created $SlimPackageId $PackageVersion with $RemovedCount optional dependency entries omitted."
Write-Output $DestinationPath
