# Shmuelie.Git

Git repository, worktree, status, completion, and PSReadLine prediction helpers.

**Version:** 0.1.0 · [Changelog](CHANGELOG.md) · Part of [`shmuelie/powershell-modules`](../../README.md)

## Install

```powershell
Install-PSResource Shmuelie.Git
Import-Module Shmuelie.Git
```

## Commands

| Command | Purpose |
|---|---|
| `New-Repository` | Clone into a standard `<root>/<org>/<repo>/<branch>` layout |
| `Sync-GitRemote` | Fetch all remotes with pruning |
| `Get-Worktrees` | List worktrees for the current repository |
| `New-Worktree` | Create a branch and check it out to a worktree |
| `Add-Worktree` | Check out an existing branch to a worktree |
| `Remove-Worktree` | Remove a worktree (optionally its branch) |
| `Set-Worktree` | Switch to a worktree by branch name |
| `Update-Worktrees` | Fast-forward all worktrees from upstream |
| `Find-StaleBranch` | Find local branches whose upstream is gone |
| `Repair-RepositoryLayout` | Conform clones to the standard layout |
| `Get-GitStatusSummary` | Parse `git status` into a typed object |
| `Update-WorktreePrediction` | Refresh the bundled predictor for the current directory |

Aliases: `cw` (Set-Worktree), `lw` (Get-Worktrees), `mw` (New-Worktree),
`rw` (Remove-Worktree).

## Worktree predictor

The module ships a compiled PSReadLine command predictor
(`WorktreePredictor.dll`) that suggests branch names for worktree commands. It
registers on import and refreshes during PowerShell idle events. Enable plugin
prediction to use it:

```powershell
Set-PSReadLineOption -PredictionSource HistoryAndPlugin -PredictionViewStyle ListView
```

## Examples

```powershell
New-Repository https://github.com/owner/repo
New-Worktree -WorkName my-feature -SetLocation
Update-Worktrees | Where-Object Status -ne Current
Find-StaleBranch | Remove-Worktree
```

## Requirements

- PowerShell 7.4 or later
- `git` on `PATH`
