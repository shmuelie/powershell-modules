# Changelog

All notable changes to this module are documented here. Pending changes live
under [Unreleased]; versions change only when a release is cut.

## [Unreleased]

### Added
- DotNet global-tool provider using the canonical Shmuelie.DotNet commands,
  lazy module/SDK discovery, optional wildcard Name filtering, per-tool previews
  and confirmation, observed version outcomes, and native failure reporting.
  Local manifests and SDK installation are not part of this integration.
- Npm provider for outdated global packages, using the optional Shmuelie.Node
  module, preserving scoped names, rejecting unsafe package identifiers, and
  reporting observed installed versions with per-package failure handling.
- Pip adapter using optional `Shmuelie.Utilities` commands, with outdated
  top-level discovery by default and Boolean `User`/`TopLevelOnly` options.
  Updates honor per-package confirmation, validate distribution names, preserve
  failures, and observe installed versions before reporting update outcomes.
  `User` filters discovery and observation; it does not override the updater's
  installation destination.

## [0.1.0] - 2026-09-08

### Added
- Initial 0.1.0 orchestration foundation with `Update-AllPackages`, provider
  selection/exclusion, provider-specific option tables, lazy dependencies,
  per-target confirmation and previews, typed outcomes, and fail-fast control.
- Private provider contract and deterministic fake-provider coverage. Reserved
  providers explicitly report unimplemented integrations as skipped; actual
  package-provider adapters are follow-up work, not part of this foundation.
