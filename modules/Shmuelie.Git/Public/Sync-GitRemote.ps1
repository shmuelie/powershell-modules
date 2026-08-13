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

    GitHub account awareness. When more than one account is signed in to the
    `gh` CLI for a remote's host (github.com or a GitHub Enterprise host), the
    fetch for that remote is run with the account that can access it. A
    per-account token is acquired with `gh auth token` and injected into the
    git child process environment only; the globally-active `gh` account is
    never changed and concurrent fetches never cross-contaminate credentials.
    An account is chosen by consulting -GitHubAccountMap, then
    -GitHubAccountResolver, then a reactive fallback that tries the active
    account and retries the remaining signed-in accounts on an auth failure
    (caching the winning host+owner -> account for the session). This is a
    graceful no-op — identical to plain 'git fetch' — when `gh` is not
    installed, only one account is signed in for the host, the host is one
    `gh` does not manage, or `gh auth token` fails.
    .PARAMETER Remote
    Fetch from a specific remote instead of all remotes.
    .PARAMETER NoPrune
    Skip removing remote-tracking references that no longer exist on the remote.
    By default, deleted remote branches are pruned.
    .PARAMETER GitHubAccountMap
    A hashtable mapping a repository to the `gh` account that should fetch it.
    Keys are "host/owner" (e.g. 'github.com/contoso') or a bare "owner" that
    applies on any host; values are `gh` account names. Consulted first when
    choosing an account.
    .PARAMETER GitHubAccountResolver
    A scriptblock that receives the remote's host and owner (as two arguments,
    also available as $args[0]/$args[1]) and returns the `gh` account name to
    use, or nothing to defer. Consulted after -GitHubAccountMap.
    .PARAMETER NoGitHubAccountResolve
    Disable GitHub account awareness entirely; fetch exactly as plain
    'git fetch' regardless of how many `gh` accounts are signed in.
    .EXAMPLE
    Sync-GitRemote
    Fetches from all remotes with pruning. Returns nothing if up to date.
    .EXAMPLE
    Sync-GitRemote | Format-Table
    Shows a table of new, updated, and deleted remote refs.
    .EXAMPLE
    Sync-GitRemote -Remote origin -NoPrune
    Fetches from origin without pruning deleted branches.
    .EXAMPLE
    Sync-GitRemote -GitHubAccountMap @{ 'github.com/contoso' = 'work-user' }
    Fetches, using the 'work-user' gh account for any github.com/contoso remote.
    #>
    [OutputType('GitFetchResult')]
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'All')]
    param(
        [Parameter(ParameterSetName = 'Specific', Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Remote,

        [switch]$NoPrune,

        [hashtable]$GitHubAccountMap,

        [scriptblock]$GitHubAccountResolver,

        [switch]$NoGitHubAccountResolve
    )

    if ($null -eq $script:GitHubAccountCache) {
        $script:GitHubAccountCache = [System.Collections.Concurrent.ConcurrentDictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    }

    $target = if ($Remote) { "remote '$Remote'" } else { 'all remotes' }
    if (-not $PSCmdlet.ShouldProcess($target, 'git fetch')) { return }

    $pruneArg = if ($NoPrune) { @() } else { @('--prune') }

    # Decide whether GitHub account awareness can apply at all. When it can't,
    # fall through to the original single 'git fetch' path unchanged.
    $accounts = if ($NoGitHubAccountResolve) { @() } else { @(Get-GitHubSignedInAccount) }

    $resolvePlan = @{}
    $remoteSet = @()
    if ($accounts.Count -gt 0) {
        $remoteSet = if ($Remote) { @($Remote) } else { @(git remote 2>$null) }

        foreach ($remoteName in $remoteSet) {
            if (-not $remoteName) { continue }
            $url = git remote get-url $remoteName 2>$null
            if (-not $url) { continue }
            $info = Get-GitHubRemoteInfo -Url "$url"
            if (-not $info) { continue }

            $hostAccounts = @($accounts | Where-Object { $_.Host -eq $info.Host })
            if ($hostAccounts.Count -eq 0) { continue }  # host gh does not manage

            $explicit = Get-GitHubAccountMapValue -Map $GitHubAccountMap -HostName $info.Host -Owner $info.Owner
            if (-not $explicit -and $GitHubAccountResolver) {
                $explicit = "$(& $GitHubAccountResolver $info.Host $info.Owner)".Trim()
            }

            $cacheKey = "$($info.Host)/$($info.Owner)"
            $cached = $null
            [void]$script:GitHubAccountCache.TryGetValue($cacheKey, [ref]$cached)

            # Only take over the fetch when there is a real choice to make:
            # an explicit mapping, a remembered winner, or more than one account
            # on the host. A lone account with no mapping behaves as today.
            if ($explicit -or $cached -or $hostAccounts.Count -gt 1) {
                $resolvePlan[$remoteName] = [PSCustomObject]@{
                    Info         = $info
                    CacheKey     = $cacheKey
                    Explicit     = $explicit
                    Cached       = $cached
                    HostAccounts = $hostAccounts
                }
            }
        }
    }

    $output = $null
    $failed = $false

    if ($resolvePlan.Count -eq 0) {
        # Original behavior: one 'git fetch' for the whole request.
        $fetchArgs = @('fetch')
        $fetchArgs += if ($Remote) { $Remote } else { '--all' }
        $fetchArgs += $pruneArg
        $output = git @fetchArgs 2>&1
        if ($LASTEXITCODE -ne 0) { $failed = $true }
    }
    else {
        # Per-remote mode: tokened fetch for planned remotes, plain fetch for
        # the rest. Aggregate all output for the shared parser below.
        $collected = [System.Collections.Generic.List[string]]::new()
        foreach ($remoteName in $remoteSet) {
            if (-not $remoteName) { continue }
            $baseArgs = @('fetch', $remoteName) + $pruneArg

            if ($resolvePlan.ContainsKey($remoteName)) {
                $result = Invoke-GitHubTokenedFetch -Arguments $baseArgs -Plan $resolvePlan[$remoteName]
            }
            else {
                $result = Invoke-GitWithEnvironment -Arguments $baseArgs
            }

            foreach ($l in $result.Output) { $collected.Add($l) }
            if ($result.ExitCode -ne 0) {
                $failed = $true
                Write-Error "git fetch failed for '$remoteName' (exit code $($result.ExitCode))."
            }
        }
        $output = $collected.ToArray()
    }

    if ($failed -and $resolvePlan.Count -eq 0) {
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

function Invoke-GitHubTokenedFetch {
    <#
    .SYNOPSIS
    Fetch a single remote using a gh account that can access it.
    .DESCRIPTION
    Tries candidate accounts in priority order (explicit mapping, then the
    session-cached winner, then the host's active account, then the rest),
    acquiring each account's token and running git with GH_TOKEN/GH_HOST set on
    the child only. Stops at the first success (caching it) or at a non-auth
    error; keeps trying on auth/access failures. Never changes the active
    account. Returns a GitInvocationResult.
    #>
    [OutputType('GitInvocationResult')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][psobject]$Plan
    )

    $gitHost = $Plan.Info.Host

    # Build the ordered, de-duplicated candidate list.
    $ordered = [System.Collections.Generic.List[string]]::new()
    $add = {
        param($name)
        if ($name -and -not ($ordered -contains $name)) { $ordered.Add($name) }
    }
    & $add $Plan.Explicit
    & $add $Plan.Cached
    foreach ($a in ($Plan.HostAccounts | Where-Object Active)) { & $add $a.Account }
    foreach ($a in $Plan.HostAccounts) { & $add $a.Account }

    $last = $null
    foreach ($account in $ordered) {
        $token = Get-GitHubAccountToken -HostName $gitHost -Account $account
        if (-not $token) { continue }

        $result = Invoke-GitWithEnvironment -Arguments $Arguments -Environment @{
            GH_TOKEN = $token
            GH_HOST  = $gitHost
        }
        $last = $result

        if ($result.ExitCode -eq 0) {
            $script:GitHubAccountCache[$Plan.CacheKey] = $account
            Write-Verbose "Fetched $($Plan.CacheKey) using gh account '$account'."
            return $result
        }

        if (-not (Test-GitHubAuthFailure -Output $result.Output)) {
            # A real error (not an access problem) — don't burn other accounts.
            return $result
        }
        Write-Verbose "gh account '$account' cannot access $($Plan.CacheKey); trying next."
    }

    if ($null -ne $last) { return $last }

    # No usable token for any candidate: fall back to a plain fetch so behavior
    # matches a machine where account resolution never engaged.
    Invoke-GitWithEnvironment -Arguments $Arguments
}
