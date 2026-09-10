function Remove-Branch {
    <#
    .SYNOPSIS
        Delete an explicitly named local or remote git branch.
    .DESCRIPTION
        Deletes a local branch with git branch -d by default. Git refuses branches
        that are not fully merged into their upstream (or HEAD without an upstream).
        -Force uses -D for local deletion only; it never suppresses confirmation
        or overrides git's protection of branches checked out in any worktree.

        -Remote deletes only refs/heads/<Name> on the selected configured remote,
        using its configured push URLs. It does not delete a local branch or just
        a remote-tracking ref. No upstream or remote-prefix inference is performed.
        Configured mirror pushes and automatic tag following are disabled.
        Git may accept deletion of an already absent remote ref as a no-op.
        -WhatIf and declined confirmation never execute a deletion or push.
    .PARAMETER Name
        Exact branch name, optionally prefixed with refs/heads/. Wildcards,
        revision expressions, other ref namespaces and option-like names are
        rejected. Accepts pipeline strings or objects with Name, BranchName or Branch.
    .PARAMETER Path
        Literal directory inside the repository. Defaults to the current location.
        Accepts object properties Path, RepositoryPath or RepoPath. Bare repositories
        are also supported. The caller's location is unchanged.
    .PARAMETER Force
        Permit deletion of an unmerged local branch. Cannot be combined with
        -Remote. Confirmation and worktree protections remain in effect.
    .PARAMETER Remote
        Delete the branch from a configured remote instead of the local repository.
    .PARAMETER RemoteName
        Configured remote name to use with -Remote. Defaults to origin. URLs and
        filesystem paths are not accepted in place of a configured remote name.
    .OUTPUTS
        None. Git failures are reported as PowerShell errors.
    .EXAMPLE
        Remove-Branch -Name feature/finished -WhatIf
        Preview deletion of a local branch.
    .EXAMPLE
        Remove-Branch -Name feature/abandoned -Force -Confirm:$false
        Delete an unmerged local branch without prompting.
    .EXAMPLE
        Remove-Branch -Name feature/finished -Remote -RemoteName upstream
        Confirm deletion of that branch on the configured upstream remote.
    .EXAMPLE
        'feature/one', 'feature/two' | Remove-Branch -Path ../project
        Confirm deletion of each named local branch in another repository.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Local')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('BranchName', 'Branch')]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Position = 1, ValueFromPipelineByPropertyName)]
        [Alias('RepositoryPath', 'RepoPath')]
        [string]$Path,

        [Parameter(ParameterSetName = 'Local')]
        [switch]$Force,

        [Parameter(Mandatory, ParameterSetName = 'Remote')]
        [switch]$Remote,

        [Parameter(ParameterSetName = 'Remote')]
        [ValidateNotNullOrEmpty()]
        [string]$RemoteName = 'origin'
    )

    process {
        $branchName = $Name
        if ($branchName.StartsWith('refs/heads/', [StringComparison]::Ordinal)) {
            $branchName = $branchName.Substring('refs/heads/'.Length)
        } elseif ($branchName.StartsWith('refs/', [StringComparison]::Ordinal)) {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                [ArgumentException]::new('Only branch names or refs/heads/ references are accepted.'),
                'GitBranchNameInvalid', [System.Management.Automation.ErrorCategory]::InvalidArgument, $Name))
            return
        }
        if (-not $branchName -or $branchName.StartsWith('-') -or $branchName -ceq 'HEAD') {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                [ArgumentException]::new("Invalid branch name: '$Name'."),
                'GitBranchNameInvalid', [System.Management.Automation.ErrorCategory]::InvalidArgument, $Name))
            return
        }
        if ($PSCmdlet.ParameterSetName -eq 'Remote' -and -not $Remote) {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                [ArgumentException]::new('Remote deletion requires -Remote; omit remote parameters for local deletion.'),
                'GitRemoteRequired', [System.Management.Automation.ErrorCategory]::InvalidArgument, $RemoteName))
            return
        }

        # A full ref cannot be parsed as an option or expand @{-1} like --branch.
        $reference = "refs/heads/$branchName"
        $validated = Invoke-Git -Path $Path -AllowBare -Arguments @('check-ref-format', $reference)
        if ($null -eq $validated) { return }
        $repositoryPath = $validated.RepositoryPath

        if ($Remote) {
            $remotes = Invoke-Git -Path $repositoryPath -AllowBare -Arguments @('remote')
            if ($null -eq $remotes) { return }
            if ($RemoteName.StartsWith('-') -or $RemoteName -cnotin ($remotes.StandardOutput -split '\r?\n')) {
                $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                    [ArgumentException]::new("Configured remote '$RemoteName' was not found in '$repositoryPath'."),
                    'GitRemoteNotFound', [System.Management.Automation.ErrorCategory]::ObjectNotFound, $RemoteName))
                return
            }
            $target = "$reference on remote '$RemoteName' in '$repositoryPath'"
            $action = 'Delete remote git branch'
            $arguments = @(
                '-c', "remote.$RemoteName.mirror=false",
                'push', '--delete', '--no-follow-tags', '--recurse-submodules=no', '--', $RemoteName, $reference
            )
        } else {
            $target = "$reference in '$repositoryPath'"
            $action = if ($Force) { 'Delete local git branch (allow unmerged)' } else { 'Delete merged local git branch' }
            $deleteOption = if ($Force) { '-D' } else { '-d' }
            $arguments = @('branch', $deleteOption, '--', $branchName)
        }

        if ($PSCmdlet.ShouldProcess($target, $action)) {
            $result = Invoke-Git -Path $repositoryPath -AllowBare -Arguments $arguments
            if ($null -eq $result) { return }
            if ($result.StandardOutput) { Write-Verbose $result.StandardOutput.TrimEnd() }
        }
    }
}
