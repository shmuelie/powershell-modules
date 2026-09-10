function Save-GitStash {
    <#
    .SYNOPSIS
        Save working-tree and index changes in a new git stash.
    .DESCRIPTION
        Runs git stash push using literal arguments. By default only tracked
        changes are saved and reset to HEAD; untracked and ignored files remain.
        Uses git's native index, submodule and nested-repository behavior without
        additional cleanup or recursion. Never applies, pops or removes a stash.

        Emits a GitStash only when refs/stash changes after a successful push.
        Nothing to save, -WhatIf and declined confirmation produce no result.
        Git informational output is available with -Verbose; successful git
        warnings are forwarded to the warning stream. Git failures are errors.
        Does not change the caller's location or LASTEXITCODE.

        Avoid concurrent stash operations in this repository (including linked
        worktrees) while saving: git locks its updates, but the before/push/after
        identity reads are not an atomic transaction with other git processes.
    .PARAMETER Path
        Literal directory inside a working tree. Defaults to the current location.
        The entire working tree is targeted, even from a subdirectory.
        Accepts pipeline paths and objects with Path, RepositoryPath or RepoPath.
        Bare repositories are not supported.
    .PARAMETER KeepIndex
        Leave staged changes in the index and working tree after saving. The
        stash still contains both staged and unstaged tracked changes.
    .PARAMETER IncludeUntracked
        Also save and remove untracked files, but leave ignored files alone.
        Cannot be combined with -All.
    .PARAMETER All
        Also save and remove untracked and ignored files, subject to git's
        native nested-repository protections. Cannot be combined with
        -IncludeUntracked.
    .PARAMETER Message
        Optional message passed as one literal argument, without trimming or
        shell evaluation. Null, empty or whitespace-only values use git's default
        message. Git controls the stored message and subject formatting.
    .OUTPUTS
        GitStash
        ObjectId is the full stash commit ID (not a moving stash@{N} selector).
        RepositoryPath is the resolved input directory, not necessarily the
        repository root. Subject is git's contents:subject for the stash commit.
        Retain ObjectId and RepositoryPath together to identify the saved stash
        even after later pushes renumber the stack. This object does not pin the
        commit against future dropping, clearing or garbage collection.
    .EXAMPLE
        Save-GitStash -Message 'Pause work'
        Saves tracked changes in the current repository.
    .EXAMPLE
        Save-GitStash -Path ../project -KeepIndex -IncludeUntracked
        Saves tracked and untracked changes, keeping staged changes checked out.
    .EXAMPLE
        Get-Worktrees | Save-GitStash -All -WhatIf
        Previews saving all eligible changes in each supplied worktree.
    #>
    [OutputType('GitStash')]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('RepositoryPath', 'RepoPath')]
        [string]$Path,

        [switch]$KeepIndex,

        [switch]$IncludeUntracked,

        [switch]$All,

        [AllowNull()]
        [AllowEmptyString()]
        [ValidateScript({ -not $_.Contains([char]0) }, ErrorMessage = 'A stash message must not contain NUL characters.')]
        [string]$Message
    )

    begin {
        if ($All -and $IncludeUntracked) {
            $PSCmdlet.ThrowTerminatingError([System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new('Use either -All or -IncludeUntracked, not both. -All already includes untracked files.'),
                'GitStashOptionsConflict', [System.Management.Automation.ErrorCategory]::InvalidArgument, $null))
        }

        $arguments = @('stash', 'push')
        if ($KeepIndex) { $arguments += '--keep-index' }
        if ($IncludeUntracked) { $arguments += '--include-untracked' }
        if ($All) { $arguments += '--all' }
        if (-not [string]::IsNullOrWhiteSpace($Message)) { $arguments += @('-m', $Message) }
    }

    process {
        # for-each-ref succeeds with empty output when no stash exists.
        $before = Invoke-Git -Path $Path -Arguments @('for-each-ref', '--format=%(objectname)', '--', 'refs/stash')
        if ($null -eq $before) { return }
        $repositoryPath = $before.RepositoryPath
        $scope = if ($All) { 'tracked, untracked and ignored' }
            elseif ($IncludeUntracked) { 'tracked and untracked' }
            else { 'tracked' }
        $action = "Save $scope changes in a git stash"
        if ($KeepIndex) { $action += ', keeping staged changes' }
        if (-not $PSCmdlet.ShouldProcess($repositoryPath, $action)) { return }

        $push = Invoke-Git -Path $repositoryPath -Arguments $arguments
        if ($null -eq $push) { return }
        if ($push.StandardOutput) { Write-Verbose $push.StandardOutput.TrimEnd() }
        if ($push.StandardError) { Write-Warning $push.StandardError.TrimEnd() }

        $after = Invoke-Git -Path $repositoryPath -Arguments @(
            'for-each-ref', '--format=%(objectname)%00%(contents:subject)', '--', 'refs/stash'
        )
        if ($null -eq $after) { return }
        if (-not $after.StandardOutput) { return }
        $record = $after.StandardOutput.TrimEnd("`r", "`n") -split "`0", 2
        if ($record.Count -ne 2 -or $record[0] -cnotmatch '^(?:[0-9a-f]{40}|[0-9a-f]{64})$') {
            $PSCmdlet.ThrowTerminatingError([System.Management.Automation.ErrorRecord]::new(
                [System.FormatException]::new('Unexpected git stash reference output; the saved stash identity could not be read.'),
                'GitStashIdentityInvalid', [System.Management.Automation.ErrorCategory]::InvalidData, $repositoryPath))
        }
        if ($record[0] -ceq $before.StandardOutput.Trim()) { return }

        [PSCustomObject]@{
            PSTypeName     = 'GitStash'
            ObjectId       = $record[0]
            RepositoryPath = $repositoryPath
            Subject        = $record[1]
        }
    }
}
