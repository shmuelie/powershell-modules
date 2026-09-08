# Changelog

All notable changes to this module are documented here. Pending changes live
under [Unreleased]; versions change only when a release is cut.

## [Unreleased]

## [0.1.0] - 2026-09-08

### Added
- Initial 0.1.0 orchestration foundation with `Update-AllPackages`, provider
  selection/exclusion, provider-specific option tables, lazy dependencies,
  per-target confirmation and previews, typed outcomes, and fail-fast control.
- Private provider contract and deterministic fake-provider coverage. Reserved
  providers explicitly report unimplemented integrations as skipped; actual
  package-provider adapters are follow-up work, not part of this foundation.
