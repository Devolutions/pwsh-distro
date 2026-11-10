# Agent instructions

This repository is a small GitHub Actions project for building PowerShell distribution artifacts across multiple supported PowerShell release channels (`7.6` LTS on `.NET 10` and `7.7` STS on `.NET 11`). Treat `.github/workflows/powershell-sdk.yml` as the primary product surface and `.github/workflows/powershell-cli.yml` as the secondary product surface.

Keep shared tool pins explicit in workflow `env` blocks and per-channel PowerShell/.NET pins in `eng/powershell-channels.json` (loaded via `eng/PowerShellChannelConfig.ps1`). When updating a PowerShell channel, update its version, release tag, upstream tag, source ref, and target framework in `eng/powershell-channels.json`, verify the upstream target framework from `pwsh-src-<channel>/PowerShell.Common.props`, and keep SDK packaging paths derived from that property instead of hardcoding `net*` folders. A channel version bump is four coordinated edits in one PR: `eng/powershell-channels.json`, the `branch = downstream/vX.Y.Z` line under `[submodule "pwsh-src-<channel>"]` in `.gitmodules` (git does not expand variables there, so it must be edited literally), the `pwsh-src-<channel>` submodule pointer on `master` (`git submodule update --remote pwsh-src-<channel> && git add pwsh-src-<channel>`), and the "Current pins" table in `README.md`.

The repository uses a downstream patch branch model with per-channel source submodules:

- `master` is downstream-only and must not contain the upstream PowerShell source tree directly. Each active release channel exposes its patched source as a same-repo git submodule at `pwsh-src-<channel>/` (`pwsh-src-7.6/` and `pwsh-src-7.7/`, `url = ./`, `branch = downstream/vX.Y.Z`) pinned to a commit on that channel's patch branch.
- `upstream` mirrors `PowerShell/PowerShell` for traceability.
- `upstream/vX.Y.Z` mirrors upstream PowerShell release tags.
- `downstream/vX.Y.Z` branches contain full PowerShell sources plus downstream patches.
- Downstream release tags use `vX.Y.Z.R`.

In PowerShell workflows and `eng/powershell-channels.json`, keep the source checkout ref separate from build version metadata. `powerShellSourceRef` (`POWERSHELL_SOURCE_REF`) points at `downstream/vX.Y.Z`, while `powerShellReleaseTag` (`POWERSHELL_RELEASE_TAG`) remains the upstream release tag passed to PowerShell build logic. Workflows check out the project with `actions/checkout` and initialize only the selected channel's submodule via `scripts/Initialize-Repository.ps1 -Channel <channel>`; do not initialize all submodules in CI jobs or add a second `actions/checkout` for PowerShell source. When a patch branch is rebased and force-pushed, re-bump `pwsh-src-<channel>` on `master` with `git submodule update --remote pwsh-src-<channel>` and commit that change.

In `.github/workflows/release.yml`, GitHub's single `Latest` release badge follows upstream `PowerShell/PowerShell` semantics: `Test-ShouldMarkGitHubReleaseLatest` passes `--latest=false` whenever a higher non-draft, non-prerelease `vX.Y.Z.R` release already exists, keeping `Latest` on the highest GA line (`7.7.x`) when servicing releases (`7.6.x`) are published later.

The `.NET runtime` workflow uses `awakecoding/llvm-prebuilt` assets and builds channel-scoped `DotNet-Runtime-<channel>-<rid>` artifacts using the `.NET` version/ref and cross-build images from `eng/powershell-channels.json`. When refreshing LLVM pins, verify the release tag and required `clang+llvm-<version>-x86_64-<platform>.tar.xz` assets exist before changing `CLANG_LLVM_VERSION`, `CLANG_LLVM_RELEASE`, or runner OS labels.

`pwsh-src-7.6/` and `pwsh-src-7.7/` are tracked submodules, not generated directories. Do not commit generated `dotnet-runtime/`, package, archive, or build output directories, and do not commit locally generated `pwsh-src-worktree/` or `pwsh-src-*-worktree/` worktrees. Prefer validating workflow edits with a YAML parser, `Test-PowerShellPins.ps1`, and `git diff --check` before finishing.
