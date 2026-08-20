function Invoke-GitWorktreeMaintenance {
    <#
    .SYNOPSIS
    Run a git worktree maintenance command and capture its output.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $output = & git @Arguments 2>&1
    $exitCode = $LASTEXITCODE

    [PSCustomObject]@{
        PSTypeName = 'GitWorktreeCommandResult'
        ExitCode   = $exitCode
        Messages   = [string[]]($output | ForEach-Object { $_.ToString() })
    }
}

function Remove-StaleWorktree {
    <#
    .SYNOPSIS
    Prune stale git worktree administrative entries.
    .DESCRIPTION
    Runs `git worktree prune --verbose` for the current repository to remove
    stale administrative entries left behind after worktree directories were
    deleted manually. Use -DryRun to report what would be pruned without making
    changes. When -WhatIf is used, the command runs git's dry-run mode so git can
    report the stale entries while preserving the repository.
    .PARAMETER DryRun
    Run `git worktree prune --dry-run --verbose` and leave stale entries in place.
    .PARAMETER Expire
    Optional value passed through to git worktree prune's --expire option.
    .EXAMPLE
    Remove-StaleWorktree
    Removes stale worktree metadata for deleted worktree directories.
    .EXAMPLE
    Remove-StaleWorktree -DryRun
    Shows the stale worktree metadata git would remove without changing it.
    .EXAMPLE
    Remove-StaleWorktree -Expire now
    Prunes stale worktree metadata using git's `--expire now` option.
    #>
    [OutputType('WorktreeMaintenanceResult')]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [switch]$DryRun,

        [string]$Expire
    )

    $repository = git rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $repository) {
        Write-Error 'Not in a git repository.'
        return
    }

    $effectiveDryRun = $DryRun.IsPresent
    if (-not $effectiveDryRun) {
        if (-not $PSCmdlet.ShouldProcess($repository, 'Prune stale worktree administrative entries')) {
            if (-not $WhatIfPreference) {
                return
            }
            $effectiveDryRun = $true
        }
    }

    $arguments = @('worktree', 'prune', '--verbose')
    if ($effectiveDryRun) {
        $arguments += '--dry-run'
    }
    if ($Expire) {
        $arguments += @('--expire', $Expire)
    }

    $gitResult = Invoke-GitWorktreeMaintenance -Arguments $arguments
    if ($gitResult.ExitCode -ne 0) {
        $message = if ($gitResult.Messages) { $gitResult.Messages -join [Environment]::NewLine } else { 'No output.' }
        Write-Error "git worktree prune failed (exit $($gitResult.ExitCode)): $message"
        return
    }

    [PSCustomObject]@{
        PSTypeName = 'WorktreeMaintenanceResult'
        Command    = 'prune'
        Repository = $repository
        Paths      = @()
        DryRun     = $effectiveDryRun
        Expire     = $Expire
        ExitCode   = $gitResult.ExitCode
        Messages   = $gitResult.Messages
    }
}

function Repair-Worktree {
    <#
    .SYNOPSIS
    Repair git worktree links after a repository or worktree move.
    .DESCRIPTION
    Runs `git worktree repair` for the current repository. Pass one or more
    -Path values to forward them to git as worktree paths to repair, matching
    git's `git worktree repair <paths...>` form.
    .PARAMETER Path
    Optional worktree path values to pass to `git worktree repair`.
    .EXAMPLE
    Repair-Worktree
    Repairs worktree links for the current repository.
    .EXAMPLE
    Repair-Worktree -Path ..\moved-worktree
    Repairs the links for a moved worktree directory.
    #>
    [OutputType('WorktreeMaintenanceResult')]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string[]]$Path
    )

    begin {
        $paths = [System.Collections.Generic.List[string]]::new()
    }

    process {
        foreach ($item in $Path) {
            if ($item) {
                $paths.Add($item)
            }
        }
    }

    end {
        $repository = git rev-parse --show-toplevel 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $repository) {
            Write-Error 'Not in a git repository.'
            return
        }

        $target = if ($paths.Count -gt 0) { $paths -join ', ' } else { $repository }
        if (-not $PSCmdlet.ShouldProcess($target, 'Repair git worktree links')) {
            return
        }

        $arguments = @('worktree', 'repair')
        $arguments += $paths.ToArray()

        $gitResult = Invoke-GitWorktreeMaintenance -Arguments $arguments
        if ($gitResult.ExitCode -ne 0) {
            $message = if ($gitResult.Messages) { $gitResult.Messages -join [Environment]::NewLine } else { 'No output.' }
            Write-Error "git worktree repair failed (exit $($gitResult.ExitCode)): $message"
            return
        }

        [PSCustomObject]@{
            PSTypeName = 'WorktreeMaintenanceResult'
            Command    = 'repair'
            Repository = $repository
            Paths      = [string[]]$paths.ToArray()
            DryRun     = $false
            Expire     = $null
            ExitCode   = $gitResult.ExitCode
            Messages   = $gitResult.Messages
        }
    }
}
