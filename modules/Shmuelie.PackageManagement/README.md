# Shmuelie.PackageManagement

Provider-neutral package update orchestration for PowerShell 7.4+.

**Version:** 0.1.0

## Provider availability

The `PSResourceGet` adapter is implemented. `DotNet`, `Npm`, `Pip`, `Uv`,
`VSCode`, `WinGet`, and `AppInstaller` remain reserved integrations and return
explicit `Skipped` results until their adapters ship. The complete provider set
is planned for milestone M6.

No provider modules are required at import time. Windows-only providers are
gated before dependency discovery on Linux and macOS.

## Commands

| Command | Description |
|---|---|
| `Update-AllPackages` | Discover selected providers, update configured PowerShell module roots through PSResourceGet, and return typed outcomes |

```powershell
Update-AllPackages -WhatIf
Update-AllPackages -Provider DotNet, Npm -ExcludeProvider Npm -StopOnFailure
Update-AllPackages -ProviderOptions @{ Npm = @{} } -Confirm:$false
```

Default selection includes every known provider; unavailable providers are
reported as skipped. Includes, exclusions, and options use case-insensitive
names. Both selection parameters complete from the same catalog used for
validation. Exclusion wins, duplicates run once, and execution follows catalog
order (the provider order above), then target discovery order. Unknown names
fail before discovery or mutation.

`ProviderOptions` maps each provider name to its own hashtable. Each implemented
adapter explicitly declares its supported options; reserved integrations accept
only empty tables. Invalid option names or non-hashtable values fail before any
provider starts. Options for unselected providers are validated but not used.
Provider and option keys are case-insensitive even in JSON-derived or custom
hashtables. Case-equivalent duplicate keys are rejected before any provider
starts, and the caller's maps are not modified.
Options are data, not commands, import paths, or scripts to execute.

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

## PSResourceGet

Requires `Microsoft.PowerShell.PSResourceGet` and `Shmuelie.Utilities`, imported
lazily only when selected. Missing modules or required commands produce
`Skipped` with an actionable dependency reason; nothing is automatically
installed. The adapter reuses Utilities' private read-only discovery and semantic
version helpers and its public `Update-InstalledPSResource` command. Utilities
must provide those helpers; no provenance or prerelease rules are copied here.

| Option | Value |
|---|---|
| `Path` | One module-root string or an array of roots previously supplied to `Save-PSResource`. No default root or `PSModulePath` scan. |
| `Name` | Optional string or string array of wildcard module-name filters; comma-separated patterns retain canonical behavior. |
| `Exclude` | Optional string or string array of wildcard exclusions, applied before repository lookup. |
| `Repository` | Optional nonempty repository-name string; only explicit values override recorded provenance. |

```powershell
Update-AllPackages -Provider PSResourceGet -ProviderOptions @{
    PSResourceGet = @{
        Path = @((Join-Path $HOME 'PowerShellModules'), (Join-Path $HOME 'OtherModules'))
        Name = 'MyTools.*'
        Exclude = '*.Local'
    }
} -WhatIf
```

Roots must be filesystem directories. Missing roots warn and skip; no configured
existing roots produces a provider-level `Skipped` result. Equivalent resolved
paths run once, in supplied order. Empty roots or filters matching nothing return
the core provider-level `Unchanged` result. Invalid option values produce
provider-level `Failed` results during read-only availability/discovery.

Each target is the full module directory path, so identical module names under
different roots remain distinct. Discovery reads installed layouts only, using
canonical wildcard filtering, highest-version selection, and prerelease parsing.
`-WhatIf` lists selected installed modules (including current modules) as
`Planned`, with unknown/null proposed versions, without repository queries or
invoking `Update-InstalledPSResource`. Module names containing commas fail
discovery because the canonical selector cannot address them individually.

After aggregate approval, the canonical update runs once per module with inner
confirmation disabled. It owns repository provenance, source-URI resolution,
fallback behavior for unrecorded provenance, prerelease selection, and saving.
`Repository` is not passed unless configured. Warnings retain their warning
stream; thrown/nonterminating errors become `Failed` results and participate in
`-StopOnFailure` between modules.

Results are based on the installed version observed after the canonical command:
`Updated` requires a newer observed version. With no newer version, a canonical
warning produces `Skipped` with that warning as its reason; otherwise the result
is `Unchanged` with an explicit limitation: the void canonical command cannot
distinguish already-current modules from silent skips such as a module absent
from its repository. `Unchanged` is not a claim that a repository lookup succeeded.
Missing post-update observations produce `Failed` with a null resulting version;
no proposed version or void output is treated as evidence of a successful update.

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
