function Set-Branch {
    <#
    .SYNOPSIS
        Switch the current working tree to a git branch.
    .DESCRIPTION
        Uses git switch in the current or specified repository without changing
        the caller's location. By default the branch must already exist locally;
        remote branch guessing is disabled. Does not fetch, synchronize branches,
        create worktrees, or bypass Git's protection for branches checked out in
        another worktree. Successful operations produce no pipeline output.
    .PARAMETER Branch
        Literal branch name. With Track, use an existing remote-tracking branch
        such as origin/feature/topic; Git derives the new local name feature/topic.
        Options, full refs, revision expressions and previous-branch shortcuts
        are not supported.
    .PARAMETER Path
        Literal directory inside the working tree. Defaults to the current location.
        Accepts pipeline paths and objects with Path, RepositoryPath or RepoPath.
    .PARAMETER CreateNew
        Create a new local branch at HEAD and switch to it, without an upstream.
        Fails if the branch already exists, even with Force. Cannot combine with Track.
    .PARAMETER Force
        Discard local index and working-tree changes when switching. Git may also
        overwrite or remove untracked files that obstruct the target checkout.
        Does not reset an existing branch, bypass worktree protection, or suppress
        WhatIf/Confirm.
    .PARAMETER Track
        Create and switch to a local branch from the supplied remote-tracking
        branch, setting that remote branch as its upstream. Fails if the inferred
        local branch already exists. Cannot combine with CreateNew.
    .OUTPUTS
        None.
    .EXAMPLE
        Set-Branch -Branch feature/topic
        Switches to an existing local branch, preserving non-conflicting changes.
    .EXAMPLE
        Set-Branch -Branch feature/new -CreateNew -Path ../project
        Creates a branch at that repository's HEAD without changing location.
    .EXAMPLE
        Set-Branch -Branch origin/feature/topic -Track
        Creates feature/topic from origin/feature/topic and sets its upstream.
    .EXAMPLE
        Set-Branch -Branch main -Force -WhatIf
        Previews discarding local changes and switching to main without mutation.
    .LINK
        https://git-scm.com/docs/git-switch
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Switch')]
    param(
        [Parameter(Mandatory, Position = 0)]
        [Alias('BranchName')]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({
            $_ -notmatch '^-|^refs/|[\x00-\x20\x7f]|@\{' -and $_ -ne '@'
        }, ErrorMessage = 'Branch must be a literal branch name, not an option, full ref, revision expression or checkout shortcut.')]
        [string]$Branch,

        [Parameter(Position = 1, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('RepositoryPath', 'RepoPath')]
        [string]$Path,

        [Parameter(Mandatory, ParameterSetName = 'Create')]
        [switch]$CreateNew,

        [switch]$Force,

        [Parameter(Mandatory, ParameterSetName = 'Track')]
        [switch]$Track
    )

    process {
        $validation = Invoke-Git -Path $Path -Arguments @('check-ref-format', '--branch', $Branch)
        if ($null -eq $validation) { return }
        $repositoryPath = $validation.RepositoryPath

        $arguments = @('switch', '--no-guess')
        $action = "Switch to branch '$Branch'"
        if ($Track) {
            $remote = Invoke-Git -Path $repositoryPath -Arguments @(
                'show-ref', '--verify', '--quiet', '--', "refs/remotes/$Branch"
            )
            if ($null -eq $remote) { return }
            $arguments += '--track=direct'
            $action = "Create and switch to a local branch tracking '$Branch'"
        } elseif ($CreateNew) {
            $arguments += @('--no-track', '--create', $Branch)
            $action = "Create and switch to branch '$Branch' at HEAD"
        }
        if ($Force) {
            $arguments += '--discard-changes'
            $action += ', discarding local changes'
        }
        $arguments += '--'
        if (-not $CreateNew) { $arguments += $Branch }

        if ($PSCmdlet.ShouldProcess($repositoryPath, $action)) {
            $result = Invoke-Git -Path $repositoryPath -Arguments $arguments
            if ($null -ne $result) {
                Write-Verbose "Switched branch in '$repositoryPath'."
            }
        }
    }
}
