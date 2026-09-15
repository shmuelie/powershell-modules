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
| App install foundation | `New-AppInstallContext` (compiled, experimental; lazy caller-owned context, no installation or search) |
| App install queue | `Get-AppInstallItem` (compiled, experimental; explicit context, caller-scoped read-only snapshots) |
| Inventory | `Get-InstalledApplications` (compiled binary cmdlet) |
| Services | `Get-ServiceProcess` (compiled binary cmdlet) |
| Virtual drives | `Get-SubstDrive`, `New-SubstDrive`, `Remove-SubstDrive` (compiled binary cmdlets) |
| Windows Terminal | `Get-WindowsTerminalSettings`, `Get-WindowsTerminalProfile` |
| Diagnostics | `Start-WindowsPerformanceRecorder`, `Stop-WindowsPerformanceRecorder` |

## Experimental AppInstall context

`New-AppInstallContext` creates an `IDisposable` context owned by the current
runspace. Creation and module import do not activate `AppInstallManager`, check
native access, search for updates, or change settings. Explicitly dispose it:

```powershell
$context = New-AppInstallContext
try {
    $context.ContextId
} finally {
    $context.Dispose()
}
```

The same context will own the same lazily activated manager for later commands;
there is no process-global manager or implicit per-command context. Do not pass
it to another runspace, a job, or a remoting session. Closing its owning runspace
also disposes it; removing the module alone does not dispose caller-owned
contexts. Context creation supports `-WhatIf` and `-Confirm`.

**Experimental access restriction:** Microsoft documents `AppInstallManager`
access as protected by a **private capability restricted to Microsoft-developed
apps**. Observed runtime access is not an official third-party support guarantee.
Neither elevation nor `runFullTrust` alone establishes authorization. Creating a
context does not claim, grant, or bypass a capability. Caller scope is not a
verified account/SID mapping or a claim about queue visibility.

This foundation is separate from the `.appinstaller` helpers below. Caller-scoped
queue reads use `Get-AppInstallItem`; no settings, search, install, entitlement,
control, or `ForUser` cmdlets are exported. See [the context contract](../../docs/appinstall.md).

The foundation also defines immutable identity/group, status, request,
entitlement and error snapshots for later commands. Unknown and unavailable
values are not empty/false successes. Local correlation IDs are not native IDs
or account/SID mappings. Request acceptance, native async completion,
installation terminal state, staging and launch readiness remain distinct.
See [snapshot contracts and the API/options matrix](../../docs/appinstall.md#immutable-snapshot-contracts)
for the cleared future subset and the still-gated families.

## Caller-scoped AppInstall inventory

```powershell
$context = New-AppInstallContext
try {
    Get-AppInstallItem -Context $context -IncludeChildren
} finally {
    $context.Dispose()
}
```

The first read activates the context's manager. `-ProductId` and
`-PackageFamilyName` accept arrays of exact, ordinal case-insensitive values:
no wildcard expansion, OR within a filter, AND between filters. These are
post-capture filters, not authorization or unique control-target selection.
The command never searches for updates or queues work.

`-IncludeChildren` reads the group-aware collection and preserves complete
subtrees for matching parents. A matching descendant of an unmatched parent is
returned with its `ParentLocalItemId`; descendants already included under a
matching parent are not emitted twice. Without this switch, children are
`Unknown`, not assumed absent.

The immutable output retains product/family identity, install type, initiation
and group-impact flags, native state codes, bytes, percentage, HRESULT, staging
and launch readiness. Unsupported optional members are `Unavailable`; access
errors and disappearing-item reads fail the capture without partial results.
An empty successful queue or unmatched filter emits no objects. Reading is not
an atomic native transaction, and a captured item can disappear afterward.

Local IDs follow projected item identity, not product/family strings. At most
4096 distinct items from the last successful capture are retained; removed
identities are pruned on the next successful capture and context disposal clears
the cache. More than 4096 items, depth beyond 128 levels, cycles, or conflicting
parents cause errors rather than truncation. Detached snapshots are not handles
or permission to control an item. See [inventory details](../../docs/appinstall.md#caller-scoped-inventory).

The prior runtime evidence covers collection getters/counts only. Nonempty
item/status/group coverage for this implementation uses deterministic fakes,
not a new claim of supported third-party native access.

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

The experimental context factory uses a separate `Shmuelie.Windows.AppInstall.dll`
with the same Windows target and projection dependencies. It requires Windows 10
build 19041 or later and is exported only on Windows. Development builds publish
the compiled assemblies and their projection dependencies; importing a source or
packaged module never installs an SDK or compiles code.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).
