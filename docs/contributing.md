---
title: Contributing
---

**[Home](index.md) · [Modules](modules.md) · [Installation](installation.md) · [Contributing](contributing.md) · [GitHub](https://github.com/shmuelie/powershell-modules)**

# Contributing

## Where code lives

Each module is a self-contained directory under `modules/`:

```text
modules/<Module>/
├── <Module>.psd1     # manifest and exported members
├── <Module>.psm1     # loader and Export-ModuleMember
├── *.ps1             # one file per topic; functions are dot-sourced
├── README.md
└── CHANGELOG.md
```

## Adding or changing a command

1. Add or edit a root-level `.ps1` file under the owning module.
2. Export it from both the `.psm1` `Export-ModuleMember` list and the `.psd1`
   `FunctionsToExport` list.
3. Include comment-based help and use `SupportsShouldProcess` for destructive or
   state-changing operations.
4. Update the module README command table and add an entry under `[Unreleased]`
   in the module's `CHANGELOG.md`.
5. Add or update tests for the behavior you added or changed — see
   [Testing](#testing). Every new cmdlet and every behavioral change ships with
   tests in the same pull request.
6. If the change also applies to the bash port, file an `upstream-parity` issue
   in `shmuelie/bash-scripts` — see [Bash port parity](#bash-port-parity).

**Do not bump `ModuleVersion` for a content change.** A module's version changes
only when a release is cut — see [Releasing](#releasing). Between releases the
manifest version stays fixed and changes accumulate under `[Unreleased]`.

## Releasing

A release is the only time a `ModuleVersion` changes:

1. Choose the module and its new semantic version.
2. Set `ModuleVersion` in the `.psd1` and the `**Version:**` header in the module
   README (and the version shown in the root README and documentation site).
3. Move the module's `[Unreleased]` notes into a dated version section in its
   `CHANGELOG.md`.
4. Commit, tag the release as `<Module>-v<version>`, and publish.

## Bash port parity

[`shmuelie/bash-scripts`](https://github.com/shmuelie/bash-scripts) is a bash
port of these modules. It is a separate repository and is not changed from a pull
request here. When a change also applies to the port — a new command, a changed
parameter or output shape, a cross-platform bug fix, or corrected help/docs for
shared behavior — open a tracking issue in the port so the update isn't lost:

```powershell
gh issue create --repo shmuelie/bash-scripts --label upstream-parity `
  --title "Port: <short description>" `
  --body "Upstream shmuelie/powershell-modules#<PR-or-issue>: <what changed and why the port needs it>."
```

Use the `upstream-parity` label (it exists to track parity with this repo),
reference the upstream PR/issue, and describe the behavior to port rather than
the PowerShell implementation. Check for an existing open `upstream-parity` issue
first to avoid duplicates. Skip this only when the change can't apply to the port
— Windows-only commands, PowerShell-specific packaging, or repo-internal
build/CI/docs with no bash equivalent.

## Public-content policy

Public modules must not reference internal-only tooling, private endpoints,
organization-specific systems, or credentials. Prefer parameters and
environment variables over hardcoded hosts or feeds.

Public modules **do not export command aliases**. Aliases are a personal
preference and are added downstream by a profile or overlay, not shipped by the
module (so `AliasesToExport` stays empty and the `.psm1` defines no `Set-Alias`).
Parameter `[Alias()]` attributes are unaffected — those are part of a command's
contract, not command aliases.

## Testing

Behavioral tests live in [`tests/`](https://github.com/shmuelie/powershell-modules/tree/main/tests),
one [Pester](https://pester.dev/) v5 file per module (`tests/<Module>.Tests.ps1`).
Each file imports its module directly from source
(`modules/<Module>/<Module>.psd1`), so tests run without a full build.

**Every new cmdlet and every behavioral change must land with tests in the same
pull request.** When you add or change a command:

- Add a `Describe` block for a new cmdlet, or extend the existing one for a
  changed cmdlet, in that module's `tests/<Module>.Tests.ps1` (create the file
  if the module has none yet).
- Prefer table-driven `It ... -ForEach` cases for pure formatters and helpers,
  covering boundaries and edge cases (e.g. `Format-Duration` second/minute/hour
  boundaries and fractional rounding; `Format-GitStatusSegment` relation,
  count, and `-ShowChangeCounts:$false` variants).
- Keep tests deterministic and self-contained. Use `$TestDrive` for scratch
  files, construct synthetic input objects where possible, and only reach for
  real external tools (e.g. temporary `git` repositories) when behavior can't be
  exercised any other way.

Run the suite with the test runner:

```powershell
.\build\Invoke-Tests.ps1                              # whole suite
.\build\Invoke-Tests.ps1 -Path tests\Shmuelie.Git.Tests.ps1   # one file
```

The runner ensures Pester 5.2+ is available (installing it if needed) and fails
on any failing test. CI runs it on every pull request, and it gates publishing,
so a change without passing tests cannot merge or ship.

## Validate

```powershell
.\build\Test-Modules.ps1
.\build\Invoke-Tests.ps1
```

`Test-Modules.ps1` builds every module, validates the manifest, imports and
removes it, and scans module sources, documentation, and READMEs for forbidden
markers. `Invoke-Tests.ps1` runs the Pester suite. Fix any reported issue before
opening a pull request.
