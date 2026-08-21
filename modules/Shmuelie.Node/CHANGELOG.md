# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/).
Versions change only when a release is cut; unreleased work stays under
`[Unreleased]`.

## [Unreleased]

## [0.1.3] - 2026-08-21

### Changed
- Fail fast with a clear Windows-only error when nvm-windows wrapper cmdlets are used on non-Windows platforms.

## [0.1.2] - 2026-08-20

### Added
- Add Pester coverage for `Update-AdoNpmToken` and exported nvm wrapper
  cmdlets.

### Fixed
- Preserve existing temporary file owners when hardening `Update-AdoNpmToken`
  scratch ACLs to avoid requiring elevated privileges.
- Gate `Get-NvmRoot -Path` with `SupportsShouldProcess` so `-WhatIf` and
  `-Confirm` are honored before changing the nvm root.
- Tolerate npm stdout warning lines before or after JSON when parsing
  `Get-NpmPackage` list and outdated results.

## [0.1.1] - 2026-08-14

### Security
- Harden `Update-AdoNpmToken` temporary `.npmrc` handling on Windows with
  owner-only ACLs and best-effort overwrite before deletion.

## [0.1.0] - 2026-08-05

### Added
- Initial `Shmuelie.Node`: Node.js and nvm-windows version management, npm
  package helpers, and `Update-AdoNpmToken` for an explicit Azure DevOps feed.
