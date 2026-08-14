# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/).
Versions change only when a release is cut; unreleased work stays under
`[Unreleased]`.

## [Unreleased]

### Security
- Harden `Update-AdoNpmToken` temporary `.npmrc` handling on Windows with
  owner-only ACLs and best-effort overwrite before deletion.

## [0.1.0] - 2026-08-05

### Added
- Initial `Shmuelie.Node`: Node.js and nvm-windows version management, npm
  package helpers, and `Update-AdoNpmToken` for an explicit Azure DevOps feed.
