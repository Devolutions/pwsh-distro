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

function Get-RequiredDistroRelativePaths {
  param(
    [Parameter(Mandatory)]
    [string] $Rid,

    [Parameter(Mandatory)]
    [string] $PowerShellVersion
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
    'System.Web.Services.Description.dll',
    'Microsoft.PowerShell.Commands.Management.xml',
    'Microsoft.PowerShell.ConsoleHost.dll',
    'Schemas/PSMaml/Maml.xsd'
  )
  if ($Rid -like 'linux-*') {
    $RequiredPaths += 'libpsl-native.so'
  }
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
      'System.Windows.Forms.dll',
      'WindowsBase.dll',
      'powershell.config.json',
      'preview/pwsh-preview.cmd',
      'pwsh.profile.dsc.resource.json',
      'pwsh.profile.resource.ps1'
    )
    # Upstream removed this script with its MSI packaging in 7.7.
    if ([version] $PowerShellVersion -lt [version] '7.7.0') {
      $RequiredPaths += 'RegisterMicrosoftUpdate.ps1'
    }
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
