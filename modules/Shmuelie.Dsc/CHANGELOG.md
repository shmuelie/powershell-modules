# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/).
Versions change only when a release is cut; unreleased work stays under
`[Unreleased]`.

## [Unreleased]

## [0.1.2] - 2026-09-22

### Fixed
- `CopilotMarketplace.Set()` passes only `Repository` to the native
  `copilot plugin marketplace add <source>` command. `Name` is the source
  manifest's actual registered identity used by `Test()` and `Get()`, not a
  custom registration alias. Document source formats and presence-only
  convergence; retain shell-safe validation and native failure handling.
  (Fixes #261.)

## [0.1.1] - 2026-09-18

### Fixed
- `SymbolicLink.Test()` anchors relative targets to the link parent and uses
  read-only directory-entry and literal-lookup evidence for case differences.
  Distinct names are noncompliant; unknown equivalence raises an explicit error
  rather than requesting replacement. Exact normalized dangling targets remain
  compliant, without assuming filesystem case rules from the OS. (Fixes #260.)
- `CopilotPlugin`, `CopilotMarketplace`, and `UvTool` validate discovery exit
  status before matching list output. `Test()` and `Get()` now raise explicit
  errors with diagnostics and exit status on failure or unknown completion,
  rather than reporting a guessed installed/absent state. CLI wrappers reject
  missing exit status without reusing a previous command's exit code and restore
  caller state. Existing known-exit `Set()` behavior is unchanged. (Fixes #259.)
- `SavePSResource.Test()` and `Get().Installed` require a readable, correctly
  named module manifest, matching version layout, and declared root/startup
  files instead of accepting empty or incomplete directories. Checks remain
  read-only and do not import candidate code or resolve dependencies; save
  options and repository/path selection are unchanged. Numeric versions compare
  with omitted components treated as zero. (Fixes #258.)

## [0.1.0] - 2026-08-24

### Added
- Initial class-based DSC v3 resources: `SavePSResource` (save a module to a
  local path, with an optional `Version`), `SymbolicLink` (create/verify a
  symbolic link), `CopilotPlugin` (install a GitHub Copilot CLI plugin, with an
  optional `Name` for URL sources), `CopilotMarketplace` (register a Copilot CLI
  marketplace), and `UvTool` (install a Python tool via `uv`). Presence checks
  use whole-token matching over ANSI-stripped CLI output, CLI arguments are
  validated as shell-safe, `Get()` reports actual state, and CLI failures
  include the tool's output.
