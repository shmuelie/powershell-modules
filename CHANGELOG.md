# Changelog

This repository contains independently versioned modules; detailed changes live
in each module's `CHANGELOG.md`. Versions change only when a release is cut, so
between releases this file tracks catalog-level changes under `[Unreleased]`.

## [Unreleased]

### Fixed
- `Build-Module.ps1` now calls `GC.Collect` + `WaitForPendingFinalizers` after
  `Remove-Module` and wraps the stage-directory deletion in a targeted retry
  (catching only IO/access-denied errors), so calling it twice for
  `Shmuelie.Git` or `Shmuelie.Windows` in the same process no longer fails with
  a locked-DLL access-denied error on the stage directory. (Fixes #154.)
- Replaced all hard-coded Windows path separators (`'bin\foo.dll'`,
  `'modules\Module'`, `"docs\$file"`, etc.) in build scripts, module loaders,
  and test files with multi-segment `Join-Path` calls, so portable modules
  build and import correctly on Linux and macOS. (Fixes #155.)

### Added
- CI job `validate-portable` on `ubuntu-latest` builds and imports the five
  portable modules (Git, Copilot, Node, Utilities, Dsc) and runs the new
  `Build.Tests.ps1` repeat-build suite, providing cross-platform separator and
  GC-release coverage.
- `tests/Build.Tests.ps1`: Pester tests validating that `Build-Module.ps1` can
  be called twice consecutively in the same process for `Shmuelie.Git` (and
  `Shmuelie.Windows` on Windows) without DLL-lock failures.

### Changed
- `Build-Module.ps1` now compiles the `Shmuelie.Windows` binary cmdlet project
  (`Shmuelie.Windows.Cmdlets.csproj`) into the staged `bin` folder, mirroring the
  existing `Shmuelie.Git` predictor build. This establishes the reusable
  C#-binary-cmdlet build/load/test pattern for the module.
- Document expected module import startup costs in the generated documentation
  site.
- `Build-Module.ps1` now stages optional module `Classes` folders for shared
  PowerShell class definitions.
- Flattened module script layout by moving `Public/*.ps1` files into each module
  root. Module loaders and `Build-Module.ps1` now discover/stage root-level
  scripts; the build still fails fast when a module declares functions but has
  no script files.

### Added
- New `Shmuelie.VisualStudio` module: Visual Studio version discovery and nested
  developer shell launch helpers, wired into build, publish workflow, tests, and
  documentation.
- New `Shmuelie.Windows` module for six Windows-only cmdlets moved out of `Shmuelie.Utilities`; `Shmuelie.Utilities` is bumped to 0.3.0 for the breaking catalog change.
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
- New `Shmuelie.Windows` module for six Windows-only cmdlets moved out of `Shmuelie.Utilities`; `Shmuelie.Utilities` is bumped to 0.3.0 for the breaking catalog change.
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
