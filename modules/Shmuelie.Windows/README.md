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

AppInstallManager development is isolated in the repository-local
[Shmuelie.AppInstall.Experimental module](../../experimental/Shmuelie.AppInstall.Experimental/README.md).
It is not included in this module or published to the Gallery. Existing
`Get-AppInstallerApp` and `Update-AppInstallerApp` commands remain here.

## Subst target paths

`New-SubstDrive -TargetPath` must resolve to exactly one existing FileSystem
directory. Wildcards remain supported when they match a single directory;
multiple matches produce a terminating `AmbiguousTargetPath` error instead of
mapping the first result. This validation also applies under `-WhatIf`, before
checking the drive letter's availability or requesting confirmation. Ambiguous
targets create no mapping and emit no success object. Missing targets, files,
and non-FileSystem providers remain invalid.

## Service process results

`Get-ServiceProcess` uses a process ID only when the same
`QueryServiceStatusEx` snapshot reports `Running`, `PausePending`, `Paused`,
or `ContinuePending`, the states for which Win32 guarantees PID validity.
`Stopped`, `StartPending`, `StopPending`, and unknown native states instead
produce the existing `ServiceProcessInfo` fallback: `ProcessId = 0`,
`Process = $null`, and an empty `ProcessName`. No process lookup is attempted
for those snapshots.

A single successfully resolved service still returns its `System.Diagnostics.Process`;
multiple matches still return per-service `ServiceProcessInfo` objects, including
services sharing a host. `-PerService` configuration and confirmation are unchanged.
The service status and process lookup are separate observations: this state check
is not an atomic snapshot or a guarantee that a process continues to own a service.
See the [Win32 PID-validity contract](https://learn.microsoft.com/windows/win32/api/winsvc/nf-winsvc-queryservicestatusex#remarks).

## App Installer request results

`Update-AppInstallerApp` still emits nothing by default. Opt in to typed
request-completion output when an orchestrator needs evidence:

```powershell
Get-AppInstallerApp | Update-AppInstallerApp -PassThru
```

A standalone `Update-AppInstallerApp` without `-Name` requests updates for all
discovered App Installer apps. An empty upstream pipeline selects nothing:
it performs no discovery, requests no updates, and emits no completion results.
Supplied names and pipeline identity properties reject null, empty, and
whitespace-only values instead of becoming an update-all request. Objects that
fail pipeline binding retain their PowerShell errors; with the default error
policy, other valid input records still select only their matching apps.

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
