# Shmuelie.Windows

Windows-only developer utilities for installed applications, Windows Terminal,
Windows Performance Recorder, and Windows service host processes.

**Version:** 0.2.0

## Install

```powershell
Install-PSResource Shmuelie.Windows
Import-Module Shmuelie.Windows
```

## Commands

| Area | Commands |
|---|---|
| App Installer | `Get-AppInstallerApp`, `Update-AppInstallerApp` (compiled, Windows-only; opt-in `-PassThru` request outcomes) |
| Inventory | `Get-InstalledApplications` (compiled binary cmdlet) |
| Services | `Get-ServiceProcess` (compiled binary cmdlet) |
| Virtual drives | `Get-SubstDrive`, `New-SubstDrive`, `Remove-SubstDrive` (compiled binary cmdlets) |
| Windows Terminal | `Get-WindowsTerminalSettings`, `Get-WindowsTerminalProfile` |
| Diagnostics | `Start-WindowsPerformanceRecorder`, `Stop-WindowsPerformanceRecorder` |

## App Installer request results

`Update-AppInstallerApp` still emits nothing by default. Opt in to typed
request-completion output when an orchestrator needs evidence:

```powershell
Get-AppInstallerApp | Update-AppInstallerApp -PassThru
```

Each `Shmuelie.Windows.AppInstallerUpdateRequestResult` has `Name`,
`PackageFullName`, `PackageFamilyName`, `AppInstallerUri`,
`Operation = UpdateCheck`, and `RequestCompleted = true`. It is emitted only
after the App Installer service operation completes without an error.
It does **not** assert installation success or an installed-version change,
and contains no resulting version. Earlier completed results remain visible
if a later request fails; failures retain the command's existing error behavior.

Unmatched/disappeared registrations, missing URIs, `-WhatIf`, and declined
confirmation emit no completion result. `-WhatIf` still performs read-only
enumeration but never initiates an update check. Identity matching remains
exact and case-insensitive. `Name` accepts pipeline input by property name with
`PackageName`, `PackageFullName`, and `PackageFamilyName` aliases; when piping a
complete application object its `Name` property takes precedence. To select
one exact registration, pipe only its `PackageFullName` property:

```powershell
Get-AppInstallerApp | Select-Object PackageFullName | Update-AppInstallerApp -PassThru -WhatIf
```

## Requirements

- PowerShell 7.4 or later.
- Windows. These commands report their platform requirements in command help.

The `Get-AppInstallerApp` and `Update-AppInstallerApp` cmdlets are compiled into
a separate Windows-targeted assembly (`Shmuelie.Windows.AppInstaller.dll`, built
for `net8.0-windows10.0.19041.0`) because they call the WinRT
`Windows.Management.Deployment.PackageManager` API in-process. That assembly is
loaded only on Windows, so those two cmdlets are unavailable on other platforms;
the rest of the module still imports everywhere PowerShell 7 runs.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).
