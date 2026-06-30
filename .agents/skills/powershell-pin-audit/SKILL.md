---
name: powershell-pin-audit
description: Audits coordinated PowerShell version pins across workflows, .gitmodules, README.md, and the checked-out upstream PowerShell target framework.
---

# powershell pin audit

Use this skill when updating the pinned PowerShell version, reviewing a PowerShell release bump, or checking that the repository's coordinated PowerShell pins still agree.

The audit checks the primary `.github/workflows/powershell-sdk.yml` workflow, the secondary `.github/workflows/powershell.yml` workflow, `.gitmodules`, the README "Current pins" table, and `pwsh-src/PowerShell.Common.props` when the submodule is available.

## Prerequisites

- PowerShell 7 (`pwsh`).
- Initialize `pwsh-src/` before release-bump validation if you need target-framework verification.

## Usage

Run the default audit from the repository root:

```powershell
pwsh .\.agents\skills\powershell-pin-audit\scripts\Test-PowerShellPins.ps1
```

Require the `pwsh-src/` submodule and fail if `PowerShell.Common.props` is unavailable:

```powershell
pwsh .\.agents\skills\powershell-pin-audit\scripts\Test-PowerShellPins.ps1 -RequireSubmodule
```

Audit a different checkout:

```powershell
pwsh .\.agents\skills\powershell-pin-audit\scripts\Test-PowerShellPins.ps1 -RepositoryRoot D:\dev\pwsh-distro
```

## Checks

- `POWERSHELL_VERSION`, `POWERSHELL_RELEASE_TAG`, `POWERSHELL_UPSTREAM_TAG`, and `POWERSHELL_SOURCE_REF` are present in both PowerShell workflows.
- The two workflows use the same PowerShell pin values.
- `POWERSHELL_RELEASE_TAG` is `v$POWERSHELL_VERSION`.
- `POWERSHELL_UPSTREAM_TAG` is `upstream/$POWERSHELL_RELEASE_TAG`.
- `POWERSHELL_SOURCE_REF` is `downstream/$POWERSHELL_RELEASE_TAG`.
- `.gitmodules` tracks the same downstream branch as `POWERSHELL_SOURCE_REF`.
- README "Current pins" records the same upstream release, downstream source ref, upstream base tag, and target framework.
- If `pwsh-src/PowerShell.Common.props` exists, README's target framework matches its `<TargetFramework>` value.
