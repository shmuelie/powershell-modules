# Shmuelie.Git

Git repository, worktree, status, completion, and PSReadLine prediction helpers.

**Version:** 0.8.2

## Install

```powershell
Install-PSResource Shmuelie.Git
Import-Module Shmuelie.Git
```

## Commands

| Command | Purpose |
|---|---|
| `New-Repository` | Clone a URL into a standard `<root>/<org>/<repo>/<branch>` layout (parses GitHub and Azure DevOps URLs) |
| `Repair-RepositoryLayout` | Conform existing clones and worktrees to that layout |
| `Sync-GitRemote` | Fetch all remotes for the current or `-Path` repository with pruning, returning typed results; picks the right `gh` account per host (github.com/GHE) when several are signed in |
| `Get-Worktrees` | List worktrees for the current or `-Path` repository |
| `Get-Branch` | List local and cached remote-tracking refs as `GitBranch` objects, with current branch, commit, upstream, ahead/behind counts and symbolic target (`-Local` / `-Remote` filter the results; never fetches) |
| `Get-CurrentWorktree` / `Get-RootWorktree` | Resolve the worktree for the current directory/`-Path` or the repository root |
| `Get-WorktreePath` | Compute the path a branch's worktree would use for the current or `-Path` repository |
| `New-Worktree` | Create a branch from the current or `-Path` repository and check it out to a worktree, optionally at destination `-WorktreePath` |
| `Add-Worktree` | Check out an existing branch from the current or `-Path` repository to a worktree, optionally at destination `-WorktreePath` |
| `Remove-Worktree` | Remove a worktree by branch name or path (optionally deleting its branch) |
| `Move-Worktree` | Move a linked worktree by branch name or path to a new filesystem location |
| `Set-Worktree` | Switch to a worktree by branch name or path |
| `Remove-StaleWorktree` | Prune stale worktree administrative entries for deleted worktree directories |
| `Repair-Worktree` | Repair worktree links after a repository or worktree move |
| `Lock-Worktree` / `Unlock-Worktree` | Lock or unlock a worktree by branch name |
| `Update-Worktrees` | Fast-forward every worktree for the current or `-Path` repository from upstream (forwards the `Sync-GitRemote` GitHub-account options to the fetch) |
| `Update-AllWorktrees` | Discover repositories under `$env:SOURCE_REPOS` or a supplied `-Path` root and update each repository in parallel (`-ChangedOnly` emits compact actionable worktree rows) |
| `Find-StaleBranch` | Find local branches in the current or `-Path` repository whose upstream branch is gone (`-IncludeNeverPushed` also includes local-only branches) |
| `Get-GitStatusSummary` | Parse `git status` for the current or `-Path` repository into a typed object (branch, ahead/behind, conflicts, stash, operation) |
| `Format-GitStatusSegment` | Render a `GitStatusSummary` as a colored posh-git-style prompt segment (`$PSStyle` string; `-ShowChangeCounts` toggles the change counts) |
| `Update-WorktreePrediction` | Refresh the bundled predictor for the current directory |

## Worktree predictor

The module ships a compiled PSReadLine command predictor
(`WorktreePredictor.dll`) that suggests branch names for the worktree commands.
It registers on import and refreshes during PowerShell idle events. Enable
plugin prediction to use it:

```powershell
Set-PSReadLineOption -PredictionSource HistoryAndPlugin -PredictionViewStyle ListView
```

Suggestions use substring (not prefix) matching, so a middle fragment like `wim`
surfaces `user/alex/wim-work`.

## Examples

```powershell
New-Repository https://github.com/owner/repo
New-Worktree -WorkName my-feature -SetLocation
Add-Worktree -BranchName feature/my-feature -WorktreePath ../custom-feature
Move-Worktree -BranchName feature/my-feature -DestinationPath ../moved-feature
Update-Worktrees | Where-Object Status -ne Current
Update-AllWorktrees -Organization shmuelie,microsoft -Exclude 'archive/*'
Update-AllWorktrees -Organization shmuelie -ChangedOnly
Find-StaleBranch | Remove-Worktree
Get-GitStatusSummary
Get-Branch -Path ../project -Local
```

`Get-Branch` accepts a literal `-Path` (aliases `-RepositoryPath` / `-RepoPath`),
pipeline paths, or objects with any of those properties. It also accepts bare
repositories and never changes location. By default it includes both local and
remote-tracking branches; `-Local -Remote` explicitly selects both.

Each `GitBranch` has `Branch`, `RefName`, `Current`, `Commit`, `Upstream`,
`AheadBy`, `BehindBy`, `UpstreamGone`, `SymbolicTarget`, `IsRemote`, `Subject`
and `RepositoryPath`. `Branch` omits `refs/heads/` or `refs/remotes/`, while
`RefName`, `Upstream` and `SymbolicTarget` use full ref names to avoid ambiguity.
`RepositoryPath` is the resolved input directory, including when it is a
subdirectory or linked worktree. Absent upstreams and symbolic targets are null.
Counts are 64-bit integers relative to locally available upstream history, or
null when no upstream exists; `UpstreamGone` identifies a configured but missing
upstream. A detached HEAD marks no branch current, and an unborn branch has no
ref to list. Remote symbolic refs such as `origin/HEAD` are included.
Implicit partial-clone fetches are disabled in child git processes; unavailable
promised objects surface as git errors rather than initiating network access.

`Update-Worktrees` skips behind worktrees that have an in-progress git
operation, returning `Status = 'InProgress'` with the existing operation string
(for example `MERGING` or `REBASE-i 1/3`) instead of stashing or fast-forwarding
them.

## Requirements

- PowerShell 7.4 or later.
- `git` on `PATH`.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).
