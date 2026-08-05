# Changelog

This repository contains independently versioned modules; detailed changes live
in each module's `CHANGELOG.md`. Versions change only when a release is cut, so
between releases this file tracks catalog-level changes under `[Unreleased]`.

## [Unreleased]

## [0.1.0] - 2026-08-05

### Added
- Initial `Shmuelie.Git`, `Shmuelie.Copilot`, `Shmuelie.Node`, and
  `Shmuelie.Utilities` modules, all published at 0.1.0.
- Independent build, validation, publishing, and documentation infrastructure,
  including a public-content scan, per-module `CHANGELOG.md` and version checks,
  and a Markdown documentation site with a Jekyll build.

### Notes
- Public modules export no command aliases (they are added downstream by a
  profile or overlay); the build enforces this.
- The publish workflow now runs the module validation (`Test-Modules.ps1`)
  before publishing, so the publish path is gated by the same checks as CI.
