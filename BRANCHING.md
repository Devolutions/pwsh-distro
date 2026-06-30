# Branching and tagging strategy

## Goals

- Keep downstream automation and packaging separate from the upstream PowerShell source tree.
- Carry Devolutions source patches on explicit per-release branches based on upstream PowerShell release tags.
- Keep upstream and downstream refs distinct so workflow pins are auditable.
- Expose the patched source on `master` as a pinned submodule so workflows build the exact reviewed tree without a second checkout.

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
   .\scripts\New-PowerShellPatchBranch.ps1 -Version 7.6.3
   ```

3. Add a linked source worktree for `downstream/v7.6.3` and apply downstream PowerShell source patches there.
4. Bump the `pwsh-src` submodule on `master` to the updated `downstream/vX.Y.Z` tip and update workflow pins so `POWERSHELL_SOURCE_REF` points to the desired `downstream/vX.Y.Z` branch while `POWERSHELL_RELEASE_TAG` remains the upstream PowerShell release tag.
5. Run the PowerShell SDK workflow first, then the PowerShell distribution workflow if the SDK package is valid.
6. Tag downstream releases as `vX.Y.Z.R` when publishing artifacts externally.

## Workflow pin model

PowerShell workflows keep source checkout refs separate from release metadata:

- `POWERSHELL_VERSION`: package and artifact version, for example `7.6.3`.
- `POWERSHELL_RELEASE_TAG`: upstream release tag passed to PowerShell build metadata, for example `v7.6.3`.
- `POWERSHELL_UPSTREAM_TAG`: mirrored upstream tag used for ancestry checks, for example `upstream/v7.6.3`.
- `POWERSHELL_SOURCE_REPOSITORY`: repository containing the source branch, normally this repository.
- `POWERSHELL_SOURCE_REF`: downstream source branch to build, for example `downstream/v7.6.3`.

This prevents a downstream source branch such as `downstream/v7.6.3` from being passed to PowerShell build logic that expects an upstream release tag.

## Source submodule

`master` exposes the patched PowerShell source tree as a same-repository git submodule at path `pwsh-src/`:

```ini
[submodule "pwsh-src"]
    path = pwsh-src
    url = ./
    branch = downstream/v7.6.3
```

The submodule pins a specific commit on `downstream/vX.Y.Z`, not the branch tip. Bumping the pointer is a normal commit on `master` and is reviewable in the PR diff. Workflows check out the project with `submodules: true`, which is enough to populate `pwsh-src/` using the default `GITHUB_TOKEN`; no second `actions/checkout` and no extra secrets are needed.

After rebasing `downstream/vX.Y.Z` (for example with an AI-assisted rebase that force-pushes the patch branch), re-bump the submodule on `master` so the pinned commit matches the new tip:

```powershell
git submodule update --remote pwsh-src
git add pwsh-src
```

## Local source worktree

The `pwsh-src/` submodule on `master` is the build source of truth, but it is a detached checkout of the pinned commit. For developing patches, use a linked worktree on the patch branch:

```powershell
git worktree add pwsh-src-worktree downstream/v7.6.3
```

`pwsh-src-worktree/` is ignored by this repository. Commit source patches in that worktree on the `downstream/vX.Y.Z` branch, not on `master`, then bump the submodule pointer on `master` as described above.

## Patch export

To export a squashed patch for review or archival:

```powershell
.\scripts\Export-PowerShellPatch.ps1 -RepoPath pwsh-src-worktree -Branch downstream/v7.6.3
```

The script compares `upstream/v7.6.3...downstream/v7.6.3` and writes the patch under `patchsets/`, which is ignored by git.
