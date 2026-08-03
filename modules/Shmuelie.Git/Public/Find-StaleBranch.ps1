function Find-StaleBranch {
    <#
    .SYNOPSIS
        Find local branches whose remote branch no longer exists.
    .DESCRIPTION
        Compares local branches against remote refs to identify stale branches
        that were deleted from the remote (e.g., after a PR was merged or abandoned).

        Optionally queries Azure DevOps for PR status to explain why the branch
        was deleted (completed/merged, abandoned, or manually deleted).
    .PARAMETER Remote
        The remote to check against. Defaults to 'origin'.
    .PARAMETER User
        Filter to branches matching user/<name>/*. Defaults to the current
        git user name derived from user.email config.
    .PARAMETER IncludePrStatus
        Query Azure DevOps for PR status on each stale branch. This makes
        one API call per stale branch and is slower.
    .PARAMETER All
        Include all local branches, not just those matching the user filter.
    .EXAMPLE
        Find-StaleBranch
        Lists stale branches for the current user.
    .EXAMPLE
        Find-StaleBranch -IncludePrStatus
        Lists stale branches with PR status from Azure DevOps.
    .EXAMPLE
        Find-StaleBranch -All
        Lists all stale branches regardless of user.
    .EXAMPLE
        Find-StaleBranch | Remove-Worktree
        Removes worktrees for stale branches.
    #>
    [OutputType('StaleBranchInfo')]
    [CmdletBinding()]
    param(
        [string]$Remote = 'origin',

        [string]$User,

        [switch]$IncludePrStatus,

        [switch]$All
    )
    process {
        # Determine user filter
        if (-not $All -and -not $User) {
            $email = git config user.email 2>$null
            if ($email -match '^([^@]+)@') {
                $User = $Matches[1]
            }
        }
        $userPrefix = if (-not $All -and $User) { "user/$User/" } else { $null }

        # Get all local branches
        $localBranches = git --no-pager for-each-ref --format='%(refname:short)|%(upstream:short)|%(upstream:track)' refs/heads/ 2>&1
        $candidates = @()
        foreach ($line in $localBranches) {
            $parts = $line -split '\|', 3
            if ($parts.Count -lt 3) { continue }
            $branch = $parts[0]
            $upstream = $parts[1]
            $upstreamTrack = $parts[2]

            # Keep branches with no upstream or an upstream whose tracking ref is gone.
            if ($upstream -and $upstreamTrack -ne '[gone]') { continue }

            # Apply user filter
            if ($userPrefix -and -not $branch.StartsWith($userPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { continue }

            $candidates += $branch
        }

        if ($candidates.Count -eq 0) { return }

        # Batch-fetch all remote refs matching user prefix in one call
        $remoteRefSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $lsRemoteFilter = if ($userPrefix) { "refs/heads/$userPrefix*" } else { 'refs/heads/*' }
        $remoteRefs = git --no-pager ls-remote --heads $Remote $lsRemoteFilter 2>$null
        foreach ($refLine in $remoteRefs) {
            if ($refLine -match '\trefs/heads/(.+)$') {
                $remoteRefSet.Add($Matches[1]) | Out-Null
            }
        }

        # Build worktree lookup for path info
        $worktreePaths = @{}
        try {
            $worktrees = Get-Worktrees
            foreach ($wt in $worktrees) {
                $worktreePaths[$wt.Branch] = $wt.Path
            }
        } catch { }

        # ADO context for PR lookups
        $adoContext = $null
        if ($IncludePrStatus) {
            $gitUrl = git config --get "remote.$Remote.url" 2>$null
            if ($gitUrl -match 'dev\.azure\.com/(?<org>[^/]+)/(?<project>[^/]+)/_git/(?<repo>.+)$' -or
                $gitUrl -match '(?<org>[^/]+)\.visualstudio\.com/(?:DefaultCollection/)?(?<project>[^/]+)/_git/(?<repo>.+)$') {
                $adoContext = @{
                    Org     = "https://dev.azure.com/$($Matches['org'])"
                    Project = $Matches['project']
                    Repo    = $Matches['repo']
                }
            }
        }

        # Classify each candidate
        foreach ($branch in $candidates) {
            $existsOnRemote = $remoteRefSet.Contains($branch)
            if ($existsOnRemote) { continue }

            $result = [PSCustomObject]@{
                PSTypeName     = 'StaleBranchInfo'
                Branch         = $branch
                Path           = $worktreePaths[$branch]
                ExistsOnRemote = $false
                PrStatus       = $null
                PrId           = $null
                PrTitle        = $null
            }

            # Optional ADO PR lookup
            if ($IncludePrStatus -and $adoContext) {
                try {
                    $prJson = az repos pr list `
                        --source-branch $branch `
                        --status all `
                        --repository $adoContext.Repo `
                        --project $adoContext.Project `
                        --org $adoContext.Org `
                        --query '[0].{id:pullRequestId,title:title,status:status}' `
                        -o json 2>$null | ConvertFrom-Json

                    if ($prJson) {
                        $result.PrStatus = $prJson.status
                        $result.PrId = $prJson.id
                        $result.PrTitle = $prJson.title
                    }
                } catch {
                    Write-Verbose "Failed to query PR for $branch`: $_"
                }
            }

            $result
        }
    }
}
