# Shmuelie.Git

Git repository and worktree helpers with tab completion and a bundled PSReadLine worktree predictor.

```powershell
Install-PSResource Shmuelie.Git
Import-Module Shmuelie.Git
```

Key commands include `New-Repository`, `Sync-GitRemote`, `Get-Worktrees`,
`New-Worktree`, `Update-Worktrees`, and `Get-GitStatusSummary`.

The module ships `WorktreePredictor.dll` and refreshes it automatically during
PowerShell idle events. Call `Update-WorktreePrediction` from a custom prompt when
an immediate refresh is preferred.

Aliases: `cw`, `lw`, `mw`, and `rw`.
