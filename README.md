# pwsh-distro

GitHub Actions workflows for building redistributable PowerShell artifacts from upstream or downstream-patched source. The primary target is the slim-by-default vendored PowerShell SDK package, and the secondary target is a self-contained PowerShell distribution archive repackaged from the SDK.

## Quick start

This repository builds PowerShell from source across two release channels (`7.6` LTS on `.NET 10` and `7.7` STS on `.NET 11`). Each channel's patched PowerShell source tree is pulled in as a git submodule (`pwsh-src-7.6/` and `pwsh-src-7.7/`), and on Windows it requires long-path support enabled in git.

```powershell
git clone https://github.com/Devolutions/pwsh-distro.git
cd pwsh-distro
.\scripts\Initialize-Repository.ps1
```

By default, `scripts\Initialize-Repository.ps1` initializes the default channel (`7.6` at `pwsh-src-7.6/`). Pass `-Channel 7.7` to initialize `pwsh-src-7.7/`, or `-Channel All` to initialize both submodules.

All workflows are manual and start from the GitHub Actions **Run workflow** button (see the Workflows table below). Select `channel` (`7.6` or `7.7`) when dispatching `release.yml`, `powershell-sdk.yml`, `powershell-cli.yml`, or `dotnet-runtime.yml`. The workflows are the authoritative release builds, and `release.yml` publishes the validated NuGet package to NuGet.org and GitHub Releases.

> On Linux/macOS no long-path configuration is needed. On Windows, if `core.longpaths` is not enabled, submodule checkouts will fail with `Filename too long`. `scripts\Initialize-Repository.ps1` enables it before initializing the submodule. The workflows set this on their Windows runners automatically.

To build a local, current-RID SDK package for smoke testing outside Actions:

```powershell
.\scripts\Build-LocalPowerShellSdk.ps1 -Validate
# Or for PowerShell 7.7 (.NET 11):
.\scripts\Build-LocalPowerShellSdk.ps1 -Channel 7.7 -Validate
```

The local script writes a single-RID validation package under `output\local-sdk\<channel>\<rid>\`. The GitHub Actions SDK workflow remains the authoritative multi-RID package build. Pass `-SdkPackageVersion 7.6.9.1` to smoke-test a specific published downstream package revision while a newer release is being prepared.

## Current pins

| Component | Version |
| --- | --- |
| Default PowerShell channel | `7.6` (`eng/powershell-channels.json`) |
| PowerShell 7.6 (LTS) upstream release | `7.6.10` / `v7.6.10` |
| PowerShell 7.6 (LTS) downstream source ref | `downstream/v7.6.10` based on `upstream/v7.6.10` (`pwsh-src-7.6`) |
| PowerShell 7.6 (LTS) target framework | `net10.0` |
| PowerShell 7.6 (LTS) SDK package | `Devolutions.PowerShell.SDK` / `7.6.10.0` workflow default; `7.6.9.1` latest published package |
| PowerShell 7.6 (LTS) .NET runtime workflow | `v10.0.5` |
| PowerShell 7.7 (STS) upstream release | `7.7.0` / `v7.7.0` |
| PowerShell 7.7 (STS) downstream source ref | `downstream/v7.7.0` based on `upstream/v7.7.0` (`pwsh-src-7.7`) |
| PowerShell 7.7 (STS) target framework | `net11.0` |
| PowerShell 7.7 (STS) SDK package | `Devolutions.PowerShell.SDK` / `7.7.0.0` workflow default |
| PowerShell 7.7 (STS) .NET runtime workflow | `v11.0.0` |
| Latest downstream release tag | `v7.6.9.1` |
| Latest PowerShell CLI release assets | `PowerShell-<version>-<os>-<arch>.tar.gz` for Windows, macOS, Linux, and Alpine Linux on x64 and arm64 |
| PowerShell SDK package source | `https://api.nuget.org/v3/index.json` |
| multi-pwsh apphost package | `Devolutions.MultiPwsh.Cli` / `0.14.2` |
| multi-pwsh apphost package source | `https://api.nuget.org/v3/index.json` |
| Linux multi-pwsh launcher source | `0.14.2` / `77676d18baaf205ec36b1711d11bd386d4b15272`; Rust `1.90.0` |
| Linux multi-pwsh bindings generator | PowerShell `7.4.0` |
| Linux ARM64 PowerShell.Native source | `700.0.2` / `f24d5494b373de20ec3e3d2fdc7c3fc98af1f9f1` |
| psign code signing tool | `Devolutions.Psign.Tool` / `0.7.0` |
| llvm-prebuilt | `v2026.1.1` |
| clang+llvm | `22.1.4` |
| VsDevShell | `latest from PSGallery` |

The `downstream/v7.6.7` source branch carries the existing downstream patches and
updates `System.Security.Cryptography.Pkcs` and `System.Security.Cryptography.Xml`
to `10.0.13`. Upstream PowerShell 7.6.7 still pins both SDK dependencies to the
vulnerable `10.0.10` versions. The downstream SDK package uses the patched source
dependency versions, and the engine also pins Pkcs to `10.0.13` for direct builds.
These updates address [CVE-2026-70162](https://github.com/advisories/GHSA-2fmv-rv2c-59x7),
[CVE-2026-84008](https://github.com/advisories/GHSA-846f-f764-76mx),
[CVE-2026-96958](https://github.com/advisories/GHSA-r955-8q5j-3h83),
[CVE-2026-96959](https://github.com/advisories/GHSA-c399-9853-6jmj), and
[CVE-2026-96960](https://github.com/advisories/GHSA-7hqp-7c5m-4vq6).
Framework-dependent applications must also use .NET 10.0.13 or later; updating
package dependencies does not patch an installed shared runtime.

## Getting started with release artifacts

### Devolutions PowerShell SDK

Use `Devolutions.PowerShell.SDK` when a .NET application needs the source-built Devolutions PowerShell assemblies and, optionally, a bundled `pwsh` apphost payload. Both `7.6.x` (`net10.0`, LTS) and `7.7.x` (`net11.0`, STS) publish under `Devolutions.PowerShell.SDK` (matching `Microsoft.PowerShell.SDK`). Applications remaining on `.NET 10` (such as Remote Desktop Manager) should constrain their package version range to `[7.6.*, 7.7.0)` until moving to `.NET 11`.

```powershell
dotnet new console -n PwshSdkSample -f net10.0
cd PwshSdkSample
dotnet add package Devolutions.PowerShell.SDK --version 7.6.9.1
```

For in-process PowerShell hosting, reference `System.Management.Automation` from the package and use the normal PowerShell SDK APIs:

```csharp
using System.Management.Automation;

using PowerShell powerShell = PowerShell.Create();
powerShell.AddScript("$PSVersionTable.PSVersion.ToString()");

foreach (PSObject result in powerShell.Invoke())
{
    Console.WriteLine(result);
}
```

To also copy a runnable PowerShell apphost beside your app, opt in from the project file:

```xml
<PropertyGroup>
  <PowerShellSDKAppHostLayout>Root</PowerShellSDKAppHostLayout>
  <PowerShellSDKLocalizedResources>Copy</PowerShellSDKLocalizedResources>
  <PowerShellSDKXmlDocumentation>Copy</PowerShellSDKXmlDocumentation>
  <PowerShellSDKPSGalleryModules>Microsoft.PowerShell.Archive;Microsoft.PowerShell.ThreadJob</PowerShellSDKPSGalleryModules>
</PropertyGroup>
```

Then publish for the target RID:

```powershell
dotnet publish -c Release -r win-x64 --self-contained true
.\bin\Release\net10.0\win-x64\publish\pwsh.exe -NoLogo -NoProfile -Command '$PSVersionTable'
```

Use `linux-x64`, `linux-arm`, `linux-arm64`, `osx-x64`, `osx-arm64`, `win-x64`, or `win-arm64` as the runtime identifier. If you only need the SDK assemblies and do not want an apphost copied to the output, leave `PowerShellSDKAppHostLayout` unset.

### PowerShell CLI

Use the PowerShell CLI archives when you want a ready-to-run, self-contained PowerShell layout without creating a .NET project. Download the archive for the target platform from the latest GitHub release:

```powershell
gh release download v7.6.3.2 --repo Devolutions/pwsh-distro --pattern PowerShell-7.6.3-windows-x64.tar.gz --dir pwsh-cli
tar -xzf .\pwsh-cli\PowerShell-7.6.3-windows-x64.tar.gz -C .\pwsh-cli
.\pwsh-cli\pwsh.exe -NoLogo -NoProfile -Command '$PSVersionTable'
```

On Linux or macOS, use the matching `PowerShell-7.6.3-linux-<arch>.tar.gz` or `PowerShell-7.6.3-macos-<arch>.tar.gz` asset, then run `./pwsh-cli/pwsh`. The release currently publishes CLI archives for:

| Platform | Assets |
| --- | --- |
| Windows | `PowerShell-7.6.3-windows-x64.tar.gz`, `PowerShell-7.6.3-windows-arm64.tar.gz` |
| macOS | `PowerShell-7.6.3-macos-x64.tar.gz`, `PowerShell-7.6.3-macos-arm64.tar.gz` |
| Linux (glibc) | `PowerShell-7.6.3-linux-x64.tar.gz`, `PowerShell-7.6.3-linux-arm64.tar.gz` |

New releases additionally include `PowerShell-<version>-linux-musl-x64.tar.gz` and `PowerShell-<version>-linux-musl-arm64.tar.gz` for Alpine Linux. The CLI archives are produced from the release-ready `Devolutions.PowerShell.SDK` package, so they include the same source-built PowerShell payloads. Windows archives also include the matching Windows Desktop runtime payload needed for WPF/WinForms assemblies under `$PSHOME`.

### Windows MSI installers

The release workflow builds x64 and ARM64 MSI installers from its release-ready Windows CLI archives, signs the MSIs with `Devolutions.Psign.Tool` 0.7.0 and Azure Key Vault when SDK code signing is enabled, and includes both installers in release assets and checksums. Non-dry-run releases require signing secrets. Selecting the `prod` GitHub environment alone does **not** enable signing: dry runs, including `skip-publish` runs, remain unsigned unless `sign-dry-run` is enabled with signing secrets. For a signed production dry run, set `github-env=prod`, `dry-run=true`, and `sign-dry-run=true` (and optionally `skip-publish=true` to skip the publish job entirely). Installing MSIs requires administrator privileges.

The MSI also installs a machine-wide Windows Terminal profile fragment for **PowerShell** under `%ProgramData%\Microsoft\Windows Terminal\Fragments`. Windows Terminal detects it on its next start; it does not change the user's default profile. Uninstalling PowerShell removes the fragment.

You can also run `.github/workflows/powershell-msi.yml` separately with a **published** release tag such as `v7.6.3.2`, or leave `release_tag` blank and provide a CLI workflow `cli_run_id` plus `package_version` (for example `7.6.6.0`). Standalone MSI signing defaults to enabled and requires code signing secrets in the selected GitHub environment; disable `sign_msi` only for unsigned test artifacts. Signing an MSI does not sign previously unsigned binaries inside a CLI artifact.

Packaging sources live in the top-level `package/` directory so other distribution formats can be added beside `package/msi/`. The installer source and image assets were copied from PowerShell's MIT-licensed 7.6.6 installer and migrated to WiX 4; the upstream copyright and permission notice appears below. `package/msi/New-PowerShellDistroMsi.ps1` harvests the existing CLI layout, not the upstream PowerShell build output. It restores pinned WiX 4 packages from NuGet.org and can be run locally on Windows with a previously unpacked Windows CLI archive:

```powershell
.\package\msi\New-PowerShellDistroMsi.ps1 -PayloadDirectory .\pwsh-cli -PackageVersion 7.6.6.0 -Architecture x64 -OutputDirectory .\output\msi
```

The MSI build rejects a `pwsh.exe` whose PE architecture does not match the requested MSI architecture and checks the compiled Directory, Upgrade, and LaunchCondition tables. CI installs the resulting packages on x64 Windows and native ARM64 Windows, testing upgrade from a test-only previous-layout MSI, repair, uninstall, and rejection of the opposite architecture in both directions. That fixture is built from the current CLI payload with an earlier MSI version and the former `<major>-<arch>` directory; it is never signed or published. When signing is enabled, CI verifies the MSI signature and the signatures of `pwsh.exe`, `pwsh.dll`, and `System.Management.Automation.dll` before uploading the MSI and after installation.

The installer uses Devolutions product names, architecture-specific upgrade codes, registry keys, and Start menu entries rather than Microsoft's MSI identity. Both x64 and ARM64 now default to `C:\Program Files\Devolutions\PowerShell\7`; they cannot be installed side by side because they share that directory. The MSI detects the opposite architecture and blocks installation instead of overwriting its files. Each architecture retains its own upgrade code, so installing a higher-version MSI of the same architecture upgrades an existing installation in `7-x64` or `7-arm64` to the shared `7` directory. An already installed `7.6.6.1` MSI needs a higher revision (for example, `7.6.6.2`); reinstalling the same version will not migrate its path. Optional PATH integration and event-manifest registration are off by default; Microsoft Update enrollment, shared App Paths registration, and machine-wide telemetry changes from the upstream installer are intentionally omitted. Other optional context-menu and remoting features remain. MSI versions encode `X.Y.Z.R` as `X.Y.(Z * 100 + R)` so revision bumps are upgrades (`R` must be 0–99). The `package/msi/` sources do not need an upstream MSI target and remain on the distro branch when PowerShell 7.7 removes upstream packaging.

### macOS pkg installers

The release workflow also builds x64 (Intel) and arm64 (Apple silicon) macOS `.pkg` installers from its release-ready macOS CLI archives, modeled on Microsoft's `powershell-<version>-osx-<arch>.pkg`, and includes `Devolutions-PowerShell-X.Y.Z.R-osx-x64.pkg` and `Devolutions-PowerShell-X.Y.Z.R-osx-arm64.pkg` in release assets and checksums. Install from a terminal with:

```bash
sudo installer -pkg ./Devolutions-PowerShell-7.6.9.2-osx-arm64.pkg -target /
pwsh -NoLogo -Command '$PSVersionTable'
```

The package installs PowerShell to a versioned directory, `/usr/local/devolutions/powershell/7`, and installs a `/usr/local/bin/pwsh` launcher that executes that payload. It also registers `/usr/local/bin/pwsh` in `/etc/shells`, installs the `pwsh(1)` man page to `/usr/local/share/man/man1/pwsh.1.gz`, and adds a `/Applications/Devolutions PowerShell.app` launcher that opens `pwsh` in Terminal. The launcher script is intentional: the vendored `multi-pwsh` apphost misinterprets a symlink as a manager shim and tries to create its default manager layout under `/usr/local`. The package uses the `com.devolutions.powershell` identifier and a separate install directory, so it does not modify Microsoft's `/usr/local/microsoft/powershell/7` installation, but whichever package was installed last owns the shared `/usr/local/bin/pwsh` launcher and man page. A `preinstall` script verifies the macOS version before removing the previous `/usr/local/devolutions/powershell/7` payload so upgrades do not leave stale files or remove an installation on an unsupported system. Each package requires macOS 12 or later to support both the stock and source-built .NET runtime payloads; Intel Macs refuse the arm64 package, while Apple silicon can install the x64 package under Rosetta. When release signing is enabled (real publishes, or `sign-dry-run=true`), every Mach-O file in the payload is signed with the Devolutions Developer ID Application certificate using the hardened runtime and a secure timestamp; `pwsh` also receives PowerShell's upstream JIT and library-validation entitlements from `package/macos/assets/pwsh-entitlements.plist`. The product archive is signed with the Developer ID Installer certificate, then notarized and stapled with DevOps' `Devolutions/actions/macos-notarize@v1` action, so it opens normally from a browser download. Unsigned dry-run packages must be installed with `installer` as shown, or approved in **System Settings > Privacy & Security**. As with Microsoft's package, there is no uninstaller; remove an installation with:

```bash
sudo rm -rf /usr/local/devolutions/powershell/7 "/Applications/Devolutions PowerShell.app"
grep -Fqx 'exec "/usr/local/devolutions/powershell/7/pwsh" "$@"' /usr/local/bin/pwsh && sudo rm /usr/local/bin/pwsh
sudo pkgutil --forget com.devolutions.powershell
```

You can also run `.github/workflows/powershell-macos-pkg.yml` separately with a **published** release tag such as `v7.6.9.2`, or leave `release_tag` blank and provide a CLI workflow `cli_run_id` plus `package_version`. Standalone signing defaults to enabled with the `publish-prod` environment, which holds the Apple signing secrets; disable `sign_pkg` only for unsigned test artifacts. `package/macos/New-PowerShellDistroMacPkg.ps1` repackages an unpacked macOS CLI archive with `pkgbuild` and `productbuild`, normalizes permissions so only `pwsh` and `createdump` are executable, and rejects a `pwsh` whose Mach-O CPU type does not match the requested architecture. Pass `-CodeSigningIdentity` and `-InstallerSigningIdentity` (and optionally `-Keychain`) to produce a signed package. It can be run locally on macOS:

```powershell
./package/macos/New-PowerShellDistroMacPkg.ps1 -PayloadDirectory ./pwsh-cli -PackageVersion 7.6.9.2 -Architecture arm64 -OutputDirectory ./output/pkg
./package/macos/Test-PowerShellDistroMacPkg.ps1 -PkgPath ./output/pkg/Devolutions-PowerShell-7.6.9.2-osx-arm64.pkg -Architecture arm64 -PackageVersion 7.6.9.2
```

`Test-PowerShellDistroMacPkg.ps1` validates the expanded distribution, component metadata, and payload. CI additionally passes `-Install`, which uses `sudo installer` on native Intel and Apple silicon runners to verify the receipt, `/usr/local/bin/pwsh`, `$PSHOME`, process architecture, `/etc/shells`, man page, launcher, and stale-file removal on reinstall, and, on Intel, refusal of the arm64 package. Signed CI builds also pass `-RequireNotarization`, which verifies the Developer ID Installer signature, Developer ID Application hardened-runtime signatures and timestamps on every payload Mach-O file, the `pwsh` entitlements, the stapled ticket, and Gatekeeper acceptance; `-RequireSignature` performs the signature checks without notarization. Do not pass `-Install` on a workstation you do not want modified. The launcher icon, installer background, and man page in `package/macos/assets/` were copied from PowerShell's MIT-licensed 7.6.9 sources.

The copied PowerShell installer source and artwork carry this MIT license notice:

```text
Copyright (c) Microsoft Corporation.

MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED *AS IS*, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### Linux packages

The release workflow repackages the release-ready glibc Linux CLI archives into the PowerShell Linux package targets for both x64 and arm64:

| Distribution | x64 | arm64 |
| --- | --- | --- |
| Debian / Ubuntu (`deb`) | `devolutions-powershell_7.6.9.2-1.deb_amd64.deb` | `devolutions-powershell_7.6.9.2-1.deb_arm64.deb` |
| RHEL / Fedora (`rh`) | `devolutions-powershell-7.6.9.2-1.rh.x86_64.rpm` | `devolutions-powershell-7.6.9.2-1.rh.aarch64.rpm` |
| Azure Linux 3 (`cm`) | `devolutions-powershell-7.6.9.2-1.cm.x86_64.rpm` | `devolutions-powershell-7.6.9.2-1.cm.aarch64.rpm` |
| Azure Linux 4 (`azl4`) | `devolutions-powershell-7.6.9.2-1.azl4.x86_64.rpm` | `devolutions-powershell-7.6.9.2-1.azl4.aarch64.rpm` |

These packages bundle the .NET runtime and declare their system dependencies, including certificates and timezone data. They install under `/opt/devolutions/powershell/7`, link `/usr/bin/pwsh`, and register the shell in `/etc/shells`. They conflict with Microsoft's `powershell` package because both own that link. The RHEL/Fedora RPM requires an OpenSSL 1.1 or 3 library; on Fedora versions that default to OpenSSL 4, the package manager installs the compatible OpenSSL 3 library. The packages are not GPG-signed or published to an apt or RPM repository.

```bash
sudo apt-get install ./devolutions-powershell_7.6.9.2-1.deb_amd64.deb
sudo dnf install ./devolutions-powershell-7.6.9.2-1.rh.x86_64.rpm
sudo tdnf install ./devolutions-powershell-7.6.9.2-1.cm.aarch64.rpm
```

Alpine uses the matching `linux-musl` CLI archive rather than an `.apk`, as in Microsoft's distribution. For example, on Alpine x64:

```sh
apk add --no-cache ca-certificates icu-libs krb5-libs libgcc libstdc++ openssl tzdata
mkdir -p pwsh-cli
tar -xzf PowerShell-7.6.9-linux-musl-x64.tar.gz -C pwsh-cli
./pwsh-cli/pwsh
```

`package/linux/New-PowerShellDistroLinuxPackage.ps1` builds deb or RPM packages from an unpacked glibc CLI archive using `dpkg-deb` or `rpmbuild`. The Linux packaging workflow can use a published `release_tag`, a CLI `cli_run_id` plus `package_version`, or the current release's prepared archives. It installs, runs, and removes each package in Ubuntu, Debian, RHEL UBI, Fedora, and Azure Linux containers on native x64 and arm64 runners. Azure Linux 4 uses Microsoft's preview base image. Older CLI artifacts whose launcher requires a newer glibc will fail these tests; use a CLI run produced by the updated workflow.

The CLI workflow builds the pinned multi-pwsh launcher from source for glibc 2.28 compatibility and for musl, includes its Rust dependencies' license metadata and standard-library notices, and tests both Alpine architectures in Alpine 3.22 and 3.23 containers. The release workflow repeats those Alpine tests on the release-ready archives, after any signing. The upstream PowerShell.Native package lacks a musl ARM64 library and its glibc ARM64 library requires a newer glibc than RHEL 8, so the workflow builds both ARM64 variants from pinned PowerShell.Native source. The musl launcher is staged into the CLI's temporary SDK restore; the published SDK's own apphost RID list remains unchanged. Keep the CLI launcher version and source ref aligned with the `MULTI_PWSH_APPHOST_PACKAGE_VERSION` pin in the SDK workflow, and update the native source pin when PowerShell's `Microsoft.PowerShell.Native` dependency changes.

## Workflows

| Workflow | Purpose | Output |
| --- | --- | --- |
| `.github/workflows/powershell-sdk.yml` | Builds PowerShell from source, vendors and signs the source-built payload, and validates the SDK package in a sample .NET app with opt-in apphost import. It can run manually or as a reusable workflow. | `PowerShell-SDK-Release-X.Y.Z.R` artifact containing the SDK `.nupkg`. |
| `.github/workflows/powershell-cli.yml` | Restores a pinned or workflow-built SDK package and builds self-contained Windows, macOS, glibc Linux, and Alpine Linux CLI archives for x64 and arm64. | `PowerShell-<version>-<os>-<arch>` `.tar.gz` artifacts, including `linux-musl` for Alpine. |
| `.github/workflows/powershell-msi.yml` | Packages published Windows CLI archives, CLI workflow artifacts, or the current release's prepared CLI archives, then signs and verifies the MSI when enabled. | `Devolutions-PowerShell-<tag-or-version>-win-<arch>-msi` artifacts containing an x64 or ARM64 `.msi`. |
| `.github/workflows/powershell-linux.yml` | Repackages Linux CLI archives as deb and RPM packages and tests installation, execution, and removal across supported distributions. | `Devolutions-PowerShell-<version>-linux-<arch>-packages` artifacts with one deb and three RPMs per architecture. |
| `.github/workflows/powershell-macos-pkg.yml` | Packages published macOS CLI archives, CLI workflow artifacts, or the current release's prepared CLI archives into macOS installer packages, then tests installation on native Intel and Apple silicon runners. | `Devolutions-PowerShell-<tag-or-version>-osx-<arch>-pkg` artifacts containing an x64 or arm64 `.pkg`. |
| `.github/workflows/release.yml` | Orchestrates the SDK, CLI, MSI, Linux, and macOS pkg workflows, signs release-ready CLI and MSI artifacts, publishes the SDK package, and creates the GitHub release. | GitHub release `vX.Y.Z.R` with the SDK `.nupkg`, eight CLI archives, two Windows MSIs, eight Linux packages, two macOS pkgs, the downstream patch, and checksums. |
| `.github/workflows/dotnet-runtime.yml` | Builds the .NET runtime for the selected channel (`v10.0.5` for `7.6`, `v11.0.0` for `7.7`) across Windows, macOS, glibc Linux, and Alpine Linux on x64 and arm64. Native builds use `awakecoding/llvm-prebuilt`; Linux builds use Microsoft's `.NET 10`/`.NET 11` cross-build images. | `DotNet-Runtime-<channel>-<rid>` artifacts containing the source-built runtime packs. |

All workflows are manual and can be started from the GitHub Actions **Run workflow** button.

## Publishing PowerShell releases

The release workflow publishes only after the SDK has been validated, every CLI archive, both MSI installers, and both macOS pkg installers have been built, and the Linux packages, Alpine archives, and macOS installers have passed their tests. ReadyToRun CLI archives are signed before installer packaging, so installers contain the final CLI payload. The release version is `<powerShellVersion>.<sdk_package_revision>`, such as `7.6.10.0` or `7.7.0.0`.

Manual inputs:

| Input | Purpose |
| --- | --- |
| `channel` | PowerShell release channel (`7.6` default for LTS / `.NET 10`, or `7.7` for STS / `.NET 11`). |
| `sdk_package_revision` | Optional revision override. Leave blank to use the selected channel's `sdkPackageRevision` pin in `eng/powershell-channels.json`, set a number such as `1` for a specific downstream revision, or set `auto` to infer the next revision from existing `vX.Y.Z.R` release tags. |
| `github-env` | `auto`, `test`, or `prod`. `auto` selects `publish-prod` for manual runs from `master` and `publish-test` elsewhere. |
| `skip-publish` | Builds, signs when requested, validates, and packages artifacts without publishing to NuGet.org or creating a GitHub release. |
| `dry-run` | Simulates publishing. This defaults to `true`; non-production environments are forced to dry-run when publishing is requested. |
| `sign-dry-run` | Signs the SDK payload, CLI binaries, and MSIs, and signs and notarizes the macOS pkgs, during a dry-run. Requires signing secrets and timestamp configuration; fails if they are missing. This defaults to `false` even with `github-env=prod` or `skip-publish=true`; set it to `true` for a signed production dry run. |
| `ready_to_run` | Applies ReadyToRun optimization to CLI archives. When SDK code signing is enabled, the release workflow signs and verifies the final post-R2R CLI archive payloads before checksums and release creation. |
| `use_custom_dotnet_runtime` | Optional. When enabled, repackages the CLI archives against a source-built .NET runtime instead of the stock `Microsoft.NETCore.App.Runtime.<rid>` pack from NuGet.org. If `dotnet_runtime_run_id` is blank, the release workflow builds `.github/workflows/dotnet-runtime.yml` for the selected `channel` first; set it to a specific run ID or `latest` to reuse a prior successful runtime run for that channel. Defaults to `false`, so releases use the stock runtime unless this is explicitly turned on. |
| `dotnet_runtime_run_id` | Optional. Reuse a prior successful `.NET runtime` workflow run instead of building one in the current release chain. Leave blank to build in the current workflow, or pass a specific run ID or `latest` to select the newest successful runtime run for the selected channel. |

The standalone CLI workflow also has an opt-in `ready_to_run` input that runs a targeted crossgen2 pass over packaged PowerShell managed assemblies after the self-contained layout is assembled. It is disabled by default because ReadyToRun rewrites managed PE files and invalidates existing Authenticode signatures. For signed releases, use `.github/workflows/release.yml` with both signing and `ready_to_run` enabled so the CLI archives are signed after the R2R pass.

Before validation and CLI packaging, the SDK workflow runs a signing stage that downloads the `.nupkg`, installs the pinned `Devolutions.Psign.Tool` .NET tool, extracts the package, signs the source-built payloads inside it with Azure Key Vault, and repacks the `.nupkg` without adding a NuGet package signature. The signing pass covers the built PowerShell assemblies in `ref/` and `runtimes/*/lib/`, the apphost payloads in `tools/apphost/*` and `runtimes/*/native`, the Windows desktop payload, and the built-in module manifests/format/script files in `contentFiles/any/any/runtimes/**/Modules/**`. A non-dry-run publish requires these environment secrets and variables:

| Name | Type |
| --- | --- |
| `CODE_SIGNING_KEYVAULT_URL` | Secret |
| `AZURE_TENANT_ID` | Secret |
| `CODE_SIGNING_CLIENT_ID` | Secret |
| `CODE_SIGNING_CLIENT_SECRET` | Secret |
| `CODE_SIGNING_CERTIFICATE_NAME` | Secret |
| `CODE_SIGNING_TIMESTAMP_SERVER` | Variable |

Signing and notarizing the macOS pkgs requires these secrets, provisioned by DevOps in the `publish-prod` environment, plus the organization `DEVOLUTIONSBOT_TOKEN` secret used to check out the private `Devolutions/actions` repository. Because the Apple secrets exist only in `publish-prod`, a signed dry run must use `github-env=prod`.

| Name | Purpose |
| --- | --- |
| `APPLE_APP_DEV_ID_APP_CERTIFICATE` | Base64 Developer ID Application `.p12` for payload code signing |
| `APPLE_APP_DEV_ID_APP_CERTIFICATE_PASSWORD` | Password for the Developer ID Application `.p12` |
| `APPLE_DEV_ID_INSTALLER_CERTIFICATE` | Base64 Developer ID Installer `.p12` for pkg signing |
| `APPLE_DEV_ID_INSTALLER_CERTIFICATE_PASSWORD` | Password for the Developer ID Installer `.p12` |
| `APPLE_BOT_PASSWORD` | App-specific password for notarization as the DevOps Apple bot account |

The complete release workflow uses the existing environments and secrets without configuration changes. Production releases require **four approval rounds**: SDK signing; one Windows job that prepares/signs all eight CLI archives and builds/signs both MSI installers; the two macOS pkg signing and notarization jobs; and final publishing after the MSI, Linux, and macOS installation tests succeed. SDK validation still runs on the signed package before CLI packaging, and MSI builds still consume the final post-ReadyToRun CLI payload. The reusable MSI workflow tests the prepared artifacts without starting its protected build jobs; standalone MSI runs retain their own build/signing stage. Production dry runs follow the same approval path when `skip-publish=false`; with `skip-publish=true`, the final publishing approval is omitted.

CLI signing replaces only the selected PE entries in each archive, preserving the original tar permissions, ownership, timestamps, and symlinks on Windows as well as Unix hosts. Run `./eng/Test-SignPowerShellDistroArchive.ps1` to exercise payload replacement, Unix metadata preservation, and failure handling without signing credentials.

Publishing uses the same NuGet.org OIDC pattern as `Devolutions/gsudo-distro`: repository environments named `publish-test` and `publish-prod`, `NuGet/login@v1`, and a `NUGET_BOT_USERNAME` secret available to the publishing environment. The release workflow grants `id-token: write` for NuGet OIDC and `contents: write` for GitHub release creation only in the publishing job. A real publish pushes the validated `.nupkg` containing signed Windows payloads to `https://api.nuget.org/v3/index.json` and creates a GitHub release named `Devolutions PowerShell vX.Y.Z.R` with tag `vX.Y.Z.R`, release notes, the SDK package, every CLI archive, both signed MSI installers, the Linux packages, both macOS pkg installers, the generated downstream PowerShell patch file, and a SHA256 checksum file covering all release assets. Matching upstream `PowerShell/PowerShell`, `release.yml` passes `--latest=false` whenever a higher non-draft, non-prerelease `vA.B.C.R` GitHub release already exists, so `7.7.x` retains the GitHub `Latest` badge even when `7.6.x` servicing releases are published afterward.

## Source-built .NET runtime option

By default, `powershell-cli.yml` repackages the `Devolutions.PowerShell.SDK` nupkg into self-contained archives using the stock `Microsoft.NETCore.App.Runtime.<rid>` pack restored from NuGet.org. For a fully from-source PowerShell distribution, the CLI workflow can instead consume the .NET runtime produced by `dotnet-runtime.yml`.

This is **off by default** and does not change existing behavior when unused. To enable it:

- In `powershell-cli.yml` (manual or reusable), set `use_custom_dotnet_runtime` to `true` and provide `dotnet_runtime_run_id` pointing at a completed `dotnet-runtime.yml` run for the selected `channel`, or set it to `latest` to auto-pick the newest successful `.NET runtime` run for that channel. The CLI job for each RID downloads the matching `DotNet-Runtime-<channel>-<rid>` artifact, stages it as a local NuGet folder feed, and repoints the self-contained restore/publish at that feed with `/p:RuntimeFrameworkVersion=<version>`.
- In `release.yml`, set `use_custom_dotnet_runtime` to `true`. If `dotnet_runtime_run_id` is blank, the release workflow runs `dotnet-runtime.yml` for the selected `channel` first; otherwise it skips the build and forwards the supplied run ID (including `latest`) to the reusable CLI job so the whole chain produces CLI archives built from the custom runtime.

Linux glibc runtime packs are cross-built against the .NET runtime workflow's Ubuntu 18.04 sysroot, and CI verifies their ELF dependencies require no newer than glibc 2.28 for RHEL 8 compatibility.

An older runtime workflow run without `linux-musl-x64` and `linux-musl-arm64` artifacts cannot supply the Alpine archives; run the updated runtime workflow before reusing its run ID.

`eng/New-PowerShellDistroArchive.ps1` accepts optional `-CustomRuntimeSource` and `-CustomRuntimePackageVersion` parameters that inject the local runtime feed (with `packageSourceMapping` patterns for `Microsoft.NETCore.App.*`) ahead of NuGet.org and pin the runtime pack version during restore and publish. When the parameters are omitted, the generated `nuget.config` and publish command are identical to the stock path.


This repository follows a downstream patch branch model inspired by `Devolutions/gsudo-distro`: `master` stays downstream-only, upstream PowerShell refs are mirrored under `upstream/*`, and source patches live on `downstream/vX.Y.Z` branches based on upstream release tags. Each channel's patched source is exposed on `master` as a same-repo submodule (`pwsh-src-7.6/` and `pwsh-src-7.7/`) pinned to a commit on `downstream/vX.Y.Z`, and workflows initialize only the selected channel's submodule via `scripts/Initialize-Repository.ps1 -Channel <channel>`. See [BRANCHING.md](BRANCHING.md) for the full branch, tag, submodule, and worktree flow.

## Updating PowerShell versions

When moving a channel (`7.6` or `7.7`) to a new upstream PowerShell release, the bump touches four surfaces in the same PR:

1. `eng/powershell-channels.json`: update the channel's `powerShellVersion`, `powerShellReleaseTag`, `powerShellUpstreamTag`, `powerShellSourceRef`, and `targetFramework`, reset `sdkPackageRevision` and `cliSdkPackageRevision` to `0` for the first downstream SDK package built from a new upstream tag, and update `cliSdkPackageVersion` accordingly.
2. `.gitmodules`: the `branch = downstream/vX.Y.Z` line under `[submodule "pwsh-src-<channel>"]` (git does not expand variables in `.gitmodules`, so this must be edited literally).
3. The `pwsh-src-<channel>` submodule pointer on `master`, bumped to the new `downstream/vX.Y.Z` tip with `git submodule update --remote pwsh-src-<channel> && git add pwsh-src-<channel>`.
4. The "Current pins" table above.

Verify the upstream target framework from `pwsh-src-<channel>/PowerShell.Common.props` after the bump and keep SDK packaging paths derived from that property instead of hardcoding `net*` folders.

## Notes

The PowerShell workflows check out this repository and run `scripts/Initialize-Repository.ps1 -Channel <channel>` to populate only `pwsh-src-<channel>/` from the pinned submodule commit on `downstream/vX.Y.Z`, while build metadata continues to use `POWERSHELL_RELEASE_TAG`. This allows downstream patch branches to be built without passing branch names to PowerShell build steps that expect upstream release tags. `powerShellSourceRef` (`POWERSHELL_SOURCE_REF`) documents which patch branch the submodule tracks; bumping the submodule pointer on `master` is what actually moves the built source. The release workflow exports the downstream patch by fetching both `POWERSHELL_UPSTREAM_TAG` and `POWERSHELL_SOURCE_REF` from `origin` and diffing the mirrored upstream ref against the mirrored downstream ref.

The SDK workflow intentionally derives the target framework from upstream `PowerShell.Common.props` (`net10.0` for `7.6`, `net11.0` for `7.7`) instead of hardcoding it, so future PowerShell updates only need the channel pins refreshed. The SDK package is assembled from locally built PowerShell binaries plus package layouts from the official NuGet packages for the same PowerShell version, then `eng/Vendor-PowerShellSdkPackage.ps1` rewrites the NuGet package ID, package version, and vendor metadata to Devolutions. The PowerShell source build also receives `PowerShellVendor=Devolutions` so the built `$PSVersionTable['Vendor']` value and related runtime metadata report Devolutions for vendored distributions.

The SDK and CLI `osx-x64` jobs run on Apple silicon (`macos-15`) instead of the slower Intel runners. The SDK apphost build remains framework-dependent portable IL and stages the x64 launcher from the pinned multi-pwsh package; CLI publishing still targets `osx-x64`. SDK validation retains restore, build, publish, and package-layout checks but skips runtime execution for this RID, and CLI packaging automatically skips execution probes when the target RID differs from the host. This avoids running x64 payloads under Rosetta. Native arm64 runtime tests and the separate native Intel macOS installer tests remain enabled.

The vendored SDK keeps upstream PowerShell build/runtime metadata separate from downstream NuGet package revisions. `POWERSHELL_VERSION` remains the upstream three-part PowerShell version used to restore Microsoft packages and validate `pwsh` runtime output. `eng/powershell-channels.json` keeps each channel's default downstream revision explicit in `sdkPackageRevision`; the manual `sdk_package_revision` input can override it or use `auto` to infer the next release tag revision. The package version is `POWERSHELL_VERSION.sdk_package_revision`, such as `7.6.10.0` or `7.7.0.0`. NuGet normalizes a trailing `.0` in package identity metadata, file names, and restore folders, so `7.6.10.0` is expected to produce/use `Devolutions.PowerShell.SDK.7.6.10.nupkg`; nonzero revisions keep all four elements.

The package keeps original assembly identities (`System.Management.Automation.dll`, `Microsoft.PowerShell.Commands.Utility.dll`, and related assemblies) so consumers only need to change the NuGet package reference. Source-built PowerShell assemblies are discovered from the selected `pwsh-src-<channel>` build outputs and embedded directly in `Devolutions.PowerShell.SDK`; the package records the embedded Microsoft package IDs and source-built package asset paths under `buildTransitive`, and validation fails if any of those package IDs appear in the restore graph. External packages that are not built by this repository, including `Microsoft.PowerShell.Native` and `Microsoft.PowerShell.MarkdownRender`, remain normal public NuGet dependencies.

`Devolutions.PowerShell.SDK` built from this repository is slim by default; existing published versions retain their original dependency metadata. It omits `Microsoft.Windows.Compatibility` and direct dependencies on `System.ServiceModel.Http`, `NetTcp`, `NetFramingBase`, `Primitives`, and `Syndication`; `System.Data.SqlClient`, `Odbc`, and `OleDb`; `System.Speech`; `System.ComponentModel.Composition` and `Composition.Registration`; `System.Reflection.Context`; `System.DirectoryServices.AccountManagement` and `Protocols`; `System.Security.Cryptography.Xml`; `System.Net.Http.WinHttpHandler`; `System.Runtime.Caching`; and `System.IO.Ports` and its RID-specific native packages. It retains the original PowerShell assemblies, type catalog, apphosts, and modules, as well as `System.Security.Cryptography.ProtectedData`, which PowerShell uses for Windows secure-string encryption.

Applications upgrading from an earlier SDK must explicitly reference any omitted packages their application, modules, or scripts need; those references still work with PowerShell's existing type catalog. SDK-hosted scripts that need an assembly supplied by `Microsoft.Windows.Compatibility`, such as `System.Web.Services.Description`, need the relevant package or an assembly supplied by their module. Referencing `Microsoft.Windows.Compatibility` restores its compatibility dependencies, but other omitted packages may still need individual references. Opting packages back in can also resolve older transitive versions: for example, `System.ServiceModel.Http` can bring in an older `System.Security.Cryptography.Xml`, so reference a patched version explicitly and review NuGet security warnings. Reducing the dependency graph can reduce ReadyToRun and trimming work, but does not by itself make PowerShell Native AOT or trimming compatible.

Standalone CLI archives retain their compatibility payload independently by referencing the omitted packages and `Microsoft.Windows.Compatibility` at the versions pinned in the upstream SDK project.

The SDK package also includes apphost files for `win-x64`, `win-arm64`, `linux-x64`, `linux-arm`, `linux-arm64`, `osx-x64`, and `osx-arm64`. These files are inert by default. A consuming project opts in by choosing an apphost layout. The root layout copies `pwsh`/`pwsh.exe`, `pwsh.dll`, `pwsh.runtimeconfig.json`, runtime assemblies, and built-in module manifests to the app root:

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

This copies a minimal native launcher to `runtimes/<rid>/native/pwsh.exe` (or `pwsh` on Unix) for each selected RID. The launcher loads `../../../pwsh.dll`, so `pwsh.dll`, `pwsh.runtimeconfig.json`, PowerShell runtime assemblies, built-in modules, and required RID-specific runtime library dependencies are copied to the app output root for external `pwsh` support. The original NuGet `runtimes/<group>/lib/<tfm>` payload is also preserved so the application `.deps.json` can resolve `System.Management.Automation` and built-in modules for in-process hosting. Leave `PowerShellSDKRuntimeNativeAppHostRuntimeIdentifiers` empty to copy every runtime-native launcher included in the package, or set it to a semicolon-delimited RID list. Unknown RIDs fail the build.

The source-built PowerShell runtime is patched so out-of-process jobs can use the selected runtime-native launcher when `$PSHOME/pwsh.exe` is not present. This lets `Start-Job` work in bundled-host scenarios that copy `pwsh.exe` under `runtimes/<rid>/native` instead of the app root.

Use `PowerShellSDKCopyPhases` to decide where opted-in payloads are copied. The default is `Output;Publish`; set it to `Output` or `Publish` to disable the other phase. The package also has optional config, localized resource, XML documentation, and PSGallery module payloads:

```xml
<PropertyGroup>
  <PowerShellSDKLocalizedResources>Copy</PowerShellSDKLocalizedResources>
  <PowerShellSDKXmlDocumentation>Copy</PowerShellSDKXmlDocumentation>
  <PowerShellSDKPSGalleryModules>Microsoft.PowerShell.Archive;Microsoft.PowerShell.ThreadJob</PowerShellSDKPSGalleryModules>
</PropertyGroup>
```

| Property | Default | Values | Effect |
| --- | --- | --- | --- |
| `PowerShellSDKAppHostLayout` | `None` | `None`, `Root`, `RuntimeNative`, `Both` | Selects the apphost file layout. |
| `PowerShellSDKAppHostImplementation` | `Auto` | `Auto`, `MultiPwsh`, `DotNet` | Selects the apphost executable implementation when the requested layout/package assets support it. Current package assets support `MultiPwsh` for `Root` and `RuntimeNative`. |
| `PowerShellSDKAppHostRuntimeIdentifier` | empty | RID | Overrides root apphost RID selection; otherwise `$(RuntimeIdentifier)` then `$(NETCoreSdkRuntimeIdentifier)` are used. |
| `PowerShellSDKAppHostTargetFramework` | empty | TFM | Overrides root apphost payload TFM lookup; normally platform-specific TFMs such as `net10.0-windows10.0.19041` normalize to the package TFM `net10.0`. |
| `PowerShellSDKRuntimeNativeAppHostRuntimeIdentifiers` | empty | RID list | Semicolon-delimited runtime-native launcher RIDs; empty selects all packaged RIDs. |
| `PowerShellSDKRuntimeNativeSharedPayloadRuntimeIdentifier` | empty | RID | Overrides the shared app-root PowerShell payload RID. Otherwise it follows `$(RuntimeIdentifier)`, `$(NETCoreSdkRuntimeIdentifier)`, then `PowerShellSDKAppHostRuntimeIdentifier`. |
| `PowerShellSDKRuntimeNativeSharedPayloadTargetFramework` | empty | TFM | Overrides shared payload TFM lookup; normally platform-specific TFMs such as `net10.0-windows10.0.19041` normalize to the package TFM `net10.0`. |
| `PowerShellSDKCopyPhases` | `Output;Publish` | `Output`, `Publish`, `Output;Publish` | Controls build output and publish copying for opted-in payloads. |
| `PowerShellSDKConfig` | `Copy` | `None`, `Copy` | Generates `powershell.config.json` when an apphost layout is enabled. |
| `PowerShellSDKConfigExecutionPolicy` | `Bypass` | PowerShell execution policy | Sets `Microsoft.PowerShell:ExecutionPolicy` in generated config. |
| `PowerShellSDKConfigOverwriteExisting` | `false` | `true`, `false` | Replaces existing `powershell.config.json` only when `true`. |
| `PowerShellSDKLocalizedResources` | `None` | `None`, `Copy` | Copies staged localized resource assemblies beside the apphost payload when the source package includes them. |
| `PowerShellSDKXmlDocumentation` | `None` | `None`, `Copy` | Copies assembly XML documentation files such as `System.Management.Automation.xml` beside the apphost payload. These files stay in the package for IntelliSense even when copy is disabled. |
| `PowerShellSDKPSGalleryModules` | `None` | `None`, `All`, or module list | Copies all staged PSGallery modules or a semicolon-delimited subset to `Modules`. |

When passing semicolon-delimited values on the `dotnet` or `msbuild` command line, encode semicolons as `%3B`, such as `/p:PowerShellSDKCopyPhases=Output%3BPublish`.

The apphost output is intended for running scripts with the core built-in modules from `$PSHOME/Modules`; it is not a full PowerShell distribution archive unless consumers deliberately enable optional payloads such as localized resources, XML documentation, and PSGallery modules. PSGallery modules increase package and output size, include additional package-management or interactive functionality, and several are script modules subject to the bundled PowerShell execution policy.

The secondary PowerShell CLI workflow uses this same package-consumer path instead of rebuilding PowerShell from source. It creates a temporary .NET project, restores the pinned SDK package from the pinned package source or a workflow-built SDK artifact, enables root apphost, XML documentation, and PSGallery module import, opts into localized resources when present, publishes self-contained for the matrix RID, removes the temporary host application files, validates the PowerShell layout, and archives the result as `.tar.gz` for every platform, including Windows. Windows archives additionally stage the matching `Microsoft.WindowsDesktop.App.Runtime.<rid>` payload so WPF/WinForms assemblies such as `PresentationFramework.dll`, `System.Windows.Forms.dll`, and `WindowsBase.dll` load from `$PSHOME`. The upstream Microsoft Update registration script is included in 7.6 Windows archives; upstream removed it in 7.7. For end-to-end dry runs outside `.github/workflows/release.yml`, pass `sdk_artifact_run_id` to `.github/workflows/powershell-cli.yml` so it downloads the `PowerShell-SDK-Release-X.Y.Z.R` artifact from a prior `.github/workflows/powershell-sdk.yml` run and repackages that workflow-built `.nupkg` instead of restoring from NuGet.org. If the artifact name does not include the SDK version, also pass `sdk_package_version`.

During NuGet packing, upstream `Microsoft.PowerShell.SDK` content file/reference metadata can emit NU5100/NU5131 package analysis warnings. The SDK workflow treats package validation as the source of truth: the generated sample must restore only the vendored PowerShell package ID, build, publish framework-dependent and self-contained outputs, execute `pwsh`, and load copied built-in modules.
Generated source checkouts and build artifacts are not part of this repository.
