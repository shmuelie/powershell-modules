# Shmuelie.Git

Git repository, worktree, status, completion, and PSReadLine prediction helpers.

**Version:** 0.1.0

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
| `Sync-GitRemote` | Fetch all remotes with pruning, returning typed results |
| `Get-Worktrees` | List worktrees for the current repository |
| `Get-CurrentWorktree` / `Get-RootWorktree` | Resolve the worktree for the current directory or the repository root |
| `Get-WorktreePath` | Compute the path a branch's worktree would use |
| `New-Worktree` | Create a branch and check it out to a worktree |
| `Add-Worktree` | Check out an existing branch to a worktree |
| `Remove-Worktree` | Remove a worktree (optionally deleting its branch) |
| `Set-Worktree` | Switch to a worktree by branch name |
| `Update-Worktrees` | Fast-forward every worktree from upstream |
| `Find-StaleBranch` | Find local branches whose upstream branch is gone |
| `Get-GitStatusSummary` | Parse `git status` into a typed object (branch, ahead/behind, conflicts, stash, operation) |
| `Update-WorktreePrediction` | Refresh the bundled predictor for the current directory |

Aliases: `cw` (Set-Worktree), `lw` (Get-Worktrees), `mw` (New-Worktree),
`rw` (Remove-Worktree).

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
Update-Worktrees | Where-Object Status -ne Current
Find-StaleBranch | Remove-Worktree
Get-GitStatusSummary
```

## Requirements

- PowerShell 7.4 or later.
- `git` on `PATH`.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).
