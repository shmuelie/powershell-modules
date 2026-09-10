function Restore-Items {
    <#
    .SYNOPSIS
        Restore explicitly selected git working-tree paths.
    .DESCRIPTION
        By default, restores only the working tree from the index, discarding
        unstaged changes while preserving staged changes. With -IncludeIndex,
        restores both the index and working tree from HEAD. An explicit -Source
        overrides either default and must resolve to a tree (for example a commit,
        tag or tree ID). An invalid source is an error, never a fallback to HEAD.

        Uses git restore with literal path operands, not wildcard/pathspec
        expansion. A directory selects its tracked descendants recursively;
        explicitly passing '.' selects the current repository directory's tree.
        Selected tracked paths absent from the source can be removed, and local
        content at selected paths can be overwritten. Untracked-only paths absent
        from the source are not cleaned. Submodule working trees are not restored.
        Selected unmerged index entries are refused, even with -Source or
        -IncludeIndex; this command does not resolve conflicts.

        Confirmation is high impact. -WhatIf and declined confirmation perform
        only read-only validation. The caller's location is unchanged. Git errors
        are PowerShell errors; a failed multi-path restore can leave partial
        changes and is not automatically rolled back.
    .PARAMETER Files
        Required literal file or directory paths, relative to -Path (or the
        current directory), or absolute paths inside the working tree. Quote
        paths with spaces or PowerShell metacharacters. Each array element is a
        separate operand. Wildcards and Git pathspec magic are treated literally,
        never expanded. Empty paths and control characters are rejected.
    .PARAMETER Path
        Literal directory inside the working tree. Defaults to the current
        location. RepositoryPath and RepoPath are aliases; this is not a file list.
        Bare repositories are not supported.
    .PARAMETER Source
        Existing local tree-ish, such as HEAD~1, a tag, or a tree ID. Overrides
        the index default (working tree only) or HEAD default (-IncludeIndex).
        Option-like values and control characters are rejected. Does not fetch.
    .PARAMETER IncludeIndex
        Also overwrite staged changes. Restores both index and working tree from
        HEAD unless -Source is supplied. Does not bypass WhatIf or confirmation.
    .OUTPUTS
        None. Use -ErrorAction Stop to terminate on a git failure.
    .EXAMPLE
        Restore-Items -Files 'src/main.ps1', 'notes with spaces.txt' -WhatIf
        Preview discarding unstaged changes to exactly these paths.
    .EXAMPLE
        Restore-Items 'src/main.ps1' -IncludeIndex -Confirm:$false
        Discard staged and unstaged changes to this path, restoring it from HEAD.
    .EXAMPLE
        Restore-Items -Files 'src' -Source HEAD~1 -Path ../project
        Restore tracked paths under src from the previous commit, leaving the
        index unchanged and confirming before overwriting the working tree.
    .LINK
        https://git-scm.com/docs/git-restore
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', PositionalBinding = $false)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [ValidateCount(1, 2147483647)]
        [ValidateScript({
            -not [string]::IsNullOrWhiteSpace($_) -and $_ -notmatch '[\x00-\x1f\x7f]'
        }, ErrorMessage = 'Files must contain nonempty literal paths without control characters.')]
        [string[]]$Files,

        [Alias('RepositoryPath', 'RepoPath')]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [ValidateNotNullOrEmpty()]
        [ValidateScript({
            -not [string]::IsNullOrWhiteSpace($_) -and $_ -notmatch '^-|[\x00-\x1f\x7f]'
        }, ErrorMessage = 'Source must be a tree-ish, not an option or a value containing control characters.')]
        [string]$Source,

        [switch]$IncludeIndex
    )

    # Ambient pathspec settings must not make an explicitly named path a pattern.
    $environment = @{
        GIT_LITERAL_PATHSPECS = '1'
        GIT_GLOB_PATHSPECS = $null
        GIT_NOGLOB_PATHSPECS = $null
        GIT_ICASE_PATHSPECS = $null
        GIT_NO_LAZY_FETCH = '1'
        GIT_OPTIONAL_LOCKS = '0'
    }
    $literalFiles = @($Files | ForEach-Object {
        if ([IO.Path]::DirectorySeparatorChar -eq '\') { $_.Replace('\', '/') } else { $_ }
    })
    $unmerged = Invoke-Git -Path $Path -Environment $environment -Arguments (
        @('--literal-pathspecs', 'ls-files', '--unmerged', '-z', '--') + $literalFiles
    )
    if ($null -eq $unmerged) { return }
    $repositoryPath = $unmerged.RepositoryPath
    if ($unmerged.StandardOutput) {
        $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
            [InvalidOperationException]::new('Selected paths have unmerged index entries; resolve conflicts explicitly before restoring.'),
            'GitRestoreUnmergedPaths', [System.Management.Automation.ErrorCategory]::InvalidOperation, $Files))
        return
    }

    $arguments = @('--literal-pathspecs', 'restore', '--worktree', '--no-recurse-submodules')
    $sourceDescription = 'the index'
    if ($PSBoundParameters.ContainsKey('Source') -or $IncludeIndex) {
        $treeish = if ($PSBoundParameters.ContainsKey('Source')) { $Source } else { 'HEAD' }
        $resolvedSource = Invoke-Git -Path $repositoryPath -Environment $environment -Arguments @(
            'rev-parse', '--verify', '--end-of-options', "$treeish^{tree}"
        )
        if ($null -eq $resolvedSource) { return }
        $tree = $resolvedSource.StandardOutput.Trim()
        $arguments += "--source=$tree"
        $sourceDescription = "'$treeish' ($tree)"
    }
    $destination = 'working-tree paths'
    if ($IncludeIndex) {
        $arguments += '--staged'
        $destination = 'index and working-tree paths'
    }
    $arguments += @('--') + $literalFiles
    $target = "'$($Files -join "', '")' in '$repositoryPath'"
    if ($PSCmdlet.ShouldProcess($target, "Restore $destination from $sourceDescription")) {
        $null = Invoke-Git -Path $repositoryPath -Environment $environment -Arguments $arguments
    }
}
