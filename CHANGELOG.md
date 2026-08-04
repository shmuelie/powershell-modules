# Changelog

This repository contains independently versioned modules. Detailed changes live
in each module's `CHANGELOG.md`.

## [Unreleased]

### Changed
- Removed the internal orchestration-CLI integration from `Shmuelie.Copilot`
  (now 0.2.0); the module depends only on the public `copilot` CLI.
- Simplified the root README to point at the documentation site; each module
  README now documents its own commands and features in full.
- Authored a Markdown documentation site under `docs/` with a Jekyll build.

### Added
- Public-content scan in `build/Test-Modules.ps1` covering module sources,
  documentation, and READMEs, plus docs presence, link, and version checks.
- Per-module `CHANGELOG.md` enforcement in `build/Test-Modules.ps1` (each module
  already ships its own changelog).

## [Private preview] - 2026-08-03

### Added
- Initial `Shmuelie.Git`, `Shmuelie.Copilot`, `Shmuelie.Node`, and
  `Shmuelie.Utilities` module sources.
- Independent build, validation, publishing, and documentation infrastructure.
