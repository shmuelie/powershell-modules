$publicRoot = Join-Path $PSScriptRoot 'Public'
foreach ($script in Get-ChildItem $publicRoot -Filter '*.ps1' | Sort-Object Name) {
    . $script.FullName
}

Register-ArgumentCompleter -CommandName Set-Worktree, Remove-Worktree -ParameterName BranchName -ScriptBlock {
    param($commandName, $parameterName, $wordToComplete)
    Get-Worktrees |
        Select-Object -ExpandProperty Branch |
        Where-Object { $_ -like "$wordToComplete*" } |
        ForEach-Object {
            [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
        }
}

Register-ArgumentCompleter -CommandName Add-Worktree -ParameterName BranchName -ScriptBlock {
    param($commandName, $parameterName, $wordToComplete)
    $worktreeBranches = @(Get-Worktrees | Select-Object -ExpandProperty Branch)
    git branch --format='%(refname:short)' |
        Where-Object { $_ -and $_ -notin $worktreeBranches -and $_ -like "$wordToComplete*" } |
        ForEach-Object {
            [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
        }
}

function Update-WorktreePrediction {
    <#
    .SYNOPSIS
        Refresh the bundled PSReadLine worktree predictor for the current directory.
    .EXAMPLE
        Update-WorktreePrediction
    #>
    [CmdletBinding()]
    param()

    if ($null -ne ('WorktreePredictor.WorktreeCommandPredictor' -as [type])) {
        [WorktreePredictor.WorktreeCommandPredictor]::UpdateWorkingDirectory((Get-Location).Path)
    }
}

$predictorPath = Join-Path $PSScriptRoot 'bin\WorktreePredictor.dll'
if (Test-Path $predictorPath) {
    if ($null -eq (Get-Module PSReadLine)) {
        Import-Module PSReadLine -ErrorAction SilentlyContinue
    }
    $predictorRegistered = (Get-PSSubsystem -Kind CommandPredictor).Implementations.Name -contains 'Worktree'
    if (-not $predictorRegistered) {
        $script:predictorModule = Import-Module $predictorPath -Force -PassThru -ErrorAction Stop
    } else {
        # Already registered (e.g. this module re-imported in the same session):
        # capture the existing module handle so OnRemove can still clean it up.
        $script:predictorModule = Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($predictorPath))
    }
}

if ($null -ne ('WorktreePredictor.WorktreeCommandPredictor' -as [type])) {
    Update-WorktreePrediction
    $script:predictorSubscription = Register-EngineEvent -SourceIdentifier PowerShell.OnIdle -Action {
        [WorktreePredictor.WorktreeCommandPredictor]::UpdateWorkingDirectory((Get-Location).Path)
    }
}

$ExecutionContext.SessionState.Module.OnRemove = {
    if ($script:predictorSubscription -and $script:predictorSubscription.Id) {
        Unregister-Event -SubscriptionId $script:predictorSubscription.Id -ErrorAction Ignore
    }
    if ($script:predictorModule) {
        Remove-Module $script:predictorModule -Force -ErrorAction Ignore
    }
}

Export-ModuleMember -Function @(
    'Sync-GitRemote',
    'Get-GitStatusSummary',
    'Get-Worktrees',
    'Get-CurrentWorktree',
    'Get-RepositoryName',
    'Get-RootWorktree',
    'Get-WorktreePath',
    'Add-Worktree',
    'New-Worktree',
    'Remove-Worktree',
    'Set-Worktree',
    'Update-Worktrees',
    'Find-StaleBranch',
    'New-Repository',
    'Repair-RepositoryLayout',
    'Update-WorktreePrediction'
)
