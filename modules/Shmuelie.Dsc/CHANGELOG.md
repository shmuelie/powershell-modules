# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/).
Versions change only when a release is cut; unreleased work stays under
`[Unreleased]`.

## [Unreleased]

### Added
- Initial class-based DSC v3 resources: `SavePSResource` (save a module to a
  local path), `SymbolicLink` (create/verify a symbolic link), `CopilotPlugin`
  (install a GitHub Copilot CLI plugin), `CopilotMarketplace` (register a
  Copilot CLI marketplace), and `UvTool` (install a Python tool via `uv`).
