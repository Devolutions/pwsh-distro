---
name: powershell-sdk-package-validate
description: Builds and validates the local single-RID Devolutions.PowerShell.SDK package using the repository's current workflow pins.
---

# powershell sdk package validate

Use this skill when validating SDK packaging changes, checking a PowerShell release bump before opening a PR, or diagnosing `Devolutions.PowerShell.SDK` package layout/apphost issues.

This skill wraps the repository's canonical local build script and passes values from `.github\workflows\powershell-sdk.yml`, so validation follows the same explicit pins used by GitHub Actions.

## Prerequisites

- PowerShell 7 (`pwsh`).
- .NET SDK and build prerequisites required by upstream PowerShell.
- Initialized `pwsh-src/` submodule:

```powershell
pwsh .\scripts\Initialize-Repository.ps1
```

## Scripts

- `scripts\Build-AndValidateLocalPowerShellSdk.ps1`: Reads current workflow pins, runs the pin audit, then calls `scripts\Build-LocalPowerShellSdk.ps1 -Validate`.
- `..\\powershell-pin-audit\\scripts\\Test-PowerShellPins.ps1`: Confirms pins agree before spending time on a local build.
- `..\\..\\..\\..\\scripts\\Build-LocalPowerShellSdk.ps1`: Canonical local package build and validation implementation.
- `..\\..\\..\\..\\eng\\Validate-PowerShellSdkPackage.ps1`: Canonical package validation script.

## Usage

Build and validate for the current host runtime identifier:

```powershell
pwsh .\.agents\skills\powershell-sdk-package-validate\scripts\Build-AndValidateLocalPowerShellSdk.ps1
```

Validate a specific RID supported by the local build script:

```powershell
pwsh .\.agents\skills\powershell-sdk-package-validate\scripts\Build-AndValidateLocalPowerShellSdk.ps1 -RuntimeIdentifier win-x64
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

The canonical build writes under `output\local-sdk\<rid>\` and emits:

- `package\Devolutions.PowerShell.SDK.<version>.nupkg`
- `PowerShell-AppHost\` source-built apphost files
- validation output proving restore, build, framework-dependent publish, self-contained publish, apphost execution, and built-in module loading

Do not stage generated `output\` contents.
