---
title: Experimental AppInstall context
---

# Experimental AppInstall context

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

Later cmdlets must accept this explicit context rather than create an
undocumented manager per invocation or share mutable global settings. The
internal manager adapter is where the approved caller-scoped reads can be added.
No such read, search, settings, mutation or `ForUser` operation is exposed here.

## Async and event integration seams

The internal async adapter accepts an already-created WinRT operation; it does
not submit one. The waiter polls native completion state on the execution thread
and preserves exceptions returned by `GetResults`. Stopping the local wait uses
a separate cancellation token and does not call native `Cancel`. Disposing an
adapter closes only terminal operations; a still-started operation is released
without cancellation. There are no polling tasks or completion callbacks left
running in the module after a wait ends.

The injectable event subscription owns its unsubscribe resource. Callbacks only
signal invalidation; future monitoring must read snapshots and call PowerShell
pipeline writers on the cmdlet execution thread. Repeated notifications can
coalesce. Native event subscription and public monitoring are not implemented in
this foundation checkpoint.

Request acceptance, async-operation completion, successful installation,
`IsStaged`, and `ReadyForLaunch` are different observations. None is inferred
from a context, a successful activation, or mere method-name presence.

## Sources

- [AppInstallManager and its access restriction](https://learn.microsoft.com/uwp/api/windows.applicationmodel.store.preview.installcontrol.appinstallmanager)
- [AppInstallItem](https://learn.microsoft.com/uwp/api/windows.applicationmodel.store.preview.installcontrol.appinstallitem)
- [AppInstallStatus](https://learn.microsoft.com/uwp/api/windows.applicationmodel.store.preview.installcontrol.appinstallstatus)
