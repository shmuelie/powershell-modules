# Changelog

## [Unreleased]

## [0.3.0] - 2026-08-04

### Added
- `Start-Copilot -PassThru` returns the resolved launch plan (`Exe`, `Args`,
  `Passthrough`) without launching, so callers can reuse the built arguments and
  the session-resume decision to wrap the launch with a different engine.

## [0.2.0] - 2026-08-03

### Removed
- Removed the internal orchestration-CLI integration (its plugins, profiles,
  marketplaces, and `Start-Copilot` code path) so the module depends only on the
  public `copilot` CLI.

## [0.1.0] - 2026-08-03

### Added
- Initial private preview.
- Copilot CLI session, plugin, marketplace, and MCP helpers.
