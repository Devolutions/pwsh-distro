---
name: powershell-sdk-package-validate
description: Builds and validates the local single-RID Devolutions.PowerShell.SDK package for a selected PowerShell channel (7.6 default or 7.7).
---

# powershell sdk package validate

Use this skill when validating SDK packaging changes, checking a PowerShell release bump before opening a PR, or diagnosing `Devolutions.PowerShell.SDK` package layout/apphost issues.

This skill wraps the repository's canonical local build script and passes channel metadata from `eng\powershell-channels.json` and apphost pins from `.github\workflows\powershell-sdk.yml`, so validation follows the same explicit pins used by GitHub Actions.

## Prerequisites

- PowerShell 7 (`pwsh`).
- .NET SDK and build prerequisites required by upstream PowerShell (`pwsh-src-7.6/global.json` or `pwsh-src-7.7/global.json`).
- Initialized channel submodule (`7.6` by default):

```powershell
pwsh .\scripts\Initialize-Repository.ps1 -Channel 7.6
```

## Scripts

- `scripts\Build-AndValidateLocalPowerShellSdk.ps1`: Resolves channel pins, runs the pin audit, then calls `scripts\Build-LocalPowerShellSdk.ps1 -Validate`.
- `..\\powershell-pin-audit\\scripts\\Test-PowerShellPins.ps1`: Confirms pins agree before spending time on a local build.
- `..\\..\\..\\..\\scripts\\Build-LocalPowerShellSdk.ps1`: Canonical local package build and validation implementation.
- `..\\..\\..\\..\\eng\\Validate-PowerShellSdkPackage.ps1`: Canonical package validation script.

## Usage

Build and validate the default channel (`7.6`) for the current host runtime identifier:

```powershell
pwsh .\.agents\skills\powershell-sdk-package-validate\scripts\Build-AndValidateLocalPowerShellSdk.ps1
```

Build and validate a specific channel (`7.6` or `7.7`):

```powershell
pwsh .\.agents\skills\powershell-sdk-package-validate\scripts\Build-AndValidateLocalPowerShellSdk.ps1 -Channel 7.7
```

Validate a specific RID supported by the local build script:

```powershell
pwsh .\.agents\skills\powershell-sdk-package-validate\scripts\Build-AndValidateLocalPowerShellSdk.ps1 -Channel 7.6 -RuntimeIdentifier win-x64
```

Use a specific NuGet CLI:

```powershell
pwsh .\.agents\skills\powershell-sdk-package-validate\scripts\Build-AndValidateLocalPowerShellSdk.ps1 -NuGetExe C:\tools\nuget.exe
```

Skip the pre-build pin audit only when intentionally debugging a partially edited tree:

```powershell
pwsh .\.agents\skills\powershell-sdk-package-validate\scripts\Build-AndValidateLocalPowerShellSdk.ps1 -SkipPinAudit
```

## Expected output

The canonical build writes under `output\local-sdk\<channel>\<rid>\` and emits:

- `package\Devolutions.PowerShell.SDK.<version>.nupkg`
- `PowerShell-AppHost\` source-built apphost files
- validation output proving the slim-by-default dependency profile, optional dependency opt-ins, restore, build, framework-dependent publish, self-contained publish, apphost execution, and built-in module loading

Do not stage generated `output\` contents.
