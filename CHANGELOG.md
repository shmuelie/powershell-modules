# Changelog

This repository contains independently versioned modules; detailed changes live
in each module's `CHANGELOG.md`. Versions change only when a release is cut, so
between releases this file tracks catalog-level changes under `[Unreleased]`.

## [Unreleased]

### Changed
- Document expected module import startup costs in the generated documentation
  site.
- `Build-Module.ps1` now stages optional module `Classes` folders for shared
  PowerShell class definitions.
- `Build-Module.ps1` now stages a module's `Public` folder only when it exists,
  so modules without `Public` scripts (such as DSC resource modules) build.

### Added
- New `Shmuelie.Dsc` module: class-based DSC v3 resources (`SavePSResource`,
  `SymbolicLink`, `CopilotPlugin`, `CopilotMarketplace`, `UvTool`), wired into
  the build, publish workflow, and documentation site.
- GitHub Pages documentation workflow now redeploys automatically when docs or its workflow change.
- Pester v5 unit test suite under `tests/`, a `build/Invoke-Tests.ps1` runner,
  and CI wiring (`ci.yml` plus a gate in `publish-module.yml`) so behavioral
  tests of exported functions run alongside `Test-Modules.ps1`. Coverage
  includes `Get-GitStatusSummary`, `Format-GitStatusSegment`, `Format-Duration`,
  `Get-CopilotLaunchPlan`, `Find-StaleBranch`, and the pure `Shmuelie.Utilities`
  helpers.

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
