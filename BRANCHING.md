# Branching and tagging strategy

## Goals

- Keep downstream automation and packaging separate from the upstream PowerShell source tree.
- Carry Devolutions source patches on explicit per-release branches based on upstream PowerShell release tags.
- Support active LTS (`7.6`, `net10.0`) and STS (`7.7`, `net11.0`) release channels concurrently from `master`.
- Keep upstream and downstream refs distinct so channel pins are auditable.
- Expose each channel's patched source on `master` as a pinned submodule (`pwsh-src-7.6/`, `pwsh-src-7.7/`) and initialize only the selected channel's submodule in each build job.

## Branches

- `master`
  - Downstream distribution-only branch.
  - Contains README, agent instructions, GitHub Actions workflows, helper scripts, and packaging logic.
  - Do not add the upstream PowerShell source tree here.
- `upstream`
  - Mirror of the upstream `PowerShell/PowerShell` default branch.
  - Used for traceability and local comparisons, not for downstream patches.
- `downstream/vX.Y.Z`
  - Downstream patch branch for one upstream PowerShell release.
  - Created from the namespaced upstream tag `upstream/vX.Y.Z`.
  - Contains the full PowerShell source tree plus downstream patch commits.

## Tags

- Upstream mirrored tags:
  - `upstream/vX.Y.Z`
  - Example: `upstream/v7.6.3`
- Downstream release tags:
  - `vX.Y.Z.R`
  - `X.Y.Z` matches the upstream PowerShell version.
  - `R` is the downstream revision for additional releases from the same upstream version.
  - Example sequence for upstream `v7.6.3`: `v7.6.3.0`, `v7.6.3.1`, `v7.6.3.2`.

Do not use plain `vX.Y.Z` downstream tags. Those names belong to upstream PowerShell and are mirrored only under `upstream/*`.

## Release flow

1. Sync the upstream mirror branch and upstream tags.
2. Create a patch branch from the upstream release tag without switching the downstream `master` worktree:

   ```powershell
   .\scripts\New-PowerShellPatchBranch.ps1 -Version 7.6.10
   ```

3. Add a linked source worktree for `downstream/v7.6.10` (for example `pwsh-src-7.6-worktree`) and apply downstream PowerShell source patches there.
4. Update `eng/powershell-channels.json`, `.gitmodules`, and `README.md`, and bump the channel's submodule pointer (`pwsh-src-7.6` or `pwsh-src-7.7`) on `master` to the updated `downstream/vX.Y.Z` tip while keeping `powerShellReleaseTag` set to the upstream PowerShell release tag.
5. Run the PowerShell SDK workflow (or `.github/workflows/release.yml`) for the target `channel` (`7.6` or `7.7`).
6. Tag downstream releases as `vX.Y.Z.R` when publishing artifacts externally. Following `PowerShell/PowerShell`, `release.yml` marks a release as GitHub `Latest` only when no higher non-draft, non-prerelease `vA.B.C.R` release already exists, so `7.7.x` retains `Latest` when `7.6.x` servicing releases are published afterward.

## Channel pin model

`eng/powershell-channels.json` (loaded through `eng/PowerShellChannelConfig.ps1`) keeps source checkout refs separate from release metadata for each supported channel (`7.6` default, `7.7`):

- `powerShellVersion` (`POWERSHELL_VERSION`): package and artifact version, for example `7.6.10` or `7.7.0`.
- `powerShellReleaseTag` (`POWERSHELL_RELEASE_TAG`): upstream release tag passed to PowerShell build metadata, for example `v7.6.10` or `v7.7.0`.
- `powerShellUpstreamTag` (`POWERSHELL_UPSTREAM_TAG`): mirrored upstream source ref used for ancestry checks and release patch export, for example `upstream/v7.6.10` or `upstream/v7.7.0`.
- `powerShellSourceRef` (`POWERSHELL_SOURCE_REF`): downstream source branch to build, for example `downstream/v7.6.10` or `downstream/v7.7.0`.
- `submodulePath` (`POWERSHELL_SUBMODULE_PATH`): channel source submodule directory, `pwsh-src-7.6` or `pwsh-src-7.7`.
- `targetFramework`: upstream target framework moniker, `net10.0` (`7.6`) or `net11.0` (`7.7`).

This prevents a downstream source branch such as `downstream/v7.6.10` from being passed to PowerShell build logic that expects an upstream release tag.

## Source submodules

`master` exposes each channel's patched PowerShell source tree as a same-repository git submodule:

```ini
[submodule "pwsh-src-7.6"]
	path = pwsh-src-7.6
	url = ./
	branch = downstream/v7.6.10
[submodule "pwsh-src-7.7"]
	path = pwsh-src-7.7
	url = ./
	branch = downstream/v7.7.0
```

Each submodule pins a specific commit on `downstream/vX.Y.Z`, not the branch tip. Bumping a pointer is a normal commit on `master` and is reviewable in the PR diff. Workflows check out `master` and run `scripts/Initialize-Repository.ps1 -Channel <channel>` to populate only the selected channel's submodule using the default `GITHUB_TOKEN`; no second `actions/checkout` and no extra secrets are needed.

After rebasing `downstream/vX.Y.Z` (for example with an AI-assisted rebase that force-pushes the patch branch), re-bump the matching submodule on `master` so the pinned commit matches the new tip:

```powershell
git submodule update --remote pwsh-src-7.6
git add pwsh-src-7.6
```

## Local source worktree

The `pwsh-src-<channel>/` submodules on `master` are the build source of truth, and each is a detached checkout of its pinned commit. For developing patches, use a linked worktree on the patch branch:

```powershell
git worktree add pwsh-src-7.6-worktree downstream/v7.6.10
```

`pwsh-src-worktree/` and `pwsh-src-*-worktree/` are ignored by this repository. Commit source patches in that worktree on the `downstream/vX.Y.Z` branch, not on `master`, then bump the channel submodule pointer on `master` as described above.

## Patch export

To export a squashed patch for review or archival:

```powershell
.\scripts\Export-PowerShellPatch.ps1 -RepoPath pwsh-src-7.6-worktree -Branch downstream/v7.6.10
```

The script compares `upstream/v7.6.10...downstream/v7.6.10` and writes the patch under `patchsets/`, which is ignored by git.
