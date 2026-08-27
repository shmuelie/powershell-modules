@{
    RootModule        = 'Shmuelie.Git.psm1'
    ModuleVersion = '0.8.0'
    GUID              = 'c94a90e6-22f7-44b9-9db0-fdf51f245693'
    Author            = 'Shmueli Englard'
    CompanyName       = 'Shmuelie'
    Copyright         = '(c) Shmueli Englard. All rights reserved.'
    Description       = 'Git repository, worktree, completion, status, and PSReadLine prediction helpers.'
    PowerShellVersion = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport = @(
        'Sync-GitRemote', 'Get-GitStatusSummary', 'Format-GitStatusSegment', 'Get-Worktrees',
        'Get-CurrentWorktree', 'Get-RepositoryName', 'Get-RootWorktree',
        'Get-WorktreePath', 'Add-Worktree', 'New-Worktree', 'Remove-Worktree',
        'Move-Worktree', 'Set-Worktree', 'Remove-StaleWorktree', 'Repair-Worktree',
        'Lock-Worktree', 'Unlock-Worktree', 'Update-Worktrees', 'Update-AllWorktrees',
        'Find-StaleBranch', 'New-Repository',
        'Repair-RepositoryLayout', 'Update-WorktreePrediction'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    FormatsToProcess  = @('GitHelpers.format.ps1xml')
    PrivateData = @{
        PSData = @{
            Tags         = @('Git', 'Worktree', 'PSReadLine', 'Predictor', 'DeveloperTools')
            LicenseUri   = 'https://github.com/shmuelie/powershell-modules/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/shmuelie/powershell-modules'
        }
    }
}
