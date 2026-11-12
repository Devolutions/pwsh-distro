[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [ValidateSet('Install', 'Uninstall')]
  [string] $Action,

  [string] $InstallLocation = $PSScriptRoot,

  [string] $CommonApplicationDataDirectory = [Environment]::GetFolderPath('CommonApplicationData')
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($CommonApplicationDataDirectory)) {
  throw 'The common application data directory could not be resolved.'
}

$FragmentDirectory = Join-Path $CommonApplicationDataDirectory 'Microsoft\Windows Terminal\Fragments\Devolutions.PowerShell'
$FragmentPath = Join-Path $FragmentDirectory 'profile.json'

if ($Action -eq 'Install') {
  $InstallLocation = $InstallLocation.Trim().TrimEnd('"')
  if ([string]::IsNullOrWhiteSpace($InstallLocation)) {
    throw 'InstallLocation is required when installing the Windows Terminal profile.'
  }

  $ExecutablePath = Join-Path $InstallLocation 'pwsh.exe'
  if (-not (Test-Path -LiteralPath $ExecutablePath -PathType Leaf)) {
    throw "PowerShell executable was not found: $ExecutablePath"
  }

  $Profile = [ordered]@{
    profiles = @(
      [ordered]@{
        guid = '{346bd64d-48b7-5053-a8ff-5815de1a38c2}'
        name = 'PowerShell'
        commandline = '"' + [System.IO.Path]::GetFullPath($ExecutablePath) + '"'
        icon = 'ms-appx:///ProfileIcons/pwsh.png'
        startingDirectory = '%USERPROFILE%'
      }
    )
  }

  New-Item -ItemType Directory -Path $FragmentDirectory -Force | Out-Null
  $Json = ConvertTo-Json -InputObject $Profile -Depth 4
  [System.IO.File]::WriteAllText(
    $FragmentPath,
    $Json,
    [System.Text.UTF8Encoding]::new($false)
  )
} else {
  if (Test-Path -LiteralPath $FragmentPath -PathType Leaf) {
    Remove-Item -LiteralPath $FragmentPath -Force
  }
  if ((Test-Path -LiteralPath $FragmentDirectory -PathType Container) -and
      -not (Get-ChildItem -LiteralPath $FragmentDirectory -Force | Select-Object -First 1)) {
    Remove-Item -LiteralPath $FragmentDirectory -Force
  }
}
