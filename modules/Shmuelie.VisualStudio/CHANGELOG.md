# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/).
Versions change only when a release is cut; unreleased work stays under
`[Unreleased]`.

## [Unreleased]

## [0.3.0] - 2026-10-20

### Added
- `Set-VS2017`, `Set-VS2019`, `Set-VS2022`, and `Set-VS2026` initialize the
  current session using Visual Studio's own `VsDevCmd.bat`, without PSVSEnv.
  They retain x86 defaults, accept architecture parameter aliases, support
  `-WhatIf`/`-Confirm`, reuse exact matches, and reject conflicting toolsets.

### Changed
- `Get-InstalledVsVersion` discovers complete, launchable release installations
  with initialization tooling, including Build Tools, without checking for
  provider commands. Preview installations are excluded; discovery failures
  are reported instead of silently returning no versions.
- `Start-DevShell` initializes the exact selected toolset after normal profiles
  run, reuses matching profile initialization, and rejects conflicts. It retains
  amd64 defaults and inline/wait behavior, preserves the caller's directory,
  isolates inherited toolset variables, and requires no custom profile code.
  Profile migration examples document the existing `VSDEV_*` handoff.

## [0.2.0] - 2026-09-10

### Added
- `Resolve-MSBuild` resolves the newest compatible Visual Studio MSBuild.exe,
  including standalone Build Tools, with optional year/version and executable
  architecture filters, typed installation metadata, and a path-only option.
  Discovery is Windows-only and does not launch MSBuild or change the environment.

## [0.1.1] - 2026-08-27

### Fixed
- `Start-DevShell` once again supports `-WhatIf` and `-Confirm`, and does not
  start a nested PowerShell process when `ShouldProcess` declines the launch.

## [0.1.0] - 2026-08-25

### Added
- Initial `Shmuelie.VisualStudio` module with `Get-InstalledVsVersion` for
  discoverable Visual Studio years and `Start-DevShell` for launching a nested
  PowerShell developer shell.
