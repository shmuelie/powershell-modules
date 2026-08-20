using module ../Classes/WorktreeSetValuesGenerator.psm1

function Resolve-WorktreeByBranchName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BranchName
    )

    $worktree = Get-Worktrees | Where-Object Branch -eq $BranchName | Select-Object -First 1
    if (-not $worktree) {
        Write-Error "No worktree found for branch '$BranchName'."
        return
    }

    $worktree
}

function Lock-Worktree {
    <#
    .SYNOPSIS
    Lock a git worktree by branch name.
    .DESCRIPTION
    Resolves the worktree for the supplied branch from `git worktree list --porcelain`
    and runs `git worktree lock` against that path. Use -Reason to record why the
    worktree should not be pruned or moved.
    .PARAMETER BranchName
    Name of the branch whose worktree should be locked.
    .PARAMETER Reason
    Optional lock reason passed to `git worktree lock --reason`.
    .EXAMPLE
    Lock-Worktree -BranchName feature/my-work -Reason 'Long-running test environment'
    Locks the worktree for feature/my-work with a reason.
    .EXAMPLE
    Get-Worktrees | Where-Object Branch -like 'user/*' | Lock-Worktree
    Locks each piped worktree by its Branch property.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [ValidateSet([WorktreeSetValuesGenerator])]
        [Alias('Branch')]
        [string]$BranchName,

        [string]$Reason
    )

    process {
        $worktree = Resolve-WorktreeByBranchName -BranchName $BranchName
        if (-not $worktree) { return }

        if ($PSCmdlet.ShouldProcess($worktree.Path, "Lock worktree for branch '$BranchName'")) {
            $output = if ([string]::IsNullOrEmpty($Reason)) {
                git worktree lock $worktree.Path 2>&1
            } else {
                git worktree lock --reason $Reason $worktree.Path 2>&1
            }
            if ($LASTEXITCODE -ne 0) {
                $message = ($output | Out-String).Trim()
                if (-not $message) {
                    $message = "git worktree lock failed for branch '$BranchName' with exit code $LASTEXITCODE."
                }
                Write-Error $message
            }
        }
    }
}

function Unlock-Worktree {
    <#
    .SYNOPSIS
    Unlock a git worktree by branch name.
    .DESCRIPTION
    Resolves the worktree for the supplied branch from `git worktree list --porcelain`
    and runs `git worktree unlock` against that path.
    .PARAMETER BranchName
    Name of the branch whose worktree should be unlocked.
    .EXAMPLE
    Unlock-Worktree -BranchName feature/my-work
    Unlocks the worktree for feature/my-work.
    .EXAMPLE
    Get-Worktrees | Where-Object Locked | Unlock-Worktree
    Unlocks each piped worktree by its Branch property.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [ValidateSet([WorktreeSetValuesGenerator])]
        [Alias('Branch')]
        [string]$BranchName
    )

    process {
        $worktree = Resolve-WorktreeByBranchName -BranchName $BranchName
        if (-not $worktree) { return }

        if ($PSCmdlet.ShouldProcess($worktree.Path, "Unlock worktree for branch '$BranchName'")) {
            $output = git worktree unlock $worktree.Path 2>&1
            if ($LASTEXITCODE -ne 0) {
                $message = ($output | Out-String).Trim()
                if (-not $message) {
                    $message = "git worktree unlock failed for branch '$BranchName' with exit code $LASTEXITCODE."
                }
                Write-Error $message
            }
        }
    }
}
