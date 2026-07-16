# NativeAOT PowerShell SDK contract

## Status and architecture

`Devolutions.PowerShell.SDK.NativeAot` is an experimental, separate package and
namespace. Its governing architecture is:

```text
NativeAOT client
  -> LibraryImport
  -> Rust cdylib broker
  -> private IPC / worker process boundary
  -> Rust worker
  -> explicit payload-local hostfxr
  -> managed WorkerBridge
  -> selected PowerShell payload
```

The parent process must never initialize CoreCLR or load
`System.Management.Automation`. A worker owns one selected payload and is
discarded to reclaim that payload. This is required because hostfxr does not
support loading different CoreCLR runtimes side-by-side in one process.

## Installation, publish, and compatibility

Install the separate package only in an application that can accept DTO-based,
out-of-process PowerShell semantics:

```xml
<PropertyGroup>
  <TargetFramework>net10.0</TargetFramework>
  <RuntimeIdentifier>win-x64</RuntimeIdentifier>
  <PublishAot>true</PublishAot>
  <SelfContained>true</SelfContained>
  <DevolutionsPowerShellNativeAotEnabled>true</DevolutionsPowerShellNativeAotEnabled>
</PropertyGroup>

<ItemGroup>
  <PackageReference Include="Devolutions.PowerShell.SDK.NativeAot" Version="*" />
</ItemGroup>
```

The opt-in property is intentionally required: without it the package copies
no broker, worker, or bridge assets. Publishing copies the selected RID's
native assets next to the application. The application must still supply a
trusted, explicit payload root; package installation never installs or finds
PowerShell globally.

| Capability | `Devolutions.PowerShell.SDK` | `Devolutions.PowerShell.SDK.NativeAot` |
| --- | --- | --- |
| Hosting model | In-process SMA/CoreCLR | NativeAOT parent plus isolated payload worker |
| Public API | `PowerShell`, runspaces, `PSObject` | `PowerShellSession`, `PowerShellCommand`, DTO results |
| Runtime selection | Parent process runtime | Explicit payload-local hostfxr in worker |
| NativeAOT parent | Not supported | Required design goal |
| Live PowerShell objects | Supported in process | Never cross process boundary |
| Current platform | Existing SDK RID matrix | Supported: `win-x64`, `linux-x64`; build/package-verified only: `win-arm64` |

The public API maps as follows:

| Existing SMA pattern | NativeAOT equivalent | Constraint |
| --- | --- | --- |
| `PowerShell.Create()` | `PowerShellSession.TryStartWorkerConnection` | Starts a private worker for one explicit payload |
| `AddCommand` / `AddScript` | `PowerShellCommand.AddCommand` / `.AddScript` | Commands are serialized into one atomic DTO |
| `AddArgument` / `AddParameter` | Same-named `PowerShellCommand` members | Only null, Boolean, Int64, finite Double, and UTF-8 String values |
| `Invoke()` | `PowerShellWorkerConnection.Invoke` | Returns ordered DTO events and one terminal result |
| `Stop()` / cancellation token | `CancellationToken` supplied to `Invoke` | Cooperative `PowerShell.Stop()`; disposal may return `WorkerExited` |
| `Dispose()` | `PowerShellWorkerConnection.Dispose()` | Idempotent; retires the worker session |

Unsupported features include runspace and host customization, custom cmdlet and
provider objects, `PSObject` transfer, arbitrary CLR values, delegates,
PowerShell event handlers, interactive host UI, remoting, unconstrained
serialization, and PowerShell exception object transfer. A worker runs scripts
under the caller's operating-system identity; process isolation is a runtime
isolation boundary, **not** a sandbox for untrusted script.

## Trusted payload staging

Stage a payload from a trusted PowerShell distribution in a dedicated,
non-symlinked directory. Generate the manifest after staging and before first
use:

```powershell
.\pack\Devolutions.PowerShell.SDK.NativeAot\tools\New-NativeAotPayloadManifest.ps1 `
  -PayloadDirectory C:\trusted-pwsh `
  -WorkerBridgePath .\publish\Devolutions.PowerShell.WorkerBridge.dll
```

The generated `devolutions-pwsh-payload.json` has this schema:

```json
{
  "schema_version": 1,
  "rid": "win-x64",
  "architecture": "x64",
  "files": [
    { "path": "pwsh.dll", "sha256": "<64 lowercase hex characters>" }
  ],
  "worker_bridge_sha256": "<64 lowercase hex characters>"
}
```

`files` is exhaustive: it must contain exactly every regular payload file
except the manifest itself. The worker rejects a root or descendant symlink,
extra/unlisted file, duplicate/path-traversing entry, required-file omission,
hash mismatch, RID mismatch, or incompatible `pwsh`/hostfxr machine type.
Payload trust therefore begins with the producer that staged the distribution;
the manifest detects later changes but is not a substitute for OS ACLs,
provenance, or a sandbox.

### Linux x64 support

`linux-x64` is supported for the same DTO-only contract as `win-x64`. The
broker creates a nonce-named, non-symlinked `0700` directory below the system
temporary directory and binds a `0600` Unix-domain socket within it. Both
client and server validate Linux `SO_PEERCRED` against their effective UID; the
worker must also complete the capability-token handshake before hostfxr loads.
The broker gives the worker a curated environment, reaps it during shutdown,
and removes the private directory, including worker-created private state.

Linux validation uses a strict staged `/opt/microsoft/powershell/7` payload,
payload-local `libhostfxr.so`, WorkerBridge injection, authenticated command
execution, and a clean published `linux-x64` NativeAOT consumer.

### Windows ARM64 build/package gate

`win-arm64` uses the same Windows named-pipe transport and payload-local
`hostfxr` design as `win-x64`. The package target cross-builds the Rust broker
and worker for `aarch64-pc-windows-msvc`, verifies their `0xAA64` PE machine,
and stages them under `runtimes/win-arm64/native` with an `arm64` asset
descriptor. A clean `win-arm64` NativeAOT consumer publish has verified RID
asset selection. This is **not support evidence**: no compatible Windows ARM64
host and explicit ARM64 PowerShell payload have run the bridge, handshake, or
command contract. `win-arm64` therefore remains build/package-verified only.

`linux-arm`, `linux-arm64`, `osx-x64`, and `osx-arm64` are not packaged or
supported. They require target-specific payload validation, hostfxr/transport
validation, and a real payload smoke test before the package target may allow
them.

| RID | Status | Evidence / remaining gate |
| --- | --- | --- |
| `win-x64` | Supported | Explicit payload bridge, broker/session, command, package, and published NativeAOT consumer execution |
| `linux-x64` | Supported | WSL explicit `/opt/microsoft/powershell/7` payload bridge, broker/session, command, package, and published NativeAOT consumer execution |
| `win-arm64` | Build/package-verified only | `aarch64-pc-windows-msvc` broker/worker PE artifacts, package selection, and NativeAOT consumer publish; requires a Windows ARM64 host plus explicit ARM64 PowerShell payload execution |
| `linux-arm64` | Deferred | Requires an ARM64 Linux runner/payload, `aarch64-unknown-linux-gnu` linker/sysroot, ELF `EM_AARCH64` validation, and end-to-end Unix-socket execution |
| `linux-arm` | Deferred | Requires an ARMv7 Linux runner/payload, target linker/sysroot, ELF `EM_ARM` validation, and end-to-end Unix-socket execution |
| `osx-x64`, `osx-arm64` | Deferred | Requires macOS runners/payloads, Mach-O validation, Darwin-specific peer-credential transport review, payload-local `libhostfxr.dylib` loading, and quarantine/code-signing validation |

The current build hosts cannot safely stage any deferred RID: the WSL host has
only `x86_64-unknown-linux-gnu` installed and no
`aarch64-unknown-linux-gnu`/`armv7-unknown-linux-gnueabihf` target or GNU
cross linker/sysroot. Its `clang`/`ld.lld` installation does not supply those
target sysroots. Neither build host has an Apple SDK, Xcode toolchain, or a
macOS runner. Package targets must continue rejecting these RIDs until a
corresponding artifact, architecture-header validation, and payload execution
gate succeed.

## Post-platform advanced capability gate

`StructuredDiagnostics` is protocol feature bit `1 << 5`. When negotiated,
Error and Progress event bodies use fixed-schema binary payloads (schema
version `1`) rather than legacy JSON. Error records add bounded invocation
name, script name, source line/offset, and pipeline length/position. Progress
records carry fixed numeric fields, bounded UTF-8 activity/status/current
operation strings, and a completion flag. Every variable field is bounded;
the existing 64 KiB frame and 256 KiB invocation limits remain unchanged.

An older peer that omits the bit receives the legacy JSON Error and Progress
payloads, so it continues to receive its bounded event/failure/terminal
sequence. Unknown feature bits remain rejected.

## Supported Phase 0/1 contract

The foundation defines a UTF-8, length-delimited C ABI:

```c
uint32_t dps_broker_get_abi_version(void);
int32_t dps_broker_probe_payload_utf8(
    const uint8_t* payload_path,
    size_t payload_path_length,
    const uint8_t* worker_path,
    size_t worker_path_length);
```

Inputs are copied by the broker before it starts the worker. The ABI does not
retain caller-owned buffers, return allocated buffers, expose managed objects,
or use C `long` or native `bool`. Status values are fixed `int32_t` values in
the public client. The client encodes paths as UTF-8 and rejects embedded NUL.

The worker validates an explicit payload directory containing `pwsh.dll`,
`pwsh.runtimeconfig.json`, and the platform `hostfxr` file. On Windows, the
Phase 1 spike loads that payload-local `hostfxr`, calls
`hostfxr_initialize_for_dotnet_command_line` for `pwsh.dll`, and closes the
host context. It does not start CoreCLR in the parent process.

The Phase 1 probe uses a one-shot worker exit status only. It is not the
production private IPC protocol and must not grow script/session behavior;
capability-token-authenticated private IPC begins with the worker-session
milestone.

`WorkerBridge` is built independently against the selected PowerShell SDK and
exports an `[UnmanagedCallersOnly]` ABI version entry point. The Phase 1
Windows worker obtains hostfxr's `hdt_get_function_pointer` delegate from the
payload context, calls
`PowerShellUnsafeAssemblyLoad.LoadAssemblyFromNativeMemory` with the bridge
bytes, resolves `BridgeExports.GetAbiVersion`, and requires the current
WorkerBridge ABI version (`2`).
The targeted integration test invokes this with explicit payload and bridge
paths, without resolving `pwsh` from `PATH`.

## Deliberately unsupported compatibility

The NativeAOT facade does not preserve binary or source compatibility with
`System.Management.Automation`. It cannot transfer live `PSObject` instances,
runspaces, custom hosts, custom cmdlets/providers, delegates, event handlers,
or arbitrary PowerShell exception types into the NativeAOT client process.

The proposed stable public surface is DTO and stream based:

- `PowerShellSession` and structured command/script requests;
- JSON/typed/CLIXML-opaque values;
- output, stream, error, progress, and terminal-result DTOs;
- cancellation and disposal through worker request IDs; and
- NativeAOT-specific exceptions and status codes.

Script invocation and output DTOs are intentionally not present yet.

## Phase 2 private IPC protocol

`native/pwsh-protocol` owns the wire format. The codec is intentionally
independent of the broker transport and worker command dispatch.

`Frame` owns its payload bytes. Encoding creates a caller-owned byte vector;
decoding copies a completed frame out of `FrameDecoder`, whose retained buffer
is private and bounded. No frame borrows a transport buffer or exposes a
pointer across a process boundary. The broker creates the capability token and
hands it to the worker out-of-band; the connection initiator owns the `Hello`
token bytes. The broker will allocate correlation IDs, session IDs, and request
IDs when dispatch is introduced. The codec only reserves and validates their
nonzero placement, so it cannot accidentally define command semantics.

Every frame has a fixed 40-byte little-endian header:

| Bytes | Field |
| --- | --- |
| 0..4 | ASCII magic `DPSI` |
| 4..6 | Protocol version (`1`) |
| 6..8 | Frame kind |
| 8..12 | Negotiated feature bits |
| 12..16 | Payload byte length |
| 16..24 | Correlation ID |
| 24..32 | Session ID |
| 32..40 | Request ID |

Payloads are limited to 64 KiB. The incremental decoder retains at most two
maximum-size frames (131,152 bytes) and rejects invalid magic, versions,
unknown kinds, unknown negotiated feature bits, invalid identifier placement,
truncated frames, trailing bytes, and oversized input before dispatch.

The first client frame is `Hello`, with zero identifiers and a payload of
minimum version (`u16`), maximum version (`u16`), offered feature bits
(`u32`), and a 32-byte one-time capability token. The worker compares that
token without early exit, chooses the current compatible protocol version, and
masks offered features to its supported set in a zero-identifier `Welcome`.
The token is supplied out-of-band when the broker creates the worker; it is
never a command argument or serialized after the handshake.

All post-handshake control/stream frames require nonzero correlation, session,
and request identifiers:

| Frame | Payload |
| --- | --- |
| `Cancel` | Empty cancellation control frame; requires negotiated cancellation |
| `Event` | `sequence: u64`, `event_kind: u16`, opaque bounded bytes |
| `Failure` | `sequence: u64`, `failure_code: u16`, `message_length: u16`, UTF-8 message capped at 4 KiB |
| `Terminal` | `sequence: u64`, terminal status (`Succeeded`, `Cancelled`, or `Failed`) |
| `ExecuteScript` | Non-empty UTF-8 PowerShell script |
| `ExecuteCommand` | Non-empty UTF-8 command name; reserved and rejected by the architecture gate |
| `ScriptOutput` | `sequence: u64`, followed by UTF-8 script output |

`RequestStream` is the worker-side frame owner. It assigns monotonically
increasing sequence numbers to event, failure, and terminal frames, refuses
output after a terminal frame, and refuses a second terminal frame. A failure
frame is diagnostic and does not replace the required terminal frame.

Version `1` rejects unknown header feature bits and frame kinds. Future
versions must retain this header shape, negotiate a new version in `Hello`,
and add only feature-gated frame payloads. A peer must never interpret an
unknown frame/payload as a known command. Feature removal or a meaning change
requires a new protocol version.

`ExecuteScript`, `ExecuteCommand`, and `ScriptOutput` are intentionally
distinct frames. They must not reuse lifecycle `Hello`/`Welcome` or generic
event frames. The Phase 2 architecture gate implemented exactly one `ExecuteScript` request
per worker connection. Phase 3 replaces that restriction with sequential
structured-command requests and ordered event streams; its compatibility
`ScriptOutput` projection remains UTF-8 and capped at 65,528 bytes, leaving
eight bytes for its sequence within the 64 KiB frame limit.

## Phase 2 worker lifecycle transport

Windows x64 has a broker-owned, private named-pipe transport. The broker
creates a fresh, byte-mode, overlapped endpoint with the owner-only security
descriptor `D:P(A;;GA;;;OW)`, generates a cryptographically random 32-byte
capability token and a separate random endpoint nonce, and starts the worker.
The endpoint name and token are never logged. The endpoint name is passed only
as the worker's `--ipc-session` argument; the token is inherited in
`DEVOLUTIONS_PWSH_CAPABILITY_TOKEN`, is removed from the worker environment
immediately after reading, and is never passed as a command argument.

The worker sends `Hello`; the broker validates its token, protocol range, and
offered features. The broker then sends its own `Hello`, which the worker
validates before it sends `Welcome`. The broker accepts only that exact
negotiated `Welcome`. Malformed frames, an invalid token, an unsupported
version, unexpected frames, or a peer close during startup reject the
connection before any command dispatch or PowerShell loading occurs. Shutdown
is idempotent for a retired token; calls other than shutdown through a retired
token return `WorkerExited`.

The lifecycle-only C ABI is cdecl and owns an opaque broker handle:

```c
struct dps_broker_connection;

int32_t dps_broker_connection_start_utf8(
    const uint8_t* worker_path,
    size_t worker_path_length,
    const uint8_t* payload_path,
    size_t payload_path_length,
    const uint8_t* worker_bridge_path,
    size_t worker_bridge_path_length,
    uint32_t startup_timeout_milliseconds,
    struct dps_broker_connection** connection);

int32_t dps_broker_connection_execute_script_utf8(
    struct dps_broker_connection* connection,
    const uint8_t* script,
    size_t script_length,
    uint32_t execution_timeout_milliseconds,
    uint8_t* output,
    size_t output_capacity,
    size_t* output_length);

int32_t dps_broker_connection_shutdown(
    struct dps_broker_connection* connection);

int32_t dps_broker_connection_abort(
    struct dps_broker_connection* connection);
```

The broker copies UTF-8 worker, payload, bridge, and script inputs and leaves
`*connection` null unless startup succeeds. The opaque value is a broker
registry token and is never dereferenced from the ABI boundary. Output is caller-owned: the broker
copies at most `output_capacity` UTF-8 bytes and always writes the required
length on success or `OutputBufferTooSmall`; it never returns a native
allocation. Startup and execution each accept a deterministic one-millisecond through
60-second deadline (the public sample uses 30 seconds) spanning connection
and both handshake directions. A startup timeout returns `StartupTimeout`;
malformed, authentication, or negotiation errors return `HandshakeRejected`;
a child that exits before completion returns `WorkerExited`; and endpoint or
random-source setup failures return `ConnectionSetupFailed`. On any startup
failure the broker closes the pipe and kills/reaps the child. Shutdown closes
the pipe, permits the worker to exit, waits up to two seconds, then kills/reaps
it if necessary. An already-dead worker returns `WorkerExited`.

The NativeAOT client wraps the opaque pointer in
`PowerShellWorkerConnection : SafeHandle`. Normal release calls the shutdown
ABI. Managed disposal first requests cooperative cancellation, then calls the
internal abort ABI to close the pipe and kill/reap an active worker before
releasing the `SafeHandle`; an in-flight invocation therefore completes as
`WorkerExited` rather than waiting for its requested deadline. The handle
never escapes as an `IntPtr`. Its `ExecuteScript` method uses a bounded,
caller-owned UTF-8 buffer and exposes only a string DTO. The worker loads the
selected payload-local hostfxr and injects WorkerBridge only after the mutual
handshake, invokes the bridge's unmanaged UTF-8 script export, and returns
`ScriptOutput` plus terminal frames. The parent remains SMA-free and never
starts CoreCLR.

`linux-x64` uses the same lifecycle ABI over the private Unix-domain socket
described above. macOS and other RIDs return `UnsupportedPlatform`; there is no
TCP or world-accessible fallback.

## Security and payload policy

An explicit payload directory is required for payload-local hosting. The broker
and worker canonicalize the payload root before loading anything and reject a
symlinked root, symlinked descendants, links escaping the root, and
non-regular manifest entries. The payload must contain `pwsh.dll`,
`pwsh.runtimeconfig.json`, the platform `hostfxr` binary (`hostfxr.dll` or
`libhostfxr.so`), and `devolutions-pwsh-payload.json`.

The manifest schema is version `1`, has `rid: "win-x64"`, `rid:
"linux-x64"`, or build/package-only `rid: "win-arm64"` and the matching `x64`
or `arm64` architecture, lists every regular payload file other than the
manifest with a SHA-256 digest, and carries the SHA-256 digest of the
independently supplied WorkerBridge assembly. The validator rejects an absent,
malformed, incomplete, duplicate, path-traversing, noncanonical,
architecture-mismatched, or digest-mismatched manifest. It checks the PE
machine type of `pwsh.dll` and `hostfxr.dll` before hostfxr is loaded.

The WorkerBridge is deliberately outside the payload directory so the
packaged worker can inject its known managed bridge without making it part of
the selected PowerShell distribution. Its canonical regular-file path and
manifest digest are checked before worker startup. Applications create the
manifest only after obtaining a payload from a trusted distribution source;
the repository provides `tools/New-NativeAotPayloadManifest.ps1` as the
deterministic x64 staging tool and a build/package-only `win-arm64` manifest
generator. Generating an ARM64 manifest does not establish ARM64 support.

There is no framework-dependent or global-host fallback. The parent never
searches `PATH`, `DOTNET_ROOT`, the registry, or a globally installed `pwsh`
for hostfxr or PowerShell assets. The worker inherits a curated environment: the broker clears the environment
and passes only the one-time capability token, a worker/payload-local `PATH`,
and platform-local temporary settings before setting its working directory to
the canonical payload root. Windows receives `SystemRoot`, `WINDIR`, and
optional `TEMP`/`TMP`; Linux receives private `HOME`/`TMPDIR` and optional
`LANG`. The same-user private IPC endpoint, one-time token, bounded frames,
and fixed startup timeouts remain mandatory. macOS and other RIDs return
`UnsupportedPlatform`; no insecure TCP or world-accessible fallback exists.

Process isolation solves runtime co-hosting, not script sandboxing. A worker
runs scripts with the caller's OS identity. Treat untrusted scripts as
untrusted native process work and use an operating-system or container sandbox
when required.

## Phase 4 package staging

`Devolutions.PowerShell.SDK.NativeAot` is an opt-in package. By default its
transitive build target is inert and copies no native files. A consuming
`win-x64`, `linux-x64`, or build/package-only `win-arm64` application opts in
only by setting:

```xml
<DevolutionsPowerShellNativeAotEnabled>true</DevolutionsPowerShellNativeAotEnabled>
```

The package rejects every other RID when that property is enabled. Its asset
layout is:

```text
lib/net10.0/Devolutions.PowerShell.SDK.NativeAot.dll
buildTransitive/Devolutions.PowerShell.SDK.NativeAot.targets
runtimes/win-x64/native/devolutions_pwsh_broker.dll
runtimes/win-x64/native/devolutions-pwsh-worker.exe
runtimes/win-x64/native/Devolutions.PowerShell.WorkerBridge.dll
runtimes/win-x64/native/devolutions-pwsh-nativeaot-assets.json
runtimes/linux-x64/native/libdevolutions_pwsh_broker.so
runtimes/linux-x64/native/devolutions-pwsh-worker
runtimes/linux-x64/native/Devolutions.PowerShell.WorkerBridge.dll
runtimes/linux-x64/native/devolutions-pwsh-nativeaot-assets.json
runtimes/win-arm64/native/devolutions_pwsh_broker.dll
runtimes/win-arm64/native/devolutions-pwsh-worker.exe
runtimes/win-arm64/native/Devolutions.PowerShell.WorkerBridge.dll
runtimes/win-arm64/native/devolutions-pwsh-nativeaot-assets.json
docs/nativeaot-sdk-contract.md
README.md
```

The `win-arm64` package assets remain unsupported until an ARM64 payload
contract run succeeds.

On opt-in build/publish, the broker, worker, bridge, and asset descriptor are
copied beside the consumer executable. The consumer still supplies an
explicit, manifest-verified PowerShell payload path. The package does not
bundle a PowerShell distribution, a global host fallback, signing material,
an SBOM, or provenance claims; this repository has no prevailing signing or
SBOM generation pattern to extend.

## Migration

Keep existing clients on `Devolutions.PowerShell.SDK` when they require the
normal in-process PowerShell API. New NativeAOT clients should adopt the
separate package and use its DTO-based facade. Do not use type forwarding,
same-name replacement assemblies, or reflection shims to present the NativeAOT
facade as `System.Management.Automation`.

## Phase 3 stream MVP

Phase 3 supersedes the Phase 2 one-request architecture gate while retaining
`ExecuteScript` as a bounded compatibility projection. The broker
keeps an authenticated worker session alive for multiple sequential requests.
The managed `PowerShellWorkerConnection` serializes requests per session; a
request is never accepted while another request is active, but a completed
request does not close the session.

New callers construct one atomic `PowerShellCommand` DTO using
`AddCommand`, `AddScript`, `AddArgument`, `AddParameter`, `AddStatement`, and
`Clear`. The only crossing value types are null, Boolean, Int64, finite Double,
and UTF-8 String. All DTO strings reject embedded NUL and all unsupported
input types are rejected before dispatch. A PowerShell output object outside
that same primitive set produces a structured Error event, Failure frame, and
failed terminal result; live `PSObject` values never cross the boundary.

`ExecuteCommand` carries a versioned binary DTO and its deadline. The worker
uses the deadline to schedule `PowerShell.Stop()`. The broker exposes a
separate cancellation ABI that sends a feature-negotiated `Cancel` frame while
the request is active; the worker calls the WorkerBridge
`StopCurrentInvocation` export, which calls `PowerShell.Stop()`. Cancellation
has a `Cancelled` terminal frame. A call racing a completed request is
idempotent and does not terminate the reusable session.

WorkerBridge ABI version 2 returns a bounded sequence of stream records in
caller-owned memory. The worker translates those records into protocol Event
frames in observed callback order:

| Event kind | DTO body |
| --- | --- |
| Output | typed primitive value |
| Error | JSON error DTO: message, FQID, category, reason, target, stack trace, exception type |
| Warning, Verbose, Debug | UTF-8 text |
| Information | JSON message/source/tags/timestamp DTO |
| Progress | JSON activity/status/progress DTO |

Every request response has contiguous sequence numbers and ends in exactly one
Terminal frame. A Failure frame is diagnostic and precedes a failed terminal;
`RequestStream` rejects output/events after terminal and a second terminal.
Nonterminating `Write-Error` records are Error events with a successful
terminal; terminating errors have Error plus Failure events and a failed
terminal. The compatibility `ExecuteScript` API joins typed output events into
its existing UTF-8 string result.

Frames remain limited to 64 KiB. WorkerBridge's aggregate response and the
client response buffer are both limited to 256 KiB, including framing. The
broker rejects an over-limit peer response rather than accumulating unbounded
data. No native allocation is returned to managed code. The public client
continues to use `LibraryImport` and an opaque `SafeHandle`, has no reference
to `System.Management.Automation`, and is supported on `win-x64` and
`linux-x64`.

## Lifecycle hardening

The opaque handle is a monotonically generated registry token, not a
dereferenceable native allocation. The broker records a bounded set of retired
tokens: a repeated shutdown is idempotent, while execute/cancel calls through a
retired token return `WorkerExited` and an unknown token returns
`InvalidArgument`. A stale pointer therefore cannot alias a later session.

One session has exactly one serialized request lane. A cancellation arriving
before its request frame is written is latched and sent immediately after that
frame; repeated cancellations send at most one control frame. A cancellation
that races the prior terminal frame is ignored by the worker if its request
identifiers no longer own an invocation. Separate sessions have independent
request locks, pipes, and worker processes; the registry lock is held only for
handle lookup or retirement and does not serialize their commands.

Startup and each frame read/write use whole-operation deadlines rather than
resetting a timeout for partial I/O. On a request deadline, the broker sends a
cooperative cancel and allows a bounded one-second terminal-response grace
period. If the worker does not finish, or if a malformed/oversized response is
observed, the broker closes/cancels the pipe and kills/reaps the child before
the session can be reused. Shutdown follows the same pipe-close discipline,
waits at most two seconds, and then kills/reaps the child. Peer close during
handshake, write, or read maps to `WorkerExited`; startup timeout,
request timeout, handshake rejection, output-limit, and protocol violations
remain distinct status diagnostics.

Managed `Dispose` first requests the active invocation's cooperative cancel.
It then retires the opaque token and invokes the broker's internal abort path,
which closes the pipe and kills/reaps the isolated worker instead of waiting
for a cooperative terminal frame. An invocation racing disposal therefore
returns `WorkerExited`; it must not be treated as a successful `Cancelled`
terminal. Repeated disposal, shutdown, and abort of a retired handle are
idempotent. A disposal race that reaches an already closed handle is also
reported as `WorkerExited`, not an unmanaged-handle failure.

The pipe owns a synchronized close path: close first cancels outstanding
overlapped I/O, waits for users of the handle to leave their read lock, and
only then disconnects and closes the Windows handle. The worker prebuilds and
sizes its complete framed response before writing it. If protocol framing would
exceed 256 KiB it sends only a bounded diagnostic failure and failed terminal,
instead of partially streaming an unparseable response. The managed parser
independently enforces the 256 KiB, frame-count, sequence, single-failure, and
terminal/failure invariants.

Focused Rust tests cover timeout cancellation of overlapped I/O, close during
an indefinite read, frame-wide deadlines, handshake rejection, cancellation
latching, stale-token retirement, idempotent abort, and status mapping. The
NativeAOT contract sample additionally verifies reusable sequential requests,
cancellation and deadline terminals, idempotent disposal, parallel commands
on independent sessions, and disposal during an active invocation. Cooperative
cancellation still depends on PowerShell honoring `Stop()`; disposal and
deadline cleanup kill the isolated worker when it does not.
