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
| `Update-Worktrees` | Fast-forward every worktree for the current or `-Path` repository from upstream (`-ChangedOnly` emits only actionable results; forwards the `Sync-GitRemote` GitHub-account options to the fetch) |
| `Update-AllWorktrees` | Discover repositories under `$env:SOURCE_REPOS` or a supplied `-Path` root and update each repository in parallel (`-ChangedOnly` emits compact actionable worktree rows) |
| `Find-StaleBranch` | Find local branches in the current or `-Path` repository whose upstream branch is gone (`-IncludeNeverPushed` also includes local-only branches) |
| `Remove-Branch` | Delete an exact local branch (`-Force` permits unmerged deletion) or a remote branch with `-Remote -RemoteName origin`; high-impact confirmation and `-WhatIf` protect every deletion |
| `Get-GitStatusSummary` | Parse `git status` for the current or `-Path` repository into a typed object (branch, ahead/behind, conflicts, stash, operation) |
| `Get-GitTag` | Inspect local annotated/lightweight tags as typed objects, with case-sensitive exact/wildcard `-Name` filtering and standard repository `-Path` input; never fetches |
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
Update-Worktrees -ChangedOnly
Update-AllWorktrees -Organization shmuelie,microsoft -Exclude 'archive/*'
Update-AllWorktrees -Organization shmuelie -ChangedOnly
Find-StaleBranch | Remove-Worktree
Get-GitStatusSummary
Get-Branch -Path ../project -Local
Get-GitTag -Name 'v1.*', 'stable' -Path ../project
Remove-Branch -Name feature/finished -Path ../project -WhatIf
Remove-Branch -Name feature/finished -Remote -RemoteName upstream
```

`Remove-Branch` accepts an exact branch name or `refs/heads/<name>`, not wildcard
patterns, revision expressions or remote-tracking refs. It uses Git's safe local
deletion (`branch -d`), which requires the branch to be merged into its upstream,
or into HEAD when no upstream is configured. Local-only `-Force` permits unmerged
deletion but never bypasses confirmation or Git's checked-out-worktree protection.
Use `-Confirm:$false` explicitly for unattended deletion.

With `-Remote`, only that branch is deleted from the selected configured remote
(default `origin`), using its push URLs. No remote is inferred from the branch's
upstream or name, and local branches are left intact. The command disables mirror
pushes and automatic tag following, never force-pushes, and reports native failures
as PowerShell errors without success output. `-WhatIf` and declined confirmation
never push. Git may accept an already absent remote branch as a no-op.
`-Path` is literal, defaults to the current directory, supports bare
repositories, and has `RepositoryPath`/`RepoPath` aliases. Pipeline strings bind to
`Name`; objects can supply both branch and repository path properties.

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

`Update-Worktrees` skips behind worktrees that have an in-progress git
operation, returning `Status = 'InProgress'` with the existing operation string
(for example `MERGING` or `REBASE-i 1/3`) instead of stashing or fast-forwarding
them.

`Update-Worktrees -ChangedOnly` returns only `WorktreeUpdateResult` objects with
status `Updated`, `Removed`, `Failed`, or `StashFailed`, matching the actionable
statuses used by `Update-AllWorktrees -ChangedOnly`. It filters output only:
fetching, update eligibility, and worktree actions are unchanged. Without the
switch (or with `-ChangedOnly:$false`), every result is returned as before.
Warnings and errors remain visible even when there is no result object.
`-WhatIf` still displays the standard fetch and fast-forward previews without
performing either operation or reporting a preview as a completed update.

## Requirements

- PowerShell 7.4 or later.
- `git` on `PATH`.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).
