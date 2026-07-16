[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $PayloadDirectory,

  [string] $Configuration = 'Debug'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ClientDirectory = Join-Path $RepositoryRoot 'src\Devolutions.PowerShell.SDK.NativeAot'
$BridgeProject = Join-Path $RepositoryRoot 'bridge\Devolutions.PowerShell.WorkerBridge\Devolutions.PowerShell.WorkerBridge.csproj'
$BridgeAssembly = Join-Path $RepositoryRoot "bridge\Devolutions.PowerShell.WorkerBridge\bin\$Configuration\net10.0\Devolutions.PowerShell.WorkerBridge.dll"
$SampleProject = Join-Path $RepositoryRoot 'samples\NativeAotPowerShellSample\NativeAotPowerShellSample.csproj'
$BrokerDirectory = Join-Path $RepositoryRoot "native\target\$Configuration"
$PayloadManifestTool = Join-Path $RepositoryRoot 'pack\Devolutions.PowerShell.SDK.NativeAot\tools\New-NativeAotPayloadManifest.ps1'
$PackageProject = Join-Path $RepositoryRoot 'pack\Devolutions.PowerShell.SDK.NativeAot\Devolutions.PowerShell.SDK.NativeAot.csproj'
$TemporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("devolutions-pwsh-nativeaot-" + [guid]::NewGuid().ToString('N'))
$StagedPayloadDirectory = Join-Path $TemporaryRoot 'payload'
$PackageOutputDirectory = Join-Path $TemporaryRoot 'package'
$ConsumerDirectory = Join-Path $TemporaryRoot 'consumer'
$OriginalNugetPackages = $env:NUGET_PACKAGES

if ($IsWindows) {
  $RuntimeIdentifier = 'win-x64'
  $WorkerFile = 'devolutions-pwsh-worker.exe'
  $BrokerFile = 'devolutions_pwsh_broker.dll'
  $SampleFile = 'NativeAotPowerShellSample.exe'
  $ConsumerFile = 'NativeAotPackageConsumer.exe'
}
elseif ($IsLinux) {
  $RuntimeIdentifier = 'linux-x64'
  $WorkerFile = 'devolutions-pwsh-worker'
  $BrokerFile = 'libdevolutions_pwsh_broker.so'
  $SampleFile = 'NativeAotPowerShellSample'
  $ConsumerFile = 'NativeAotPackageConsumer'
}
else {
  throw "The NativeAOT contract test supports only win-x64 and linux-x64, not '$($PSVersionTable.OS)'."
}

$WorkerPath = Join-Path $BrokerDirectory $WorkerFile
$SampleExecutable = Join-Path $RepositoryRoot "samples\NativeAotPowerShellSample\bin\$Configuration\net10.0\$RuntimeIdentifier\publish\$SampleFile"

try {
  $ClientSources = Get-ChildItem -LiteralPath $ClientDirectory -Filter '*.cs' -File -Recurse
  if ($ClientSources | Select-String -Pattern 'System\.Management\.Automation') {
    throw 'The NativeAOT client must not reference System.Management.Automation.'
  }

  $CargoArguments = @('build', '--manifest-path', (Join-Path $RepositoryRoot 'native\Cargo.toml'))
  if ($Configuration -eq 'Release') {
    $CargoArguments += '--release'
  }
  & cargo @CargoArguments
  if ($LASTEXITCODE -ne 0) {
    throw "cargo build failed with exit code $LASTEXITCODE"
  }

  & dotnet build (Join-Path $ClientDirectory 'Devolutions.PowerShell.SDK.NativeAot.csproj') -c $Configuration
  if ($LASTEXITCODE -ne 0) {
    throw "NativeAOT client build failed with exit code $LASTEXITCODE"
  }

  & dotnet build $BridgeProject -c $Configuration
  if ($LASTEXITCODE -ne 0) {
    throw "WorkerBridge build failed with exit code $LASTEXITCODE"
  }
  if (-not (Test-Path -LiteralPath $BridgeAssembly -PathType Leaf)) {
    throw "WorkerBridge assembly was not produced: $BridgeAssembly"
  }
  if (-not (Test-Path -LiteralPath $WorkerPath -PathType Leaf)) {
    throw "Worker executable was not produced: $WorkerPath"
  }

  New-Item -ItemType Directory -Path $StagedPayloadDirectory -Force | Out-Null
  if ($IsLinux) {
    $PayloadRoot = (Resolve-Path -LiteralPath $PayloadDirectory).Path
    foreach ($file in Get-ChildItem -LiteralPath $PayloadRoot -File -Recurse -Force) {
      if ($file.LinkType) {
        continue
      }

      $relativePath = [System.IO.Path]::GetRelativePath($PayloadRoot, $file.FullName)
      $destinationPath = Join-Path $StagedPayloadDirectory $relativePath
      New-Item -ItemType Directory -Path (Split-Path -Parent $destinationPath) -Force | Out-Null
      Copy-Item -LiteralPath $file.FullName -Destination $destinationPath -Force
    }
  }
  else {
    Copy-Item -Path (Join-Path $PayloadDirectory '*') -Destination $StagedPayloadDirectory -Recurse -Force
  }
  & $PayloadManifestTool -PayloadDirectory $StagedPayloadDirectory -WorkerBridgePath $BridgeAssembly -RuntimeIdentifier $RuntimeIdentifier
  if ($LASTEXITCODE -ne 0) {
    throw "Payload manifest staging failed with exit code $LASTEXITCODE"
  }

  $BridgeProbeOutput = & $WorkerPath --probe-bridge $StagedPayloadDirectory $BridgeAssembly
  if ($LASTEXITCODE -ne 0 -or $BridgeProbeOutput -notcontains 'WorkerBridge ABI: 2') {
    throw "WorkerBridge injection probe failed: $BridgeProbeOutput"
  }

  $env:PATH = "$BrokerDirectory$([System.IO.Path]::PathSeparator)$env:PATH"
  if ($IsLinux) {
    $env:LD_LIBRARY_PATH = "$BrokerDirectory$([System.IO.Path]::PathSeparator)$env:LD_LIBRARY_PATH"
  }
  & dotnet publish $SampleProject -c $Configuration -r $RuntimeIdentifier --self-contained true
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $SampleExecutable -PathType Leaf)) {
    throw 'NativeAOT sample publish failed.'
  }

  $SampleOutput = & $SampleExecutable $StagedPayloadDirectory $WorkerPath $BridgeAssembly
  if ($LASTEXITCODE -ne 0) {
    throw "NativeAOT broker/worker contract failed: $SampleOutput"
  }
  $ExpectedSampleOutput = @(
    'Worker connection: Success',
    'Script execution: Success',
    'Script output: nativeaot-script-architecture-gate',
    'Stream terminal: Succeeded',
    'Nonterminating invocation: Success (Succeeded)',
    'Terminating invocation: Success (Failed)',
    'Cancelled invocation: Success (Cancelled)',
    'Deadline invocation: Success (Cancelled)',
    'Sequential invocation: Success (Succeeded)',
    'Unsupported invocation: Success (Failed)',
    'Connection disposal: Success',
    'Concurrent sessions: Success'
  )
  foreach ($ExpectedOutput in $ExpectedSampleOutput) {
    if ($SampleOutput -notcontains $ExpectedOutput) {
      throw "NativeAOT contract output was missing: $ExpectedOutput"
    }
  }
  if (-not ($SampleOutput | Where-Object { $_ -like 'Disposal race: Success*' })) {
    throw "NativeAOT disposal/cancellation race contract failed: $SampleOutput"
  }

  & dotnet pack $PackageProject -c $Configuration -o $PackageOutputDirectory
  if ($LASTEXITCODE -ne 0) {
    throw "NativeAOT package staging failed with exit code $LASTEXITCODE"
  }
  $Package = Get-ChildItem -LiteralPath $PackageOutputDirectory -Filter 'Devolutions.PowerShell.SDK.NativeAot.*.nupkg' -File |
    Select-Object -First 1
  if ($null -eq $Package) {
    throw 'NativeAOT package staging did not produce an nupkg.'
  }

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $Archive = [System.IO.Compression.ZipFile]::OpenRead($Package.FullName)
  try {
    $PackageEntries = $Archive.Entries.FullName
    $ExpectedEntries = @(
      'lib/net10.0/Devolutions.PowerShell.SDK.NativeAot.dll',
      "runtimes/$RuntimeIdentifier/native/$BrokerFile",
      "runtimes/$RuntimeIdentifier/native/$WorkerFile",
      "runtimes/$RuntimeIdentifier/native/Devolutions.PowerShell.WorkerBridge.dll",
      "runtimes/$RuntimeIdentifier/native/devolutions-pwsh-nativeaot-assets.json",
      'buildTransitive/Devolutions.PowerShell.SDK.NativeAot.targets',
      'docs/nativeaot-sdk-contract.md',
      'README.md'
    )
    foreach ($ExpectedEntry in $ExpectedEntries) {
      if ($PackageEntries -notcontains $ExpectedEntry) {
        throw "NativeAOT package is missing required asset: $ExpectedEntry"
      }
    }
  }
  finally {
    $Archive.Dispose()
  }

  New-Item -ItemType Directory -Path $ConsumerDirectory -Force | Out-Null
  $env:NUGET_PACKAGES = Join-Path $ConsumerDirectory 'packages'
  @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net10.0</TargetFramework>
    <RuntimeIdentifier>__RUNTIME_IDENTIFIER__</RuntimeIdentifier>
    <PublishAot>true</PublishAot>
    <SelfContained>true</SelfContained>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
    <DevolutionsPowerShellNativeAotEnabled>true</DevolutionsPowerShellNativeAotEnabled>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Devolutions.PowerShell.SDK.NativeAot" Version="1.0.0" />
  </ItemGroup>
</Project>
'@.Replace('__RUNTIME_IDENTIFIER__', $RuntimeIdentifier) | Set-Content -LiteralPath (Join-Path $ConsumerDirectory 'NativeAotPackageConsumer.csproj') -Encoding utf8NoBOM
  @'
using System;
using System.IO;
using Devolutions.PowerShell.NativeAot;

string assetDirectory = AppContext.BaseDirectory;
var options = new PowerShellSessionOptions
{
    PayloadDirectory = args[0],
    WorkerPath = Path.Combine(assetDirectory, "__WORKER_FILE__"),
    WorkerBridgePath = Path.Combine(assetDirectory, "Devolutions.PowerShell.WorkerBridge.dll"),
};

NativeStatus status = PowerShellSession.TryStartWorkerConnection(
    options,
    TimeSpan.FromSeconds(30),
    out PowerShellWorkerConnection? connection);
using (connection)
{
    if (status != NativeStatus.Success || connection is null)
    {
        return (int)status;
    }

    status = connection.ExecuteScript("'packaged-nativeaot-payload'", TimeSpan.FromSeconds(5), out string? output);
    if (status != NativeStatus.Success || output != "packaged-nativeaot-payload")
    {
        return (int)(status == NativeStatus.Success ? NativeStatus.ProtocolViolation : status);
    }
}

Console.WriteLine("Packaged consumer: Success");
return 0;
'@.Replace('__WORKER_FILE__', $WorkerFile) | Set-Content -LiteralPath (Join-Path $ConsumerDirectory 'Program.cs') -Encoding utf8NoBOM
  @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <config>
    <add key="globalPackagesFolder" value="$ConsumerDirectory\packages" />
  </config>
  <packageSources>
    <clear />
    <add key="nativeaot-package" value="$PackageOutputDirectory" />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />
  </packageSources>
</configuration>
"@ | Set-Content -LiteralPath (Join-Path $ConsumerDirectory 'NuGet.Config') -Encoding utf8NoBOM

  & dotnet publish (Join-Path $ConsumerDirectory 'NativeAotPackageConsumer.csproj') -c $Configuration -r $RuntimeIdentifier --self-contained true "-p:RestoreConfigFile=$(Join-Path $ConsumerDirectory 'NuGet.Config')"
  if ($LASTEXITCODE -ne 0) {
    throw "Clean NativeAOT package consumer publish failed with exit code $LASTEXITCODE"
  }
  $ConsumerExecutable = Join-Path $ConsumerDirectory "bin\$Configuration\net10.0\$RuntimeIdentifier\publish\$ConsumerFile"
  $ConsumerOutput = & $ConsumerExecutable $StagedPayloadDirectory
  if ($LASTEXITCODE -ne 0 -or $ConsumerOutput -notcontains 'Packaged consumer: Success') {
    throw "Clean NativeAOT package consumer failed: $ConsumerOutput"
  }
}
finally {
  if ($null -eq $OriginalNugetPackages) {
    Remove-Item Env:NUGET_PACKAGES -ErrorAction SilentlyContinue
  }
  else {
    $env:NUGET_PACKAGES = $OriginalNugetPackages
  }
  Remove-Item -LiteralPath $TemporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}
