---
name: powershell-release-bump
description: Coordinates PowerShell release bumps across workflow env pins, .gitmodules, README current pins, and the pwsh-src submodule pointer.
---

# powershell release bump

Use this skill when moving this repository to a new upstream PowerShell release or reviewing a PR that claims to bump PowerShell.

This repository requires a coordinated bump across `.github\workflows\powershell-sdk.yml`, `.github\workflows\powershell.yml`, `.gitmodules`, the `pwsh-src` submodule pointer, and README's "Current pins" table. Keep `POWERSHELL_SOURCE_REF` separate from `POWERSHELL_RELEASE_TAG`: the source ref points to `downstream/vX.Y.Z`, while the release tag remains the upstream `vX.Y.Z` value.

## Prerequisites

- PowerShell 7 (`pwsh`).
- The upstream release tag should already be mirrored as `upstream/vX.Y.Z`.
- The downstream patch branch should exist as `downstream/vX.Y.Z`.
- Initialize `pwsh-src/` when you want the script to discover the target framework automatically.

## Scripts

- `scripts\Set-PowerShellReleasePins.ps1`: Updates text pins in both PowerShell workflows, `.gitmodules`, and README.
- `..\\powershell-pin-audit\\scripts\\Test-PowerShellPins.ps1`: Audits the resulting pins after the edit.
- `..\\..\\..\\..\\scripts\\New-PowerShellPatchBranch.ps1`: Creates a downstream branch from a mirrored upstream tag when needed.
- `..\\..\\..\\..\\scripts\\Sync-PowerShellUpstream.ps1`: Syncs upstream refs and mirrored upstream tags.

## Usage

Create a downstream patch branch if it does not already exist:

```powershell
pwsh .\scripts\Sync-PowerShellUpstream.ps1 -SyncTags
pwsh .\scripts\New-PowerShellPatchBranch.ps1 -Version 7.6.4
```

Update the repository text pins, deriving the target framework from `pwsh-src\PowerShell.Common.props`:

```powershell
pwsh .\.agents\skills\powershell-release-bump\scripts\Set-PowerShellReleasePins.ps1 -Version 7.6.4
```

If the submodule is not initialized yet, pass the framework explicitly:

```powershell
pwsh .\.agents\skills\powershell-release-bump\scripts\Set-PowerShellReleasePins.ps1 -Version 7.6.4 -TargetFramework net10.0
```

Preview the text edits:

```powershell
pwsh .\.agents\skills\powershell-release-bump\scripts\Set-PowerShellReleasePins.ps1 -Version 7.6.4 -TargetFramework net10.0 -WhatIf
```

Then bump the pinned source submodule commit on `master`:

```powershell
git submodule update --remote pwsh-src
git add pwsh-src
```

Finish by auditing pins and checking the diff:

```powershell
pwsh .\.agents\skills\powershell-pin-audit\scripts\Test-PowerShellPins.ps1 -RequireSubmodule
git --no-pager diff --check
```

## Review checklist

1. Confirm both workflows use the same `POWERSHELL_VERSION`, `POWERSHELL_RELEASE_TAG`, `POWERSHELL_UPSTREAM_TAG`, and `POWERSHELL_SOURCE_REF`.
2. Confirm `.gitmodules` has a literal `branch = downstream/vX.Y.Z` value.
3. Confirm README current pins match the workflow values and upstream target framework.
4. Confirm `pwsh-src` is a submodule pointer change, not a copied PowerShell source tree.
5. Confirm generated output directories such as `output\`, `package\`, `dotnet-runtime\`, and `pwsh-src-worktree\` are not staged.
