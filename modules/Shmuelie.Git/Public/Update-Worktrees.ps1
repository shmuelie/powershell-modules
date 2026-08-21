function Update-Worktrees {
    <#
    .SYNOPSIS
    Update all worktrees for the repository to the latest from upstream.
    .DESCRIPTION
    Fetches from all remotes and fast-forwards worktrees that have zero local
    commits, stashing and then popping any local changes. Returns an object
    per worktree describing the action taken.

    Uses a bulk 'git for-each-ref' call to get ahead/behind counts for all
    branches in one pass, then checks only worktrees that need merging for
    local changes or in-progress git operations.
    .PARAMETER CheckRemote
    Also query the remote for branches with no local upstream, reclassifying
    NoUpstream worktrees so deleted/stale remote branches are detected.
    .PARAMETER GitHubAccountMap
    Forwarded to Sync-GitRemote. Maps a repository ("host/owner" or bare
    "owner") to the `gh` account that should fetch it when several accounts are
    signed in for the host (github.com or a GitHub Enterprise host).
    .PARAMETER GitHubAccountResolver
    Forwarded to Sync-GitRemote. A scriptblock that receives the remote's host
    and owner and returns the `gh` account name to use.
    .PARAMETER NoGitHubAccountResolve
    Forwarded to Sync-GitRemote. Disable GitHub account awareness during the
    fetch; behave exactly as plain 'git fetch'.
    .EXAMPLE
    Update-Worktrees
    Fetches and fast-forwards all worktrees, returning status objects.
    .EXAMPLE
    Update-Worktrees | Where-Object Status -eq 'Removed'
    Returns only worktrees whose upstream branch is gone.
    .EXAMPLE
    Update-Worktrees | Format-Table Branch, Status, BehindBy
    Shows a summary table of all worktree update results.
    .EXAMPLE
    Update-Worktrees -CheckRemote
    Also checks the remote for NoUpstream branches to detect stale branches.
    #>
    [OutputType('WorktreeUpdateResult')]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [switch]$CheckRemote,

        [hashtable]$GitHubAccountMap,

        [scriptblock]$GitHubAccountResolver,

        [switch]$NoGitHubAccountResolve
    )
    process {
        $previousView = $PSStyle.Progress.View

        try {
        if ($VerbosePreference -eq 'Continue') {
            $PSStyle.Progress.View = 'Classic'
        }

        # Get latest state
        Write-Progress -Activity 'Updating Worktrees' -Status 'Fetching' -PercentComplete 0 -Id 0
        $syncParams = @{}
        if ($PSBoundParameters.ContainsKey('GitHubAccountMap')) { $syncParams.GitHubAccountMap = $GitHubAccountMap }
        if ($PSBoundParameters.ContainsKey('GitHubAccountResolver')) { $syncParams.GitHubAccountResolver = $GitHubAccountResolver }
        if ($NoGitHubAccountResolve) { $syncParams.NoGitHubAccountResolve = $true }
        $fetchResults = Sync-GitRemote @syncParams
        if (-not $?) { return }

        # Build set of branch names whose remote refs were just pruned
        $prunedBranches = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($fr in $fetchResults) {
            if ($fr.Action -eq 'Deleted' -and $fr.Ref -match '^[^/]+/(.+)$') {
                $prunedBranches.Add($Matches[1]) | Out-Null
            }
        }

        Write-Progress -Activity 'Updating Worktrees' -Status 'Getting Worktrees' -PercentComplete 0 -Id 0
        $worktrees = Get-Worktrees
        if ($null -eq $worktrees -or @($worktrees).Count -eq 0) {
            Write-Progress -Activity 'Updating Worktrees' -Id 0 -Completed
            return
        }

        # Bulk-fetch ahead/behind counts for all branches in one git call
        $branchStatus = @{}
        $refLines = git for-each-ref --format='%(refname:short)|%(upstream:short)|%(upstream:track)' refs/heads/ 2>&1
        foreach ($line in $refLines) {
            $parts = $line -split '\|', 3
            if ($parts.Count -lt 3) { continue }
            $branch = $parts[0]
            $upstream = $parts[1]
            $track = $parts[2]

            $ahead = 0; $behind = 0; $gone = $false
            if ($track -match '\[gone\]') {
                $gone = $true
            } else {
                if ($track -match 'ahead (\d+)') { $ahead = [int]$Matches[1] }
                if ($track -match 'behind (\d+)') { $behind = [int]$Matches[1] }
            }
            $branchStatus[$branch] = @{ Ahead = $ahead; Behind = $behind; Gone = $gone; HasUpstream = ($upstream -ne '') }
        }

        $results = [System.Collections.Generic.List[PSObject]]::new()
        $behindWorktrees = [System.Collections.Generic.List[PSObject]]::new()

        # Classify all worktrees using bulk data (no cd or git calls needed)
        foreach ($worktree in $worktrees) {
            $branch = $worktree.Branch
            $bs = $branchStatus[$branch]

            if ($null -eq $bs -or -not $bs.HasUpstream) {
                # No upstream configured — check if the remote ref was just pruned
                $status = if ($prunedBranches.Contains($branch)) {
                    Write-Verbose "$branch upstream removed (pruned this fetch)"
                    'Removed'
                } else {
                    'NoUpstream'
                }
                $results.Add([PSCustomObject]@{
                    PSTypeName = 'WorktreeUpdateResult'
                    Branch     = $branch
                    Path       = $worktree.Path
                    Status     = $status
                    BehindBy   = 0
                    Stashed    = $false
                    Operation  = $null
                })
            }
            elseif ($bs.Gone) {
                Write-Verbose "$branch upstream removed"
                $results.Add([PSCustomObject]@{
                    PSTypeName = 'WorktreeUpdateResult'
                    Branch     = $branch
                    Path       = $worktree.Path
                    Status     = 'Removed'
                    BehindBy   = 0
                    Stashed    = $false
                    Operation  = $null
                })
            }
            elseif ($bs.Ahead -gt 0) {
                $results.Add([PSCustomObject]@{
                    PSTypeName = 'WorktreeUpdateResult'
                    Branch     = $branch
                    Path       = $worktree.Path
                    Status     = 'Skipped'
                    BehindBy   = $bs.Behind
                    Stashed    = $false
                    Operation  = $null
                })
            }
            elseif ($bs.Behind -eq 0) {
                $results.Add([PSCustomObject]@{
                    PSTypeName = 'WorktreeUpdateResult'
                    Branch     = $branch
                    Path       = $worktree.Path
                    Status     = 'Current'
                    BehindBy   = 0
                    Stashed    = $false
                    Operation  = $null
                })
            }
            else {
                # Behind only — collect for parallel merge
                $behindWorktrees.Add([PSCustomObject]@{
                    Branch  = $branch
                    Path    = $worktree.Path
                    Behind  = $bs.Behind
                })
            }
        }

        # If -CheckRemote, reclassify NoUpstream branches by checking the remote
        if ($CheckRemote) {
            $noUpstream = @($results | Where-Object { $_.Status -eq 'NoUpstream' })
            if ($noUpstream.Count -gt 0) {
                Write-Progress -Activity 'Updating Worktrees' -Status 'Checking remote refs' -PercentComplete 40 -Id 0
                $remoteRefSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                $remoteRefs = git --no-pager ls-remote --heads origin 2>$null
                foreach ($refLine in $remoteRefs) {
                    if ($refLine -match '\trefs/heads/(.+)$') {
                        $remoteRefSet.Add($Matches[1]) | Out-Null
                    }
                }

                foreach ($entry in $noUpstream) {
                    if (-not $remoteRefSet.Contains($entry.Branch)) {
                        $entry.Status = 'Removed'
                        Write-Verbose "$($entry.Branch) not found on remote"
                    }
                }
            }
        }

        # Merge behind worktrees. Clean worktrees can fast-forward in parallel, but
        # dirty worktrees must stash/pop sequentially because refs/stash is shared
        # across every worktree in the repository and git stash pop always pops
        # stash@{0}.
        if ($behindWorktrees.Count -gt 0 -and $PSCmdlet.ShouldProcess("$($behindWorktrees.Count) worktrees", 'Fast-forward merge from upstream')) {
            Write-Progress -Activity 'Updating Worktrees' -Status "Checking $($behindWorktrees.Count) worktrees" -PercentComplete 50 -Id 0

            $cleanWorktrees = [System.Collections.Generic.List[PSObject]]::new()
            $dirtyWorktrees = [System.Collections.Generic.List[PSObject]]::new()
            $mergeResults = [System.Collections.Generic.List[PSObject]]::new()
            foreach ($wt in $behindWorktrees) {
                $statusSummary = Get-GitStatusSummary -Path $wt.Path
                if ($statusSummary.Operation) {
                    $mergeResults.Add([PSCustomObject]@{
                        PSTypeName = 'WorktreeUpdateResult'
                        Branch     = $wt.Branch
                        Path       = $wt.Path
                        Status     = 'InProgress'
                        BehindBy   = $wt.Behind
                        Stashed    = $false
                        Operation  = $statusSummary.Operation
                        PopFailed  = $false
                    })
                    continue
                }

                Push-Location $wt.Path
                try {
                    $dirtyOutput = git status --porcelain 2>&1
                    $isDirty = $dirtyOutput -and @($dirtyOutput).Count -gt 0
                    if ($isDirty) {
                        $dirtyWorktrees.Add($wt)
                    } else {
                        $cleanWorktrees.Add($wt)
                    }
                } finally {
                    Pop-Location
                }
            }

            if ($cleanWorktrees.Count -gt 0) {
                Write-Progress -Activity 'Updating Worktrees' -Status "Merging $($cleanWorktrees.Count) clean worktrees" -PercentComplete 60 -Id 0
                $cleanResults = $cleanWorktrees | ForEach-Object -Parallel {
                    $wt = $_
                    Push-Location $wt.Path
                    try {
                        git merge --ff-only '@{upstream}' --quiet 2>&1 | Out-Null
                        $mergeSuccess = $LASTEXITCODE -eq 0

                        [PSCustomObject]@{
                            PSTypeName = 'WorktreeUpdateResult'
                            Branch     = $wt.Branch
                            Path       = $wt.Path
                            Status     = if ($mergeSuccess) { 'Updated' } else { 'Failed' }
                            BehindBy   = $wt.Behind
                            Stashed    = $false
                            Operation  = $null
                            PopFailed  = $false
                        }
                    } finally {
                        Pop-Location
                    }
                } -ThrottleLimit 4

                foreach ($cr in $cleanResults) { $mergeResults.Add($cr) }
            }

            if ($dirtyWorktrees.Count -gt 0) {
                Write-Progress -Activity 'Updating Worktrees' -Status "Merging $($dirtyWorktrees.Count) dirty worktrees" -PercentComplete 70 -Id 0
            }

            foreach ($wt in $dirtyWorktrees) {
                Push-Location $wt.Path
                try {
                    $stashed = $false
                    $dirtyOutput = git status --porcelain 2>&1
                    $isDirty = $dirtyOutput -and @($dirtyOutput).Count -gt 0

                    if ($isDirty) {
                        git stash push --include-untracked --quiet 2>&1 | Out-Null
                        $stashed = $LASTEXITCODE -eq 0
                    }

                    # Only fast-forward when the tree is safe: either it was clean, or we
                    # successfully stashed it. A dirty tree that failed to stash must NOT be
                    # fast-forwarded, and we must NOT run `git stash pop` (which would pop an
                    # unrelated, pre-existing stash into this worktree).
                    if ($isDirty -and -not $stashed) {
                        $mergeResults.Add([PSCustomObject]@{
                            PSTypeName = 'WorktreeUpdateResult'
                            Branch     = $wt.Branch
                            Path       = $wt.Path
                            Status     = 'StashFailed'
                            BehindBy   = $wt.Behind
                            Stashed    = $false
                            Operation  = $null
                            PopFailed  = $false
                        })
                        continue
                    }

                    git merge --ff-only '@{upstream}' --quiet 2>&1 | Out-Null
                    $mergeSuccess = $LASTEXITCODE -eq 0

                    if ($stashed) {
                        git stash pop --quiet 2>&1 | Out-Null
                        $popFailed = $LASTEXITCODE -ne 0
                    }

                    $mergeResults.Add([PSCustomObject]@{
                        PSTypeName = 'WorktreeUpdateResult'
                        Branch     = $wt.Branch
                        Path       = $wt.Path
                        Status     = if ($mergeSuccess) { 'Updated' } else { 'Failed' }
                        BehindBy   = $wt.Behind
                        Stashed    = $stashed
                        Operation  = $null
                        PopFailed  = if ($stashed) { $popFailed } else { $false }
                    })
                } finally {
                    Pop-Location
                }
            }

            foreach ($mr in $mergeResults) {
                if ($mr.PopFailed) {
                    Write-Warning "git stash pop failed for $($mr.Branch) — stash may need manual resolution"
                }
                if ($mr.Status -eq 'Updated') {
                    Write-Verbose "Updated $($mr.Branch)"
                } elseif ($mr.Status -eq 'Failed') {
                    Write-Warning "Fast-forward failed for $($mr.Branch)"
                } elseif ($mr.Status -eq 'StashFailed') {
                    Write-Warning "git stash push failed for $($mr.Branch); skipped fast-forward to avoid disturbing the working tree"
                } elseif ($mr.Status -eq 'InProgress') {
                    Write-Warning "Skipped $($mr.Branch): git operation in progress ($($mr.Operation))"
                }
                $results.Add($mr)
            }
        }

        Write-Progress -Activity 'Updating Worktrees' -Id 0 -Completed

        $results
        }
        finally {
            $PSStyle.Progress.View = $previousView
        }
    }
}