function Select-ChangedWorktreeResult {
    <#
    .SYNOPSIS
        Select actionable worktree update results without changing their shape.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowNull()]
        [PSObject]$InputObject
    )

    process {
        if ($null -ne $InputObject -and $InputObject.Status -in @('Updated', 'Removed', 'Failed', 'StashFailed')) {
            $InputObject
        }
    }
}

function Restore-WorktreeUpdateStash {
    <#
    .SYNOPSIS
        Restore an update's captured stash object, removing only its verified top entry.
    #>
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidatePattern('\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z')]
        [string]$ObjectId
    )

    $apply = Invoke-Git -Path $Path -Arguments @('stash', 'apply', '--', $ObjectId) -AllowNonZeroExit
    if ($null -eq $apply) { return $false }
    if ($apply.ExitCode -ne 0) {
        Write-Warning "git stash apply failed for saved stash '$ObjectId' in '$Path' (exit $($apply.ExitCode)): $($apply.Output -join [Environment]::NewLine)"
        return $false
    }

    # Apply the immutable object, not a reflog position. If another writer moved
    # the stack, keep every entry rather than dropping an unrelated newest stash.
    $head = Invoke-Git -Path $Path -Arguments @(
        'for-each-ref', '--format=%(objectname)', '--', 'refs/stash'
    ) -AllowNonZeroExit
    if ($null -eq $head) { return $false }
    if ($head.ExitCode -ne 0) {
        Write-Warning "Could not verify saved stash '$ObjectId' after applying it in '$Path' (exit $($head.ExitCode)): $($head.Output -join [Environment]::NewLine)"
        return $false
    }
    if ($head.StandardOutput.Trim() -cne $ObjectId) {
        Write-Warning "Applied saved stash '$ObjectId' in '$Path', but the stash stack changed; no stash was dropped."
        return $false
    }

    $drop = Invoke-Git -Path $Path -Arguments @('stash', 'drop', '--quiet', '--', 'stash@{0}') -AllowNonZeroExit
    if ($null -eq $drop) { return $false }
    if ($drop.ExitCode -ne 0) {
        Write-Warning "git stash drop failed for restored stash '$ObjectId' in '$Path' (exit $($drop.ExitCode)): $($drop.Output -join [Environment]::NewLine)"
        return $false
    }
    $true
}

function Update-Worktrees {
    <#
    .SYNOPSIS
    Update all worktrees for the repository to the latest from upstream.
    .DESCRIPTION
    Fetches from all remotes and fast-forwards worktrees that have zero local
    commits, saving and restoring any local changes through an owned stash.
    Returns an object per worktree describing the action taken.

    Restores only the captured stash object and drops it only when it is still
    the newest entry. A successful stash push that creates no stash (for example
    submodule-only changes) leaves the worktree untouched and returns StashFailed.
    Restoration conflicts retain the stash and report PopFailed.

    Dirty worktrees are processed sequentially because the stash stack is shared.
    Avoid other stash writers in any linked worktree while updating: the stash
    identity reads and verified drop are not atomic with external Git processes.

    Uses a bulk 'git for-each-ref' call to get ahead/behind counts for all
    branches in one pass, then checks only worktrees that need merging for
    local changes or in-progress git operations.

    Use -ChangedOnly to emit only updated, removed, or failed worktree results.
    This filters output only; it does not change which worktrees are processed.
    WhatIf previews and warning/error messages remain visible.
    .PARAMETER Path
    Directory inside the git working tree to update. Defaults to the current location.
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
    .PARAMETER ChangedOnly
    Emit only WorktreeUpdateResult objects with Status Updated, Removed, Failed,
    or StashFailed. Omit this switch to return every result. WhatIf still shows
    the standard fetch and fast-forward previews without reporting updates.
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
    .EXAMPLE
    Update-Worktrees -ChangedOnly
    Returns only updated, removed, or failed worktrees.
    .EXAMPLE
    Update-Worktrees -ChangedOnly -WhatIf
    Previews fetching and fast-forwarding without performing either operation.
    #>
    [OutputType('WorktreeUpdateResult')]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('RepositoryPath', 'RepoPath')]
        [string]$Path,

        [switch]$CheckRemote,

        [hashtable]$GitHubAccountMap,

        [scriptblock]$GitHubAccountResolver,

        [switch]$NoGitHubAccountResolve,

        [switch]$ChangedOnly
    )
    process {
        $repoPath = Resolve-GitRepositoryPath -Path $Path
        if (-not $repoPath) { return }

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
        $syncParams.Path = $repoPath
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
        $worktrees = Get-Worktrees -Path $repoPath
        if ($null -eq $worktrees -or @($worktrees).Count -eq 0) {
            Write-Progress -Activity 'Updating Worktrees' -Id 0 -Completed
            return
        }

        # Bulk-fetch ahead/behind counts for all branches in one git call
        $branchStatus = @{}
        $refLines = git -C $repoPath for-each-ref --format='%(refname:short)|%(upstream:short)|%(upstream:track)' refs/heads/ 2>&1
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
                # A failed `ls-remote` (e.g. an unreachable remote) returns an
                # empty ref set; reclassifying from that would wrongly mark every
                # NoUpstream worktree as Removed. Skip the reclassification and
                # warn instead of guessing from nothing.
                $remoteRefs = git -C $repoPath --no-pager ls-remote --heads origin 2>&1
                if ($LASTEXITCODE -ne 0) {
                    $detail = ($remoteRefs | ForEach-Object { "$_" }) -join ' '
                    Write-Warning "Skipping remote branch check: git ls-remote failed for 'origin' (exit $LASTEXITCODE): $detail. NoUpstream worktrees left unclassified."
                } else {
                    $remoteRefSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
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
        }

        # Merge behind worktrees. Clean worktrees can fast-forward in parallel, but
        # dirty worktrees must save/restore sequentially because refs/stash is
        # shared across every worktree in the repository.
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

                $dirtyOutput = git -C $wt.Path status --porcelain 2>&1
                $isDirty = $dirtyOutput -and @($dirtyOutput).Count -gt 0
                if ($isDirty) {
                    $dirtyWorktrees.Add($wt)
                } else {
                    $cleanWorktrees.Add($wt)
                }
            }

            if ($cleanWorktrees.Count -gt 0) {
                Write-Progress -Activity 'Updating Worktrees' -Status "Merging $($cleanWorktrees.Count) clean worktrees" -PercentComplete 60 -Id 0
                $cleanResults = $cleanWorktrees | ForEach-Object -Parallel {
                    $wt = $_
                    git -C $wt.Path merge --ff-only '@{upstream}' --quiet 2>&1 | Out-Null
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
                } -ThrottleLimit 4

                foreach ($cr in $cleanResults) { $mergeResults.Add($cr) }
            }

            if ($dirtyWorktrees.Count -gt 0) {
                Write-Progress -Activity 'Updating Worktrees' -Status "Merging $($dirtyWorktrees.Count) dirty worktrees" -PercentComplete 70 -Id 0
            }

            foreach ($wt in $dirtyWorktrees) {
                $stash = $null
                $stashErrors = @()
                $dirtyOutput = git -C $wt.Path status --porcelain 2>&1
                $isDirty = $dirtyOutput -and @($dirtyOutput).Count -gt 0

                if ($isDirty) {
                    # Reject another writer's stash if it wins the post-push identity read.
                    $stashMessage = "Update-Worktrees $([guid]::NewGuid().ToString('N'))"
                    $stash = Save-GitStash -Path $wt.Path -IncludeUntracked -Message $stashMessage `
                        -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable stashErrors
                    if ($stash -and -not $stash.Subject.EndsWith($stashMessage, [StringComparison]::Ordinal)) {
                        $stashErrors += 'The recorded stash was not created by this update; the stash stack may have changed'
                        $stash = $null
                    }
                }
                $stashed = $null -ne $stash

                # A successful no-op push owns no stash, just like a failed push.
                if ($isDirty -and -not $stashed) {
                    $detail = if ($stashErrors.Count -gt 0) {
                        "git stash push failed for $($wt.Branch): $($stashErrors -join ' ')"
                    } else {
                        "git stash push did not create a stash for $($wt.Branch)"
                    }
                    Write-Warning "$detail; skipped fast-forward to avoid disturbing the working tree."
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

                git -C $wt.Path merge --ff-only '@{upstream}' --quiet 2>&1 | Out-Null
                $mergeSuccess = $LASTEXITCODE -eq 0

                if ($stashed) {
                    $popFailed = -not (Restore-WorktreeUpdateStash -Path $wt.Path -ObjectId $stash.ObjectId)
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
            }

            foreach ($mr in $mergeResults) {
                if ($mr.PopFailed) {
                    Write-Warning "git stash restoration failed for $($mr.Branch) — stash may need manual resolution"
                }
                if ($mr.Status -eq 'Updated') {
                    Write-Verbose "Updated $($mr.Branch)"
                } elseif ($mr.Status -eq 'Failed') {
                    Write-Warning "Fast-forward failed for $($mr.Branch)"
                } elseif ($mr.Status -eq 'InProgress') {
                    Write-Warning "Skipped $($mr.Branch): git operation in progress ($($mr.Operation))"
                }
                $results.Add($mr)
            }
        }

        Write-Progress -Activity 'Updating Worktrees' -Id 0 -Completed

        if ($ChangedOnly) {
            $results | Select-ChangedWorktreeResult
        } else {
            $results
        }
        }
        finally {
            $PSStyle.Progress.View = $previousView
        }
    }
}