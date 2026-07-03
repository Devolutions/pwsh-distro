# pwsh-distro

GitHub Actions workflows for building redistributable PowerShell artifacts from upstream or downstream-patched source. The primary target is a single vendored `Devolutions.PowerShell.SDK` package, and the secondary target is a self-contained PowerShell distribution archive repackaged from that SDK package.

## Quick start

This repository builds PowerShell from source. The full PowerShell source tree is pulled in as a git submodule at `pwsh-src/`, so the checkout must initialize submodules, and on Windows it requires long-path support enabled in git.

```powershell
git clone https://github.com/awakecoding/pwsh-distro.git
cd pwsh-distro
.\scripts\Initialize-Repository.ps1
```

All workflows are manual and start from the GitHub Actions **Run workflow** button (see the Workflows table below). The workflows are the authoritative release builds, and the SDK workflow can publish the validated NuGet package to NuGet.org and GitHub Releases.

> On Linux/macOS no long-path configuration is needed. On Windows, if `core.longpaths` is not enabled, the `pwsh-src` submodule checkout will fail with `Filename too long`. `scripts\Initialize-Repository.ps1` enables it before initializing the submodule. The workflows set this on their Windows runners automatically.

To build a local, current-RID SDK package for smoke testing outside Actions:

```powershell
.\scripts\Build-LocalPowerShellSdk.ps1 -Validate
```

The local script writes under `output\local-sdk\<rid>\` and produces a single-RID validation package. The GitHub Actions SDK workflow remains the authoritative multi-RID package build. Pass `-SdkPackageVersion 7.6.3.1` to smoke-test a downstream package revision for the same upstream PowerShell release.

## Current pins

| Component | Version |
| --- | --- |
| PowerShell upstream release | `7.6.3` / `v7.6.3` |
| PowerShell downstream source ref | `downstream/v7.6.3` based on `upstream/v7.6.3` |
| PowerShell target framework | `net10.0` |
| PowerShell SDK package | `Devolutions.PowerShell.SDK` / `7.6.3.0` |
| PowerShell SDK package source | `https://api.nuget.org/v3/index.json` |
| multi-pwsh apphost package | `Devolutions.MultiPwsh.Cli` / `0.14.0` |
| multi-pwsh apphost package source | `https://api.nuget.org/v3/index.json` |
| psign code signing tool | `Devolutions.Psign.Tool` / `latest (un-pinned)` |
| .NET runtime workflow | `v10.0.5` |
| llvm-prebuilt | `v2026.1.1` |
| clang+llvm | `22.1.4` |
| VsDevShell | `2026.1.0` / `9b4518e6c45a2abedbf6a05b77c9912aaef70f1e` |

## Workflows

| Workflow | Purpose | Output |
| --- | --- | --- |
| `.github/workflows/powershell-sdk.yml` | Builds PowerShell from source, vendors the source-built PowerShell SDK assemblies into one `Devolutions.PowerShell.SDK` package, signs the source-built payloads, and validates it in a sample .NET app with opt-in apphost import. It can run manually or as a reusable workflow. | `PowerShell-SDK-Release-7.6.3.0` artifact containing one `.nupkg`. |
| `.github/workflows/powershell-cli.yml` | Restores a pinned or workflow-built `Devolutions.PowerShell.SDK` package, imports its apphost and module payload through MSBuild, publishes a self-contained PowerShell layout, and repackages it for Windows, macOS, and Linux on x64 and arm64. It can run manually or as a reusable workflow. | `PowerShell-7.6.3-<os>-<arch>` `.tar.gz` artifacts. |
| `.github/workflows/release.yml` | Orchestrates the reusable SDK workflow first, repackages that signed SDK artifact through the reusable CLI workflow, publishes the SDK package, and creates the GitHub release. | NuGet.org publish plus GitHub release `v7.6.3.0` containing the SDK `.nupkg`, all CLI `.tar.gz` archives, and checksums. |
| `.github/workflows/dotnet-runtime.yml` | Builds the .NET runtime tag used by this PowerShell release for Windows, macOS, and Linux on x86_64 and arm64 with prebuilt clang+llvm from `awakecoding/llvm-prebuilt`. | Runtime build output in the workflow logs/workspace. |

All workflows are manual and can be started from the GitHub Actions **Run workflow** button.

## Publishing PowerShell releases

The release workflow publishes only after the SDK package has been built, had its source-built payloads signed for release, been validated on every RID in the validation matrix, and been repackaged into every CLI archive. The release version is `POWERSHELL_VERSION.SDK_PACKAGE_REVISION`, such as `7.6.3.0`.

Manual inputs:

| Input | Purpose |
| --- | --- |
| `sdk_package_revision` | Optional revision override. Leave blank to use the explicit `SDK_PACKAGE_REVISION` env pin, set a number such as `1` for a specific downstream revision, or set `auto` to infer the next revision from existing `vX.Y.Z.R` release tags. |
| `github-env` | `auto`, `test`, or `prod`. `auto` selects `publish-prod` for manual runs from `master` and `publish-test` elsewhere. |
| `skip-publish` | Builds, signs when requested, validates, and packages artifacts without publishing to NuGet.org or creating a GitHub release. |
| `dry-run` | Simulates publishing. This defaults to `true`; non-production environments are forced to dry-run when publishing is requested. |
| `sign-dry-run` | Signs the package during a dry-run when code signing secrets are available. This defaults to `false` so dry-runs can exercise packaging and release flow without requiring signing credentials. |
| `ready_to_run` | Applies ReadyToRun optimization to CLI archives. When SDK code signing is enabled, the release workflow signs and verifies the final post-R2R CLI archive payloads before checksums and release creation. |

The standalone CLI workflow also has an opt-in `ready_to_run` input that runs a targeted crossgen2 pass over packaged PowerShell managed assemblies after the self-contained layout is assembled. It is disabled by default because ReadyToRun rewrites managed PE files and invalidates existing Authenticode signatures. For signed releases, use `.github/workflows/release.yml` with both signing and `ready_to_run` enabled so the CLI archives are signed after the R2R pass.

Before validation and CLI packaging, the SDK workflow runs a signing stage that downloads the built `.nupkg`, installs the latest `Devolutions.Psign.Tool` .NET tool, extracts the package, signs the source-built payloads inside it with Azure Key Vault, and repacks the `.nupkg` without adding a NuGet package signature. The signing pass covers the built PowerShell assemblies in `ref/` and `runtimes/*/lib/`, the apphost payloads in `tools/apphost/*` and `runtimes/*/native`, the Windows desktop payload, and the built-in module manifests/format/script files in `contentFiles/any/any/runtimes/**/Modules/**`. CLI archives are built from this release-ready SDK package, so their Windows executable and module payloads come from the signed `.nupkg`. A non-dry-run publish requires these environment secrets and variables:

| Name | Type |
| --- | --- |
| `CODE_SIGNING_KEYVAULT_URL` | Secret |
| `AZURE_TENANT_ID` | Secret |
| `CODE_SIGNING_CLIENT_ID` | Secret |
| `CODE_SIGNING_CLIENT_SECRET` | Secret |
| `CODE_SIGNING_CERTIFICATE_NAME` | Secret |
| `CODE_SIGNING_TIMESTAMP_SERVER` | Variable |

Publishing uses the same NuGet.org OIDC pattern as `Devolutions/gsudo-distro`: repository environments named `publish-test` and `publish-prod`, `NuGet/login@v1`, and a `NUGET_BOT_USERNAME` secret available to the publishing environment. The release workflow grants `id-token: write` for NuGet OIDC and `contents: write` for GitHub release creation only in the publishing job. A real publish pushes the validated `.nupkg` containing signed Windows payloads to `https://api.nuget.org/v3/index.json` and creates a GitHub release named `Devolutions.PowerShell.SDK vX.Y.Z.R` with tag `vX.Y.Z.R`, release notes, the SDK package asset, every CLI archive, and a SHA256 checksum file covering all release assets.

## Branching model

This repository follows a downstream patch branch model inspired by `Devolutions/gsudo-distro`: `master` stays downstream-only, upstream PowerShell refs are mirrored under `upstream/*`, and source patches live on `downstream/vX.Y.Z` branches based on upstream release tags. The patched source is exposed on `master` as a same-repo submodule at `pwsh-src/` pinned to a commit on `downstream/vX.Y.Z`, so workflows build the exact reviewed source tree with a single `actions/checkout` using `submodules: true`. See [BRANCHING.md](BRANCHING.md) for the full branch, tag, submodule, and worktree flow.

## Updating PowerShell versions

When moving to a new upstream PowerShell release, the bump touches four surfaces in the same PR:

1. Workflow `env` blocks in `.github/workflows/powershell-sdk.yml` and `.github/workflows/powershell-cli.yml`: `POWERSHELL_VERSION`, `POWERSHELL_RELEASE_TAG`, `POWERSHELL_UPSTREAM_TAG`, and `POWERSHELL_SOURCE_REF`. Reset `.github/workflows/powershell-sdk.yml` `SDK_PACKAGE_REVISION` to `0` for the first downstream SDK package built from a new upstream tag, and keep `.github/workflows/powershell-cli.yml` `SDK_PACKAGE_VERSION` and `SDK_PACKAGE_REVISION` aligned with the SDK package version that the CLI workflow should repackage by default.
2. `.gitmodules`: the `branch = downstream/vX.Y.Z` line under `[submodule "pwsh-src"]` (git does not expand variables in `.gitmodules`, so this must be edited literally).
3. The `pwsh-src` submodule pointer on `master`, bumped to the new `downstream/vX.Y.Z` tip with `git submodule update --remote pwsh-src && git add pwsh-src`.
4. The "Current pins" table above.

Verify the upstream target framework from `pwsh-src/PowerShell.Common.props` after the bump and keep SDK packaging paths derived from that property instead of hardcoding `net*` folders.

## Notes

The PowerShell workflows check out this repository with `submodules: true` to populate `pwsh-src/` from the pinned submodule commit on `downstream/vX.Y.Z`, while build metadata continues to use `POWERSHELL_RELEASE_TAG`. This allows downstream patch branches to be built without passing branch names to PowerShell build steps that expect upstream release tags. `POWERSHELL_SOURCE_REF` documents which patch branch the submodule tracks; bumping the submodule pointer on `master` is what actually moves the built source.

The SDK workflow intentionally derives the target framework from upstream `PowerShell.Common.props` instead of hardcoding it, so future PowerShell updates only need the version pins refreshed. The SDK package is assembled from locally built PowerShell binaries plus package layouts from the official NuGet packages for the same PowerShell version, then `eng/Vendor-PowerShellSdkPackage.ps1` rewrites the NuGet package ID, package version, and vendor metadata to Devolutions.

The vendored SDK keeps upstream PowerShell build/runtime metadata separate from downstream NuGet package revisions. `POWERSHELL_VERSION` remains the upstream three-part PowerShell version used to restore Microsoft packages and validate `pwsh` runtime output. `.github/workflows/powershell-sdk.yml` keeps the default downstream revision explicit in `SDK_PACKAGE_REVISION`; the manual `sdk_package_revision` input can override it or use `auto` to infer the next release tag revision. The package version is `POWERSHELL_VERSION.sdk_package_revision`, such as `7.6.3.0`, `7.6.3.1`, or `7.6.3.2`. NuGet normalizes a trailing `.0` in package identity metadata, file names, and restore folders, so `7.6.3.0` is expected to produce/use `Devolutions.PowerShell.SDK.7.6.3.nupkg`; nonzero revisions keep all four elements.

The package keeps original assembly identities (`System.Management.Automation.dll`, `Microsoft.PowerShell.Commands.Utility.dll`, and related assemblies) so consumers only need to change the NuGet package reference. Source-built PowerShell assemblies are discovered from the current `pwsh-src` build outputs and embedded directly in `Devolutions.PowerShell.SDK`; the package records the embedded Microsoft package IDs and source-built package asset paths under `buildTransitive`, and validation fails if any of those package IDs appear in the restore graph. External packages that are not built by this repository, including `Microsoft.PowerShell.Native` and `Microsoft.PowerShell.MarkdownRender`, remain normal public NuGet dependencies.

The SDK package also includes apphost files for `win-x64`, `win-arm64`, `linux-x64`, `linux-arm64`, `osx-x64`, and `osx-arm64`. These files are inert by default. A consuming project opts in by choosing an apphost layout. The root layout copies `pwsh`/`pwsh.exe`, `pwsh.dll`, `pwsh.runtimeconfig.json`, runtime assemblies, and built-in module manifests to the app root:

```xml
<PropertyGroup>
  <PowerShellSDKAppHostLayout>Root</PowerShellSDKAppHostLayout>
</PropertyGroup>
```

Applications that need architecture-specific apphost launchers in a native asset layout can use the runtime-native layout:

```xml
<PropertyGroup>
  <PowerShellSDKAppHostLayout>RuntimeNative</PowerShellSDKAppHostLayout>
  <PowerShellSDKRuntimeNativeAppHostRuntimeIdentifiers>win-x64;win-arm64</PowerShellSDKRuntimeNativeAppHostRuntimeIdentifiers>
</PropertyGroup>
```

This copies a minimal native launcher to `runtimes/<rid>/native/pwsh.exe` (or `pwsh` on Unix) for each selected RID. The launcher loads `../../../pwsh.dll`, so `pwsh.dll`, `pwsh.runtimeconfig.json`, PowerShell runtime assemblies, built-in modules, and required RID-specific runtime library dependencies are copied once to the app output root and shared with the consuming executable. Leave `PowerShellSDKRuntimeNativeAppHostRuntimeIdentifiers` empty to copy every runtime-native launcher included in the package, or set it to a semicolon-delimited RID list. Unknown RIDs fail the build.

The source-built PowerShell runtime is patched so out-of-process jobs can use the selected runtime-native launcher when `$PSHOME/pwsh.exe` is not present. This lets `Start-Job` work in bundled-host scenarios that copy `pwsh.exe` under `runtimes/<rid>/native` instead of the app root.

Use `PowerShellSDKCopyPhases` to decide where opted-in payloads are copied. The default is `Output;Publish`; set it to `Output` or `Publish` to disable the other phase. The package also has optional config, localized resource, and PSGallery module payloads:

```xml
<PropertyGroup>
  <PowerShellSDKLocalizedResources>Copy</PowerShellSDKLocalizedResources>
  <PowerShellSDKPSGalleryModules>Microsoft.PowerShell.Archive;Microsoft.PowerShell.ThreadJob</PowerShellSDKPSGalleryModules>
</PropertyGroup>
```

| Property | Default | Values | Effect |
| --- | --- | --- | --- |
| `PowerShellSDKAppHostLayout` | `None` | `None`, `Root`, `RuntimeNative`, `Both` | Selects the apphost file layout. |
| `PowerShellSDKAppHostImplementation` | `Auto` | `Auto`, `MultiPwsh`, `DotNet` | Selects the apphost executable implementation when the requested layout/package assets support it. Current package assets support `MultiPwsh` for `Root` and `DotNet` for `RuntimeNative`. |
| `PowerShellSDKAppHostRuntimeIdentifier` | empty | RID | Overrides root apphost RID selection; otherwise `$(RuntimeIdentifier)` then `$(NETCoreSdkRuntimeIdentifier)` are used. |
| `PowerShellSDKRuntimeNativeAppHostRuntimeIdentifiers` | empty | RID list | Semicolon-delimited runtime-native launcher RIDs; empty selects all packaged RIDs. |
| `PowerShellSDKRuntimeNativeSharedPayloadRuntimeIdentifier` | empty | RID | Overrides the shared app-root PowerShell payload RID. Otherwise it follows `$(RuntimeIdentifier)`, `$(NETCoreSdkRuntimeIdentifier)`, then `PowerShellSDKAppHostRuntimeIdentifier`. |
| `PowerShellSDKRuntimeNativeSharedPayloadTargetFramework` | empty | TFM | Overrides shared payload TFM lookup; normally platform-specific TFMs such as `net10.0-windows10.0.19041` normalize to the package TFM `net10.0`. |
| `PowerShellSDKCopyPhases` | `Output;Publish` | `Output`, `Publish`, `Output;Publish` | Controls build output and publish copying for opted-in payloads. |
| `PowerShellSDKConfig` | `Copy` | `None`, `Copy` | Generates `powershell.config.json` when an apphost layout is enabled. |
| `PowerShellSDKConfigExecutionPolicy` | `Bypass` | PowerShell execution policy | Sets `Microsoft.PowerShell:ExecutionPolicy` in generated config. |
| `PowerShellSDKConfigOverwriteExisting` | `false` | `true`, `false` | Replaces existing `powershell.config.json` only when `true`. |
| `PowerShellSDKLocalizedResources` | `None` | `None`, `Copy` | Copies staged localized resource assemblies beside the apphost payload. |
| `PowerShellSDKPSGalleryModules` | `None` | `None`, `All`, or module list | Copies all staged PSGallery modules or a semicolon-delimited subset to `Modules`. |

When passing semicolon-delimited values on the `dotnet` or `msbuild` command line, encode semicolons as `%3B`, such as `/p:PowerShellSDKCopyPhases=Output%3BPublish`.

The apphost output is intended for running scripts with the core built-in modules from `$PSHOME/Modules`; it is not a full PowerShell distribution archive unless consumers deliberately enable optional payloads such as localized resources and PSGallery modules. PSGallery modules increase package and output size, include additional package-management or interactive functionality, and several are script modules subject to the bundled PowerShell execution policy.

The secondary PowerShell CLI workflow uses this same package-consumer path instead of rebuilding PowerShell from source. It creates a temporary .NET project, restores the pinned SDK package from the pinned package source or a workflow-built SDK artifact, enables root apphost and PSGallery module import, opts into localized resources when present, publishes self-contained for the matrix RID, removes the temporary host application files, validates the PowerShell layout, and archives the result as `.tar.gz` for every platform, including Windows. Windows archives additionally stage the matching `Microsoft.WindowsDesktop.App.Runtime.<rid>` payload so WPF/WinForms assemblies such as `PresentationFramework.dll`, `System.Windows.Forms.dll`, and `WindowsBase.dll` load from `$PSHOME`. For end-to-end dry runs outside `.github/workflows/release.yml`, pass `sdk_artifact_run_id` to `.github/workflows/powershell-cli.yml` so it downloads the `PowerShell-SDK-Release-X.Y.Z.R` artifact from a prior `.github/workflows/powershell-sdk.yml` run and repackages that workflow-built `.nupkg` instead of restoring from NuGet.org. If the artifact name does not include the SDK version, also pass `sdk_package_version`.

During NuGet packing, upstream `Microsoft.PowerShell.SDK` content file/reference metadata can emit NU5100/NU5131 package analysis warnings. The SDK workflow treats package validation as the source of truth: the generated sample must restore only the vendored PowerShell package ID, build, publish framework-dependent and self-contained outputs, execute `pwsh`, and load copied built-in modules.

Generated source checkouts and build artifacts are not part of this repository.
