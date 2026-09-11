# Changelog

All notable changes to this module are documented here. Pending changes live
under [Unreleased]; versions change only when a release is cut.

## [Unreleased]

### Added
- Windows-only AppInstaller provider using optional compiled Shmuelie.Windows
  cmdlets, lazy capability discovery, per-registration previews/confirmation,
  and explicit update-check completion evidence. Results describe requests,
  not installed-version changes; absent evidence and original errors fail.

## [0.2.0] - 2026-09-10

### Added
- VSCode provider using the optional Utilities extension helpers and native CLI:
  default and configured named profiles, per-profile bulk results and observed
  extension inventories, read-only previews, and explicit native failures.
- Optional Uv provider for outdated top-level system Python packages and
  individually approved installed-tool upgrades, with scope selection,
  lazy Utilities commands, distinct package/tool targets, observed versions,
  strict tool-list parsing, and explicit dependency skips and failures.
- PSResourceGet adapter for configured module roots, name/exclusion filters, and
  optional repository overrides, reusing Utilities' canonical discovery,
  provenance, prerelease, and update behavior. Read-only previews avoid network
  lookups; per-module results reflect observed installed versions and preserve
  warning/error behavior and aggregate confirmation/fail-fast boundaries.
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
