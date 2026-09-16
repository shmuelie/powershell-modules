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
| App install observation | `Wait-AppInstallItem` (compiled, experimental; one retained local item, explicit context, mandatory 1-30 second observation budget) |
| App install settings | `Get-AppInstallSettings` (compiled, experimental; explicit context, read-only, acquisition identity opt-in) |
| App update search | `Request-AppInstallUpdateSearch` (compiled, experimental; explicit context and correlation inputs, confirmed caller all-app paused-queue mutation) |
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

The same context owns the same lazily activated manager for queue/settings reads and approved searches;
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

This surface is separate from the `.appinstaller` helpers below. Caller-scoped
queue and settings reads use `Get-AppInstallItem` and `Get-AppInstallSettings`.
`Request-AppInstallUpdateSearch` adds only the approved caller all-app paused
search. No settings mutation, install, entitlement, control, or `ForUser` cmdlets
are exported. See [the context contract](../../docs/appinstall.md).

### Bounded exact-item observation

`Wait-AppInstallItem -Context $context -LocalItemId $item.Identity.LocalItemId -TimeoutSeconds 10`
observes one previously captured item in its creating caller context. Use the exact
local ID from inventory or a paused-search result; product/family names are not
unique identities and are never used as a fallback. Stale IDs fail. One observation
per context is allowed. There is no implicit context, pipeline fan-out, group wait,
manager-wide queue following, individual-item event subscription or `ForUser`.

Only manager `ItemStatusChanged`/`ItemCompleted` are subscribed. Callbacks read no
native payloads or properties and call no PowerShell APIs. Any manager notification
may trigger a selected-item reread; it is **not** claimed to belong to that item.
One pending invalidation slot coalesces reasons. Reads run on the cmdlet execution
thread, subscribe before the initial snapshot, and retry when a delivered callback
invalidates a capture. Local ordering is not lossless native event order or an atomic
native snapshot guarantee.

One immutable `AppInstallMonitorResult` is emitted **after cleanup**, containing at
most 64 locally ordered observations. There is no streaming progress output.
`Outcome` is `TimedOut` or `TargetTerminal`; inspect the final snapshot to distinguish
observed success, failure and native cancellation. `GroupOutcome` is always
`NotEvaluated`. Completion notifications, percent, staging and launch readiness
never prove success. Unknown native state or unavailable HRESULT stays unknown.
An already-terminal item needs no notification. Retained items are not membership
probes: removal from the queue is not inferred, and a disappearing-item getter
failure preserves its error rather than being treated as completion.

The mandatory 1-30 second budget bounds local waiting, not blocking native calls.
Stopping/Ctrl+C cancels only observation. Every acquired subscription is removed
before the observation lease releases the manager, including error/timeout/stop
paths. Caller contexts are not disposed by the command; context/runspace shutdown
signals observers and defers manager release until their leases unwind, without
waiting or unsubscribing under the context lock. Cleanup failures terminate without
an optimistic result and preserve primary HRESULT plus secondary failures. Default
formatting omits item/error payloads; explicit properties/JSON retain them.

AppInstall remains **unreleased pending #233 support clarification**. Limited
manager-event observations do not verify per-item events, group semantics or
official third-party support. See [the monitoring contract](../../docs/appinstall.md#bounded-exact-item-observation).

### Read-only settings

```powershell
$context = New-AppInstallContext
try {
    Get-AppInstallSettings -Context $context
    # Only this explicit selector reads acquisition identity; keep its output private.
    $identitySnapshot = Get-AppInstallSettings -Context $context -Property AcquisitionIdentity
} finally {
    $context.Dispose()
}
```

The default reads only `AutoUpdateSetting` and `CanInstallForAllUsers`.
`-Property` replaces the defaults with an exact list of the three allowed names;
numeric aliases, wildcards and `All` are rejected. Repeated names are read once. Acquisition
identity is neither probed nor read unless explicitly selected, and is never
written to verbose/debug/information logs. Its value is a manager-context
observation, not a verified account/SID or evidence of cross-manager persistence.

`AutoUpdateSetting` is the documented **device** setting: independent managers
do not isolate device-wide settings or policy. Its typed `AppInstallValue<int>`
preserves the raw native enum (`0` Disabled, `1` Enabled, `2` DisabledByPolicy,
`3` EnabledByPolicy), including future codes. `CanInstallForAllUsers` is
**get-only** and reflects the calling process's privilege observation, not a
privilege grant, private-capability authorization or proof that an all-user
installation is available or will succeed.

The immutable `AppInstallSettingsSnapshot` records `ContextId`, caller scope,
each property's scope, `RequestedProperties` and successfully `ReadProperties`.
Unselected values are `Unknown`; missing members/types are `Unavailable` without
invocation. Available false/zero (and explicitly requested empty identity) remain
distinct from unknown/unavailable. Reads are sequential, not atomic. Operational
failures terminate without a partial snapshot and retain the original exception,
HRESULT and typed failure phase in the error record. Default error rendering
omits raw native diagnostics because they can contain sensitive data.

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
4096 distinct items from the last successful inventory plus partial search results
are retained; removed identities are pruned on the next successful inventory scan and context disposal clears
the cache. More than 4096 items, depth beyond 128 levels, cycles, or conflicting
parents cause errors rather than truncation. Detached snapshots are not handles
or permission to control an item. See [inventory details](../../docs/appinstall.md#caller-scoped-inventory).

The prior runtime evidence covers collection getters/counts only. Nonempty
item/status/group coverage for this implementation uses deterministic fakes,
not a new claim of supported third-party native access.

## Caller-scoped paused update search

`Request-AppInstallUpdateSearch` is a **queue mutation**, not a read-only
query: discovered updates can be added to the queue paused. The only native
call is `SearchForAllUpdatesAsync(correlationVector, clientId, AppUpdateOptions)`,
with `AutomaticallyDownloadAndInstallUpdateIfFound = false` and
`AllowForcedAppRestart = false` explicitly fixed before submission.

Supply your own legitimate correlation vector and client identifier; the module
does not invent a caller identity or alter acquisition settings. Preview safely:

```powershell
$context = New-AppInstallContext
try {
    Request-AppInstallUpdateSearch -Context $context `
        -CorrelationVector $correlationVector -ClientId $clientId -WhatIf
} finally {
    $context.Dispose()
}
```

All three parameters are mandatory. The context must belong to the current
runspace. `-WhatIf` and declined confirmation perform **zero native calls**:
no metadata probes, activation, options construction or search, and no output.
An authorized invocation without `-WhatIf` uses high-impact `ShouldProcess`
confirmation. Per-app, `ForUser`, custom catalog, automatic download/install,
forced restart and alternate overloads remain unavailable, with no fallback.

A successful call emits one immutable `AppInstallRequestSnapshot`, even when
`Items` is empty. `Acceptance = Accepted` means the API returned an async handle;
`OperationState = Completed` means **search completion, not installation
completion**. Returned item/group identities and status observations remain
separate. Local `RequestId`, context and item IDs are correlation only, not
native install IDs. Caller-provided `CorrelationVector` and `ClientId` are
retained unchanged; keep snapshots and original native diagnostics private.
The default request view shows local IDs, API/scope/outcome fields and item
count, but omits native correlation strings, item payloads and raw errors.
All public properties remain available: `Format-List *`, direct property access
and JSON serialization expose the original values. This display choice is not
redaction, secret storage or a security boundary.
Search results merge into the bounded identity cache without pruning unrelated
items. A subsequent successful inventory scan still prunes normally.

Failures emit no success or partial items. The terminating error's `TargetObject`
retains the typed request, original exception/HRESULT and cleanup diagnostics.
A throwing submission has `Unknown` acceptance, not proof of rejection.
Stopping the pipeline ends only local waiting, never native work or queued
items; a stopped pipeline may suppress output/errors entirely. Missing output
therefore does not prove that nothing was submitted.

The private-capability restriction and open support clarification still apply.
Only empty native-search evidence was previously observed; nonempty/grouped
results and cancellation here use fail-closed fakes, not live Store actions or
a third-party support guarantee. Broader #244 API families remain gated.
See [the search contract](../../docs/appinstall.md#caller-scoped-paused-update-search).

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

The experimental context factory and read-only commands use a separate `Shmuelie.Windows.AppInstall.dll`
with the same Windows target and projection dependencies. It requires Windows 10
build 19041 or later and is exported only on Windows. Development builds publish
the compiled assemblies and their projection dependencies; importing a source or
packaged module never installs an SDK or compiles code.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).
