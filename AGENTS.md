# Agent instructions

This repository is a small GitHub Actions project for building PowerShell distribution artifacts. Treat `.github/workflows/powershell-sdk.yml` as the primary product surface and `.github/workflows/powershell.yml` as the secondary product surface.

Keep version pins explicit in workflow `env` blocks. When updating PowerShell, update the PowerShell version, release tag, upstream tag, and source ref in both PowerShell workflows, verify the upstream target framework from `pwsh-src/PowerShell.Common.props`, and keep SDK packaging paths derived from that property instead of hardcoding `net*` folders. The version bump is four coordinated edits in one PR: the `POWERSHELL_*` env vars in both PowerShell workflows, the `branch = downstream/vX.Y.Z` line in `.gitmodules` (git does not expand variables there, so it must be edited literally), the `pwsh-src` submodule pointer on `master` (`git submodule update --remote pwsh-src && git add pwsh-src`), and the "Current pins" table in README.md.

The repository uses a downstream patch branch model:

- `master` is downstream-only and must not contain the upstream PowerShell source tree directly. The patched source is exposed as a same-repo git submodule at path `pwsh-src/` (`url = ./`, `branch = downstream/vX.Y.Z`) pinned to a commit on the patch branch.
- `upstream` mirrors `PowerShell/PowerShell` for traceability.
- `upstream/vX.Y.Z` mirrors upstream PowerShell release tags.
- `downstream/vX.Y.Z` branches contain full PowerShell sources plus downstream patches.
- Downstream release tags use `vX.Y.Z.R`.

In PowerShell workflows, keep the source checkout ref separate from build version metadata. `POWERSHELL_SOURCE_REF` can point at `downstream/vX.Y.Z`, but `POWERSHELL_RELEASE_TAG` should remain the upstream release tag passed to PowerShell build logic. Workflows check out the project with `actions/checkout` using `submodules: true` to populate `pwsh-src/` from the pinned submodule commit; do not add a second `actions/checkout` for PowerShell source. When the patch branch is rebased and force-pushed, re-bump the `pwsh-src` submodule pointer on `master` with `git submodule update --remote pwsh-src` and commit that change.

The `.NET runtime` workflow uses `awakecoding/llvm-prebuilt` assets. When refreshing it, verify the release tag and required `clang+llvm-<version>-x86_64-<platform>.tar.xz` assets exist before changing `CLANG_LLVM_VERSION`, `CLANG_LLVM_RELEASE`, or runner OS labels.

`pwsh-src/` is a tracked submodule, not a generated directory. Do not commit generated `dotnet-runtime/`, package, archive, or build output directories, and do not commit a locally generated `pwsh-src-worktree/` worktree. Prefer validating workflow edits with a YAML parser and `git diff --check` before finishing.
