Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'PowerShellDistroLayout.ps1')

$Cases = @(
  @{ Name = 'LtsWindowsX64RequiresUpdateScript'; Rid = 'win-x64'; Version = '7.6.10'; RequiresUpdate = $true },
  @{ Name = 'LtsWindowsArm64RequiresUpdateScript'; Rid = 'win-arm64'; Version = '7.6.10'; RequiresUpdate = $true },
  @{ Name = 'StsWindowsX64OmitsUpdateRequirement'; Rid = 'win-x64'; Version = '7.7.0'; RequiresUpdate = $false },
  @{ Name = 'StsWindowsArm64OmitsUpdateRequirement'; Rid = 'win-arm64'; Version = '7.7.0'; RequiresUpdate = $false },
  @{ Name = 'StsWindowsPatchOmitsUpdateRequirement'; Rid = 'win-x64'; Version = '7.7.1'; RequiresUpdate = $false },
  @{ Name = 'LinuxLtsOmitsWindowsRequirements'; Rid = 'linux-x64'; Version = '7.6.10'; RequiresUpdate = $false },
  @{ Name = 'LinuxStsOmitsWindowsRequirements'; Rid = 'linux-x64'; Version = '7.7.0'; RequiresUpdate = $false },
  @{ Name = 'MacStsOmitsWindowsRequirements'; Rid = 'osx-arm64'; Version = '7.7.0'; RequiresUpdate = $false }
)

foreach ($Case in $Cases) {
  $RequiredPaths = @(Get-RequiredDistroRelativePaths -Rid $Case.Rid -PowerShellVersion $Case.Version)
  if (($RequiredPaths -contains 'RegisterMicrosoftUpdate.ps1') -ne $Case.RequiresUpdate) {
    throw "$($Case.Name): unexpected Microsoft Update script requirement."
  }
  if (($RequiredPaths -contains 'RegisterManifest.ps1') -ne ($Case.Rid -like 'win-*')) {
    throw "$($Case.Name): unexpected Windows manifest script requirement."
  }
  Write-Host "PASS $($Case.Name)"
}

$LtsPaths = @(Get-RequiredDistroRelativePaths -Rid 'win-x64' -PowerShellVersion '7.6.10')
$StsPaths = @(Get-RequiredDistroRelativePaths -Rid 'win-x64' -PowerShellVersion '7.7.0')
$Differences = @(Compare-Object -ReferenceObject $LtsPaths -DifferenceObject $StsPaths)
if ($Differences.Count -ne 1 -or
    $Differences[0].InputObject -ne 'RegisterMicrosoftUpdate.ps1' -or
    $Differences[0].SideIndicator -ne '<=') {
  throw 'Only the Microsoft Update registration script should differ between 7.6 and 7.7 Windows requirements.'
}
Write-Host 'PASS WindowsRequirementsDifferOnlyByUpdateScript'
