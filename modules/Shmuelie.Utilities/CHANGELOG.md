# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/).
Versions change only when a release is cut; unreleased work stays under
`[Unreleased]`.

## [Unreleased]

## [0.2.3] - 2026-08-21

### Changed
- Windows-only utilities now fail fast with clear terminating errors on
  non-Windows platforms before touching registry, Windows Terminal, or WPR state.

## [0.2.2] - 2026-08-20

### Fixed
- Harden `Get-PipPackages` and `Get-UvPackages` JSON parsing to tolerate stray
  warning lines emitted before or after the tool's JSON payload.
- `Get-InstalledApplications -Scope AllUsers` now honors `-WhatIf` for offline
  user hive load/unload operations, checks `REG LOAD`/`REG UNLOAD` exit codes,
  and attempts unload cleanup even when registry reads fail.

## [0.2.1] - 2026-08-14

### Security
- Validate VS Code CLI wrapper arguments before forwarding names, IDs, and path
  values to the `code` shim, and pass open paths after an option separator.

## [0.2.0] - 2026-08-12

### Added
- `Format-Duration` — format a `TimeSpan` as a compact duration string that
  scales with length (`H:MM:SS.mmm`, `M:SS.mmm`, or `<seconds> seconds`), with no
  trailing label so it can be embedded in a sentence (e.g. a prompt's command-time
  line).

## [0.1.0] - 2026-08-05

### Added
- Initial `Shmuelie.Utilities`: general developer utilities for PowerShell, .NET
  tools, Python packages, VS Code, Windows Terminal, Windows services, installed
  applications, and WPR tracing.
