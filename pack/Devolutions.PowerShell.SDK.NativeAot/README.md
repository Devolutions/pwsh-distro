# Devolutions PowerShell SDK NativeAOT

Experimental NativeAOT-safe facade for process-isolated PowerShell hosting.

This package is not a replacement for `Devolutions.PowerShell.SDK`. It does
not include or reference `System.Management.Automation`; a Rust worker owns
the selected PowerShell payload and its CoreCLR runtime. The NativeAOT parent
never hosts CoreCLR, because hostfxr cannot load independent CoreCLR runtimes
side by side in one process.

## Publish setup

Native assets are inert unless the consuming project explicitly opts in:

```xml
<PropertyGroup>
  <TargetFramework>net10.0</TargetFramework>
  <RuntimeIdentifier>win-x64</RuntimeIdentifier>
  <PublishAot>true</PublishAot>
  <SelfContained>true</SelfContained>
  <DevolutionsPowerShellNativeAotEnabled>true</DevolutionsPowerShellNativeAotEnabled>
</PropertyGroup>
```

The opt-in target copies the broker, worker, WorkerBridge, and asset descriptor
beside the published executable. `win-x64` and `linux-x64` are supported.
`win-arm64` is build/package-verified only: it can be selected and its native
assets are cross-built, but it has not executed the payload contract on a
Windows ARM64 host, so it is not supported. Other RIDs are rejected when
opt-in is enabled. Linux uses a private `0700` directory containing a `0600`
Unix-domain socket and rejects peers whose UID does not match the worker's
effective UID.

| RID | Status |
| --- | --- |
| `win-x64`, `linux-x64` | Supported |
| `win-arm64` | Build/package-verified only |
| `linux-arm64`, `linux-arm`, `osx-x64`, `osx-arm64` | Deferred; not packaged |

## Payload and security boundary

The application supplies an explicit trusted PowerShell payload. Stage it in a
non-symlinked directory, then generate `devolutions-pwsh-payload.json` with
the repository's `tools/New-NativeAotPayloadManifest.ps1`. The version-1
manifest records the `win-x64`, `linux-x64`, or build/package-only `win-arm64`
RID; its matching x64 or arm64 architecture; SHA-256 for every regular payload
file; and the WorkerBridge SHA-256. The broker/worker reject missing,
symlinked, incomplete, unlisted, tampered, or architecture-mismatched payloads
before hostfxr loads.

There is no global `pwsh`, hostfxr, registry, `PATH`, or
framework-dependent fallback. The worker receives a curated environment and
uses the caller's OS identity. This isolates runtimes, not untrusted scripts;
use OS/container isolation for sandboxing.

## API and limits

Use `PowerShellSession`, `PowerShellCommand`, and
`PowerShellWorkerConnection`. Commands support `AddCommand`, `AddScript`,
arguments, parameters, statements, and clear operations. Values are limited to
null, Boolean, Int64, finite Double, and UTF-8 String. Results carry ordered
Output/Error/Warning/Verbose/Debug/Information/Progress DTO events and one
terminal result. Runspaces, `PSObject`, custom hosts/providers, arbitrary CLR
values, delegates, event handlers, and live PowerShell exceptions are not
supported.

Per-session requests are serialized. Cancellation calls `PowerShell.Stop()`;
timeouts, protocol faults, worker exit, and output limits map to distinct
`NativeStatus` values. Disposal is idempotent and can end an active request as
`WorkerExited`.

See `docs/nativeaot-sdk-contract.md` in the package for the full protocol,
lifecycle, migration, and compatibility contract.
