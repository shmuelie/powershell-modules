---
title: Experimental AppInstall foundation
---

# Experimental AppInstall foundation

**Microsoft documents AppInstallManager access as protected by a private
capability restricted to Microsoft-developed apps.** Observed activation and
selected calls are empirical evidence, not an official third-party support
guarantee. `runFullTrust`, administrator access and successful context creation
must not be interpreted as authorization. No capability bypass is provided.

The scope decision in [#232](https://github.com/shmuelie/powershell-modules/issues/232)
permits this foundation while
[#233](https://github.com/shmuelie/powershell-modules/issues/233) remains open for
support clarification. Other API families retain their approval prerequisites.

## Context contract

`New-AppInstallContext` is an in-process compiled PowerShell 7.4+ command, available
on Windows 10 build 19041 or later. It creates an
`Shmuelie.Windows.AppInstall.AppInstallContext` without native activation. Use
`-WhatIf` to avoid even this local allocation. It exposes:

| Property | Meaning |
|---|---|
| `ContextId` | Local context correlation ID, not a native installation or account ID |
| `RunspaceId` | Creating PowerShell runspace |
| `UserScope` | `Caller`; does not imply a SID, known account or all-user visibility |
| `IsActivated` | Whether lazy native activation succeeded, not authorization for other operations |
| `IsDisposed` | Whether the context has ended its lifetime |

Call `Dispose()` in `finally`. Disposal is idempotent and also occurs when the
creating runspace closes or breaks. Module removal does not end caller-owned
contexts. Neither disposal nor stopping a future local wait implicitly cancels
remote queued work. No native manager is exposed publicly.

Each context owns one lazy manager. The internal `Use` integration seam checks
runspace ownership, platform and exact member availability before activation or
invocation. Native activation errors are retained, including their HRESULT; a
failed activation is cached rather than retried invisibly. A new explicit context
is required to retry activation. Metadata presence is not an access check.

`Use` callbacks **must perform only a short native invocation**. Wait for any
returned async operation outside the context lifecycle lock. Disposal/local
cancellation is not a hard timeout or a way to forcibly cancel a synchronous
WinRT call. Independently owned managers do not isolate native device-wide
settings: for example, `AutoUpdateSetting` is documented as a device setting.
No settings writes are implemented.

Later cmdlets must accept this explicit context rather than create an
undocumented manager per invocation or share mutable global settings. The
internal manager adapter provides caller-scoped queue reads through
`Get-AppInstallItem`. No search, settings, mutation or `ForUser` operation is exposed here.

## Async and event integration seams

The internal async adapter accepts an already-created WinRT operation; it does
not submit one. The waiter polls native completion state on the execution thread
and preserves exceptions returned by `GetResults`. Stopping the local wait uses
a separate cancellation token and does not call native `Cancel`. Disposing an
adapter closes only terminal operations; a still-started operation is released
without cancellation. There are no polling tasks or completion callbacks left
running in the module after a wait ends.

Future command implementations should use the owning `WaitAndDispose` boundary
outside `Use`, then write a result only after both the wait and cleanup succeed.
It translates operational native failures to `AppInstallError`, preserving the
primary exception/HRESULT and any secondary `Status`/`Close` cleanup failure.
A cleanup-only failure produces an error, not a successful result. On failure,
the internal `AppInstallOperationException.Error.ToErrorRecord()` retains the
original exception and puts the typed metadata in `TargetObject`; it does not
write to PowerShell itself. `StopProcessing` should cancel only the local wait
token. No implicit native cancellation or queue-control action is provided.

Failure preservation is independent of the operational translation policy.
The owning boundary captures every primary and cleanup exception solely to
preserve/rethrow failures, never to return a fallback result. An untranslated
failure with successful cleanup is rethrown with its original instance and
stack. If it also has a cleanup failure, `AppInstallCleanupException` retains
both original exceptions in order, the primary HRESULT, source operation and
both phases without classifying the primary as native. A translated primary
keeps any unclassified cleanup in `CleanupErrors` with kind
`UnclassifiedFailure`. An unclassified cleanup-only failure propagates unchanged.
In particular, exception type alone cannot prove that a null-reference or
invalid-cast failure came from native code rather than a managed bug.

The injectable event subscription owns its unsubscribe resource. Callbacks only
signal invalidation; future monitoring must read snapshots and call PowerShell
pipeline writers on the cmdlet execution thread. Repeated notifications can
coalesce. Native event subscription and public monitoring belong to #239 and are
not implemented here.

Request acceptance, async-operation completion, successful installation,
`IsStaged`, and `ReadyForLaunch` are different observations. None is inferred
from a context, a successful activation, or mere method-name presence.

## Immutable snapshot contracts

All snapshot types live in `Shmuelie.Windows.AppInstall`. Constructors perform
no native access. Get-only properties and copied, read-only collections prevent
caller mutations of the input lists from changing a snapshot or its descendants.
These are data contracts for dependent commands, not additional exported
operations.

| Contract | Meaning |
|---|---|
| `AppInstallValue<T>` | A nullable scalar and explicit `Unknown`, `Available`, or `Unavailable` availability. Available `false`/zero is different from unknown/unavailable. |
| `AppInstallItemIdentity` | Observed `ProductId`/`PackageFamilyName`, explicit caller/unknown user scope, and local `ContextId`/`LocalItemId`/`ParentLocalItemId` correlation. |
| `AppInstallItemSnapshot` | Identity, status, and copied children with their own availability. Available empty children are distinct from children not observed or unavailable. |
| `AppInstallStatusSnapshot` | Observed native state code, byte counts, percentage, `IsStaged`, `ReadyForLaunch`, explicit terminal observation and error. |
| `AppInstallRequestSnapshot` | Separate request acceptance, native operation state, local wait state and returned-item availability. No installed-success shortcut. |
| `AppInstallEntitlementSnapshot` | Explicit caller/device/unknown entitlement scope, observed native status and grant observation. No grant is inferred from native code zero or object construction. |
| `AppInstallError` | Source operation, failure phase/kind, original HRESULT, exception type/message, and copied cleanup failures. |

`Unknown` means not observed; `Unavailable` means the caller established that the
value cannot be obtained in this context/version. A missing member must not be
replaced with a successful-looking zero or empty inventory. Native integer enum
codes are preserved even when newer than the module's knowledge. Future adapters
must map a terminal state from actual installation evidence, not from percentage,
request completion, staging, launch readiness or an entitlement result.

Local item IDs remain stable while the same projected identity stays in the last
successful inventory. They are **not native IDs**, are not derived from a
product/account/SID, and must not be reused to target a different item. The
inventory adapter owns that bounded projection-identity-to-local-ID mapping. Serialized snapshots are detached
observations, not native handles or authorization to perform later queue actions.
Product/family identifiers are preserved verbatim, not fabricated from context
IDs. `AppInstallStatus.User` is not projected into a SID or account name; that
mapping and broader user scopes remain unverified.

Request `Accepted` may coexist with native `Started` and local `StoppedLocally`.
Native `Completed` reports only the API operation completion; the returned items
can still have unknown/nonterminal installation states. `IsStaged` is the native
restart-pending observation, and `ReadyForLaunch` can be true before installation
has finished. These fields never change one another.

System.Text.Json round-trips the get-only scalar, identity, group, request,
entitlement and error metadata, including collection copies. `AppInstallError`
retains the original exception reference in-process (an exception itself is a
mutable diagnostic object); its captured metadata is immutable. JSON deliberately
omits that reference. Deserialized metadata cannot be converted back into a
live-native `ErrorRecord`, and does not synthesize an exception pretending to be
the original. Nothing automatically logs identities, snapshots or native messages.

## API and options matrix

`New-AppInstallContext` (#234) and `Get-AppInstallItem` (#236) ship here. Names below for other work items
are **proposed naming conventions**, not commands available to invoke. Later
commands use an explicit `-Context`, singular nouns and approved PowerShell verbs.
Mutating commands must use `ShouldProcess`; `-WhatIf` must submit no request.
Read-style verbs must not conceal queue mutations.

**Observed** means bounded runtime evidence for a particular call, not a support
guarantee. **Cleared later** still requires its dependent implementation PR.
**Gated** means unverified/unapproved for this scoped foundation. All counts below
refer to documented manager members; overloads are grouped by exact method name.
The minimum Windows target of this module remains build 19041; per-member and
method-parameter-count checks are still required before invocation.

### Manager properties (5)

| Member | Planned surface | Evidence / delivery scope |
|---|---|---|
| `AppInstallItems` | `Get-AppInstallItem -Context` | Caller-scoped inventory implemented in #236. Getter/count observed previously; nonempty item/status paths are covered by deterministic fakes, not live support claims. |
| `AppInstallItemsWithGroupSupport` | `Get-AppInstallItem -Context -IncludeChildren` | Grouped inventory implemented in #236. Getter/count observed previously; group/child paths have fake coverage only. Added in build 15063. |
| `AcquisitionIdentity` | `Get-AppInstallSetting -Context`; future `Set-AppInstallSetting` | Getter observed, cleared later in #238. Setter remains gated in #240; no identity spoofing or implicit account/SID interpretation. |
| `AutoUpdateSetting` | `Get-AppInstallSetting -Context`; future `Set-AppInstallSetting` | Getter observed, cleared later in #238. Device-setting write gated in #240; independent contexts do not isolate device settings. |
| `CanInstallForAllUsers` | `Get-AppInstallSetting -Context` | Getter observed, cleared later in #238. Read-only in the C# signature (despite the reference summary saying "gets or sets"), added in build 17763. Not a private-capability authorization check. |

### Manager methods (23 families)

| Member | Planned surface / overload distinctions | Evidence / delivery scope |
|---|---|---|
| `Cancel` | `Stop-AppInstallItem -Context`; product, optional telemetry overload | Gated #246; exact target and group impact must be explicit. |
| `GetFreeDeviceEntitlementAsync` | `Request-AppInstallEntitlement -Scope Device` | Gated #237; grants to device users, not a read-only query. |
| `GetFreeUserEntitlementAsync` | `Request-AppInstallEntitlement -Scope Caller` | Gated #237; grant operation, not a read-only query. |
| `GetFreeUserEntitlementForUserAsync` | Future explicit-user entitlement variant | Gated #237 and user-scope validation; no ForUser binding here. |
| `GetIsAppAllowedToInstallAsync` | `Test-AppInstallPolicy`; basic and telemetry overloads | Gated #235; method-name presence does not prove policy-query access. |
| `GetIsAppAllowedToInstallForUserAsync` | Future explicit-user policy variant | Gated #235 and user-scope validation. |
| `GetIsApplicableAsync` | `Test-AppInstallApplicability` | Gated #235. |
| `GetIsApplicableForUserAsync` | Future explicit-user applicability variant | Gated #235 and user-scope validation. |
| `GetIsPackageIdentityAllowedToInstallAsync` | `Test-AppInstallPolicy` package-identity parameter set | Gated #235; added in build 17134. |
| `GetIsPackageIdentityAllowedToInstallForUserAsync` | Future explicit-user package-policy variant | Gated #235 and user-scope validation; added in build 17134. |
| `IsStoreBlockedByPolicyAsync` | `Test-AppInstallPolicy` Store-policy parameter set | Gated #235. |
| `MoveToFrontOfDownloadQueue` | `Move-AppInstallItem -Context` | Gated #243; exact target, queue mutation. |
| `Pause` | `Suspend-AppInstallItem -Context`; product, optional telemetry overload | Gated #241; group impact must be explicit. |
| `Restart` | `Resume-AppInstallItem -Context`; product, optional telemetry overload | Gated #242; resume/restart request is not installation completion. |
| `SearchForAllUpdatesAsync` | `Request-AppInstallUpdateSearch -Context`; no-argument, telemetry-only, and options overloads | Only caller-scoped **options overload** with both safety flags false is observed/cleared later in #244 after #234/#236. Other overloads and automatic-update variants remain gated. |
| `SearchForAllUpdatesForUserAsync` | Future explicit-user all-app search; telemetry/options overloads | Gated #244 and user-scope validation, including false-flag variants. |
| `SearchForUpdatesAsync` | Future per-app update search; basic/telemetry/options overloads | Gated #244; caller all-app evidence does not authorize per-app variants. |
| `SearchForUpdatesForUserAsync` | Future explicit-user per-app update search | Gated #244 and user-scope validation. |
| `StartAppInstallAsync` | No new command or fallback | **Retired**, including basic and telemetry overloads. Do not use as the default or an automatic fallback. |
| `StartProductInstallAsync` | `Start-AppInstall -Context`; options and older boolean/volume overloads | Gated #245. Prefer the options overload once approved; after first sign-in, not during OOBE. |
| `StartProductInstallForUserAsync` | Future explicit-user product install | Gated #245 and user-scope validation; after first sign-in, not during OOBE. |
| `UpdateAppByPackageFamilyNameAsync` | `Request-AppInstallUpdate -Context`; basic/telemetry overloads | Gated #247; submits an update rather than merely discovering it. |
| `UpdateAppByPackageFamilyNameForUserAsync` | Future explicit-user package-family update | Gated #247 and user-scope validation. |

### Manager events (2)

| Member | Planned surface | Evidence / delivery scope |
|---|---|---|
| `ItemCompleted` | `Wait-AppInstallItem -Context` | Metadata observed, subscription unverified/gated #239. Must reread a final status; not a callback-thread pipeline writer. |
| `ItemStatusChanged` | `Wait-AppInstallItem -Context` | Metadata observed, subscription unverified/gated #239. Owned subscription, bounded waiting, coalesced invalidation and explicit local cancellation. |

### AppUpdateOptions (3)

| Member | Planned binding / safety contract | Delivery scope |
|---|---|---|
| `AutomaticallyDownloadAndInstallUpdateIfFound` | Fixed `false` in the cleared caller all-app path; not an opt-in true switch in that subset | Added in build 17763. **False still adds found updates to the install queue in a paused state.** It is not a read-only search. Only #244's cleared path after dependencies; broader behavior gated. |
| `AllowForcedAppRestart` | Fixed `false` in the cleared caller all-app path | Added with options in build 17134. No implicit forced-restart consent. True and broader variants remain gated. |
| `CatalogId` | Future explicit catalog option where applicable | No implicit catalog override in the cleared subset; per-app/custom catalog behavior requires its own validation. |

No real update search is run by foundation tests, including false-flag searches.
Future #244 must still use `ShouldProcess` because finding updates can queue work.
The options object must be fully configured before submitting the approved call;
omitting an option is not equivalent to explicitly setting it false.

### AppInstallOptions (15)

All bindings below are planning only for gated #245. The options type was added
in build 17134; later members still require availability checks.

| Member | Planned binding / safety contract | Delivery scope |
|---|---|---|
| `AllowForcedAppRestart` | Explicit restart consent; never inferred | Gated #245 |
| `CampaignId` | Explicit documented campaign value, no hardcoded caller identity | Gated #245; build 17763 |
| `CatalogId` | Explicit catalog value where supported | Gated #245 |
| `CompletedInstallToastNotificationMode` | Explicit notification choice | Gated #245; build 17763 |
| `ExtendedCampaignId` | Explicit documented campaign value | Gated #245; build 17763 |
| `ForceUseOfNonRemovableStorage` | Explicit storage-policy override | Gated #245 |
| `InstallForAllUsers` | Explicit all-user consent and separately validated access | Gated #245; build 17763. No elevation or capability workaround provided. |
| `InstallInProgressToastNotificationMode` | Explicit notification choice | Gated #245; build 17763 |
| `LaunchAfterInstall` | Explicit launch consent | Gated #245 |
| `PinToDesktopAfterInstall` | Explicit pinning consent | Gated #245; build 17763 |
| `PinToStartAfterInstall` | Explicit pinning consent | Gated #245; build 17763 |
| `PinToTaskbarAfterInstall` | Explicit pinning consent | Gated #245; build 17763 |
| `Repair` | Explicit repair request, not normal-install inference | Gated #245 |
| `StageButDoNotInstall` | Explicit staging-only request; not completed installation | Gated #245; build 17763 |
| `TargetVolume` | Explicit typed package-volume selection | Gated #245; no silently substituted volume |

### Related item/status members

`AppInstallItem.ProductId`, `PackageFamilyName`, `InstallType`, `IsUserInitiated`,
`Children`, `ItemOperationsMightAffectOtherItems` and `GetCurrentStatus` feed #236's
immutable snapshots. `AppInstallStatus.InstallState`, `BytesDownloaded`,
`DownloadSizeInBytes`, `PercentComplete`, `ErrorCode`, `IsStaged` and
`ReadyForLaunch` must retain independent observations and member availability.
The `User` object remains unexposed until its identity/scope semantics are
validated; no fabricated `Windows.System.User` or SID is supplied.

Item `Completed`/`StatusChanged` events belong to gated #239. Item
`Cancel`/`Pause`/`Restart` overloads remain gated along with the corresponding
manager controls. `LaunchAfterInstall`, notification and pinning properties do
not authorize implicit setting writes; they stay in the separately reviewed
install/settings families. Inventory does not materialize or invoke those
mutating native members.

## Caller-scoped inventory

```powershell
Get-AppInstallItem -Context $context [-ProductId <string[]>] [-PackageFamilyName <string[]>] [-IncludeChildren]
```

The context must be live and belong to the current runspace. Inventory activates
its manager lazily, then reads one of the two caller-scoped collections. Each
native member read is a short `Use` invocation with an exact availability check;
there is no subscription, user override, search, update, entitlement, or control
request. Native getter failures preserve the original exception, HRESULT, phase
and source member in the PowerShell error record.

Identity getters and `GetCurrentStatus` are required. Optional item/status
properties absent from metadata are `Unavailable` and are not called. A native
getter that throws, including access denial or a disappeared item, is an error,
not `Unknown`/`Unavailable`. Results are buffered: a failed capture emits none.
A successful empty queue or unmatched filter emits no objects. Earlier results
from a separate pipeline context/capture remain valid historical observations.
Native reads are not a single atomic transaction and state may change afterward.

`AppInstallItemSnapshot` additionally exposes availability-qualified `InstallType`,
`IsUserInitiated`, and `ItemOperationsMightAffectOtherItems`. Status exposes
availability-qualified `HResult`, alongside the existing independent fields.
`ErrorCode` returned as an exception is installation-status data, distinct from
a getter throwing. The supported C#/WinRT projection uses null for a successful
HRESULT; inventory represents that as zero. Non-failing HRESULT distinctions
not retained by that projection are not reconstructed through raw ABI calls.

Known native `Completed` with an observed non-failure HRESULT is terminal
`Succeeded`; native `Error` and `Canceled` have their own terminal observations.
Other known states remain `NotTerminal`, and future unknown state codes remain
`Unknown` while the integer code is preserved. Completed without an observed
non-failure HRESULT remains conservatively `Unknown`. PercentComplete,
IsStaged, ReadyForLaunch and presence in the queue do not imply success.

Filters are ordinal case-insensitive exact matches. Alternatives within one
filter use OR; different filters use AND; wildcard characters are literal.
Filtering occurs after the full read/validation, so an unrelated unreadable
item is not silently hidden by a filter. Distinct projected identities with the
same product/family still return distinct local IDs rather than choosing an
ambiguous control target.

Grouped mode reads Children, deduplicates repeated references under the same
parent, and removes top-level aliases of a known child. Conflicting parents or
cycles fail explicitly. Matching parents retain complete subtrees; matching
descendants of unmatched parents retain their parent-local ID. The default
ungrouped view leaves child availability Unknown and does not invent parents.
No status User/account/SID getter is called. Caller scope describes the chosen
API context, not a verified account identity for every returned item.

The context's manager owns a cache keyed by supported projection equality, which
AppInstallItem implements. Strong references are retained only for the last
successful captured graph, bounded to 4096 distinct items and 128 group levels.
A successful later capture prunes missing identities; failed captures do not
grow or replace the cache. Context disposal clears it. Switching views can
prune items not visible in the chosen view; an item returning after pruning gets
a fresh local ID. This is neither a universal native install ID nor permission
to use a deserialized snapshot for controls.

Snapshots are ordinary immutable CLR values. JSON retains their nested structure;
CSV consumers can select scalar fields explicitly, for example:

```powershell
Get-AppInstallItem -Context $context |
    Select-Object @{n='ProductId';e={$_.Identity.ProductId}},
                  @{n='PackageFamilyName';e={$_.Identity.PackageFamilyName}},
                  @{n='NativeState';e={$_.Status.NativeInstallState.Value}},
                  @{n='HResult';e={$_.Status.HResult.Value}}
```

No native nonempty item/status/group calls were executed during implementation.
Those paths, source/packaged command execution, duplicate/cycle/error behavior
and serialization are validated with fail-closed injected adapters. The official
private-capability restriction and limited native evidence remain unchanged.

## Sources

- [AppInstallManager and its access restriction](https://learn.microsoft.com/uwp/api/windows.applicationmodel.store.preview.installcontrol.appinstallmanager)
- [AppInstallItem](https://learn.microsoft.com/uwp/api/windows.applicationmodel.store.preview.installcontrol.appinstallitem)
- [AppInstallStatus](https://learn.microsoft.com/uwp/api/windows.applicationmodel.store.preview.installcontrol.appinstallstatus)
- [AppInstallOptions](https://learn.microsoft.com/uwp/api/windows.applicationmodel.store.preview.installcontrol.appinstalloptions)
- [AppUpdateOptions](https://learn.microsoft.com/uwp/api/windows.applicationmodel.store.preview.installcontrol.appupdateoptions)
- [False searches queue paused updates](https://learn.microsoft.com/uwp/api/windows.applicationmodel.store.preview.installcontrol.appupdateoptions.automaticallydownloadandinstallupdateiffound)
- [CanInstallForAllUsers read-only signature](https://learn.microsoft.com/uwp/api/windows.applicationmodel.store.preview.installcontrol.appinstallmanager.caninstallforallusers)
