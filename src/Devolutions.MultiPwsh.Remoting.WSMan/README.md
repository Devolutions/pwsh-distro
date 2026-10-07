# Payload-local WSMan provider scaffold

This directory belongs to the PowerShell source history on `downstream/v7.6.6`,
not the distribution scripts on `master`.
The distribution pins a source commit, builds this project separately against
the Devolutions-patched SDK, and stages its assembly, provider manifest, and
options schema into each managed payload.
The companion tests live in `test\Devolutions.MultiPwsh.Remoting.WSMan.Tests`.
Neither project is part of the PowerShell engine's project-reference graph or
the existing `test\xUnit` runner.
Distribution validation invokes the provider test project explicitly.

## Contract and scope

The public adapter type is
`Devolutions.MultiPwsh.Remoting.WSMan.DevolutionsWsmanAdapter`.
It has a public parameterless constructor and these public static properties:
`ProviderId : string`, `ContractHash : string`, `ProviderVersion : string`,
and `Capabilities : ulong`.
Its public instance method returns `RunspacePool`:

```csharp
CreateRunspacePool(
    string optionsJson,
    PSCredential credential,
    Func<string, int, bool, CancellationToken, Task<Stream>> connector)
```

The contract descriptor is:

```text
devolutions.wsman|1|static ProviderId:string|static ContractHash:string|static ProviderVersion:string|static Capabilities:uint64|ctor()|CreateRunspacePool(string,PSCredential,Func<string,int,bool,CancellationToken,Task<Stream>>):RunspacePool
```

Its SHA-256 hash is
`836ea45ab6a3169cc786392cf9db644ac2e6fe59494f514e6a4f94f2a5cd20f9`.
The provider ID is `devolutions.wsman` and the provider version is `0.1.0`.
`Capabilities` remains zero.
After validating its arguments and options, `CreateRunspacePool` throws
`NotSupportedException`; this is not an operational WSMan transport.
Capability enum values describe the reserved contract bits, not supported
features.
SMA types remain within the managed payload, not across the NativeAOT boundary.

The manifest and strict options schema preserve the existing contract.
Options reject unknown members, integer authentication/SSPI enum values,
and null or non-HTTP(S) endpoints.
The endpoint path is the complete request path (`AppName`);
connection bounds, SSPI selection, the 5,000 ms minimum effective cancel
timeout, KDC proxy text, and the 512 KB envelope default remain unchanged.

## Build boundary

Both projects intentionally use standalone `Microsoft.NET.Sdk` settings.
There is no inherited `Directory.Build.props` or central package configuration
in this source tree.
They do not import `PowerShell.Common.props` or `test\Test.Common.props`:
those files impose engine/test-specific signing, version generation, analyzer
packages, and Microsoft ownership metadata.
The source `.editorconfig` still applies.
The existing `.gitignore` already excludes `bin`, `obj`, assemblies, and
NuGet packages, so no extra ignore rules are required.

The project default remains `AdapterTargetFramework=net8.0`.
That default is a compatibility target, not a claim that the current patched
SDK supports .NET 8.
The actual SMA source currently targets `net10.0` in `PowerShell.Common.props`.
The distribution must derive that framework and supply it explicitly as
`AdapterTargetFramework` when building and testing the adapter.

`PowerShellSdkVendor=Devolutions` and `PowerShellSdkAssemblyPath` pointing to
the source-built Devolutions-patched `System.Management.Automation.dll` are
required.
There is no stock SMA or `Microsoft.PowerShell.SDK` NuGet package reference.
The provider does not copy SMA into its output; the test project copies it for
test execution.
The vendor property is a build assertion supplied by the caller, not an
independent provenance check.

From the repository root, with the patched assembly path supplied by the caller:

```powershell
$env:AdapterTargetFramework = ([xml](Get-Content .\PowerShell.Common.props -Raw)).Project.PropertyGroup.TargetFramework |
    Where-Object { $_ } |
    Select-Object -First 1
$env:PowerShellSdkVendor = 'Devolutions'
# Set PowerShellSdkAssemblyPath to the source-built patched SMA before running.
dotnet test .\test\Devolutions.MultiPwsh.Remoting.WSMan.Tests\Devolutions.MultiPwsh.Remoting.WSMan.Tests.csproj --configuration Release -p:TreatWarningsAsErrors=true
dotnet format .\test\Devolutions.MultiPwsh.Remoting.WSMan.Tests\Devolutions.MultiPwsh.Remoting.WSMan.Tests.csproj --verify-no-changes --no-restore
```

These are focused provider gates, not substitutes for the distribution's full
SDK package validation.
The existing PowerShell source build and Roslyn analyzer gate remains
`Start-PSBuild -Configuration StaticAnalysis` from `build.psm1`.
No existing SMA source changes are required by this scaffold.

## Deferred transport

The RDM WSMan/SSPI source closure has not been copied.
Its file-level ownership/licensing provenance must be resolved before extraction;
this scaffold makes no licensing assumptions about that source.
An operational managed transport and the patched-SMA integration remain
separate work, as does resolving the .NET 8 compatibility blocker.
