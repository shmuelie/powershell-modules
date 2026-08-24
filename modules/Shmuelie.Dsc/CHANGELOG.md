# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/).
Versions change only when a release is cut; unreleased work stays under
`[Unreleased]`.

## [Unreleased]

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
