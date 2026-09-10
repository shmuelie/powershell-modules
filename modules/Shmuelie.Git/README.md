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
| `Get-GitTag` | Inspect local annotated/lightweight tags as typed objects, with case-sensitive exact/wildcard `-Name` filtering and standard repository `-Path` input; never fetches |
| `Set-Branch` | Switch an existing working tree to a local branch; `-CreateNew` creates at HEAD, `-Track` creates from a remote-tracking branch, and `-Force` explicitly discards local changes; supports `-Path`, `-WhatIf` and `-Confirm` |
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
Get-GitTag -Name 'v1.*', 'stable' -Path ../project
Set-Branch -Branch feature/new -CreateNew -Path ../project
Set-Branch -Branch origin/feature/topic -Track
Set-Branch -Branch main -Force -WhatIf
```

`Get-GitTag` returns `GitTag` objects with `Name`, `Reference`, `ObjectId`,
`ObjectType`, `IsAnnotated`, `TargetObjectId`, `TargetObjectType`, `TargetCommit`,
`Subject`, `Annotation`, `TaggerDate`, `CreatorDate`, and `RepositoryPath`.
The object fields describe the ref itself; the target fields fully dereference
annotated tags, including tags of tags. `TargetCommit` is null for blob/tree
targets. `Annotation` preserves Git's UTF-8-decoded `contents` field
(including whitespace and signatures), or is null for lightweight tags.
`Subject` is the tag subject or, for lightweight commit tags, the commit subject.
Dates are nullable `DateTimeOffset` values that retain their recorded offsets;
the creator date of a lightweight commit tag is the commit's committer date,
not the tag's creation time. Git does not record creation times for lightweight
tags. `RepositoryPath` is the resolved input directory. Bare repositories are
supported; no tags or no name matches produces no output.

`Set-Branch` requires a literal `-Branch` (`-BranchName` is also accepted).
`-Path` defaults to the current directory and also accepts `-RepositoryPath`,
`-RepoPath`, pipeline paths, and objects with those path properties. The caller's
location is unchanged. Without a creation flag, the branch must already exist
locally; Git's implicit remote-branch guessing is disabled.
`-CreateNew` creates at HEAD without an upstream and never resets an existing
branch, even with `-Force`. `-Track` instead takes a remote-tracking name such as
`origin/feature/topic`, creates `feature/topic`, and sets its upstream. These two
creation modes cannot be combined. Neither mode fetches or updates a remote.
`-Force` can discard staged/unstaged changes and obstructing untracked files;
it does not bypass `-WhatIf`, `-Confirm`, or Git's protection for branches checked
out in another worktree. Git failures are PowerShell errors (use
`-ErrorAction Stop` to terminate); success produces no pipeline output.

`Update-Worktrees` skips behind worktrees that have an in-progress git
operation, returning `Status = 'InProgress'` with the existing operation string
(for example `MERGING` or `REBASE-i 1/3`) instead of stashing or fast-forwarding
them.

## Requirements

- PowerShell 7.4 or later.
- `git` on `PATH`.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).
