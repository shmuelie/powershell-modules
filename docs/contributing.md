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

## Interactive input and confirmation

Use the active PowerShell host UI for module-owned input:
`$Host.UI.Prompt(...)` with `FieldDescription` metadata for fields/free-form input,
and `$Host.UI.PromptForChoice(...)` with `ChoiceDescription` metadata for defined
options. Supply meaningful captions, messages, labels/help, and intentional
defaults. Keep candidate identity/order exact and cancellation explicit.
Do not automatically select grid-view packages, render custom menus, parse
numbered responses, or read console keys. Preserve explicit selector callbacks.
A descriptive numbered list inside the host prompt's **message** is appropriate:
keep useful context visible upfront while leaving rendering and input to the
host. For session choices, use unique numeric labels without `&`, sanitized
normalized names capped at 80 Unicode text elements including `...`, and branch
suffixes only for duplicates after sanitization/truncation. Keep full sanitized
names and identity/context in help. Do not truncate UTF-16 code units or remove
Unicode joiners/combining sequences; do not depend on console width or RawUI.
Rely on the host's prompting capability, not console availability or
`Environment.UserInteractive`; surface unsupported input, errors, and invalid
choice indices without silently selecting or proceeding. Method-call failures
must terminate even under `-ErrorAction Continue`.

These input APIs **do not replace operation confirmation**. Keep
`SupportsShouldProcess`, `ShouldProcess`, `ConfirmImpact`, `$ConfirmPreference`,
`-Confirm`, `-WhatIf`, and any existing `ShouldContinue` safeguards framework
managed. Do not add input prompts to preview or explicit noninteractive paths.
Mandatory-parameter prompting already belongs to PowerShell; do not duplicate it.

Test prompts with a controlled `PSHostUserInterface` in an isolated runspace,
synthetic candidates, and fail-closed native boundaries. Cover exact mapping,
metadata/defaults, cancellation, host errors, unavailable input, explicit
bypasses, callbacks, and standard confirmation separately. No real UI, user
session data, optional picker installations, or native launches are needed.

## Running git from module commands

Within `Shmuelie.Git`, use the private `Invoke-Git` helper with `-Arguments`
containing individual tokens and optional `-Path` (alias `-RepositoryPath`).
It resolves the directory with `Resolve-GitRepositoryPath`, supplies `-C`,
and never changes the caller's location or `$LASTEXITCODE`. Pass `-AllowBare`
only for commands that support bare repositories.

The returned `GitInvocationResult` contains `ExitCode`, `StandardOutput`,
`StandardError`, `Output`, and `RepositoryPath`. The two text streams preserve
newlines; `Output` is the legacy stdout-then-stderr line array, not a
chronological merge. On failure, the helper writes `GitCommandFailed` and emits
no result. Use `-ErrorAction Stop` for a terminating error, or
`-AllowNonZeroExit` when the command must interpret an expected non-zero exit
itself. The error's `TargetObject` retains the complete result.

Keep `ShouldProcess` and command-specific operand validation in the calling
cmdlet. Pass `--` before operand values where git supports it; token boundaries
prevent shell injection but do not make arbitrary git options safe.
`-Environment` supplies child-only overrides for discovery and execution (null
removes a variable).
The runner disables pagers, interactive editors, and credential prompts, and
closes stdin; supply commit messages and other required input as arguments.
Custom hooks or credential/SSH helpers remain responsible for their own
non-interactive behavior and network timeouts.

Repository discovery and legacy callers that already own error handling use
`Invoke-GitProcess`, the same low-level runner without repository validation
or non-zero-exit errors. `Invoke-GitWithEnvironment` remains its fetch
compatibility wrapper. All three helpers are private root-level script
functions and must stay out of both export lists.

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

Supported modules live under `modules/`. The repository-local
`experimental/Shmuelie.AppInstall.Experimental/` module is not publishable and is
not a dependency of the Windows module. Build it explicitly with
`Build-Module.ps1 -Module Shmuelie.AppInstall.Experimental` and select its own
`tests` directory with `Invoke-Tests.ps1 -Path` only when validation is authorized.
Default build/test and publication flows cover the supported catalog instead.
The shared `build/Assert-ModulePublishable.ps1` policy rejects experimental
publication and inspects the Windows artifact before import/publication.

Draft PRs skip automated build/test jobs. Mark a PR ready for review only after
validation is authorized; that event starts the required checks. A skipped draft
job is not validation evidence.

Behavioral tests live in [`tests/`](https://github.com/shmuelie/powershell-modules/tree/main/tests),
one [Pester](https://pester.dev/) v6 file per module (`tests/<Module>.Tests.ps1`).
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
- Pester 6 rejects calls that do not match any parameter-filtered mock. Cover
  expected calls explicitly or supply a safe, intentional default. Keep
  unexpected native operations behind throwing stubs; never fall back to real
  package updates, credential operations, or deployments.
- When mocking `Get-Command` or `Get-Module`, return only the required dependency
  metadata. Capture source command metadata before installing mocks so parameter
  contracts remain accurate. These commands accept arrays of names, so a
  single-name lookup should validate the count and use `Name[0]`.

Run the suite with the test runner:

```powershell
.\build\Invoke-Tests.ps1                              # whole suite
.\build\Invoke-Tests.ps1 -Path tests\Shmuelie.Git.Tests.ps1   # one file
```

The shared runner selects the newest installed stable Pester version from 6.2.0
up to, but not including, 7.0.0, installing within that range if needed. It
imports the selected module by its exact path; prereleases and newer major
versions do not take precedence. The runner fails on any failing test. CI and
publication use that same runner rather than independent framework installation
policies, so a change without passing tests cannot merge or ship.

## Building a module

```powershell
.\build\Build-Module.ps1 -Module Shmuelie.Dsc -OutputPath '.\output-[ab]'
```

`OutputPath` is a literal filesystem path, including brackets and PowerShell
escape characters. The build normalizes it and replaces only the selected
module's version directory, preserving neighboring modules, versions, and
wildcard-looking sibling paths. Output directories must not be links.

Source manifests are checked before staging cleanup. Because
`Test-ModuleManifest` internally expands wildcards even in referenced file paths,
affected source and staged directories are validated through isolated temporary
copies with wildcard-free paths. These copies retain the module/version layout,
reject linked contents, and are removed on success or failure. The system
temporary directory must itself have no wildcard or escape characters when a
copy is needed. Ordinary paths continue to use direct manifest validation.
The final import and removal always run against the **actual staged artifact**
in a short-lived child PowerShell process, not against a validation copy.

## Validate

```powershell
.\build\Test-Modules.ps1
.\build\Invoke-Tests.ps1
```

`Test-Modules.ps1` builds every module, validates the manifest, imports and
removes it, and scans module sources, documentation, and READMEs for forbidden
markers. `Invoke-Tests.ps1` runs the Pester suite. Fix any reported issue before
opening a pull request.
