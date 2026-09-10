function Get-Branch {
    <#
    .SYNOPSIS
    List local and remote-tracking branches with tracking information.
    .DESCRIPTION
    Reads refs with git for-each-ref and returns GitBranch objects. By default,
    includes local branches and locally stored remote-tracking refs, including
    symbolic refs such as origin/HEAD. Never fetches or contacts a remote.
    Implicit partial-clone fetches are disabled; unavailable promised objects
    surface as git errors.

    Branch is the name below refs/heads/ or refs/remotes/. RefName, Upstream and
    SymbolicTarget retain full ref names to distinguish otherwise ambiguous
    local and remote names. Current identifies the branch named by HEAD in the
    selected repository or worktree, not other branches sharing its commit.

    AheadBy and BehindBy count commits relative to the configured upstream using
    the locally available history. Both are null without an upstream or when
    that upstream is gone; UpstreamGone distinguishes these cases. Empty string
    ref metadata is exposed as null. A detached HEAD marks no branch Current.
    An unborn branch has no ref yet and produces no row.
    .PARAMETER Path
    Literal directory inside the git working tree, or a bare repository.
    Defaults to the current location. Accepts pipeline paths or objects with a
    Path, RepositoryPath or RepoPath property. Does not change location.
    .PARAMETER Local
    Include local branches only, unless Remote is also specified.
    .PARAMETER Remote
    Include remote-tracking refs only, unless Local is also specified. These
    are cached refs in this repository, not a live query of any remote.
    .OUTPUTS
    GitBranch
    Branch, RefName, Current, Commit, Upstream, AheadBy, BehindBy, UpstreamGone,
    SymbolicTarget, IsRemote, Subject and RepositoryPath.
    .EXAMPLE
    Get-Branch
    Lists local and remote-tracking branches for the current repository.
    .EXAMPLE
    Get-Branch -Path ../project -Local
    Lists local branches for another repository without changing location.
    .EXAMPLE
    Get-Worktrees | Get-Branch -Local | Where-Object Current
    Gets each worktree's current branch with its repository context.
    #>
    [OutputType('GitBranch')]
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('RepositoryPath', 'RepoPath')]
        [string]$Path,

        [switch]$Local,

        [switch]$Remote
    )

    process {
        $gitEnvironment = @{ GIT_NO_LAZY_FETCH = '1' }
        $refPrefixes = @(
            if ($Local -or -not $Remote) { 'refs/heads/' }
            if ($Remote -or -not $Local) { 'refs/remotes/' }
        )
        $format = '%(refname)%00%(HEAD)%00%(objectname)%00%(upstream)%00%(symref)%00%(subject)%00'
        $refs = Invoke-Git -Path $Path -AllowBare -Environment $gitEnvironment -Arguments (
            @('for-each-ref', '--sort=refname', "--format=$format", '--') + $refPrefixes
        )
        if (-not $refs -or -not $refs.StandardOutput) { return }

        $repoPath = $refs.RepositoryPath
        $entries = [System.Collections.Generic.List[object]]::new()
        # Each record has six NUL-terminated fields followed by git's newline.
        # Do not split records on newlines or trim user-controlled subjects.
        $fields = $refs.StandardOutput.Split([char]0)
        if ($fields.Count % 6 -ne 1 -or $fields[-1] -notin @("`n", "`r`n")) {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                [System.FormatException]::new("Invalid branch ref output from git in '$repoPath'."),
                'InvalidGitBranchOutput', [System.Management.Automation.ErrorCategory]::InvalidData, $refs))
            return
        }

        for ($index = 0; $index -lt $fields.Count - 1; $index += 6) {
            $refName = if ($index -eq 0) { $fields[$index] } else { $fields[$index] -replace '\A\r?\n', '' }
            $isRemote = $refName.StartsWith('refs/remotes/', [System.StringComparison]::Ordinal)
            $prefix = if ($isRemote) { 'refs/remotes/' } else { 'refs/heads/' }
            if (-not $refName.StartsWith($prefix, [System.StringComparison]::Ordinal) -or
                $refName.Length -eq $prefix.Length -or
                $fields[$index + 1] -notin @(' ', '*') -or
                $fields[$index + 2] -cnotmatch '\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z') {
                $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                    [System.FormatException]::new("Invalid branch ref record from git in '$repoPath'."),
                    'InvalidGitBranchOutput', [System.Management.Automation.ErrorCategory]::InvalidData, $refs))
                return
            }

            $entries.Add([PSCustomObject]@{
                PSTypeName     = 'GitBranch'
                Branch         = $refName.Substring($prefix.Length)
                RefName        = $refName
                Current        = $fields[$index + 1] -ceq '*'
                Commit         = $fields[$index + 2]
                Upstream       = if ($fields[$index + 3]) { $fields[$index + 3] } else { $null }
                AheadBy        = $null
                BehindBy       = $null
                UpstreamGone   = $false
                SymbolicTarget = if ($fields[$index + 4]) { $fields[$index + 4] } else { $null }
                IsRemote       = $isRemote
                Subject        = $fields[$index + 5]
                RepositoryPath = $repoPath
            })
        }

        $upstreamRefs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($entry in $entries) {
            if ($entry.Upstream) { $null = $upstreamRefs.Add($entry.Upstream) }
        }
        if ($upstreamRefs.Count -gt 0) {
            $upstreams = Invoke-Git -Path $repoPath -AllowBare -Environment $gitEnvironment -Arguments (
                @('for-each-ref', '--format=%(refname)%00%(objectname)', '--') + @($upstreamRefs)
            )
            if (-not $upstreams) { return }

            $upstreamCommits = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
            foreach ($line in ($upstreams.StandardOutput -split '\r?\n')) {
                if (-not $line) { continue }
                $parts = $line.Split([char]0)
                if ($parts.Count -ne 2 -or $parts[1] -cnotmatch '\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z') {
                    $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                        [System.FormatException]::new("Invalid upstream ref output from git in '$repoPath'."),
                        'InvalidGitBranchOutput', [System.Management.Automation.ErrorCategory]::InvalidData, $upstreams))
                    return
                }
                # for-each-ref patterns also match descendants; require an exact,
                # case-sensitive ref match before treating an upstream as present.
                if ($upstreamRefs.Contains($parts[0])) { $upstreamCommits[$parts[0]] = $parts[1] }
            }

            foreach ($entry in $entries) {
                if (-not $entry.Upstream) { continue }
                if (-not $upstreamCommits.ContainsKey($entry.Upstream)) {
                    $entry.UpstreamGone = $true
                    continue
                }

                $counts = Invoke-Git -Path $repoPath -AllowBare -Environment $gitEnvironment -Arguments @(
                    'rev-list', '--left-right', '--count',
                    "$($entry.Commit)...$($upstreamCommits[$entry.Upstream])", '--'
                )
                if (-not $counts) { return }
                if ($counts.StandardOutput -cnotmatch '\A([0-9]+)\t([0-9]+)\r?\n?\z') {
                    $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                        [System.FormatException]::new("Invalid tracking counts from git in '$repoPath'."),
                        'InvalidGitBranchOutput', [System.Management.Automation.ErrorCategory]::InvalidData, $counts))
                    return
                }
                $entry.AheadBy = [long]$Matches[1]
                $entry.BehindBy = [long]$Matches[2]
            }
        }

        $entries
    }
}
