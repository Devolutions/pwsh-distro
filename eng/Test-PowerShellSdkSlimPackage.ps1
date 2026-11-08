[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $StandardPackagePath,

  [Parameter(Mandatory)]
  [string] $SlimPackagePath,

  [string] $StandardPackageId = 'Devolutions.PowerShell.SDK',

  [string] $SlimPackageId = "$StandardPackageId.Slim"
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$OptionalDependencyIds = @(
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
  'System.Speech'
)

function Read-PackageXml {
  param(
    [Parameter(Mandatory)]
    [System.IO.Compression.ZipArchive] $Zip,

    [Parameter(Mandatory)]
    [string] $EntryName
  )

  $Entry = $Zip.GetEntry($EntryName)
  if (-not $Entry) {
    throw "Package '$($Zip.ToString())' is missing '$EntryName'."
  }
  $Document = [System.Xml.XmlDocument]::new()
  $Stream = $Entry.Open()
  try {
    $Document.Load($Stream)
  } finally {
    $Stream.Dispose()
  }
  return $Document
}

function Get-PackageDependencyMap {
  param(
    [Parameter(Mandatory)]
    [System.Xml.XmlDocument] $Nuspec
  )

  $Namespaces = [System.Xml.XmlNamespaceManager]::new($Nuspec.NameTable)
  $Namespaces.AddNamespace('n', $Nuspec.DocumentElement.NamespaceURI)
  $Dependencies = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($Node in @($Nuspec.SelectNodes('/n:package/n:metadata/n:dependencies//n:dependency', $Namespaces))) {
    $Framework = if ($Node.ParentNode.LocalName -eq 'group') { $Node.ParentNode.GetAttribute('targetFramework') } else { '' }
    $Key = "$Framework|$($Node.GetAttribute('id'))"
    if ($Dependencies.ContainsKey($Key)) {
      throw "Package contains a duplicate dependency '$Key'."
    }
    $Dependencies.Add($Key, $Node.GetAttribute('version'))
  }
  return $Dependencies
}

function Assert-SlimDependencyProfile {
  param(
    [Parameter(Mandatory)]
    [System.Xml.XmlDocument] $StandardNuspec,

    [Parameter(Mandatory)]
    [System.Xml.XmlDocument] $SlimNuspec
  )

  $StandardDependencies = Get-PackageDependencyMap -Nuspec $StandardNuspec
  $SlimDependencies = Get-PackageDependencyMap -Nuspec $SlimNuspec
  $RemovedCount = 0
  $ProtectedDataCount = 0
  foreach ($Key in $StandardDependencies.Keys) {
    $Id = ($Key -split '\|', 2)[1]
    $Optional = $Id -in $OptionalDependencyIds -or $Id -match '^runtime\..*System\.IO\.Ports$'
    if ($Optional) {
      if ($SlimDependencies.ContainsKey($Key)) {
        throw "Slim SDK still declares optional dependency '$Key'."
      }
      $RemovedCount++
      continue
    }
    if (-not $SlimDependencies.ContainsKey($Key) -or $SlimDependencies[$Key] -ne $StandardDependencies[$Key]) {
      throw "Slim SDK changed required dependency '$Key'."
    }
    if ($Id -eq 'System.Security.Cryptography.ProtectedData') {
      $ProtectedDataCount++
    }
  }
  foreach ($Key in $SlimDependencies.Keys) {
    if (-not $StandardDependencies.ContainsKey($Key)) {
      throw "Slim SDK added an unexpected dependency '$Key'."
    }
  }
  if ($RemovedCount -eq 0 -or $ProtectedDataCount -eq 0) {
    throw 'Slim SDK must omit optional dependencies while retaining System.Security.Cryptography.ProtectedData.'
  }
  Write-Host "PASS Assert-SlimDependencyProfile: omitted $RemovedCount dependency entries and retained PowerShell's required dependencies."
}

function Assert-PackageIdentity {
  param(
    [Parameter(Mandatory)]
    [System.IO.Compression.ZipArchive] $Zip,

    [Parameter(Mandatory)]
    [string] $PackageId,

    [Parameter(Mandatory)]
    [string] $ExpectedVersion
  )

  $Nuspec = Read-PackageXml -Zip $Zip -EntryName "$PackageId.nuspec"
  $Namespaces = [System.Xml.XmlNamespaceManager]::new($Nuspec.NameTable)
  $Namespaces.AddNamespace('n', $Nuspec.DocumentElement.NamespaceURI)
  $Id = $Nuspec.SelectSingleNode('/n:package/n:metadata/n:id', $Namespaces)
  $Version = $Nuspec.SelectSingleNode('/n:package/n:metadata/n:version', $Namespaces)
  if (-not $Id -or $Id.InnerText -ne $PackageId -or -not $Version -or $Version.InnerText -ne $ExpectedVersion) {
    throw "Package nuspec does not identify $PackageId $ExpectedVersion."
  }

  $Relationships = Read-PackageXml -Zip $Zip -EntryName '_rels/.rels'
  $RelationshipNamespaces = [System.Xml.XmlNamespaceManager]::new($Relationships.NameTable)
  $RelationshipNamespaces.AddNamespace('r', $Relationships.DocumentElement.NamespaceURI)
  $Manifest = @($Relationships.SelectNodes("/r:Relationships/r:Relationship[@Type='http://schemas.microsoft.com/packaging/2010/07/manifest']", $RelationshipNamespaces))
  $Core = @($Relationships.SelectNodes("/r:Relationships/r:Relationship[@Type='http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties']", $RelationshipNamespaces))
  if ($Manifest.Count -ne 1 -or $Manifest[0].GetAttribute('Target') -ne "/$PackageId.nuspec" -or $Core.Count -ne 1) {
    throw "Package relationships do not identify $PackageId."
  }
  $CorePath = $Core[0].GetAttribute('Target').TrimStart('/')
  $Properties = Read-PackageXml -Zip $Zip -EntryName $CorePath
  $Identifiers = @($Properties.SelectNodes("//*[local-name()='identifier' and namespace-uri()='http://purl.org/dc/elements/1.1/']"))
  if ($Identifiers.Count -ne 1 -or $Identifiers[0].InnerText -ne $PackageId) {
    throw "Package core properties do not identify $PackageId."
  }
  return $CorePath
}

function Get-ZipEntryHash {
  param(
    [Parameter(Mandatory)]
    [System.IO.Compression.ZipArchiveEntry] $Entry
  )

  $Stream = $Entry.Open()
  try {
    return [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($Stream))
  } finally {
    $Stream.Dispose()
  }
}

function Assert-SlimPayloadMatches {
  param(
    [Parameter(Mandatory)]
    [System.IO.Compression.ZipArchive] $StandardZip,

    [Parameter(Mandatory)]
    [System.IO.Compression.ZipArchive] $SlimZip,

    [Parameter(Mandatory)]
    [string] $CorePropertiesPath
  )

  $ExpectedNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  foreach ($Entry in $StandardZip.Entries) {
    $ExpectedName = switch ($Entry.FullName) {
      "$StandardPackageId.nuspec" { "$SlimPackageId.nuspec"; break }
      "buildTransitive/$StandardPackageId.targets" { "buildTransitive/$SlimPackageId.targets"; break }
      default { $Entry.FullName }
    }
    if (-not $ExpectedNames.Add($ExpectedName)) {
      throw "Duplicate package entry '$ExpectedName'."
    }
    $SlimEntry = $SlimZip.GetEntry($ExpectedName)
    if (-not $SlimEntry) {
      throw "Slim SDK is missing package entry '$ExpectedName'."
    }
    if ($Entry.FullName -in @("$StandardPackageId.nuspec", '_rels/.rels', $CorePropertiesPath)) {
      continue
    }
    if ((Get-ZipEntryHash -Entry $Entry) -ne (Get-ZipEntryHash -Entry $SlimEntry)) {
      throw "Slim SDK changed package payload '$ExpectedName'."
    }
  }
  foreach ($Entry in $SlimZip.Entries) {
    if (-not $ExpectedNames.Contains($Entry.FullName)) {
      throw "Slim SDK added unexpected package entry '$($Entry.FullName)'."
    }
  }
  Write-Host "PASS Assert-SlimPayloadMatches: package assets and signed payloads match the standard SDK."
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$StandardZip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $StandardPackagePath).Path)
$SlimZip = $null
try {
  $SlimZip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $SlimPackagePath).Path)
  $StandardNuspec = Read-PackageXml -Zip $StandardZip -EntryName "$StandardPackageId.nuspec"
  $SlimNuspec = Read-PackageXml -Zip $SlimZip -EntryName "$SlimPackageId.nuspec"
  $Namespaces = [System.Xml.XmlNamespaceManager]::new($StandardNuspec.NameTable)
  $Namespaces.AddNamespace('n', $StandardNuspec.DocumentElement.NamespaceURI)
  $VersionElement = $StandardNuspec.SelectSingleNode('/n:package/n:metadata/n:version', $Namespaces)
  if (-not $VersionElement) {
    throw 'Standard SDK nuspec does not contain a package version.'
  }
  $StandardCorePath = Assert-PackageIdentity -Zip $StandardZip -PackageId $StandardPackageId -ExpectedVersion $VersionElement.InnerText
  $SlimCorePath = Assert-PackageIdentity -Zip $SlimZip -PackageId $SlimPackageId -ExpectedVersion $VersionElement.InnerText
  if ($StandardCorePath -ne $SlimCorePath) {
    throw 'The SDK package core-properties paths differ.'
  }
  Write-Host 'PASS Assert-PackageIdentity: both SDK package identities and versions are valid.'
  Assert-SlimDependencyProfile -StandardNuspec $StandardNuspec -SlimNuspec $SlimNuspec
  Assert-SlimPayloadMatches -StandardZip $StandardZip -SlimZip $SlimZip -CorePropertiesPath $StandardCorePath
} finally {
  if ($SlimZip) {
    $SlimZip.Dispose()
  }
  $StandardZip.Dispose()
}
