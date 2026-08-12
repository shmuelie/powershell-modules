# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/).
Versions change only when a release is cut; unreleased work stays under
`[Unreleased]`.

## [Unreleased]

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
