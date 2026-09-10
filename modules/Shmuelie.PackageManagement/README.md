# Shmuelie.PackageManagement

Provider-neutral package update orchestration for PowerShell 7.4+.

**Version:** 0.1.0

## Provider availability

The catalog names, in order, are `PSResourceGet`, `DotNet`, `Npm`, `Pip`, `Uv`,
`VSCode`, `WinGet`, and `AppInstaller`. Catalog membership does not guarantee
an installed integration: unavailable dependencies and unimplemented adapters
produce explicit `Skipped` results with reasons, not successful updates.
See the provider sections below for supported integrations and options.

No provider modules are required at import time. Windows-only providers are
gated before dependency discovery on Linux and macOS.

## Commands

| Command | Description |
|---|---|
| `Update-AllPackages` | Discover selected providers, preview or confirm each package update, and return typed outcomes |

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

`ProviderOptions` maps each provider name to its own hashtable. Each adapter declares its
supported options. Invalid option names or non-hashtable values fail before any
provider starts. Options for unselected providers are validated but not used.
Provider and option keys are case-insensitive even in JSON-derived or custom
hashtables. Case-equivalent duplicate keys are rejected before any provider
starts, and the caller's maps are not modified.
Options are data, not commands, module paths, or scripts to execute.

### Uv

`Uv` covers both **system Python environment packages** and **installed uv
tools**. Install uv separately. Package operations additionally require
`Shmuelie.Utilities` (`Install-PSResource Shmuelie.Utilities`); this optional
module is loaded only when package operations are selected. A tools-only run
does not require Utilities. Nothing is installed automatically.

| Option | Values / default | Behavior |
|---|---|---|
| `Scope` | `All` (default), `Packages`, `Tools` | Select both kinds of target or just one |
| `TopLevelOnly` | Boolean; `$true` by default | Package filtering; `$false` includes outdated dependencies. Not valid for `Tools` |

```powershell
Update-AllPackages -Provider Uv -WhatIf
Update-AllPackages -Provider Uv -ProviderOptions @{ Uv = @{ Scope = 'Tools' } } -Confirm:$false
Update-AllPackages -Provider Uv -ProviderOptions @{ Uv = @{ Scope = 'Packages'; TopLevelOnly = $false } }
```

Package discovery reuses `Shmuelie.Utilities\Get-UvPackages -Outdated
-TopLevelOnly`, and approved updates reuse `Shmuelie.Utilities\Update-UvPackage`
with inner confirmation disabled. These commands always use uv's `--system`
selection, **not** the active virtual environment. The adapter does not support
custom Python interpreters, project environments, extra indexes, arbitrary
arguments, or an environment-path option. Invalid option values fail explicitly;
unknown option names terminate before discovery.

Targets are `pip:system:<distribution-name>` for packages and
`tool:<distribution-name>` for installed tools, including previews and failures.
Tools are listed using `uv tool list --color never --no-progress`. The official
CLI currently has **no JSON output format for tool listing**; the adapter
strictly validates tool headings and entrypoint lines instead of guessing
through warnings or unknown formats. Pip package discovery already uses JSON.

Every installed tool is an update candidate (not just those with a newer
index version). Its approved callback runs `uv tool upgrade` for that single
tool, preserving recorded version constraints and installation settings. There
is no `uv tool run`, `uvx` cache refresh, self-update, or shell/PATH modification.
After successful updates, the adapter re-reads the relevant installed listing:
`ResultingVersion` is observed, never copied from an available/proposed version.
`Unchanged` means the main distribution's version is unchanged; a tool's
dependencies or executables may still have been refreshed. Tool previews have
no proposed version. Native failures and malformed/absent update evidence fail;
discovery failures prevent all mutations for this provider. A missing previous
or observed version produces `Failed` rather than assuming the version changed.

Official uv references: [CLI flags](https://docs.astral.sh/uv/reference/cli/#uv-tool-list),
[tool upgrade semantics](https://docs.astral.sh/uv/concepts/tools/#upgrading-tools),
and [tool list output implementation](https://github.com/astral-sh/uv/blob/main/crates/uv/src/commands/tool/list.rs).

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
