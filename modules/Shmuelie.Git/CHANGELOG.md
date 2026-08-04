# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/).
Versions change only when a release is cut; unreleased work stays under
`[Unreleased]`.

## [Unreleased]

### Added
- Initial `Shmuelie.Git`: git repository, worktree, status, completion, and
  PSReadLine prediction helpers, including `New-Repository`, the worktree
  lifecycle cmdlets, `Update-Worktrees`, `Find-StaleBranch`,
  `Get-GitStatusSummary`, and a bundled worktree predictor.

### Fixed
- `Get-Worktrees` no longer stores a `$null` path for a worktree whose directory
  was deleted manually. It now keeps the git-reported path when the directory no
  longer resolves, so `Get-RootWorktree` and callers behave correctly for stale
  worktrees.
- `Find-StaleBranch` now throws a clear error when run outside a git repository
  instead of silently returning nothing (it checked no exit code and redirected
  the git error away).
- The bundled worktree predictor is cleaned up on module removal even when it was
  already registered from an earlier import; the module now captures the existing
  predictor handle so `OnRemove` can unload it.
