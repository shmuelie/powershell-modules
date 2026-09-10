# Shmuelie.PackageManagement

Provider-neutral package update orchestration for PowerShell 7.4+.

**Version:** 0.1.0

## Provider availability

The ordered catalog contains `PSResourceGet`, `DotNet`, `Npm`, `Pip`, `Uv`,
`VSCode`, `WinGet`, and `AppInstaller`. The **DotNet**, **Npm**, and **Pip** adapters are implemented;
the other adapters remain separate follow-up work and report explicit
`Skipped` results, not successful updates.

No provider modules are required at import time. Windows-only providers are
gated before dependency discovery on Linux and macOS.

## Commands

| Command | Description |
|---|---|
| `Update-AllPackages` | Discover selected providers, preview or confirm each package update, and return typed outcomes; see provider availability and options below |

```powershell
Update-AllPackages -WhatIf
Update-AllPackages -Provider DotNet, Npm -ExcludeProvider Npm -StopOnFailure
Update-AllPackages -Provider Pip -ProviderOptions @{ Pip = @{ User = $true } } -WhatIf
```

Default selection includes every known provider; unavailable providers are
reported as skipped. Includes, exclusions, and options use case-insensitive
names. Both selection parameters complete from the same catalog used for
validation. Exclusion wins, duplicates run once, and execution follows catalog
order (the provider order above), then target discovery order. Unknown names
fail before discovery or mutation.

`ProviderOptions` maps each provider name to its own hashtable. Each implemented
adapter explicitly declares its supported options; placeholders accept only
empty tables. Invalid option names or non-hashtable values fail before any
provider starts. Options for unselected providers are validated but not used.
Provider and option keys are case-insensitive even in JSON-derived or custom
hashtables. Case-equivalent duplicate keys are rejected before any provider
starts, and the caller's maps are not modified.
Options are data, not commands, module paths, or scripts to execute.

`-WhatIf` performs read-only discovery and returns `Planned` rows for discovered
targets, without ever invoking mutating callbacks. `-Confirm` asks once per
target; declining returns `Skipped`. `-Confirm:$false` permits unattended
updates. Integrations must not prompt a second time after this approval.

Thrown errors, nonterminating errors, and adapter-reported `Failed` rows do
not stop other targets or providers by default. `-StopOnFailure` stops after
the first failed callback, before the next target or provider, retaining all
outcomes already produced by that callback. Skips do not trigger fail-fast.
Provider failures are result data even with `-ErrorAction Stop`; invalid
arguments remain terminating errors. Read-only discovery errors prevent any
updates for that provider. No results are invented for unstarted providers.

## DotNet global tools

DotNet discovers `Shmuelie.DotNet` lazily and requires `dotnet` with an installed
SDK. Missing modules, commands, or an SDK produce `Skipped`; nothing is installed
automatically. If needed, install the canonical module separately with
`Install-PSResource Shmuelie.DotNet`.

The adapter uses module-qualified `Shmuelie.DotNet\Get-DotNetTool` and
`Shmuelie.DotNet\Update-DotNetTool`, not compatibility wrappers or shell overlays.
Only global tools are considered. `Name` is an optional nonempty wildcard string,
matching the canonical listing filter; it is validated before target discovery.
Local tools, manifest paths, versions, feeds, and SDK installation are not
supported provider options.

```powershell
Update-AllPackages -Provider DotNet -ProviderOptions @{ DotNet = @{ Name = 'dotnet-*' } } -WhatIf
```

The current canonical API has no read-only outdated/latest-version query.
Discovery therefore lists installed candidates, not proven outdated tools;
previews have a null proposed/resulting version. Each approved tool is updated
individually and then re-listed to observe its installed version. A changed
version reports `Updated`, an equal version reports `Unchanged`, and unknown
versions stay null. When versions are unknown, an explicit canonical update
report is required for `Updated`; otherwise the outcome is `Failed`. Native
failures, errors, malformed/empty update output, and missing post-update tools
are failures, never successful fallbacks. No matching installed tools produces
the standard provider-level `Unchanged` result.

## Npm

Install `Shmuelie.Node` separately and make npm available on `PATH`. Neither
dependency is installed automatically; missing dependencies return `Skipped`.
Discovery reuses `Get-NpmPackage -Global -Outdated`, and each outdated global
package is passed to `Update-NpmPackage -Global`. Scoped names such as
`@scope/tool` are preserved. Package specs, paths, options, and shell
metacharacters are rejected before forwarding names to npm.

Npm accepts no provider options. Repository dependencies and lockfiles are never
update targets. An empty outdated set returns `Unchanged`. After each successful
update, the installed global version is read again. Equal versions return
`Unchanged`; different observed versions return `Updated`. Failed commands,
invalid results, or an unverifiable version change return `Failed`, never an
assumed success based on the proposed latest version. Individual failures do not
prevent later package updates unless `-StopOnFailure` is set.

## Pip

Pip uses the optional `Shmuelie.Utilities` commands `Get-PipPackages` and
`Update-PipPackage`, with `pip` on PATH. Missing modules or commands produce
`Skipped` results with a reason. Dependencies are discovered lazily; install
`Shmuelie.Utilities` separately if needed. The adapter does not install pip,
choose a Python interpreter, or change environments.

By default, discovery selects **outdated top-level packages** (`--outdated`
and `--not-required`), avoiding independent updates of transitive dependencies.
The active pip environment determines which installations are visible.

| Option | Type | Default | Behavior |
|---|---|---|---|
| `User` | Boolean | `$false` | Restrict discovery and post-update observation to user-installed packages (`pip list --user`) |
| `TopLevelOnly` | Boolean | `$true` | Discover only packages not required by other installed packages; `$false` explicitly includes dependencies |

SwitchParameter values are also accepted. Strings such as `'false'`, numbers,
null, scripts, and other values are rejected during read-only discovery, before
any package is updated. Additional native arguments and requirement specifiers
are not supported.

**User scope is a discovery filter, not an installation-destination override.**
The existing `Update-PipPackage` has no `User` parameter: updates use its
`pip install --upgrade <name>` behavior in the active environment. This adapter
does not invent a `--user` installation option or change pip configuration.

```powershell
Update-AllPackages -Provider Pip -WhatIf
Update-AllPackages -Provider Pip -ProviderOptions @{ Pip = @{ User = $true } } -Confirm:$false
Update-AllPackages -Provider Pip -ProviderOptions @{ Pip = @{ TopLevelOnly = $false } } -WhatIf
```

Each approved package is updated separately, with inner confirmation disabled.
Package names are validated as distribution identifiers before being forwarded
to pip. A successful typed updater result is followed by a read-only installed
package query in the same user scope, without outdated or top-level filters.
The observed version determines `Updated` versus `Unchanged`; the proposed
version is used only for `Planned` rows. An empty/invalid updater result, native
failure, or unavailable/ambiguous post-update version produces `Failed`.
Warnings retain their stream, errors retain their records when available, and
native diagnostics routed through the updater's verbose stream are included in
reported failure reasons. Independent packages continue unless `-StopOnFailure`
is set.

## Output

Every row has PowerShell type name
`Shmuelie.PackageManagement.UpdateResult`.

| Property | Contract |
|---|---|
| `Provider` | Canonical provider name |
| `Target` | Package identifier or provider-specific target; provider name for discovery/dependency failures or an empty update set |
| `PreviousVersion` | Installed version before the update, as a string, or null |
| `ResultingVersion` | Observed version after the update, or null; for `Planned`, the proposed version when known |
| `Status` | `Planned`, `Updated`, `Unchanged`, `Skipped`, or `Failed` |
| `Error` | Original PowerShell `ErrorRecord` for failures where available, otherwise a contract-error record; null for other statuses |
| `Reason` | Skip explanation, error message, or optional outcome detail |

An empty successful target discovery returns a provider-level `Unchanged` row
with reason `Provider reported no update targets.` An update callback that
returns nothing has an unknown outcome and produces `Failed`, never a
success-shaped fallback. Valid adapter results are preserved, including
versions, errors, and additional properties. A callback can report success for
an operation and then fail: both records remain visible in emission order.

## Private adapter contract

This section is for sibling adapter implementations, not a public extension
API. There is **no exported provider registry** and no discovery of arbitrary
configuration or third-party scripts.

Add an owning root-level `.ps1` file to this module and wire its descriptor
into `Get-PackageProvider` in `PackageProviders.ps1`, replacing only the
corresponding placeholder. Root scripts are automatically loaded and staged.
The catalog must remain read-only and side-effect-free: selection, validation,
and completion call it without importing dependencies or probing tools.
Tests inject descriptors by mocking this private function in module scope.

| Descriptor field | Contract |
|---|---|
| `Name` | One canonical catalog name; unique, stable ordering |
| `Platforms` | Array drawn from `Windows`, `Linux`, `MacOS` |
| `RequiredModules` | Module names imported lazily for selected, implemented, platform-supported providers; no hard manifest dependencies |
| `RequiredCommands` | Commands checked after imports, with no command auto-loading |
| `OptionNames` | Allow-listed provider option keys; no common parameters or orchestration overrides |
| `TestAvailable` | Optional read-only scriptblock with `param([hashtable]$Options)` returning exactly one object with Boolean `Available` and nonempty `Reason` if false |
| `GetTargets` | Required read-only scriptblock with `param([hashtable]$Options)` emitting zero or more `New-PackageUpdateTarget` objects |
| `Update` | Required mutating scriptblock with `param($Target, [hashtable]$Options)` emitting one or more `New-PackageUpdateResult` objects for that target |

Missing `GetTargets` or `Update` means unimplemented, and produces `Skipped`.
Missing modules or commands and unsupported platforms also skip with actionable
reasons. Dependency import exceptions are real failures, not missing-provider
skips. Custom availability is called only after dependencies are ready.

Use `New-PackageUpdateTarget -Target <id> -PreviousVersion <version>
-ProposedVersion <version> -Data <object>` to describe each update. `Data` is
private read-only adapter state (for example the original package object);
it is not copied into aggregate results. Discover targets without mutation,
including under `-WhatIf`. Validate option values in read-only discovery
before returning any targets; the core validates option *names* and table shape.
Treat options as read-only (the core shallow-copies each table).

The core invokes `Update` only inside `ShouldProcess` for the specific target.
Reuse existing provider cmdlets rather than copying them or moving exports.
Pass `-Confirm:$false` to supporting inner update commands after aggregate
approval; never execute updates from `TestAvailable` or `GetTargets`.

Use `New-PackageUpdateResult -Provider <canonical-name> -Target <same-id>
-Status <status> [-PreviousVersion <version>] [-ResultingVersion <version>]
[-Error <ErrorRecord>] [-Reason <text>]`. Update callbacks may emit `Updated`,
`Unchanged`, `Skipped`, or `Failed` (not `Planned`); failures require an
`ErrorRecord`, and skips require a reason. Emit each actual result as it becomes
available so preceding results survive a later error. Success-stream logging,
untyped output, mismatched providers/targets, and empty update output are
contract failures. Use verbose/information streams for diagnostics.

Do not swallow errors or assume a native exit code means success. Check native
exit codes and normalize native output in the adapter. The callback boundary
also enables PowerShell's native-command error preference and captures thrown
and nonterminating errors, retaining already-emitted typed results. Unknown
versions stay null; never label a proposed version as an observed version.
