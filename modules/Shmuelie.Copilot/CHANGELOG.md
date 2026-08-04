# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/).
Versions change only when a release is cut; unreleased work stays under
`[Unreleased]`.

## [Unreleased]

### Added
- Initial `Shmuelie.Copilot`: GitHub Copilot CLI session, plugin, marketplace,
  and MCP helpers, plus the `Start-Copilot` launcher with session resume, safe
  git deny rules, full flag mapping, and terminal recovery.
- `Start-Copilot -PassThru` returns the resolved launch plan (`Exe`, `Args`,
  `Passthrough`) without launching, so other tools can reuse the built arguments
  and the session-resume decision.

### Fixed
- `Start-Copilot -Remote:$false` no longer emits `--remote`. The launcher tested
  parameter presence instead of the switch value, so explicitly forcing the flag
  off still passed `--remote`.

### Notes
- Depends only on the public `copilot` CLI.
