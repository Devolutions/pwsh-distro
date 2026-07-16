# Current `Devolutions.PowerShell.SDK` baseline

This document records the package and public API boundary that the NativeAOT
facade is deliberately **not** binary-compatible with. It is a checked-in
baseline for migration planning, not a replacement API specification.

## Current package identity

| Item | Baseline |
| --- | --- |
| Package ID | `Devolutions.PowerShell.SDK` |
| Latest inspected package | `7.6.3.4` |
| PowerShell source release | `7.6.3` |
| Target framework | `net10.0` |
| Packaging source | The PowerShell SDK workflow and `eng/Vendor-PowerShellSdkPackage.ps1` |

The package preserves upstream assembly identities and vendors source-built
PowerShell assemblies into its own package. Consumers use normal in-process
PowerShell APIs after referencing the package.

## Public managed API baseline

The authoritative public C# API is the metadata of the package's `ref/net10.0`
assemblies. The primary public contract is the complete public surface of these
assemblies:

| Assembly group | Representative public types and behavior |
| --- | --- |
| `System.Management.Automation` | `PowerShell`, `Runspace`, `RunspacePool`, `InitialSessionState`, `PSObject`, pipeline/command types, stream records, error records and exceptions, host interfaces, providers, cmdlets, remoting, formatting, and type-table APIs |
| `Microsoft.PowerShell.Commands.*` | Management, utility, and diagnostics command implementations and public command-related types |
| `Microsoft.PowerShell.Security` | Security command and provider behavior |
| `Microsoft.PowerShell.ConsoleHost` | Console-host APIs and hosting assets |
| Windows-only assemblies | `Microsoft.Management.Infrastructure.CimCmdlets`, `Microsoft.WSMan.Management`, and `Microsoft.WSMan.Runtime` |

These APIs expose live CLR object graphs, delegates, interfaces, virtual
methods, and types whose identity is tied to the in-process PowerShell
CoreCLR. A client cannot preserve this contract across a process boundary.

## Package/distribution baseline

The current package also contains:

- `ref/net10.0` reference assemblies and XML documentation;
- `runtimes/unix/lib/net10.0` and `runtimes/win/lib/net10.0` runtime
  assemblies;
- `buildTransitive/Devolutions.PowerShell.SDK.targets`, source-built asset
  metadata, localized resources, built-in modules, and distribution payload
  metadata;
- `tools/apphost/<rid>/` with `pwsh`, `pwsh.dll`, and
  `pwsh.runtimeconfig.json`; and
- native `pwsh` apphost assets for `win-x64`, `win-arm64`, `linux-x64`,
  `linux-arm`, `linux-arm64`, `osx-x64`, and `osx-arm64`.

The existing package and its targets remain unchanged by the NativeAOT work.

## Baseline verification

For every PowerShell release bump, compare the new package against this
baseline by inspecting its `ref/<TargetFramework>` public metadata and package
layout. The target framework must continue to be obtained from
`pwsh-src/PowerShell.Common.props`; do not add a hard-coded `net*` path to the
SDK workflow.
