foreach ($script in Get-ChildItem $PSScriptRoot -Filter '*.ps1' -File | Sort-Object Name) {
    . $script.FullName
}

Register-ArgumentCompleter -CommandName Set-Worktree, Remove-Worktree, Move-Worktree -ParameterName BranchName -ScriptBlock {
    param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
    Get-WorktreeBranchCompletion -WordToComplete $wordToComplete -CommandAst $commandAst -BoundParameters $fakeBoundParameters
}

Register-ArgumentCompleter -CommandName Add-Worktree -ParameterName BranchName -ScriptBlock {
    param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
    Get-WorktreeBranchCompletion -WordToComplete $wordToComplete -CommandAst $commandAst -BoundParameters $fakeBoundParameters -AvailableBranch
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

$script:predictorModule = $null
$script:predictorJob = $null
$predictorPath = Join-Path $PSScriptRoot 'bin' 'WorktreePredictor.dll'
if (Test-Path $predictorPath) {
    $predictorRegistered = (Get-PSSubsystem -Kind CommandPredictor).Implementations.Name -contains 'Worktree'
    if (-not $predictorRegistered) {
        $script:predictorModule = Import-Module $predictorPath -Force -PassThru -ErrorAction Stop
    }
}

if ($null -ne ('WorktreePredictor.WorktreeCommandPredictor' -as [type])) {
    Update-WorktreePrediction
    $script:predictorJob = Register-EngineEvent -SourceIdentifier PowerShell.OnIdle -Action {
        [WorktreePredictor.WorktreeCommandPredictor]::UpdateWorkingDirectory((Get-Location).Path)
    }
}

$ExecutionContext.SessionState.Module.OnRemove = {
    if ($script:predictorJob) {
        # Register-EngineEvent returns an action job, not a subscription. Match
        # the actual association; job and subscription IDs use separate counters.
        foreach ($subscriber in Get-EventSubscriber -Force) {
            if ([object]::ReferenceEquals($subscriber.Action, $script:predictorJob)) {
                Unregister-Event -SubscriptionId $subscriber.SubscriptionId -ErrorAction Ignore
            }
        }
        Remove-Job -Job $script:predictorJob -Force -ErrorAction Ignore
        $script:predictorJob = $null
    }
    if ($script:predictorModule) {
        Remove-Module $script:predictorModule -Force -ErrorAction Ignore
    }
}

Export-ModuleMember -Function @(
    'Sync-GitRemote',
    'Get-GitStatusSummary',
    'Get-GitTag',
    'Save-GitStash',
    'Remove-Branch',
    'Set-Branch',
    'Restore-GitStash',
    'Restore-Items',
    'Format-GitStatusSegment',
    'Get-Worktrees',
    'Get-Branch',
    'Set-Config',
    'Get-CurrentWorktree',
    'Get-RepositoryName',
    'Get-RootWorktree',
    'Get-WorktreePath',
    'Add-Worktree',
    'New-Worktree',
    'Remove-Worktree',
    'Move-Worktree',
    'Set-Worktree',
    'Remove-StaleWorktree',
    'Repair-Worktree',
    'Lock-Worktree',
    'Unlock-Worktree',
    'Update-Worktrees',
    'Update-AllWorktrees',
    'Find-StaleBranch',
    'New-Repository',
    'Repair-RepositoryLayout',
    'Update-WorktreePrediction'
)
