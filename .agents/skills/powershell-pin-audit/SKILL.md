---
name: powershell-pin-audit
description: Audits coordinated PowerShell channel pins across eng/powershell-channels.json, workflows, .gitmodules, README.md, and checked-out PowerShell submodules.
---

# powershell pin audit

Use this skill when updating a pinned PowerShell channel version, reviewing a PowerShell release bump, or checking that the repository's coordinated `7.6` and `7.7` PowerShell pins still agree.

The audit checks `eng/powershell-channels.json`, `.github/workflows/powershell-sdk.yml`, `.github/workflows/powershell-cli.yml`, `.github/workflows/dotnet-runtime.yml`, `.github/workflows/release.yml`, `.gitmodules`, the README "Current pins" table, and `pwsh-src-<channel>/PowerShell.Common.props` when submodules are initialized.

## Prerequisites

- PowerShell 7 (`pwsh`).
- Initialize `pwsh-src-7.6/`, `pwsh-src-7.7/`, or `-Channel All` before release-bump validation if you need target-framework verification.

## Usage

Run the default audit across all configured channels (`7.6` and `7.7`) from the repository root:

```powershell
pwsh .\.agents\skills\powershell-pin-audit\scripts\Test-PowerShellPins.ps1
```

Audit a single channel and require its submodule checkout:

```powershell
pwsh .\.agents\skills\powershell-pin-audit\scripts\Test-PowerShellPins.ps1 -Channel 7.6 -RequireSubmodule
```

Require all channel submodules (`pwsh-src-7.6/` and `pwsh-src-7.7/`) and fail if any `PowerShell.Common.props` is unavailable:

```powershell
pwsh .\.agents\skills\powershell-pin-audit\scripts\Test-PowerShellPins.ps1 -RequireSubmodule
```

Audit a different checkout:

```powershell
pwsh .\.agents\skills\powershell-pin-audit\scripts\Test-PowerShellPins.ps1 -RepositoryRoot D:\dev\pwsh-distro
```

## Checks

- `eng/powershell-channels.json` defines valid `defaultChannel`, `sdkPackageId`, vendor metadata, and per-channel `powerShellVersion`, `powerShellReleaseTag`, `powerShellUpstreamTag`, `powerShellSourceRef`, `submodulePath`, `targetFramework`, SDK package revisions, and `.NET runtime` pins.
- `powershell-sdk.yml`, `powershell-cli.yml`, `dotnet-runtime.yml`, and `release.yml` expose matching `channel` options and defaults, and agree on `SDK_PACKAGE_ID` and manifest paths.
- `.gitmodules` defines `[submodule "pwsh-src-<channel>"]` with `url = ./` and `branch = downstream/vX.Y.Z` matching each channel's `powerShellSourceRef`.
- README "Current pins" records the default channel plus each channel's upstream release, downstream source ref, submodule path, target framework, SDK workflow-default version, and `.NET runtime` ref.
- If `pwsh-src-<channel>/PowerShell.Common.props` exists, its `<TargetFramework>` matches the channel's `targetFramework` pin (and README).
