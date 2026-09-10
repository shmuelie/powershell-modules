function Restore-GitStash {
    <#
    .SYNOPSIS
        Restore a stash entry using git stash pop.
    .DESCRIPTION
        Applies the selected stash to the current or specified working tree and
        removes that entry only when native git stash pop succeeds. Git retains
        the stash on an apply failure or conflict; conflicts can leave partially
        restored files and an unmerged index for the caller to resolve.
        Does not force an overwrite, resolve conflicts, or retry with apply/drop.
        Successful operations produce no pipeline output.
    .PARAMETER Path
        Literal directory inside the working tree. Defaults to the current location.
        Accepts pipeline paths and objects with Path, RepositoryPath or RepoPath.
        Pipeline properties select only the repository, not a stash object ID.
        Objects carrying ObjectId (including Save-GitStash results) require an
        explicit Stash selector to avoid silently restoring a different entry.
        Explicit empty paths are rejected rather than falling back to the caller.
    .PARAMETER Stash
        Exact stash reflog selector, such as stash@{0} or stash@{1}. Defaults to
        stash@{0}, the newest entry when Git runs. Bare numeric indices, object
        IDs, revision expressions and wildcards are not supported. The index
        must be a canonical nonnegative 32-bit integer.
    .OUTPUTS
        None. Native failures are PowerShell errors; use -ErrorAction Stop to
        terminate. The error's TargetObject contains Git's exit code and streams.
    .NOTES
        Selectors are mutable positions, not immutable stash identities. Avoid
        concurrent stash writers (including other worktrees of this repository)
        while confirming or running this command. It uses Git's native pop
        semantics and does not add transactional or concurrent-writer protection.
        The caller's location and LASTEXITCODE are unchanged. Like default git
        stash pop, it does not request --index to reinstate the staged state.
    .EXAMPLE
        Restore-GitStash
        Pops the newest stash in the current repository.
    .EXAMPLE
        Restore-GitStash -Path ../project -Stash 'stash@{1}'
        Pops the second-newest stash in that repository without changing location.
    .EXAMPLE
        Restore-GitStash -Path ../project -WhatIf
        Previews the pop without changing files, the index or the stash stack.
    .LINK
        https://git-scm.com/docs/git-stash
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('RepositoryPath', 'RepoPath')]
        [ValidateNotNullOrWhiteSpace()]
        [string]$Path,

        [ValidateScript({
            $index = 0
            $_ -cmatch '\Astash@\{(?:0|[1-9][0-9]*)\}\z' -and
                [int]::TryParse($_.Substring(7, $_.Length - 8), [ref]$index)
        }, ErrorMessage = 'Stash must be an exact stash@{n} selector with a canonical nonnegative 32-bit index, not an object ID or Git option.')]
        [string]$Stash = 'stash@{0}'
    )

    process {
        if ($MyInvocation.ExpectingInput -and $null -ne $PSItem -and
            ($PSItem.PSObject.Properties['ObjectId'] -or $PSItem.PSObject.TypeNames -contains 'GitStash') -and
            -not $PSBoundParameters.ContainsKey('Stash')) {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new('Stash objects require an explicit -Stash ''stash@{n}'' selector. ObjectId is not a native stash pop selector.'),
                'GitStashSelectorRequired', [System.Management.Automation.ErrorCategory]::InvalidArgument, $PSItem))
            return
        }

        $repositoryPath = Resolve-GitRepositoryPath -Path $Path
        if (-not $repositoryPath) { return }

        if ($PSCmdlet.ShouldProcess($repositoryPath, "Pop git stash '$Stash' (apply changes and remove on success)")) {
            $result = Invoke-Git -Path $repositoryPath -Arguments @('stash', 'pop', '--', $Stash)
            if ($null -ne $result) {
                Write-Verbose "Restored '$Stash' in '$repositoryPath'."
            }
        }
    }
}
