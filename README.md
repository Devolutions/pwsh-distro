# Devolutions PowerShell

**Devolutions PowerShell** is an open, cross-platform distribution of PowerShell maintained by [Devolutions](https://devolutions.net). Built directly from upstream [`PowerShell/PowerShell`](https://github.com/PowerShell/PowerShell) source and code-signed by Devolutions, it provides ready-to-run **`pwsh` command-line installers and portable archives** for Windows, macOS, and Linux, as well as a slim **`.NET` hosting SDK** ([`Devolutions.PowerShell.SDK`](https://www.nuget.org/packages/Devolutions.PowerShell.SDK)) on NuGet.org.

Originally created for Devolutions applications and shared openly for everyone, Devolutions PowerShell continues publishing traditional machine-wide **Windows `.msi` installers** (`x64` and `arm64`) across both **PowerShell 7.6 (LTS)** and **PowerShell 7.7 (STS)**—even after upstream PowerShell 7.7 moved Windows installer packaging to MSIX—alongside auto-updating Windows 11 **`.msixbundle`** packages, notarized **macOS `.pkg`** installers, **Linux `.deb` and `.rpm`** packages (`x64` and `arm64`), and **Alpine Linux** / portable `.tar.gz` archives.

- **100% PowerShell 7 compatible, side-by-side safe**: Runs existing PowerShell scripts, profiles, and modules unchanged while installing into dedicated Devolutions directories on Windows and macOS (with distinct Devolutions blue `#0068C3` icons and Windows Terminal profiles) without overwriting Microsoft PowerShell.
- **Signed, notarized, and transparent**: Windows binaries and installers are Authenticode-signed, macOS `.pkg` installers are Apple-signed and notarized, and every [GitHub Release](https://github.com/Devolutions/pwsh-distro/releases) includes SHA-256 `checksums` and the exact downstream `.patch` applied on top of upstream PowerShell.
- **Active LTS and STS channels**: Choose **PowerShell 7.6 LTS** (`.NET 10`) for long-term production deployments or **PowerShell 7.7 STS** (`.NET 11`) for the latest PowerShell release line.

[**Install PowerShell CLI**](#installing-devolutions-powershell-cli) · [Windows (MSI)](#windows) · [macOS](#macos) · [Linux](#linux) · [**Devolutions PowerShell SDK**](#devolutions-powershell-sdk) · [Maintainer & Build Guide](#building-and-maintaining-this-repository)

---

## Release channels

Download CLI installers and archives from [**GitHub Releases**](https://github.com/Devolutions/pwsh-distro/releases), or add [`Devolutions.PowerShell.SDK`](https://www.nuget.org/packages/Devolutions.PowerShell.SDK) from [**NuGet.org**](https://www.nuget.org/packages/Devolutions.PowerShell.SDK).

| Channel | Support track | .NET runtime | Latest release | Recommended for |
| --- | --- | --- | --- | --- |
| **`7.6`** | **LTS** (Long-Term Support) | `.NET 10` (`net10.0`) | [`v7.6.10.0`](https://github.com/Devolutions/pwsh-distro/releases/tag/v7.6.10.0) | Production workstations, servers, golden images, and `.NET 10` apps |
| **`7.7`** | **STS** (Standard-Term Support) | `.NET 11` (`net11.0`) | [`v7.7.0.0`](https://github.com/Devolutions/pwsh-distro/releases/tag/v7.7.0.0) (`Latest`) | Latest PowerShell features and `.NET 11` apps |

Release tags follow `vX.Y.Z.R`, where `X.Y.Z` matches the upstream PowerShell version (such as `7.6.10` or `7.7.0`) and `R` is the Devolutions downstream revision (`0`, `1`, ...). Matching upstream `PowerShell/PowerShell`, GitHub's `Latest` badge tracks the highest GA line (`7.7.x`); select the latest `v7.6.x.R` tag on the [Releases page](https://github.com/Devolutions/pwsh-distro/releases) when deploying **7.6 LTS**.

---

## Installing Devolutions PowerShell CLI

Self-contained installers and archives include the `.NET` runtime—no separate `.NET` installation is required.

| Platform | Format | Architectures | Install location | Admin required |
| --- | --- | --- | --- | --- |
| **Windows** | [`.msi` installer](#msi-installer-recommended) *(recommended)* | `x64`, `arm64` | `C:\Program Files\Devolutions\PowerShell\7` | Yes |
| **Windows** | [`.msixbundle` / `.appinstaller`](#msix-bundle-and-automatic-updates-windows-11) | `x64` + `arm64` | Packaged (`%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe`) | No |
| **Windows** | [Portable `.tar.gz`](#portable-archive-windows) | `x64`, `arm64` | Any folder | No |
| **macOS** (12+) | [`.pkg` installer](#pkg-installer-macos-12-or-later) | `arm64`, `x64` | `/usr/local/devolutions/powershell/7` | Yes (`sudo`) |
| **macOS** (12+) | [Portable `.tar.gz`](#portable-archive-macos) | `arm64`, `x64` | Any folder | No |
| **Linux** (Debian / Ubuntu) | [`.deb` package](#debian-and-ubuntu-deb) | `amd64`, `arm64` | `/opt/devolutions/powershell/7` | Yes (`sudo`) |
| **Linux** (RHEL / Rocky / Fedora) | [`.rpm` package (`rh`)](#rhel-rocky-almalinux-and-fedora-rpm) | `x86_64`, `aarch64` | `/opt/devolutions/powershell/7` | Yes (`sudo`) |
| **Linux** (Azure Linux 3 / 4) | [`.rpm` package (`cm`, `azl4`)](#azure-linux-3-and-4-rpm) | `x86_64`, `aarch64` | `/opt/devolutions/powershell/7` | Yes (`sudo`) |
| **Linux** (Alpine / portable) | [Portable `.tar.gz`](#alpine-linux-and-portable-linux-archives) | `x64`, `arm64` | Any folder | No |

### Windows

#### MSI installer (Recommended)

The Windows MSI installer is the recommended option for desktops, servers, enterprise deployments, and machines pinning the **7.6 LTS** channel. Each release publishes signed installers for both 64-bit Intel/AMD (`x64`) and Windows on ARM (`arm64`):

- `Devolutions-PowerShell-<X.Y.Z.R>-win-x64.msi`
- `Devolutions-PowerShell-<X.Y.Z.R>-win-arm64.msi`

**Interactive install:**

1. Download the `.msi` matching your CPU architecture from [**GitHub Releases**](https://github.com/Devolutions/pwsh-distro/releases) (for example `Devolutions-PowerShell-7.6.10.0-win-x64.msi` for 7.6 LTS, or `Devolutions-PowerShell-7.7.0.0-win-x64.msi` for 7.7 STS).
2. Double-click the `.msi` file, choose any optional integration features (such as adding `pwsh.exe` to `PATH` or Explorer context menus), and complete the wizard as an administrator.

**Command-line / silent install (PowerShell as Administrator):**

```powershell
# Download the 7.6 LTS x64 MSI from GitHub Releases (use win-arm64 on ARM64 devices)
Invoke-WebRequest `
  -Uri "https://github.com/Devolutions/pwsh-distro/releases/download/v7.6.10.0/Devolutions-PowerShell-7.6.10.0-win-x64.msi" `
  -OutFile .\Devolutions-PowerShell-7.6.10.0-win-x64.msi

# Install silently and add Devolutions PowerShell to the system PATH
msiexec.exe /i .\Devolutions-PowerShell-7.6.10.0-win-x64.msi /quiet /norestart ADD_PATH=1
```

**Optional `msiexec` properties** (all off by default unless previously enabled on the machine):

| Property | Value | Effect |
| --- | --- | --- |
| `ADD_PATH` | `1` | Appends `C:\Program Files\Devolutions\PowerShell\7` to the system `PATH`. |
| `ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL` | `1` | Adds **Open here** and **Open here as Administrator** to File Explorer folder/background menus. |
| `ADD_FILE_CONTEXT_MENU_RUNPOWERSHELL` | `1` | Adds **Run with Devolutions PowerShell 7** when right-clicking `.ps1` files. |
| `ENABLE_PSREMOTING` | `1` | Runs `Enable-PSRemoting` during initial installation. |
| `REGISTER_MANIFEST` | `1` | Registers the Windows Event Logging manifest. |
| `INSTALLFOLDER` | Path | Overrides the base `Devolutions` directory under `Program Files` (`<INSTALLFOLDER>\PowerShell\7`). |

**MSI install details & coexistence:**

- **Coexists with Microsoft PowerShell**: Installs to `C:\Program Files\Devolutions\PowerShell\7\pwsh.exe` with Devolutions-specific Start menu shortcuts, registry keys, and upgrade codes—leaving `C:\Program Files\PowerShell\7` untouched. Because `ADD_PATH` defaults to `0`, an existing `pwsh` on `PATH` is not replaced unless you opt in.
- **Windows Terminal profile**: Automatically registers a machine-wide Windows Terminal profile fragment under `%ProgramData%\Microsoft\Windows Terminal\Fragments\Devolutions.PowerShell` without changing your default profile. Uninstalling removes the fragment.
- **Windows Desktop support**: Includes the Windows Desktop runtime payload so `WPF` and `WinForms` scripts work out of the box.
- **Upgrades & architectures**: Installing a newer MSI of the same architecture upgrades in place and preserves saved installer options. `x64` and `arm64` MSIs share `C:\Program Files\Devolutions\PowerShell\7` and cannot be installed side by side; uninstall one architecture before installing the other.
- **Uninstall**: Remove **Devolutions PowerShell 7-\<arch\>** from **Settings > Apps > Installed apps**, or run:

  ```powershell
  msiexec.exe /x .\Devolutions-PowerShell-7.6.10.0-win-x64.msi /quiet /norestart
  ```

#### MSIX bundle and automatic updates (Windows 11)

For per-user installation **without administrator privileges** and automatic background updates on **Windows 11 version 21H2 (build 22000) or later**, install from the App Installer feed:

```powershell
Add-AppxPackage -AppInstallerFile https://github.com/Devolutions/pwsh-distro/releases/latest/download/Devolutions-PowerShell.appinstaller
```

- Registers the `pwsh.exe` App Execution Alias under `%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe` and disables filesystem/registry write virtualization.
- Checks silently for updates from GitHub Releases in the background (and defers applying updates while `pwsh.exe` is running on **Windows 11 24H2 / build 26100+**).
- **Channel note**: The MSIX auto-update feed tracks the repository's `Latest` GA release (`7.7.x`). To stay pinned to **7.6 LTS**, use the [MSI installer](#msi-installer-recommended) or [portable archive](#portable-archive-windows) instead.
- **Windows 10 (1809–22H2)**: Install `Devolutions-PowerShell-<X.Y.Z.R>-win.msixbundle` directly (`Add-AppxPackage -Path .\Devolutions-PowerShell-<X.Y.Z.R>-win.msixbundle`). Windows 10 ignores `uap13:AutoUpdate`, so updates are manual on Windows 10.

#### Portable archive (Windows)

Use the self-contained `.tar.gz` archive (`PowerShell-<X.Y.Z>-windows-x64.tar.gz` or `PowerShell-<X.Y.Z>-windows-arm64.tar.gz`) when you want an isolated, side-by-side copy of `pwsh.exe` without running an installer or elevating privileges:

```powershell
Invoke-WebRequest `
  -Uri "https://github.com/Devolutions/pwsh-distro/releases/download/v7.6.10.0/PowerShell-7.6.10-windows-x64.tar.gz" `
  -OutFile .\PowerShell-7.6.10-windows-x64.tar.gz

New-Item -ItemType Directory -Force -Path .\pwsh-cli | Out-Null
tar -xzf .\PowerShell-7.6.10-windows-x64.tar.gz -C .\pwsh-cli
.\pwsh-cli\pwsh.exe -NoLogo -NoProfile -Command '$PSVersionTable'
```

---

### macOS

#### `.pkg` installer (macOS 12 or later)

Each release provides Apple-signed and notarized installer packages for **Apple silicon** (`arm64`) and **Intel** (`x64`) Macs running macOS 12 Monterey or later:

- `Devolutions-PowerShell-<X.Y.Z.R>-osx-arm64.pkg` (Apple silicon)
- `Devolutions-PowerShell-<X.Y.Z.R>-osx-x64.pkg` (Intel)

Download the `.pkg` from [**GitHub Releases**](https://github.com/Devolutions/pwsh-distro/releases) and double-click it in Finder, or install from Terminal:

```bash
curl -fLO https://github.com/Devolutions/pwsh-distro/releases/download/v7.6.10.0/Devolutions-PowerShell-7.6.10.0-osx-arm64.pkg
sudo installer -pkg ./Devolutions-PowerShell-7.6.10.0-osx-arm64.pkg -target /
pwsh -NoLogo -Command '$PSVersionTable'
```

- Installs the payload to `/usr/local/devolutions/powershell/7`, adds `/Applications/Devolutions PowerShell.app`, installs the `pwsh(1)` man page to `/usr/local/share/man/man1/pwsh.1.gz`, registers `/usr/local/bin/pwsh` in `/etc/shells`, and places a `/usr/local/bin/pwsh` launcher script.
- **Coexistence with Microsoft PowerShell**: Does not modify `/usr/local/microsoft/powershell/7`, though whichever package was installed last owns the shared `/usr/local/bin/pwsh` entry point and man page.
- **Uninstall**:

  ```bash
  sudo rm -rf /usr/local/devolutions/powershell/7 "/Applications/Devolutions PowerShell.app"
  grep -Fqx 'exec "/usr/local/devolutions/powershell/7/pwsh" "$@"' /usr/local/bin/pwsh && sudo rm /usr/local/bin/pwsh
  sudo pkgutil --forget com.devolutions.powershell
  ```

#### Portable archive (macOS)

```bash
curl -fLO https://github.com/Devolutions/pwsh-distro/releases/download/v7.6.10.0/PowerShell-7.6.10-macos-arm64.tar.gz
mkdir -p ./pwsh-cli
tar -xzf ./PowerShell-7.6.10-macos-arm64.tar.gz -C ./pwsh-cli
./pwsh-cli/pwsh -NoLogo -Command '$PSVersionTable'
```

*(Use `PowerShell-7.6.10-macos-x64.tar.gz` on Intel Macs.)*

---

### Linux

Linux `.deb` and `.rpm` packages bundle the `.NET` runtime, install to `/opt/devolutions/powershell/7`, symlink `/usr/bin/pwsh`, and register `/usr/bin/pwsh` in `/etc/shells`. Because both own `/usr/bin/pwsh`, `devolutions-powershell` conflicts with Microsoft's `powershell` package—remove `powershell` first if switching. Packages are downloaded directly from [**GitHub Releases**](https://github.com/Devolutions/pwsh-distro/releases) (not an apt or RPM repository).

| Distribution | `x64` (`amd64` / `x86_64`) | `arm64` (`arm64` / `aarch64`) |
| --- | --- | --- |
| **Debian / Ubuntu** (`deb`) | `devolutions-powershell_<X.Y.Z.R>-1.deb_amd64.deb` | `devolutions-powershell_<X.Y.Z.R>-1.deb_arm64.deb` |
| **RHEL / Rocky / AlmaLinux / Fedora** (`rh`) | `devolutions-powershell-<X.Y.Z.R>-1.rh.x86_64.rpm` | `devolutions-powershell-<X.Y.Z.R>-1.rh.aarch64.rpm` |
| **Azure Linux 3** (`cm`) | `devolutions-powershell-<X.Y.Z.R>-1.cm.x86_64.rpm` | `devolutions-powershell-<X.Y.Z.R>-1.cm.aarch64.rpm` |
| **Azure Linux 4** (`azl4`) | `devolutions-powershell-<X.Y.Z.R>-1.azl4.x86_64.rpm` | `devolutions-powershell-<X.Y.Z.R>-1.azl4.aarch64.rpm` |

#### Debian and Ubuntu (`.deb`)

```bash
curl -fLO https://github.com/Devolutions/pwsh-distro/releases/download/v7.6.10.0/devolutions-powershell_7.6.10.0-1.deb_amd64.deb
sudo apt-get update
sudo apt-get install -y ./devolutions-powershell_7.6.10.0-1.deb_amd64.deb
pwsh -NoLogo -Command '$PSVersionTable'
```

*(Replace `amd64` with `arm64` on ARM64 hosts.)*

#### RHEL, Rocky, AlmaLinux, and Fedora (`.rpm`)

Built for glibc 2.28+ (RHEL 8 and newer) and OpenSSL 1.1 or 3 (on Fedora releases defaulting to OpenSSL 4, `dnf` automatically pulls in the compatible OpenSSL 3 library):

```bash
curl -fLO https://github.com/Devolutions/pwsh-distro/releases/download/v7.6.10.0/devolutions-powershell-7.6.10.0-1.rh.x86_64.rpm
sudo dnf install -y ./devolutions-powershell-7.6.10.0-1.rh.x86_64.rpm
pwsh -NoLogo -Command '$PSVersionTable'
```

*(Replace `x86_64` with `aarch64` on ARM64 hosts.)*

#### Azure Linux 3 and 4 (`.rpm`)

```bash
# Azure Linux 3 (use .azl4. instead of .cm. on Azure Linux 4; use aarch64 on ARM64)
curl -fLO https://github.com/Devolutions/pwsh-distro/releases/download/v7.6.10.0/devolutions-powershell-7.6.10.0-1.cm.x86_64.rpm
sudo tdnf install -y ./devolutions-powershell-7.6.10.0-1.cm.x86_64.rpm
pwsh -NoLogo -Command '$PSVersionTable'
```

#### Alpine Linux and portable Linux archives

Alpine Linux uses the `linux-musl` `.tar.gz` archive (`PowerShell-<X.Y.Z>-linux-musl-x64.tar.gz` or `arm64`):

```sh
apk add --no-cache ca-certificates icu-libs krb5-libs libgcc libstdc++ openssl tzdata
curl -fLO https://github.com/Devolutions/pwsh-distro/releases/download/v7.6.10.0/PowerShell-7.6.10-linux-musl-x64.tar.gz
mkdir -p ./pwsh-cli
tar -xzf ./PowerShell-7.6.10-linux-musl-x64.tar.gz -C ./pwsh-cli
./pwsh-cli/pwsh -NoLogo -Command '$PSVersionTable'
```

For any glibc 2.28+ Linux distribution without root access, extract `PowerShell-<X.Y.Z>-linux-x64.tar.gz` or `PowerShell-<X.Y.Z>-linux-arm64.tar.gz` the same way.

---

### Verifying checksums and vendor metadata

Every GitHub release attaches a SHA-256 `checksums` file covering all installers, archives, SDK packages, and patch files:

```powershell
# Windows (PowerShell)
(Get-FileHash .\Devolutions-PowerShell-7.6.10.0-win-x64.msi -Algorithm SHA256).Hash
```

```bash
# Linux / macOS
shasum -a 256 -c --ignore-missing checksums
```

Once installed, confirm you are running the Devolutions build:

```powershell
$PSVersionTable | Select-Object PSVersion, PSEdition, Vendor
```

---

## Devolutions PowerShell SDK

Use [`Devolutions.PowerShell.SDK`](https://www.nuget.org/packages/Devolutions.PowerShell.SDK) from NuGet.org when embedding PowerShell in a `.NET` application or bundling a runnable `pwsh` executable alongside your app.

The package preserves upstream assembly identities (`System.Management.Automation.dll`, `Microsoft.PowerShell.Commands.Utility.dll`, and built-in modules), making it a drop-in NuGet replacement for `Microsoft.PowerShell.SDK` while embedding Devolutions' source-built, signed assemblies directly (excluding Microsoft's SDK package IDs from your transitive restore graph). In addition to a [slim-by-default dependency graph](#slim-by-default-dependency-profile), the downstream runtime includes targeted hosting enhancements:

- **Pluggable client remoting transports**: Extends PowerShell Remoting (PSRP) with a client transport provider registry so host applications and modules can supply custom session/command transports or opt-in replacements for built-in connection types such as WSMan.
- **Isolated runspace module paths**: Supports overriding `PSModulePath` directly on `InitialSessionState`.
- **Bundled `pwsh` job resolution**: Allows out-of-process `Start-Job` calls to resolve `runtimes/<rid>/native/pwsh[.exe]` when `pwsh` is not placed in the application root.
- **Runtime vendor metadata**: Exposes `$PSVersionTable.Vendor` (`Devolutions`) via `PSVersionInfo`.

### Choosing a package version and target framework

Both channels publish under the `Devolutions.PowerShell.SDK` package ID:

| Channel | Target framework | NuGet version range | Notes |
| --- | --- | --- | --- |
| **`7.6` (LTS)** | `net10.0` | `[7.6.*, 7.7.0)` (latest: `7.6.10`) | Recommended for `.NET 10` applications (such as Remote Desktop Manager) so NuGet updates stay within `7.6.x`. |
| **`7.7` (STS)** | `net11.0` | `7.7.*` (latest: `7.7.0`) | Requires `.NET 11` (`net11.0` or platform-specific `net11.0-*` TFMs). |

> **NuGet version normalization**: Downstream revision `.0` normalizes to three-part versions on NuGet.org (`7.6.10.0` publishes as `7.6.10`; `7.7.0.0` publishes as `7.7.0`), while nonzero revisions keep all four parts (such as `7.6.9.3`).

### Hosting PowerShell in-process

Create a `.NET` project and reference `Devolutions.PowerShell.SDK`:

```powershell
dotnet new console -n PwshSdkSample -f net10.0
cd PwshSdkSample
dotnet add package Devolutions.PowerShell.SDK --version 7.6.10
```

To stay on the `.NET 10` LTS line automatically across patch updates, constrain the range in your `.csproj`:

```xml
<ItemGroup>
  <PackageReference Include="Devolutions.PowerShell.SDK" Version="[7.6.*, 7.7.0)" />
</ItemGroup>
```

Host PowerShell in C# with the standard `System.Management.Automation` APIs:

```csharp
using System.Management.Automation;

using PowerShell powerShell = PowerShell.Create();
powerShell.AddScript("$PSVersionTable.PSVersion.ToString()");

foreach (PSObject result in powerShell.Invoke())
{
    Console.WriteLine(result);
}
```

### Bundling a runnable `pwsh` apphost

The SDK includes native `multi-pwsh` apphost launchers for `win-x64`, `win-arm64`, `osx-x64`, `osx-arm64`, `linux-x64`, `linux-arm`, and `linux-arm64`. Apphost files are inert by default—leave `PowerShellSDKAppHostLayout` unset if you only host PowerShell in-process.

#### Root layout (`<output>/pwsh[.exe]`)

Copies `pwsh`/`pwsh.exe`, `pwsh.dll`, `pwsh.runtimeconfig.json`, runtime assemblies, and built-in modules directly into your application's output/publish directory:

```xml
<PropertyGroup>
  <PowerShellSDKAppHostLayout>Root</PowerShellSDKAppHostLayout>
  <PowerShellSDKLocalizedResources>Copy</PowerShellSDKLocalizedResources>
  <PowerShellSDKXmlDocumentation>Copy</PowerShellSDKXmlDocumentation>
  <PowerShellSDKPSGalleryModules>Microsoft.PowerShell.Archive;Microsoft.PowerShell.ThreadJob</PowerShellSDKPSGalleryModules>
</PropertyGroup>
```

Publish and test for your target RID (`win-x64`, `win-arm64`, `osx-x64`, `osx-arm64`, `linux-x64`, `linux-arm`, or `linux-arm64`):

```powershell
dotnet publish -c Release -r win-x64 --self-contained true
.\bin\Release\net10.0\win-x64\publish\pwsh.exe -NoLogo -NoProfile -Command '$PSVersionTable'
```

#### Runtime-native layout (`runtimes/<rid>/native/pwsh[.exe]`)

For applications that stage architecture-specific launchers under `runtimes/<rid>/native` while sharing managed PowerShell assemblies at the application root:

```xml
<PropertyGroup>
  <PowerShellSDKAppHostLayout>RuntimeNative</PowerShellSDKAppHostLayout>
  <PowerShellSDKRuntimeNativeAppHostRuntimeIdentifiers>win-x64;win-arm64</PowerShellSDKRuntimeNativeAppHostRuntimeIdentifiers>
</PropertyGroup>
```

Leave `PowerShellSDKRuntimeNativeAppHostRuntimeIdentifiers` empty to stage every packaged RID, or pass a semicolon-delimited list (unknown RIDs fail the build). Devolutions PowerShell patches `Start-Job` so out-of-process background jobs automatically use `runtimes/<rid>/native/pwsh[.exe]` when `$PSHOME/pwsh[.exe]` is not present at the root.

#### MSBuild properties reference

| Property | Default | Values | Effect |
| --- | --- | --- | --- |
| `PowerShellSDKAppHostLayout` | `None` | `None`, `Root`, `RuntimeNative`, `Both` | Selects the apphost file layout. |
| `PowerShellSDKAppHostImplementation` | `Auto` | `Auto`, `MultiPwsh`, `DotNet` | Selects the apphost executable implementation when supported by packaged assets (`MultiPwsh` for `Root` and `RuntimeNative`). |
| `PowerShellSDKAppHostRuntimeIdentifier` | empty | RID | Overrides root apphost RID selection; otherwise `$(RuntimeIdentifier)` then `$(NETCoreSdkRuntimeIdentifier)` are used. |
| `PowerShellSDKAppHostTargetFramework` | empty | TFM | Overrides root apphost payload TFM lookup; platform-specific TFMs such as `net10.0-windows10.0.19041` normalize to the package TFM (`net10.0`). |
| `PowerShellSDKRuntimeNativeAppHostRuntimeIdentifiers` | empty | RID list | Semicolon-delimited runtime-native launcher RIDs; empty selects all packaged RIDs. |
| `PowerShellSDKRuntimeNativeSharedPayloadRuntimeIdentifier` | empty | RID | Overrides the shared app-root PowerShell payload RID. Otherwise follows `$(RuntimeIdentifier)`, `$(NETCoreSdkRuntimeIdentifier)`, then `PowerShellSDKAppHostRuntimeIdentifier`. |
| `PowerShellSDKRuntimeNativeSharedPayloadTargetFramework` | empty | TFM | Overrides shared payload TFM lookup; platform-specific TFMs normalize to the package TFM. |
| `PowerShellSDKCopyPhases` | `Output;Publish` | `Output`, `Publish`, `Output;Publish` | Controls whether opted-in payloads copy on build output, publish, or both. |
| `PowerShellSDKConfig` | `Copy` | `None`, `Copy` | Generates `powershell.config.json` when an apphost layout is enabled. |
| `PowerShellSDKConfigExecutionPolicy` | `Bypass` | Execution policy | Sets `Microsoft.PowerShell:ExecutionPolicy` in the generated config. |
| `PowerShellSDKConfigOverwriteExisting` | `false` | `true`, `false` | Replaces an existing `powershell.config.json` only when `true`. |
| `PowerShellSDKLocalizedResources` | `None` | `None`, `Copy` | Copies staged localized satellite assemblies beside the apphost payload. |
| `PowerShellSDKXmlDocumentation` | `None` | `None`, `Copy` | Copies XML documentation files (such as `System.Management.Automation.xml`) beside the apphost payload. IntelliSense XML files remain in the package even when `None`. |
| `PowerShellSDKPSGalleryModules` | `None` | `None`, `All`, or module list | Copies all staged PSGallery modules or a semicolon-delimited subset to `Modules`. |

> When passing semicolon-delimited properties on the `dotnet` or `msbuild` CLI, escape semicolons as `%3B` (for example `/p:PowerShellSDKCopyPhases=Output%3BPublish`). PSGallery modules increase output size and several are script modules subject to the bundled execution policy.

### Slim-by-default dependency profile

`Devolutions.PowerShell.SDK` is **slim by default** to keep application restore graphs smaller and reduce ReadyToRun/publish overhead (note that slimming dependencies does not make PowerShell itself trimming or Native AOT compatible):

- **Retained**: All core PowerShell assemblies, the full PowerShell type catalog, apphosts, built-in modules, external runtime dependencies (`Microsoft.PowerShell.Native`, `Microsoft.PowerShell.MarkdownRender`), and `System.Security.Cryptography.ProtectedData` (used for Windows DPAPI `SecureString` encryption).
- **Omitted by default**: `Microsoft.Windows.Compatibility`; `System.ServiceModel.Http`, `NetTcp`, `NetFramingBase`, `Primitives`, and `Syndication`; `System.Data.SqlClient`, `Odbc`, and `OleDb`; `System.Speech`; `System.ComponentModel.Composition` and `Composition.Registration`; `System.Reflection.Context`; `System.DirectoryServices.AccountManagement` and `Protocols`; `System.Security.Cryptography.Xml`; `System.Net.Http.WinHttpHandler`; `System.Runtime.Caching`; and `System.IO.Ports` (plus its RID-specific native packages). *(Standalone Devolutions PowerShell CLI installers and archives re-add these compatibility packages automatically.)*

If your hosted scripts or modules require any omitted APIs (for example `System.Web.Services.Description` or WCF client packages), add an explicit `<PackageReference>` to your project—PowerShell's type catalog still resolves them automatically. When opting into `System.ServiceModel.Http`, also reference a patched `System.Security.Cryptography.Xml` explicitly and review NuGet security advisories, since WCF's transitive minimum can resolve an older version.

---

## Building and maintaining this repository

Everything below covers building Devolutions PowerShell from source, local package testing, pin management, and GitHub Actions release automation.

### Local checkout and SDK smoke build

`master` is a downstream-only packaging branch. Each channel's patched PowerShell source tree lives in a same-repository git submodule (`pwsh-src-7.6/` and `pwsh-src-7.7/`) tracking `downstream/vX.Y.Z`. See [BRANCHING.md](BRANCHING.md) for the full branch, tag, submodule, and worktree model.

```powershell
git clone https://github.com/Devolutions/pwsh-distro.git
cd pwsh-distro
.\scripts\Initialize-Repository.ps1
```

- By default, `scripts\Initialize-Repository.ps1` enables `core.longpaths` on Windows (required to avoid `Filename too long` errors during PowerShell checkout) and initializes the default channel (`7.6` at `pwsh-src-7.6/`).
- Pass `-Channel 7.7` to initialize `pwsh-src-7.7/`, or `-Channel All` to initialize both submodules.

To build and validate a single-RID `Devolutions.PowerShell.SDK` package locally under `output\local-sdk\<channel>\<rid>\`:

```powershell
.\scripts\Build-LocalPowerShellSdk.ps1 -Validate
# Or for PowerShell 7.7 (.NET 11):
.\scripts\Build-LocalPowerShellSdk.ps1 -Channel 7.7 -Validate
```

Pass `-SdkPackageVersion 7.6.10` to smoke-test a specific published downstream revision. Multi-RID production packages are built via the GitHub Actions workflows below.

### Local installer repackaging scripts

Installer scripts under `package/` repackage unpacked CLI archives locally for testing:

```powershell
# Windows MSI (WiX 4; requires Windows)
.\package\msi\New-PowerShellDistroMsi.ps1 -PayloadDirectory .\pwsh-cli -PackageVersion 7.6.10.0 -Architecture x64 -OutputDirectory .\output\msi

# Windows MSIX bundle + App Installer feed (requires Windows SDK makeappx)
.\package\msix\New-ReleasePowerShellDistroMsix.ps1 -X64PayloadDirectory .\pwsh-cli-x64 -Arm64PayloadDirectory .\pwsh-cli-arm64 -PackageVersion 7.6.10.0 -OutputDirectory .\output\msix
.\package\msix\Test-PowerShellDistroMsixPackage.ps1 -BundlePath .\output\msix\Devolutions-PowerShell-7.6.10.0-win.msixbundle -AppInstallerPath .\output\msix\Devolutions-PowerShell.appinstaller -PackageVersion 7.6.10.0
.\package\msix\Test-PowerShellDistroAppInstaller.ps1
```

```powershell
# macOS .pkg (requires macOS pkgbuild/productbuild; omit -Install on Test-PowerShellDistroMacPkg.ps1 to avoid modifying /usr/local)
./package/macos/New-PowerShellDistroMacPkg.ps1 -PayloadDirectory ./pwsh-cli -PackageVersion 7.6.10.0 -Architecture arm64 -OutputDirectory ./output/pkg
./package/macos/Test-PowerShellDistroMacPkg.ps1 -PkgPath ./output/pkg/Devolutions-PowerShell-7.6.10.0-osx-arm64.pkg -Architecture arm64 -PackageVersion 7.6.10.0

# Linux .deb / .rpm (requires Linux with dpkg-deb or rpmbuild; Distribution: deb, rh, cm, azl4)
./package/linux/New-PowerShellDistroLinuxPackage.ps1 -PayloadDirectory ./pwsh-cli -PackageVersion 7.6.10.0 -Architecture x64 -Distribution deb -OutputDirectory ./output/linux
```

## Current pins

| Component | Version |
| --- | --- |
| Default PowerShell channel | `7.6` (`eng/powershell-channels.json`) |
| PowerShell 7.6 (LTS) upstream release | `7.6.10` / `v7.6.10` |
| PowerShell 7.6 (LTS) downstream source ref | `downstream/v7.6.10` based on `upstream/v7.6.10` (`pwsh-src-7.6`) |
| PowerShell 7.6 (LTS) target framework | `net10.0` |
| PowerShell 7.6 (LTS) SDK package | `Devolutions.PowerShell.SDK` / `7.6.10.0` workflow default; `7.6.10` latest published package |
| PowerShell 7.6 (LTS) .NET runtime workflow | `v10.0.5` |
| PowerShell 7.7 (STS) upstream release | `7.7.0` / `v7.7.0` |
| PowerShell 7.7 (STS) downstream source ref | `downstream/v7.7.0` based on `upstream/v7.7.0` (`pwsh-src-7.7`) |
| PowerShell 7.7 (STS) target framework | `net11.0` |
| PowerShell 7.7 (STS) SDK package | `Devolutions.PowerShell.SDK` / `7.7.0.0` workflow default; `7.7.0` latest published package |
| PowerShell 7.7 (STS) .NET runtime workflow | `v11.0.0` |
| Latest downstream release tag | `v7.7.0.0` (`7.7` STS / `Latest`), `v7.6.10.0` (`7.6` LTS) |
| Latest PowerShell CLI release assets | `PowerShell-<version>-<os>-<arch>.tar.gz` for Windows, macOS, Linux, and Alpine Linux on x64 and arm64 |
| PowerShell SDK package source | `https://api.nuget.org/v3/index.json` |
| multi-pwsh apphost package | `Devolutions.MultiPwsh.Cli` / `0.14.2` |
| multi-pwsh apphost package source | `https://api.nuget.org/v3/index.json` |
| Linux multi-pwsh launcher source | `0.14.2` / `77676d18baaf205ec36b1711d11bd386d4b15272`; Rust `1.90.0` |
| Linux multi-pwsh bindings generator | PowerShell `7.4.0` |
| Linux ARM64 PowerShell.Native source | `700.0.2` / `f24d5494b373de20ec3e3d2fdc7c3fc98af1f9f1` |
| psign code signing tool | `Devolutions.Psign.Tool` / `0.8.2` |
| llvm-prebuilt | `v2026.1.1` |
| clang+llvm | `22.1.4` |
| VsDevShell | `latest from PSGallery` |

## Workflows

All workflows are manual and started from the GitHub Actions **Run workflow** button:

| Workflow | Purpose | Output |
| --- | --- | --- |
| `.github/workflows/powershell-sdk.yml` | Builds PowerShell from source, vendors and signs the source-built payload, and validates the SDK package in a sample `.NET` app with opt-in apphost import. Runs manually or as a reusable workflow. | `PowerShell-SDK-Release-X.Y.Z.R` artifact containing the SDK `.nupkg`. |
| `.github/workflows/powershell-cli.yml` | Restores a pinned or workflow-built SDK package and builds self-contained Windows, macOS, glibc Linux, and Alpine Linux CLI archives for x64 and arm64. | `PowerShell-<version>-<os>-<arch>` `.tar.gz` artifacts, including `linux-musl` for Alpine. |
| `.github/workflows/powershell-msi.yml` | Packages published Windows CLI archives, CLI workflow artifacts, or the current release's prepared CLI archives, then signs and verifies the MSI when enabled. | `Devolutions-PowerShell-<tag-or-version>-win-<arch>-msi` artifacts containing an x64 or ARM64 `.msi`. |
| `.github/workflows/powershell-msix.yml` | Packages Windows x64 and ARM64 CLI archives into a combined MSIX bundle with embedded and standalone GitHub Releases App Installer auto-update feeds, signs when enabled, and tests installation and upgrades on x64 and ARM64 Windows. | `Devolutions-PowerShell-<tag-or-version>-win-msix` artifact containing `Devolutions-PowerShell-X.Y.Z.R-win.msixbundle` and `Devolutions-PowerShell.appinstaller`. |
| `.github/workflows/powershell-linux.yml` | Repackages Linux CLI archives as deb and RPM packages and tests installation, execution, and removal across supported distributions. | `Devolutions-PowerShell-<version>-linux-<arch>-packages` artifacts with one deb and three RPMs per architecture. |
| `.github/workflows/powershell-macos-pkg.yml` | Packages published macOS CLI archives, CLI workflow artifacts, or the current release's prepared CLI archives into macOS installer packages, then tests installation on native Intel and Apple silicon runners. | `Devolutions-PowerShell-<tag-or-version>-osx-<arch>-pkg` artifacts containing an x64 or arm64 `.pkg`. |
| `.github/workflows/release.yml` | Orchestrates the SDK, CLI, MSI, MSIX, Linux, and macOS pkg workflows, signs release-ready CLI, MSI, and MSIX artifacts, publishes the SDK package, and creates the GitHub release. | GitHub release `vX.Y.Z.R` with the SDK `.nupkg`, eight CLI archives, two Windows MSIs, the Windows MSIX bundle and App Installer feed, eight Linux packages, two macOS pkgs, the downstream patch, and checksums. |
| `.github/workflows/dotnet-runtime.yml` | Builds the `.NET` runtime for the selected channel (`v10.0.5` for `7.6`, `v11.0.0` for `7.7`) across Windows, macOS, glibc Linux, and Alpine Linux on x64 and arm64. Native builds use `awakecoding/llvm-prebuilt`; Linux builds use Microsoft's `.NET 10`/`.NET 11` cross-build images. | `DotNet-Runtime-<channel>-<rid>` artifacts containing the source-built runtime packs. |

## Publishing PowerShell releases

The release workflow publishes only after the SDK has been validated, every CLI archive, both MSI installers, the MSIX bundle and App Installer feed, and both macOS pkg installers have been built, and the MSI, MSIX, Linux, Alpine, and macOS installation tests have passed. ReadyToRun CLI archives are signed before installer packaging, so installers contain the final CLI payload. The release version is `<powerShellVersion>.<sdk_package_revision>`, such as `7.6.10.0` or `7.7.0.0`.

Manual inputs:

| Input | Purpose |
| --- | --- |
| `channel` | PowerShell release channel (`7.6` default for LTS / `.NET 10`, or `7.7` for STS / `.NET 11`). |
| `sdk_package_revision` | Optional revision override. Leave blank to use the selected channel's `sdkPackageRevision` pin in `eng/powershell-channels.json`, set a number such as `1` for a specific downstream revision, or set `auto` to infer the next revision from existing `vX.Y.Z.R` release tags. |
| `github-env` | `auto`, `test`, or `prod`. `auto` selects `publish-prod` for manual runs from `master` and `publish-test` elsewhere. |
| `skip-publish` | Builds, signs when requested, validates, and packages artifacts without publishing to NuGet.org or creating a GitHub release. |
| `dry-run` | Simulates publishing. Defaults to `true`; non-production environments are forced to dry-run when publishing is requested. |
| `sign-dry-run` | Signs the SDK payload, CLI binaries, MSIs, and MSIX bundle, and signs and notarizes the macOS pkgs, during a dry-run. Requires signing secrets and timestamp configuration (`github-env=prod` is required for Apple signing secrets). Defaults to `false` even with `github-env=prod` or `skip-publish=true`. |
| `ready_to_run` | Applies ReadyToRun optimization to CLI archives. When SDK code signing is enabled, the release workflow signs and verifies the final post-R2R CLI archive payloads before checksums and release creation. |
| `use_custom_dotnet_runtime` | Optional (`false` by default). Repackages CLI archives against a source-built `.NET` runtime instead of the stock `Microsoft.NETCore.App.Runtime.<rid>` pack from NuGet.org. |
| `dotnet_runtime_run_id` | Optional. Reuse a prior successful `.NET runtime` workflow run (`<run-id>` or `latest`) instead of building one in the current release chain. |

The standalone CLI workflow also exposes `ready_to_run` (disabled by default because ReadyToRun rewrites managed PE files and invalidates existing Authenticode signatures) and `sdk_artifact_run_id` (to repackage a workflow-built `.nupkg` from a prior `powershell-sdk.yml` run). Standalone MSI, MSIX, macOS `.pkg`, and Linux workflows can similarly consume either a published `release_tag` or a `cli_run_id` plus `package_version`.

Before validation and CLI packaging, the SDK workflow signs source-built assemblies in `ref/` and `runtimes/*/lib/`, apphost payloads in `tools/apphost/*` and `runtimes/*/native`, the Windows desktop payload, and built-in module manifests/format/script files under `contentFiles/any/any/runtimes/**/Modules/**` using `Devolutions.Psign.Tool` and Azure Key Vault (without adding a NuGet package signature). Non-dry-run releases require these environment secrets and variables:

| Name | Type / Scope | Purpose |
| --- | --- | --- |
| `CODE_SIGNING_KEYVAULT_URL` | Secret | Azure Key Vault URL for Authenticode signing |
| `AZURE_TENANT_ID` | Secret | Azure AD tenant ID |
| `CODE_SIGNING_CLIENT_ID` | Secret | Azure service principal client ID |
| `CODE_SIGNING_CLIENT_SECRET` | Secret | Azure service principal client secret |
| `CODE_SIGNING_CERTIFICATE_NAME` | Secret | Key Vault certificate name |
| `CODE_SIGNING_TIMESTAMP_SERVER` | Variable | Authenticode RFC 3161 timestamp server URL |
| `APPLE_APP_DEV_ID_APP_CERTIFICATE` | Secret (`publish-prod`) | Base64 Developer ID Application `.p12` for Mach-O payload signing |
| `APPLE_APP_DEV_ID_APP_CERTIFICATE_PASSWORD` | Secret (`publish-prod`) | Password for the Developer ID Application `.p12` |
| `APPLE_DEV_ID_INSTALLER_CERTIFICATE` | Secret (`publish-prod`) | Base64 Developer ID Installer `.p12` for `.pkg` signing |
| `APPLE_DEV_ID_INSTALLER_CERTIFICATE_PASSWORD` | Secret (`publish-prod`) | Password for the Developer ID Installer `.p12` |
| `APPLE_BOT_PASSWORD` | Secret (`publish-prod`) | App-specific password for notarization (`Devolutions/actions/macos-notarize@v1`) |
| `DEVOLUTIONSBOT_TOKEN` | Org secret | Checks out the private `Devolutions/actions` repository |
| `NUGET_BOT_USERNAME` | Secret | NuGet.org account username for `NuGet/login@v1` OIDC publishing |

Production releases require **four approval rounds**: SDK signing; one Windows job that prepares/signs all eight CLI archives and builds/signs both MSI installers and the MSIX bundle; the two macOS pkg signing and notarization jobs; and final publishing after all MSI, MSIX, Linux, Alpine, and macOS installation tests succeed (`skip-publish=true` omits the fourth round). Publishing uses `publish-test` and `publish-prod` environments with `NuGet/login@v1` OIDC, pushes the validated `.nupkg` to NuGet.org, and creates the `Devolutions PowerShell vX.Y.Z.R` GitHub release—passing `--latest=false` whenever a higher non-draft, non-prerelease `vA.B.C.R` release already exists (`Test-ShouldMarkGitHubReleaseLatest`).

CLI archive signing replaces only selected PE entries while preserving tar permissions, ownership, timestamps, and symlinks (`./eng/Test-SignPowerShellDistroArchive.ps1` exercises metadata preservation offline).

## Source-built .NET runtime option

By default, `powershell-cli.yml` uses the stock `Microsoft.NETCore.App.Runtime.<rid>` packs from NuGet.org. For a fully from-source PowerShell distribution, enable `use_custom_dotnet_runtime`:

- In `powershell-cli.yml`, set `use_custom_dotnet_runtime=true` and `dotnet_runtime_run_id` to a completed `dotnet-runtime.yml` run ID for the selected `channel` (or `latest`).
- In `release.yml`, set `use_custom_dotnet_runtime=true`; leave `dotnet_runtime_run_id` blank to build `dotnet-runtime.yml` first, or pass a run ID / `latest` to reuse an existing run.

Linux glibc runtime packs are cross-built against an Ubuntu 18.04 sysroot and verified to require no newer than glibc 2.28. Locally, `eng/New-PowerShellDistroArchive.ps1` accepts `-CustomRuntimeSource` and `-CustomRuntimePackageVersion` to inject a local runtime feed ahead of NuGet.org via `packageSourceMapping`.

## Updating PowerShell versions

When moving a channel (`7.6` or `7.7`) to a new upstream PowerShell release, update four coordinated surfaces in the same PR:

1. `eng/powershell-channels.json`: update `powerShellVersion`, `powerShellReleaseTag`, `powerShellUpstreamTag`, `powerShellSourceRef`, and `targetFramework`, reset `sdkPackageRevision` and `cliSdkPackageRevision` to `0`, and update `cliSdkPackageVersion`.
2. `.gitmodules`: update the literal `branch = downstream/vX.Y.Z` line under `[submodule "pwsh-src-<channel>"]`.
3. The `pwsh-src-<channel>` submodule pointer on `master` (`git submodule update --remote pwsh-src-<channel> && git add pwsh-src-<channel>`).
4. The [Current pins](#current-pins) table above.

Verify `<TargetFramework>` from `pwsh-src-<channel>/PowerShell.Common.props` and run `pwsh .\.agents\skills\powershell-pin-audit\scripts\Test-PowerShellPins.ps1` before opening the PR.

## Architecture and packaging notes

- **Source checkout vs. build metadata**: Workflows initialize only the selected channel's submodule via `scripts/Initialize-Repository.ps1 -Channel <channel>`, while build steps receive `POWERSHELL_RELEASE_TAG` (`vX.Y.Z`) rather than `downstream/vX.Y.Z`. Release patch artifacts are exported by diffing `POWERSHELL_UPSTREAM_TAG` against `POWERSHELL_SOURCE_REF`.
- **Target framework & vendor derivation**: The SDK workflow reads `TargetFramework` from `pwsh-src-<channel>/PowerShell.Common.props` (`net10.0` for `7.6`, `net11.0` for `7.7`), passes `PowerShellVendor=Devolutions` during compilation, and runs `eng/Vendor-PowerShellSdkPackage.ps1` to rewrite package metadata and verify Microsoft PowerShell SDK package IDs do not leak into the restore graph. Upstream NU5100/NU5131 pack warnings are superseded by end-to-end sample restore, publish, and execution validation.
- **CLI repackaging & custom icons**: `powershell-cli.yml` consumes `Devolutions.PowerShell.SDK` as a normal NuGet consumer (with `Root` apphost, XML docs, PSGallery modules, localized resources, optional compatibility packages, and `Microsoft.WindowsDesktop.App.Runtime.<rid>` on Windows). Windows and macOS launchers recolor the PowerShell icon with Devolutions blue (`#0068C3`, `package/powershell-icon.svg`); signed releases re-sign the modified executables, while local/unsigned builds leave them unsigned.
- **Linux launcher & native compatibility**: `powershell-cli.yml` builds the pinned `multi-pwsh` launcher from Rust source for glibc 2.28 and Alpine `musl`, and builds both ARM64 `Microsoft.PowerShell.Native` variants from pinned source so RHEL 8 and Alpine ARM64 are supported.
- **macOS cross-validation & notarization**: `osx-x64` SDK and CLI jobs build on `macos-15` (Apple silicon) and skip Rosetta execution probes, while `powershell-macos-pkg.yml` tests installation on native Intel and Apple silicon runners, signs Mach-O binaries with hardened-runtime + `package/macos/assets/pwsh-entitlements.plist`, and notarizes/staples the product archive. The `/usr/local/bin/pwsh` wrapper script is used instead of a symlink so `multi-pwsh` does not treat it as a manager shim.
- **Windows MSI & MSIX internals**: WiX 4 MSI versions encode `X.Y.Z.R` as `X.Y.(Z * 100 + R)` (`R` in `0..99`) so downstream revisions upgrade cleanly, including migration from legacy `7-<arch>` paths to `C:\Program Files\Devolutions\PowerShell\7`. MSIX bundles embed a byte-for-byte copy of `Devolutions-PowerShell.appinstaller` as `Update.appinstaller` (`uap13:AutoUpdate` + `uap17:UpdateWhileInUse`) and stamp `Identity/@Publisher` from the active signing certificate subject.

### Third-party notices

Installer sources and visual assets under `package/msi/`, `package/msix/`, and `package/macos/` adapted from `PowerShell/PowerShell` carry the upstream MIT license notice:

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
