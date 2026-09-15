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
The separately approved caller-context reads in
[#236](https://github.com/shmuelie/powershell-modules/issues/236) and
[#238](https://github.com/shmuelie/powershell-modules/issues/238) are implemented;
#233 no longer blocks this read-only subset, but does not authorize setters or
broader operations. The approved caller-scoped all-app paused search in
[#244](https://github.com/shmuelie/powershell-modules/issues/244) is also implemented
with explicit confirmation. Other #244 variants remain gated.

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
internal manager adapter provides caller-scoped queue and settings reads through
`Get-AppInstallItem` and `Get-AppInstallSettings`, and only the approved paused
search through `Request-AppInstallUpdateSearch`. No settings writes, queue
controls or `ForUser` operation is included.

## Read-only settings

`Get-AppInstallSettings -Context $context [-Property <exact names>]` requires
the explicit, live, current-runspace context from `New-AppInstallContext`. It
never allocates a hidden manager. The default selection is `AutoUpdateSetting`
and `CanInstallForAllUsers`. `-Property` replaces that selection and accepts only
`AcquisitionIdentity`, `AutoUpdateSetting` and `CanInstallForAllUsers` (duplicates
are read once, in first-selection order). Numeric aliases, wildcards and `All`
are rejected before any getter is invoked.

**Privacy:** `AcquisitionIdentity` is neither probed nor read by default. It is
returned only with an explicit `-Property AcquisitionIdentity` selection, alone
or in a list. Nothing writes its value to verbose, debug or information output.
The null unselected identity is omitted by System.Text.Json; its availability
remains `Unknown`. Default error rendering omits raw native messages, while the
original diagnostic exception and typed metadata remain available in the
`ErrorRecord` for deliberate inspection. Treat explicitly requested identity
and native diagnostic messages as sensitive.

| Property | Scope and interpretation |
|---|---|
| `AcquisitionIdentity` | `ManagerContext`: identity associated with installs on the supplied manager. No verified account/SID mapping or persistent user/global setting is inferred. Cross-manager persistence is not established. |
| `AutoUpdateSetting` | `Device`: documented device-wide app auto-update setting, including policy-controlled values. Independent context/manager objects do not isolate device settings or establish a persistent per-user preference. |
| `CanInstallForAllUsers` | `CallingProcess`: get-only privilege observation, not a privilege grant, capability authorization, proof that installation is available or guarantee of success. |

An `AppInstallSettingsSnapshot` contains `ContextId` (local correlation, never a
SID or native install ID), `UserScope = Caller`, per-property scope,
`RequestedProperties`, and successfully `ReadProperties`. Acquisition identity
has a separate availability and nullable string. `AutoUpdateSetting` uses
`AppInstallValue<int>` to retain the native enum code, including unknown future
codes: `0` Disabled, `1` Enabled, `2` DisabledByPolicy, `3` EnabledByPolicy.
`CanInstallForAllUsers` uses `AppInstallValue<bool>`.

Unselected values are `Unknown`; selected members absent from runtime metadata
are `Unavailable` without activation or invocation for that member. Available
false/zero and an explicitly requested empty identity remain real observations.
A missing member may coexist with other successfully read values. Platform,
lifetime, runspace, activation and getter errors terminate without a partial
snapshot; access denial is never false/empty/unavailable success. Original
exceptions, HRESULTs, source getter and availability/activation/invocation phase
are retained. Activation failure is still cached by the context.

Each selected getter uses the existing availability/lifecycle boundary. These
three getters are synchronous: no async operation or wait is created, and only
the short getter runs under the context lock. The returned snapshot is a
sequential, detached observation, not an atomic settings transaction. Reusing
the context rereads the values rather than caching observations. Dispose the
context in `finally`; module removal does not end its caller-owned lifetime.
The settings reader performs no setter, identity change, user override,
entitlement, installation, search or queue-control operation.

## Caller-scoped paused update search

`Request-AppInstallUpdateSearch -Context $context -CorrelationVector $correlationVector -ClientId $clientId`
implements only `SearchForAllUpdatesAsync(string correlationVector, string clientId, AppUpdateOptions)`.
All three parameters are mandatory; correlation/client strings must be nonempty
and non-whitespace and are forwarded unchanged. No client identity, acquisition
identity, catalog, account or user override is invented. These inputs are not
authorization or a way to bypass capability restrictions.

**This is a queue mutation.** Both writable safety properties are explicitly set
false: `AutomaticallyDownloadAndInstallUpdateIfFound` and `AllowForcedAppRestart`.
The documented false value still adds discovered updates to the install queue
paused. High-impact `ShouldProcess` confirmation describes that side effect.
`-WhatIf` and declined confirmation perform no native metadata probes, activation,
options construction or search, and return no success result. There is no
read-only-search switch, per-app selection, `ForUser`, custom catalog,
automatic-action switch or alternate-overload fallback.

After confirmation the coordinator checks required types, method arity, writable
safety properties and required item/status members before activation, constructs
and configures options, then submits through the context's short-call lifecycle
boundary. Waiting stays outside the context lock on the execution thread.
Optional item/status fields keep inventory's per-member availability semantics.
The same live owning context is required; it is not disposed by this command.

One immutable `AppInstallRequestSnapshot` is emitted only after the search,
operation cleanup and complete item capture succeed, including an available
empty result. `Acceptance = Accepted` means an async handle was returned;
`OperationState = Completed` means search completion, **not installation
completion**. Returned items can be paused/nonterminal or have unknown status.
Native item state, percentage, staging and launch readiness do not redefine
request acceptance or search completion.

`RequestId` is a per-invocation local GUID, separate from `ContextId`, projected
item/parent identities and the caller's native `CorrelationVector`/`ClientId`.
No value is a synthesized native installation ID or verified SID. These three
new request fields are nullable for older snapshots; the prior constructor and
older JSON remain compatible. Default request formatting (including PowerShell
deserialized requests while the module's view is loaded) displays local IDs,
API/scope/outcome fields and item count, not `CorrelationVector`, `ClientId`,
item payloads or raw errors. Direct property access, `Format-List *` and JSON
retain the original values for explicit inspection. Hiding fields in a default
view is not redaction, secret storage or a security boundary.

Children are captured when available, de-duplicated
by projection identity and retain parent/context/caller scope. Partial search
results merge into the bounded 4096-entry identity cache, preserving unrelated
items and existing local IDs. Overflow fails atomically without pruning; full
inventory scans retain their existing pruning behavior.

Failure produces a terminating `ErrorRecord` whose `TargetObject` is the typed
request (not a successful pipeline result). It retains acceptance, last observed
native state, local wait state, original error/HRESULT/source/phase and secondary
cleanup errors. Pre-submission failures are `NotSubmitted`; an exception during
submission is `Unknown`, since remote rejection/rollback cannot be proved.
Errors or failed capture retain `ItemsAvailability = Unknown` with no partial
list. Raw native messages and caller correlation values are not rendered by
default; deliberate inspection of error records/snapshots can expose them.

`StopProcessing` cancels only the per-command local wait token. There is no
native `Cancel`, pause/resume/control call or rollback. The adapter closes
terminal operations and releases pending ones without canceling them. Waiting
can end as `StoppedLocally` while acceptance is `Accepted` and native state is
`Started` or unknown. PowerShell may suppress all result/error writes once a
pipeline is stopped, so absence of output is never evidence of no submission.
There is no hard timeout for synchronous WinRT calls.

Only prior empty native-search evidence supports the scoped development
decision; grouped/nonempty capture, confirmation and cancellation are tested
with fail-closed fakes. No live Store actions are exercised by these tests.
[#233](https://github.com/shmuelie/powershell-modules/issues/233) remains open:
private-capability restrictions still apply, and this does not deliver the
broader #244 family or guarantee third-party support.

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
| `AppInstallRequestSnapshot` | Separate request acceptance, native operation state, local wait state and returned-item availability, with nullable local RequestId and caller-provided native correlation strings. No installed-success shortcut. |
| `AppInstallEntitlementSnapshot` | Explicit caller/device/unknown entitlement scope, observed native status and grant observation. No grant is inferred from native code zero or object construction. |
| `AppInstallError` | Source operation, failure phase/kind, original HRESULT, exception type/message, and copied cleanup failures. |
| `AppInstallSettingsSnapshot` | Caller context correlation, property scopes, copied requested/read property lists and only the selected settings observations; acquisition identity is opt-in. |

`Unknown` means not observed; `Unavailable` means the caller established that the
value cannot be obtained in this context/version. A missing member must not be
replaced with a successful-looking zero or empty inventory. Native integer enum
codes are preserved even when newer than the module's knowledge. Future adapters
must map a terminal state from actual installation evidence, not from percentage,
request completion, staging, launch readiness or an entitlement result.

Local item IDs remain stable while the same projected identity stays in the
bounded cache, refreshed by full inventory scans and augmented by partial search
results. They are **not native IDs**, are not derived from a
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

`New-AppInstallContext` (#234), `Get-AppInstallItem` (#236) and
`Get-AppInstallSettings` (#238) and only the caller all-app paused
`Request-AppInstallUpdateSearch` (#244 subset) ship here.
Names below for other work items
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
| `AcquisitionIdentity` | `Get-AppInstallSettings -Context -Property AcquisitionIdentity`; future `Set-AppInstallSetting` | Getter implemented in #238, exact opt-in only; omitted by default. Setter remains gated in #240; no identity spoofing or implicit account/SID interpretation. |
| `AutoUpdateSetting` | `Get-AppInstallSettings -Context`; future `Set-AppInstallSetting` | Getter implemented in #238 and selected by default. Device-setting write gated in #240; independent contexts do not isolate device settings. |
| `CanInstallForAllUsers` | `Get-AppInstallSettings -Context` | Getter implemented in #238 and selected by default. Read-only in the C# signature (despite the reference summary saying "gets or sets"), added in build 17763. Not an authorization grant or guarantee of installation availability/success. |

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
| `SearchForAllUpdatesAsync` | `Request-AppInstallUpdateSearch -Context -CorrelationVector -ClientId`; no-argument, telemetry-only, and options overloads are distinct | Only caller-scoped three-argument **options overload** with both safety flags explicitly false is implemented (#244 subset). High-impact ShouldProcess; found updates can be queued paused. Other overloads and automatic-update variants remain gated. |
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
| `AutomaticallyDownloadAndInstallUpdateIfFound` | Fixed `false` in the implemented caller all-app path; no true switch | Added in build 17763. **False still adds found updates to the install queue in a paused state.** It is not a read-only search. Only #244's approved subset; broader behavior gated. |
| `AllowForcedAppRestart` | Fixed `false` in the cleared caller all-app path | Added with options in build 17134. No implicit forced-restart consent. True and broader variants remain gated. |
| `CatalogId` | Future explicit catalog option where applicable | No implicit catalog override in the cleared subset; per-app/custom catalog behavior requires its own validation. |

No real update search is run by foundation tests, including false-flag searches.
The #244 subset uses `ShouldProcess` because finding updates can queue work.
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
