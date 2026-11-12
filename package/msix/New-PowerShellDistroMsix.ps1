[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $PayloadDirectory,

  [Parameter(Mandatory)]
  [ValidatePattern('^\d+\.\d+\.\d+\.\d+$')]
  [string] $PackageVersion,

  [Parameter(Mandatory)]
  [ValidateSet('x64', 'arm64')]
  [string] $Architecture,

  [Parameter(Mandatory)]
  [string] $OutputDirectory,

  [string] $Publisher,

  [string] $AppInstallerPath
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
  throw 'MSIX packaging requires Windows (MakePri and MakeAppx).'
}

function Find-WindowsSdkTool {
  param(
    [Parameter(Mandatory)]
    [string] $ToolName
  )

  $Command = Get-Command -Name $ToolName -CommandType Application -ErrorAction SilentlyContinue
  if ($null -ne $Command) {
    return $Command.Source
  }

  $HostArch = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq [System.Runtime.InteropServices.Architecture]::Arm64) {
    'arm64'
  } else {
    'x64'
  }
  $Candidates = @(
    Get-ChildItem -Path "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\$HostArch\$ToolName" -File -ErrorAction SilentlyContinue |
      Sort-Object FullName -Descending
  )
  if ($Candidates.Count -eq 0 -and $HostArch -ne 'x64') {
    $Candidates = @(
      Get-ChildItem -Path "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\$ToolName" -File -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending
    )
  }
  if ($Candidates.Count -eq 0) {
    throw "Windows SDK tool '$ToolName' was not found under Program Files (x86)\Windows Kits\10\bin."
  }

  return $Candidates[0].FullName
}

$MsixRoot = $PSScriptRoot
$AssetsRoot = Join-Path $MsixRoot 'assets'
$Payload = (Resolve-Path -LiteralPath $PayloadDirectory -ErrorAction Stop).Path
if (-not (Test-Path -LiteralPath $Payload -PathType Container)) {
  throw "Payload directory was not found: $Payload"
}
foreach ($RequiredFile in 'pwsh.exe', 'pwsh.dll', 'System.Management.Automation.dll', 'LICENSE.txt', 'ThirdPartyNotices.txt') {
  if (-not (Test-Path -LiteralPath (Join-Path $Payload $RequiredFile) -PathType Leaf)) {
    throw "MSIX payload is missing $RequiredFile in $Payload"
  }
}

$ExecutablePath = Join-Path $Payload 'pwsh.exe'
$ExpectedMachine = if ($Architecture -eq 'x64') { 0x8664 } else { 0xAA64 }
$Stream = [System.IO.File]::OpenRead($ExecutablePath)
try {
  $Reader = [System.IO.BinaryReader]::new($Stream)
  if ($Stream.Length -lt 0x40 -or $Reader.ReadUInt16() -ne 0x5A4D) {
    throw "MSIX payload is not a valid PE executable: $ExecutablePath"
  }
  $Stream.Position = 0x3C
  $PeOffset = $Reader.ReadInt32()
  if ($PeOffset -lt 0x40 -or $PeOffset -gt $Stream.Length - 6) {
    throw "MSIX payload has an invalid PE header: $ExecutablePath"
  }
  $Stream.Position = $PeOffset
  if ($Reader.ReadUInt32() -ne 0x00004550) {
    throw "MSIX payload is not a valid PE executable: $ExecutablePath"
  }
  $Machine = $Reader.ReadUInt16()
  if ($Machine -ne $ExpectedMachine) {
    throw "MSIX payload pwsh.exe machine type 0x$($Machine.ToString('X4')) does not match $Architecture (expected 0x$($ExpectedMachine.ToString('X4')))."
  }
} finally {
  $Stream.Dispose()
}

$Version = [version] $PackageVersion
if ("$($Version.Major).$($Version.Minor).$($Version.Build).$($Version.Revision)" -cne $PackageVersion) {
  throw "MSIX package version must not contain leading zeros: '$PackageVersion'."
}
if ($Version.Major -gt 65535 -or $Version.Minor -gt 65535 -or $Version.Build -gt 65535 -or $Version.Revision -gt 65535) {
  throw "MSIX package version components must not exceed 65535: '$PackageVersion'."
}

$ResolvedAppInstallerPath = ''
if (-not [string]::IsNullOrWhiteSpace($AppInstallerPath)) {
  if (-not (Test-Path -LiteralPath $AppInstallerPath -PathType Leaf)) {
    throw "App Installer file was not found: $AppInstallerPath"
  }
  $ResolvedAppInstallerPath = (Resolve-Path -LiteralPath $AppInstallerPath).Path
}

$EffectivePublisher = if (-not [string]::IsNullOrWhiteSpace($Publisher)) {
  $Publisher.Trim()
} else {
  $DllSignature = Get-AuthenticodeSignature -LiteralPath (Join-Path $Payload 'pwsh.dll')
  $ExeSignature = Get-AuthenticodeSignature -LiteralPath $ExecutablePath
  if ($null -ne $DllSignature -and $null -ne $DllSignature.SignerCertificate -and
      -not [string]::IsNullOrWhiteSpace($DllSignature.SignerCertificate.Subject)) {
    $DllSignature.SignerCertificate.Subject
  } elseif ($null -ne $ExeSignature -and $null -ne $ExeSignature.SignerCertificate -and
      -not [string]::IsNullOrWhiteSpace($ExeSignature.SignerCertificate.Subject)) {
    $ExeSignature.SignerCertificate.Subject
  } else {
    'CN=Devolutions Inc.'
  }
}

$Output = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
if ($Output.StartsWith($Payload.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase) -or
    $Output -ieq $Payload) {
  throw "MSIX output must be outside the payload directory: $Output"
}
New-Item -ItemType Directory -Path $Output -Force | Out-Null
$MsixPath = Join-Path $Output "Devolutions-PowerShell-$PackageVersion-win-$Architecture.msix"
if (Test-Path -LiteralPath $MsixPath) {
  throw "MSIX output already exists: $MsixPath"
}

$MakePriPath = Find-WindowsSdkTool -ToolName 'makepri.exe'
$MakeAppxPath = Find-WindowsSdkTool -ToolName 'makeappx.exe'

$TempBase = if ($Env:RUNNER_TEMP) { $Env:RUNNER_TEMP } else { Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Temp' }
if ([string]::IsNullOrWhiteSpace($TempBase) -or -not (Test-Path -LiteralPath $TempBase -PathType Container)) {
  $TempBase = [System.IO.Path]::GetTempPath()
}
$Work = Join-Path $TempBase "pwsh-distro-msix-$([guid]::NewGuid().ToString('N'))"
$StagingDirectory = Join-Path $Work 'staging'
$PriStagingDirectory = Join-Path $Work 'pri'
New-Item -ItemType Directory -Path $StagingDirectory, (Join-Path $StagingDirectory 'assets'), (Join-Path $PriStagingDirectory 'assets') -Force | Out-Null

try {
  Get-ChildItem -LiteralPath $Payload -Force | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $StagingDirectory $_.Name) -Recurse -Force
  }

  $LogoAssets = @(
    'StoreLogo.png',
    'Square150x150Logo.png',
    'Square44x44Logo.png',
    'Square44x44Logo.targetsize-48.png',
    'Square44x44Logo.targetsize-48_altform-unplated.png'
  )
  foreach ($AssetName in $LogoAssets) {
    $SourceAsset = Join-Path $AssetsRoot $AssetName
    if (-not (Test-Path -LiteralPath $SourceAsset -PathType Leaf)) {
      throw "Required MSIX visual asset was not found: $SourceAsset"
    }
    Copy-Item -LiteralPath $SourceAsset -Destination (Join-Path $StagingDirectory "assets\$AssetName") -Force
    Copy-Item -LiteralPath $SourceAsset -Destination (Join-Path $PriStagingDirectory "assets\$AssetName") -Force
  }

  [xml] $Manifest = Get-Content -LiteralPath (Join-Path $AssetsRoot 'AppxManifest.xml') -Raw
  $Namespaces = [System.Xml.XmlNamespaceManager]::new($Manifest.NameTable)
  $Namespaces.AddNamespace('p', 'http://schemas.microsoft.com/appx/manifest/foundation/windows10')
  $Namespaces.AddNamespace('uap13', 'http://schemas.microsoft.com/appx/manifest/uap/windows10/13')

  $Identity = $Manifest.SelectSingleNode('/p:Package/p:Identity', $Namespaces)
  $Identity.SetAttribute('ProcessorArchitecture', $Architecture)
  $Identity.SetAttribute('Publisher', $EffectivePublisher)
  $Identity.SetAttribute('Version', $PackageVersion)

  $Properties = $Manifest.SelectSingleNode('/p:Package/p:Properties', $Namespaces)
  $ExistingAutoUpdate = @($Properties.SelectNodes('uap13:AutoUpdate', $Namespaces))
  foreach ($Node in $ExistingAutoUpdate) {
    [void] $Properties.RemoveChild($Node)
  }

  if ($ResolvedAppInstallerPath) {
    $AutoUpdateNamespace = 'http://schemas.microsoft.com/appx/manifest/uap/windows10/13'
    $AutoUpdate = $Manifest.CreateElement('uap13', 'AutoUpdate', $AutoUpdateNamespace)
    $AppInstallerRef = $Manifest.CreateElement('uap13', 'AppInstaller', $AutoUpdateNamespace)
    $AppInstallerRef.SetAttribute('File', 'Update.appinstaller')
    [void] $AutoUpdate.AppendChild($AppInstallerRef)
    [void] $Properties.AppendChild($AutoUpdate)
    Copy-Item -LiteralPath $ResolvedAppInstallerPath -Destination (Join-Path $StagingDirectory 'Update.appinstaller') -Force
  }

  $WriterSettings = [System.Xml.XmlWriterSettings]::new()
  $WriterSettings.Encoding = [System.Text.UTF8Encoding]::new($false)
  $WriterSettings.Indent = $true
  foreach ($TargetManifestPath in @(
      (Join-Path $StagingDirectory 'AppxManifest.xml'),
      (Join-Path $PriStagingDirectory 'AppxManifest.xml'))) {
    $Writer = [System.Xml.XmlWriter]::Create($TargetManifestPath, $WriterSettings)
    try {
      $Manifest.Save($Writer)
    } finally {
      $Writer.Dispose()
    }
  }

  $PriConfigPath = Join-Path $Work 'priconfig.xml'
  $ResourcesPriPath = Join-Path $StagingDirectory 'resources.pri'
  $ToolOutput = & $MakePriPath createconfig /o /cf $PriConfigPath /dq en-US 2>&1
  if ($LASTEXITCODE -ne 0) {
    $ToolOutput | ForEach-Object { Write-Host $_ }
    throw "makepri createconfig failed with exit code $LASTEXITCODE"
  }
  $ToolOutput = & $MakePriPath new /o /pr $PriStagingDirectory /cf $PriConfigPath /mn (Join-Path $PriStagingDirectory 'AppxManifest.xml') /of $ResourcesPriPath 2>&1
  if ($LASTEXITCODE -ne 0) {
    $ToolOutput | ForEach-Object { Write-Host $_ }
    throw "makepri new failed with exit code $LASTEXITCODE"
  }

  $ToolOutput = & $MakeAppxPath pack /o /h SHA256 /d $StagingDirectory /p $MsixPath 2>&1
  if ($LASTEXITCODE -ne 0) {
    $ToolOutput | ForEach-Object { Write-Host $_ }
    throw "makeappx pack failed for $Architecture with exit code $LASTEXITCODE"
  }

  Write-Host "Built $MsixPath"
} finally {
  Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
}
