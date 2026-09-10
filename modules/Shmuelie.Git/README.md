# Shmuelie.Git

Git repository, worktree, status, completion, and PSReadLine prediction helpers.

**Version:** 0.9.0

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
| `Set-Config` | Set one literal git configuration value with `-Location local` (default), `global` or `system`; supports `-Path`, `-WhatIf` and `-Confirm` |
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
| `Save-GitStash` | Save tracked changes with `git stash push`; opt into `-KeepIndex`, `-IncludeUntracked` or `-All`, and a literal `-Message`; supports pipeline repository paths and `-WhatIf`/`-Confirm` |
| `Set-Branch` | Switch an existing working tree to a local branch; `-CreateNew` creates at HEAD, `-Track` creates from a remote-tracking branch, and `-Force` explicitly discards local changes; supports `-Path`, `-WhatIf` and `-Confirm` |
| `Restore-GitStash` | Pop the newest stash or an exact `-Stash 'stash@{n}'` entry with native conflict preservation; supports repository `-Path`, `-WhatIf` and `-Confirm` |
| `Restore-Items` | Restore explicit literal `-Files` from the index (unstaged changes only); `-IncludeIndex` restores index and working tree from HEAD, `-Source` overrides the source; high-impact `-WhatIf`/`-Confirm` protection |
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
$stash = Save-GitStash -Path ../project -KeepIndex -Message 'Pause work'
Set-Config -Path ../project -Property user.name -Value 'Example User'
Set-Config core.editor 'code --wait' -Location global -WhatIf
Remove-Branch -Name feature/finished -Path ../project -WhatIf
Remove-Branch -Name feature/finished -Remote -RemoteName upstream
Set-Branch -Branch feature/new -CreateNew -Path ../project
Set-Branch -Branch origin/feature/topic -Track
Set-Branch -Branch main -Force -WhatIf
Restore-GitStash -Path ../project -WhatIf
Restore-GitStash -Path ../project -Stash 'stash@{1}'
Restore-Items -Files 'src/main.ps1', 'notes with spaces.txt' -WhatIf
Restore-Items 'src/main.ps1' -IncludeIndex -Confirm:$false
Restore-Items -Files 'src' -Source HEAD~1 -Path ../project
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

`Save-GitStash` saves staged and unstaged tracked changes, then resets them to
HEAD. `-KeepIndex` leaves staged changes in the index and working tree, but still
includes them in the stash. Untracked and ignored files stay in place by default:
`-IncludeUntracked` also saves/removes untracked files; `-All` also saves/removes
ignored files. Combining `-All` and `-IncludeUntracked` is an error because `-All`
already includes untracked files. Git's normal submodule and nested-repository
protections apply; the command does not recurse or perform extra cleanup.

`-Message` passes non-whitespace text as one literal argument, including quotes
and shell metacharacters. Null, empty and whitespace-only messages select Git's
default message; other messages are not trimmed before Git receives them.
Git controls stored message/subject formatting.

`-Path` (aliases `-RepositoryPath` and `-RepoPath`) accepts literal directories,
pipeline strings and objects with those properties. It defaults to the current
location, targets the entire working tree even from a subdirectory, and does
not change the caller's location or `$LASTEXITCODE`. Bare repositories are rejected.

A successful push that changes `refs/stash` returns one **`GitStash`** object:

| Property | Meaning |
|---|---|
| `ObjectId` | Full stash commit ID, stable across later stash pushes and stack renumbering |
| `RepositoryPath` | Resolved input directory identifying the repository/worktree, not necessarily its root |
| `Subject` | Git's `contents:subject` for the saved stash commit |

Keep `ObjectId` and `RepositoryPath` together for later restoration; do not
replace the ID with a moving `stash@{N}` selector. These fields do not keep a
dropped/cleared stash alive indefinitely. Nothing to save, `-WhatIf` and declined
confirmation produce no result; failures surface as errors. Git's informational
output is available with `-Verbose`, and successful Git warnings are forwarded
to the warning stream. No stash is automatically applied, popped or removed.
Avoid concurrent stash operations in the same repository, including linked
worktrees: Git locks updates, but reading the before/after identity is not atomic
with another process's stash changes.

`Set-Config` writes one key and produces no output. Property and value are
literal arguments, including quotes, whitespace, special characters and empty
or leading-dash values; git validates key syntax. An existing single value is
replaced, while multiple existing values or write errors are reported by git
rather than silently replacing all values. Other keys remain unchanged.
The literal `-Path` defaults to the current directory and has `-RepositoryPath`,
`-RepoPath` and legacy `-Repository` aliases; paths or path-bearing objects can
also be piped in. Local scope requires a working tree or bare repository.
Global/system scope can run outside a repository, but an explicit path must
still be an existing FileSystem directory. Git selects the scope's file using
its normal environment and configuration rules; system scope may need elevated
permissions. Each pipeline item is independently gated by `-WhatIf`/`-Confirm`;
previewing or declining a change never writes configuration.

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

`Restore-GitStash` runs native `git stash pop`, applying `stash@{0}` by default
and removing the selected entry on success. `-Stash` accepts only an exact
`stash@{n}` selector with a canonical nonnegative 32-bit index, not bare numbers,
commit object IDs, revision expressions or wildcards. `-Path` defaults to the
current directory, accepts the `-RepositoryPath` / `-RepoPath` aliases, pipeline paths, or objects with those
path properties, and never changes location. Explicit empty paths are rejected.
Pipeline input routes repositories only: an `ObjectId` property does **not**
select a stash. Objects carrying `ObjectId` (including `Save-GitStash` results)
require an explicit `-Stash` selector; otherwise the command reports an error
without popping anything. It does not translate object IDs into reflog positions.

Git retains the stash if applying it fails or conflicts. Conflicts can leave
partially restored files and an unmerged index; the command surfaces the native
failure and does not resolve conflicts, force overwrites, or retry with separate
apply/drop commands. It uses default pop behavior (no `--index` to reinstate
staging). Success produces no pipeline output; errors retain Git's exit code,
stdout and stderr in `TargetObject`, and `-ErrorAction Stop` terminates.
`-WhatIf` or declining `-Confirm` prevents the entire pop, including stash removal.
Selectors are mutable positions evaluated by Git, not pinned identities.
Coordinate stash writers, including other worktrees, while confirming/running a
pop: this wrapper does not add concurrency protection to native Git semantics.

`Restore-Items` requires an explicit file/directory array (`-Files`, or position
0). Its `-Path` is only the repository directory, defaults to the current
directory, and has `RepositoryPath`/`RepoPath` aliases. Relative file paths are
relative to that directory; absolute paths must be inside the working tree.
The caller's location is unchanged, and bare repositories are not supported.

By default, only the working tree is restored **from the index**, so unstaged
changes are discarded but staged changes are preserved. `-IncludeIndex`
explicitly restores **both index and working tree from HEAD**. `-Source`
overrides either default with an existing local commit, tag, revision expression
(such as `HEAD~1`), or tree ID; without `-IncludeIndex`, even an explicit source
leaves the index unchanged. Invalid sources fail rather than falling back to
HEAD, and missing objects are not fetched.

File arguments are literal: wildcards, brackets and Git pathspec magic are not
expanded. Quote PowerShell metacharacters and pass each path as an array element.
A directory includes its tracked descendants recursively; `'.'` explicitly
selects the entire subtree at `-Path`, not necessarily the repository root.
Selected tracked paths absent from the source can be deleted, and local content
at selected paths can be overwritten. Untracked-only paths absent from the source
are not cleaned, and submodule working trees are not restored.
Selected unmerged index entries fail even with `-IncludeIndex` or `-Source`;
resolve conflicts explicitly instead. There is no legacy `-Force` switch.
`-WhatIf` and declined confirmation perform only read-only validation; use
`-Confirm:$false` for unattended restores. Success produces no pipeline output.
Failures are PowerShell errors (`-ErrorAction Stop` terminates); a failed
multi-path restore can leave partial changes and is not automatically rolled back.

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
