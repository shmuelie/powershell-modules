# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/).
Versions change only when a release is cut; unreleased work stays under
`[Unreleased]`.

## [Unreleased]

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
