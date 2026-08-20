# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/).
Versions change only when a release is cut; unreleased work stays under
`[Unreleased]`.

## [Unreleased]

### Added
- `Lock-Worktree` and `Unlock-Worktree` wrap `git worktree lock` and
  `git worktree unlock` by branch name, with optional lock reasons.
- `Get-Worktrees` now surfaces the remaining `git worktree list --porcelain`
  state on each object: `Bare`, `Detached`, `Locked`/`LockReason`, and
  `Prunable`/`PrunableReason`. Existing `Path`/`Commit`/`Branch` behavior is
  unchanged.

## [0.4.0] - 2026-08-20

### Added
- Added direct test coverage for the core worktree cmdlets.
- Added test coverage for `Update-Worktrees` current, no-upstream, and clean
  fast-forward result statuses.

### Fixed
- `Find-StaleBranch` no longer reports never-pushed local branches by default;
  use `-IncludeNeverPushed` to include local-only branches intentionally.

## [0.3.0] - 2026-08-14

### Added
- `Sync-GitRemote` is now GitHub-account-aware. When more than one account is
  signed in to the `gh` CLI for a remote's host — github.com or a GitHub
  Enterprise host — the fetch for that remote runs with the account that can
  access it. A per-account token is acquired with `gh auth token` and injected
  into the git child process environment only, so the globally-active `gh`
  account is never changed and concurrent fetches never cross-contaminate
  credentials. New `-GitHubAccountMap` (host/owner → account) and
  `-GitHubAccountResolver` (scriptblock) parameters choose the account, with a
  reactive fallback that tries the active account and retries the remaining
  signed-in accounts on an auth failure (caching the winner for the session).
  `-NoGitHubAccountResolve` opts out. It is a graceful no-op — identical to
  plain `git fetch` — when `gh` is absent, only one account is signed in for the
  host, the host is not one `gh` manages, or `gh auth token` fails.
- `Update-Worktrees` gains matching `-GitHubAccountMap`,
  `-GitHubAccountResolver`, and `-NoGitHubAccountResolve` parameters, forwarded
  to `Sync-GitRemote`.

### Fixed
- `Get-GitStatusSummary -Path` now fails fast when the target path cannot be
  entered and only calls `Pop-Location` after a successful `Push-Location`, so a
  bad path cannot corrupt the caller's location stack.
- `Update-Worktrees` now serializes dirty worktrees that need `git stash`
  push/pop while still fast-forwarding clean worktrees in parallel, preventing
  concurrent workers from popping each other's shared repository stash.
- `Repair-RepositoryLayout` now uses the platform path separator when converting
  nested git branch names into directories and when checking whether the current
  directory is inside a repository or worktree.
- `Add-Worktree` now requires a non-empty `-BranchName`, failing during parameter
  binding instead of attempting to create a worktree with an empty branch name.
- `Format-GitStatusSegment` now renders diverged upstream relations in the same
  down-then-up, space-separated order as `Get-GitStatusSummary.StatusString`
  (for example, `↓4 ↑1`).
- The bundled worktree predictor now drains `git` stdout and stderr concurrently
  and kills timed-out `git` processes, preventing stderr pipe deadlocks from
  permanently disabling cache refreshes.
- `Sync-GitRemote` now returns `Updated` results for fast-forwarded refs.
- Git tab completion now offers the destination path for renamed/copied files
  and preserves non-ASCII paths in `git status --porcelain` completions.
- `Sync-GitRemote` now parses fetch output with a stable C locale so result
  classification does not depend on the caller's git localization.

## [0.2.0] - 2026-08-12

### Added
- `Format-GitStatusSegment` — render a `GitStatusSummary` (from
  `Get-GitStatusSummary`) as a colored posh-git-style prompt segment
  (`[branch|OP ↑A↓B +A ~M -D | +A ~M -D !C]`). Emits an ANSI-colored string via
  `$PSStyle` (capturable/testable), branch color reflecting upstream state.
  `-ShowChangeCounts:$false` renders only the branch, operation, and ahead/behind
  relation (for large repos where counting working-tree changes is expensive).

### Fixed
- `Get-GitStatusSummary` no longer hard-codes Windows path separators, so it works
  on Linux/macOS. Git-reported paths are only normalized to backslashes on Windows,
  and in-progress operation detection (rebase, merge, revert, cherry-pick, bisect)
  now resolves its `.git` sentinel files cross-platform instead of always returning
  `$null` for `Operation` off Windows.
- The bundled worktree predictor's background cache refresh is now thread-safe: the
  `refreshing` guard uses an atomic compare-and-exchange (instead of a non-atomic
  check-then-set that allowed overlapping refreshes) and the cache timestamp is
  published atomically, and the guard is released even if scheduling the refresh
  fails. Background refresh failures are now traced instead of silently swallowed.
- The worktree predictor's identifier is defined once and shared between
  registration and cleanup, so it can no longer leak across a module reload if the
  two copies drifted.
- `Find-StaleBranch -IncludePrStatus` now validates the branch name and the Azure
  DevOps org/project/repo before passing them to `az`, preventing command injection
  via `cmd.exe` metacharacters in those names when `az` resolves to `az.cmd`
  (CVE-2024-1874 class). Unsafe names skip the PR lookup with a warning.

## [0.1.0] - 2026-08-05

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
