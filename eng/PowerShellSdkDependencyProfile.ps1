$OptionalPowerShellSdkDependencyIds = @(
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

function Test-PowerShellSdkOptionalDependency {
  param(
    [Parameter(Mandatory)]
    [string] $Id
  )

  return $Id -in $OptionalPowerShellSdkDependencyIds -or $Id -match '^runtime\..*System\.IO\.Ports$'
}

function Get-PowerShellCliDependencyVersions {
  param(
    [Parameter(Mandatory)]
    [string] $SdkProjectPath
  )

  if (-not (Test-Path -LiteralPath $SdkProjectPath -PathType Leaf)) {
    throw "PowerShell SDK project was not found. Initialize the pwsh-src submodule first: $SdkProjectPath"
  }

  [xml] $SdkProject = Get-Content -LiteralPath $SdkProjectPath -Raw
  $DependencyVersions = [ordered]@{}
  foreach ($Reference in @($SdkProject.SelectNodes("//*[local-name()='PackageReference']"))) {
    $Id = $Reference.GetAttribute('Include')
    if ([string]::IsNullOrWhiteSpace($Id)) {
      continue
    }
    if ($Id -ne 'Microsoft.Windows.Compatibility' -and -not (Test-PowerShellSdkOptionalDependency -Id $Id)) {
      continue
    }

    $Version = $Reference.GetAttribute('Version')
    if ([string]::IsNullOrWhiteSpace($Version)) {
      $VersionElement = $Reference.SelectSingleNode("*[local-name()='Version']")
      if ($VersionElement) {
        $Version = $VersionElement.InnerText
      }
    }
    if ([string]::IsNullOrWhiteSpace($Version) -or $Version.Contains('$(')) {
      throw "$Id must have an explicit version in $SdkProjectPath."
    }
    if ($DependencyVersions.Contains($Id)) {
      throw "PowerShell SDK project has multiple references to '$Id': $SdkProjectPath"
    }
    $DependencyVersions[$Id] = $Version
  }

  if (-not $DependencyVersions.Contains('Microsoft.Windows.Compatibility')) {
    throw "PowerShell SDK project does not reference Microsoft.Windows.Compatibility: $SdkProjectPath"
  }
  if ($DependencyVersions.Count -le 1) {
    throw "PowerShell SDK project does not reference any optional SDK dependencies: $SdkProjectPath"
  }

  return $DependencyVersions
}
