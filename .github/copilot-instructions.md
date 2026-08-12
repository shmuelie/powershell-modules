# Copilot instructions for `shmuelie/powershell-modules`

This repository is a set of **independently versioned PowerShell 7.4+ modules**
published to the PowerShell Gallery. One module also ships a compiled C#
PSReadLine command predictor. These instructions tell an AI coding agent how to
make changes that fit the project's conventions. For the human-facing version,
see [`docs/contributing.md`](../docs/contributing.md).

## Modules

| Module | Purpose |
|---|---|
| `Shmuelie.Git` | Git repository, worktree, status, completion, and PSReadLine prediction helpers (includes the compiled `WorktreePredictor`) |
| `Shmuelie.Copilot` | GitHub Copilot CLI session, plugin, marketplace, and MCP helpers, plus the `Start-Copilot` launcher |
| `Shmuelie.Node` | Node.js, nvm-windows, npm, and Azure DevOps npm credential helpers |
| `Shmuelie.Utilities` | General developer utilities (dotnet/pip/uv/VS Code tools, services, WPR, terminal) |

## Repository layout

```text
modules/<Module>/
├── <Module>.psd1     # manifest: ModuleVersion + FunctionsToExport
├── <Module>.psm1     # loader + Export-ModuleMember (+ any C#/predictor wiring)
├── README.md         # command table + Version header
├── CHANGELOG.md      # Keep a Changelog; [Unreleased] holds pending work
└── Public/*.ps1      # one file per topic; every *.ps1 is dot-sourced on import
modules/Shmuelie.Git/Predictor/   # C# source for the bundled predictor
build/                            # Build-Module / Test-Modules / Invoke-Tests / Publish-Module
tests/<Module>.Tests.ps1          # Pester v5, imports the module from source
docs/                             # Markdown docs site (contributing, modules, installation)
```

## Golden rules

- **This is a public repo. Never commit or push to `main`.** Do all work on a
  branch and open a pull request — even for a one-line or docs-only change.
- **Never `git push --force`, rebase, amend, or `git pull`.** Use `git fetch` +
  fast-forward. To resolve conflicts, merge `origin/main` into the branch and
  fix the working tree; do not rewrite history.
- **Do not bump `ModuleVersion` for a content change.** A version changes only
  when a release is cut (see Releasing). Between releases, changes accumulate
  under `[Unreleased]`.
- **No internal-only references.** No private endpoints, org-specific systems,
  internal tooling, or credentials. Prefer parameters and environment variables
  over hardcoded hosts or feeds.
- **Modules export no command aliases.** Keep `AliasesToExport` empty and define
  no `Set-Alias` in a `.psm1`. (Parameter `[Alias()]` attributes are fine — they
  are part of a command's contract.)

## Adding or changing a command

1. Add or edit a function under the owning module's `Public/`.
2. Export it from **both** the `.psm1` `Export-ModuleMember -Function` list
   **and** the `.psd1` `FunctionsToExport` list. Private helpers stay out of both
   lists (dot-sourcing a helper in a `Public/*.ps1` file does not export it).
3. Include comment-based help, and add `[CmdletBinding(SupportsShouldProcess)]`
   for any destructive or state-changing operation (honor `-WhatIf`/`-Confirm`).
4. Update the module README command table and add an entry under `[Unreleased]`
   in that module's `CHANGELOG.md` (`### Added` / `### Fixed` / `### Changed`).
5. Add or update tests in the same pull request (see Testing).

## Changelogs

- Format: [Keep a Changelog](https://keepachangelog.com/). Pending work lives
  under `## [Unreleased]` with `### Added` / `### Fixed` / `### Changed`.
- Each module owns its `CHANGELOG.md`. The **root** `CHANGELOG.md` tracks only
  catalog-level changes (build/CI/docs infrastructure), not per-module fixes.
- A user-visible behavior change should have a changelog entry.

## Testing

- One Pester v5 file per module: `tests/<Module>.Tests.ps1`. Each imports its
  module directly from source (`modules/<Module>/<Module>.psd1`) — no build step.
- **Every new cmdlet and every behavioral change ships with tests in the same
  PR.** Add a `Describe` for a new cmdlet or extend the existing one.
- Keep tests deterministic and self-contained: use `$TestDrive` for scratch
  files, construct synthetic input objects, and prefer table-driven
  `It ... -ForEach` cases for pure formatters/helpers. Only reach for real
  external tools (e.g. a temporary `git` repo) when behavior can't be exercised
  another way.

## Validate before opening a PR

```powershell
.\build\Test-Modules.ps1   # build, manifest validation, import/remove, forbidden-marker scan
.\build\Invoke-Tests.ps1   # full Pester suite (installs Pester 5.2+ if needed)
```

Run the smallest relevant slice while iterating
(`.\build\Invoke-Tests.ps1 -Path tests\Shmuelie.Git.Tests.ps1`), then the full
commands above before pushing. CI runs both on `windows-latest` as the required
**`validate`** status check; `main` is protected and requires the branch to be
up to date, so update the branch and let `validate` pass before merging. Merges
are squash merges titled `... (#N)`.

## Cross-platform

Non-Windows-specific commands must run anywhere PowerShell 7 does (Linux/macOS
too). Build paths with `Join-Path` / `[System.IO.Path]` and
`[System.IO.Path]::DirectorySeparatorChar`; never hardcode `\`, and normalize
git's `/`-separated output to backslashes only when
`[System.IO.Path]::DirectorySeparatorChar -eq '\'`.

## Security

Values derived from a repository (branch names, remote-URL segments) must be
validated before being passed as arguments to a command that resolves to a
`.cmd`/`.bat` shim on Windows (`az`, `npm`, `code`, `copilot`, …). Windows
re-parses `cmd.exe` metacharacters when launching batch wrappers
(CVE-2024-1874 / "BatBadBut" class), so allow-list or reject unsafe input rather
than passing it through.

## The bundled predictor (`Shmuelie.Git`)

- C# source is under `modules/Shmuelie.Git/Predictor/`; `Test-Modules.ps1` /
  `Build-Module.ps1` compile it to `bin/WorktreePredictor.dll` (needs the .NET
  SDK). The `.psm1` registers it on import and unregisters it on removal.
- Keep the predictor's subsystem GUID a single source of truth (shared between
  registration and cleanup) and keep the background cache refresh thread-safe.

## Releasing (rare — only when explicitly cutting a release)

1. Set the new `ModuleVersion` in the `.psd1` and the `**Version:**` header in
   the module README (and the version shown in the root README and docs site).
2. Move that module's `[Unreleased]` notes into a dated version section.
3. Commit, tag `<Module>-v<version>`, and publish via `build/Publish-Module.ps1`.
