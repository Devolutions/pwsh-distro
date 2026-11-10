---
name: powershell-release-bump
description: Upgrades a PowerShell channel (7.6 or 7.7) to a new release by mirroring its tag, porting downstream patches, publishing the downstream source branch, and coordinating channel manifest and submodule pins.
---

# powershell release bump

Use this skill when moving a PowerShell channel (`7.6` or `7.7`) in this repository to a new upstream PowerShell release. It covers the full upgrade flow: mirror the upstream tag, create and patch the downstream source branch, update the channel's submodule pin (`pwsh-src-<channel>`), and synchronize `eng/powershell-channels.json`, `.gitmodules`, and `README.md`.

Do not use this skill to merely check existing pins; use `powershell-pin-audit` for that. Do not copy the PowerShell source tree to `master`: each channel remains a `pwsh-src-<channel>` submodule pinned to a commit on a per-release downstream branch.

Keep source checkout and build metadata separate in `eng/powershell-channels.json`:

- `powerShellReleaseTag` is the upstream release tag, `vX.Y.Z`.
- `powerShellUpstreamTag` is the mirrored tag, `upstream/vX.Y.Z`.
- `powerShellSourceRef` is the patched source branch, `downstream/vX.Y.Z`.

## Prerequisites

- PowerShell 7 (`pwsh`).
- Git push permission for this repository. The source branch and mirrored upstream tag must be available on `origin` before `master` points at them.
- A clean or understood working tree. Do not overwrite unrelated work.
- Yayaml for workflow parsing:

  ```powershell
  Install-Module Yayaml -Scope CurrentUser
  ```

## Scripts

- `scripts\Set-PowerShellReleasePins.ps1`: Updates channel pins in `eng/powershell-channels.json`, `.gitmodules`, and README.
- `..\powershell-pin-audit\scripts\Test-PowerShellPins.ps1`: Audits the resulting pins after the edit.
- `..\..\..\..\scripts\New-PowerShellPatchBranch.ps1`: Creates `downstream/vX.Y.Z` from `upstream/vX.Y.Z`.
- `..\..\..\..\scripts\Sync-PowerShellUpstream.ps1`: Mirrors upstream refs and namespaced tags.
- `..\..\..\..\scripts\Build-LocalPowerShellSdk.ps1`: Canonical local SDK build. Prefer the `powershell-sdk-package-validate` skill to run it with package validation.

## Upgrade procedure

Set the channel, previous release, and target PowerShell release. The examples below update channel `7.6` from `7.6.9` to `7.6.10`:

```powershell
$Channel = '7.6'
$SubmodulePath = "pwsh-src-$Channel"
$PreviousVersion = '7.6.9'
$Version = '7.6.10'
```

### 1. Inspect the release and existing patch series

Confirm that the upstream release exists, identify every downstream commit in oldest-first order, and record the current target framework:

```powershell
gh api "repos/PowerShell/PowerShell/releases/tags/v$Version" --jq '.tag_name, .published_at, .target_commitish'
git log --oneline --reverse "upstream/v$PreviousVersion..origin/downstream/v$PreviousVersion"
git show "upstream/v$PreviousVersion:PowerShell.Common.props" |
  Select-String -Pattern 'TargetFramework'
```

The patch range is the source of truth. Carry all of its commits unless a newer upstream release has already incorporated an equivalent change.

### 2. Mirror and publish the upstream release tag

Synchronize namespaced upstream tags, verify the target tag, and publish the refreshed upstream mirror branch plus the new mirror tag:

```powershell
pwsh .\scripts\Sync-PowerShellUpstream.ps1 -SyncTags
git rev-parse --verify "upstream/v$Version^{commit}"
git show "upstream/v$Version:PowerShell.Common.props" |
  Select-String -Pattern 'TargetFramework'
git push --force origin "refs/heads/upstream:refs/heads/upstream"
git push origin "refs/tags/upstream/v$Version:refs/tags/upstream/v$Version"
```

Use the target release's `PowerShell.Common.props` as the target-framework authority. It may change between PowerShell releases; never hardcode an assumed `net*` folder.

### 3. Create and patch the downstream source branch

Create the downstream branch from the mirrored tag, then use an isolated linked worktree for source changes. Keep this worktree outside the repository checkout or in ignored `pwsh-src-<channel>-worktree\`; never commit it to `master`.

```powershell
pwsh .\scripts\New-PowerShellPatchBranch.ps1 -Version $Version
$PatchWorktree = "pwsh-src-$Channel-worktree"
git worktree add $PatchWorktree "downstream/v$Version"

$PatchCommits = @(git rev-list --reverse "upstream/v$PreviousVersion..origin/downstream/v$PreviousVersion")
if ($PatchCommits.Count -gt 0) {
  git -C $PatchWorktree cherry-pick @PatchCommits
  if ($LASTEXITCODE -ne 0) {
    throw "Resolve the cherry-pick in $PatchWorktree, then run 'git -C $PatchWorktree cherry-pick --continue'."
  }
}
```

When a cherry-pick conflicts, inspect the target release's implementation and port the downstream intent, then continue:

```powershell
git -C $PatchWorktree status
# Resolve only the relevant source conflict, then:
git -C $PatchWorktree add <resolved-files>
git -C $PatchWorktree cherry-pick --continue
```

If Git reports an empty cherry-pick, first verify the target release already contains the downstream behavior. Only then skip it:

```powershell
git -C $PatchWorktree show --stat CHERRY_PICK_HEAD
git -C $PatchWorktree cherry-pick --skip
```

Validate the patched source, confirm it remains based on the target upstream tag, then publish the branch before updating the submodule:

```powershell
git -C $PatchWorktree diff --check
if ($LASTEXITCODE -ne 0) {
  throw "The patched source diff check failed."
}
git -C $PatchWorktree merge-base --is-ancestor "upstream/v$Version^{commit}" HEAD
if ($LASTEXITCODE -ne 0) {
  throw "downstream/v$Version is not based on upstream/v$Version."
}
git -C $PatchWorktree log --oneline "upstream/v$Version..HEAD"
git push origin "downstream/v$Version"
if ($LASTEXITCODE -ne 0) {
  throw "Failed to publish downstream/v$Version."
}
```

### 4. Update coordinated distribution pins

Read the target framework from the patched worktree and pass it to the pin script. Passing it explicitly avoids depending on the currently pinned submodule checkout, which still represents the previous release.

```powershell
[xml] $CommonProps = Get-Content -Raw (Join-Path $PatchWorktree 'PowerShell.Common.props')
$TargetFramework = $CommonProps.Project.PropertyGroup |
  ForEach-Object { $_.TargetFramework } |
  Where-Object { $_ } |
  Select-Object -First 1

pwsh .\.agents\skills\powershell-release-bump\scripts\Set-PowerShellReleasePins.ps1 `
  -Channel $Channel `
  -Version $Version `
  -TargetFramework $TargetFramework
```

The script updates these coordinated surfaces for `$Channel` without modifying other channels:

- `powerShellVersion`, `powerShellReleaseTag`, `powerShellUpstreamTag`, `powerShellSourceRef`, `targetFramework`, `sdkPackageRevision`, `cliSdkPackageVersion`, and `cliSdkPackageRevision` in `eng/powershell-channels.json`.
- The literal `branch = downstream/vX.Y.Z` line under `[submodule "pwsh-src-<channel>"]` in `.gitmodules`.
- The README "Current pins" rows for `PowerShell <channel> (<track>)`.

Update the channel gitlink only after the new downstream branch is on `origin`:

```powershell
git submodule update --init --remote $SubmodulePath
git add $SubmodulePath
```

### 5. Validate and clean up

The checked-out channel submodule is now the target-framework authority for the final audit:

```powershell
pwsh .\.agents\skills\powershell-pin-audit\scripts\Test-PowerShellPins.ps1 -Channel $Channel -RequireSubmodule

Import-Module Yayaml
Get-Content -Raw .github\workflows\powershell-sdk.yml | ConvertFrom-Yaml | Out-Null
Get-Content -Raw .github\workflows\powershell-cli.yml | ConvertFrom-Yaml | Out-Null

git -C $SubmodulePath rev-parse --verify "upstream/v$Version^{commit}"
if ($LASTEXITCODE -ne 0) {
  throw "$SubmodulePath is missing upstream/v$Version."
}
git -C $SubmodulePath merge-base --is-ancestor "upstream/v$Version^{commit}" HEAD
if ($LASTEXITCODE -ne 0) {
  throw "$SubmodulePath is not based on upstream/v$Version."
}
git --no-pager diff --check
if ($LASTEXITCODE -ne 0) {
  throw "The unstaged diff check failed."
}
git --no-pager diff --cached --check
if ($LASTEXITCODE -ne 0) {
  throw "The staged diff check failed."
}
git submodule status $SubmodulePath
git status --short
```

Remove the temporary worktree only after it is clean:

```powershell
git worktree remove $PatchWorktree
git worktree prune
```

Before opening the distribution PR, use `powershell-sdk-package-validate` (`-Channel $Channel`) to build and validate one local SDK package. In GitHub Actions, run the SDK workflow (or `release.yml`) with `channel=$Channel`.

## Safety checklist

1. Verify `eng/powershell-channels.json`, `.gitmodules`, and `README.md` agree on all pins for every configured channel.
2. Verify `powerShellReleaseTag` remains `vX.Y.Z`, not `downstream/vX.Y.Z`.
3. Confirm the current `pwsh-src-<channel>` commit is a descendant of `upstream/vX.Y.Z` and is on the published `downstream/vX.Y.Z` branch.
4. Confirm `.gitmodules` has a literal `branch = downstream/vX.Y.Z` value for `pwsh-src-<channel>` and the submodule diff is a gitlink update, not copied source files.
5. Ensure no generated `output\`, `package\`, archive, `dotnet-runtime\`, or temporary source-worktree paths are staged.
6. Do not create a downstream release tag until validated artifacts are ready; downstream tags use `vX.Y.Z.R`, never plain `vX.Y.Z`.
