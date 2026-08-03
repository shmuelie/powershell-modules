function Sync-GitRemote {
    <#
    .SYNOPSIS
    Fetch latest state from git remotes.
    .DESCRIPTION
    Wraps 'git fetch' with typed parameters. By default fetches from all
    remotes with --prune to clean up deleted remote branches. Returns
    GitFetchResult objects describing what changed (new, updated, deleted,
    or forced-update refs).

    When a remote branch is pruned, any matching local branch that lacks
    tracking configuration gets branch.X.remote and branch.X.merge set
    automatically. This ensures git reports the branch as [gone] rather
    than simply missing its upstream, enabling reliable detection in
    prompts, Update-Worktrees, and 'git branch -vv'.
    .PARAMETER Remote
    Fetch from a specific remote instead of all remotes.
    .PARAMETER NoPrune
    Skip removing remote-tracking references that no longer exist on the remote.
    By default, deleted remote branches are pruned.
    .EXAMPLE
    Sync-GitRemote
    Fetches from all remotes with pruning. Returns nothing if up to date.
    .EXAMPLE
    Sync-GitRemote | Format-Table
    Shows a table of new, updated, and deleted remote refs.
    .EXAMPLE
    Sync-GitRemote -Remote origin -NoPrune
    Fetches from origin without pruning deleted branches.
    #>
    [OutputType('GitFetchResult')]
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'All')]
    param(
        [Parameter(ParameterSetName = 'Specific', Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Remote,

        [switch]$NoPrune
    )

    $fetchArgs = @('fetch')
    if ($PSCmdlet.ParameterSetName -eq 'Specific') {
        $fetchArgs += $Remote
    } else {
        $fetchArgs += '--all'
    }
    if (-not $NoPrune) { $fetchArgs += '--prune' }

    $target = if ($Remote) { "remote '$Remote'" } else { 'all remotes' }
    if ($PSCmdlet.ShouldProcess($target, 'git fetch')) {
        # Run without --quiet to capture change lines; stderr has the ref updates
        $output = git @fetchArgs 2>&1

        if ($LASTEXITCODE -ne 0) {
            Write-Error "git fetch failed (exit code $LASTEXITCODE)."
            return
        }

        foreach ($line in $output) {
            $text = "$line".Trim()
            # Parse git fetch output lines:
            #  * [new branch]      feature    -> origin/feature
            #  * [new tag]         v1.0       -> v1.0
            #  - [deleted]         (none)     -> origin/old-branch
            #    abc1234..def5678  main       -> origin/main
            #  + abc1234..def5678  main       -> origin/main  (forced update)
            if ($text -match '^\*\s+\[new (branch|tag)\]\s+\S+\s+->\s+(\S+)') {
                [PSCustomObject]@{
                    PSTypeName = 'GitFetchResult'
                    Action     = "New $($Matches[1])"
                    Ref        = $Matches[2]
                    Summary    = $text
                }
            }
            elseif ($text -match '^-\s+\[deleted\]\s+.*->\s+(\S+)') {
                $deletedRef = $Matches[1]
                [PSCustomObject]@{
                    PSTypeName = 'GitFetchResult'
                    Action     = 'Deleted'
                    Ref        = $deletedRef
                    Summary    = $text
                }

                # Set tracking config on orphaned local branches so [gone] detection works.
                # When a remote ref is pruned, local branches that tracked it lose their
                # upstream pointer if they never had explicit tracking config.
                if ($deletedRef -match '^([^/]+)/(.+)$') {
                    $remoteName = $Matches[1]
                    $branchName = $Matches[2]
                    $existingRemote = git config --get "branch.$branchName.remote" 2>$null
                    if (-not $existingRemote -and (git rev-parse --verify "refs/heads/$branchName" 2>$null)) {
                        git config "branch.$branchName.remote" $remoteName
                        git config "branch.$branchName.merge" "refs/heads/$branchName"
                        Write-Verbose "Set tracking config on '$branchName' -> '$remoteName/$branchName' (pruned) for [gone] detection"
                    }
                }
            }
            elseif ($text -match '^\+\s+\S+\s+\S+\s+->\s+(\S+)') {
                [PSCustomObject]@{
                    PSTypeName = 'GitFetchResult'
                    Action     = 'Forced update'
                    Ref        = $Matches[1]
                    Summary    = $text
                }
            }
            elseif ($text -match '^\s+[0-9a-f]+\.\.[0-9a-f]+\s+\S+\s+->\s+(\S+)') {
                [PSCustomObject]@{
                    PSTypeName = 'GitFetchResult'
                    Action     = 'Updated'
                    Ref        = $Matches[1]
                    Summary    = $text
                }
            }
            # Skip "Fetching <remote>" and "From <url>" header lines
        }
    }
}