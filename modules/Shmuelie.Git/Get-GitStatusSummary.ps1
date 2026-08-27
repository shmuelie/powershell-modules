function ConvertTo-NativeGitPath {
    param([AllowNull()][string]$Path)

    if ([System.IO.Path]::DirectorySeparatorChar -eq '\') {
        return $Path -replace '/', '\'
    }

    $Path
}

function Get-GitStatusSummary {
    <#
    .SYNOPSIS
        Get a summary of the current git repository status.
    .DESCRIPTION
        Parses 'git status --porcelain=v1 --branch' directly to produce a typed
        GitStatusSummary object with branch, upstream, ahead/behind counts,
        index/working file change counts, conflicts, untracked count, stash count,
        any in-progress operation (rebase/merge/cherry-pick/revert/bisect),
        repo name, relative path, and a formatted status string.

        Self-contained — no posh-git or external module dependency. Only requires
        the git CLI.
    .PARAMETER Path
        The directory to check. Defaults to the current location.
    .EXAMPLE
        Get-GitStatusSummary
        Returns git status summary for the current directory.
    .EXAMPLE
        (Get-GitStatusSummary).StatusString
        Returns just the formatted status string like [main ≡ +1 ~2 -0 | +0 ~1 -0].
    #>
    [OutputType('GitStatusSummary')]
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('RepositoryPath', 'RepoPath')]
        [string]$Path
    )

    process {
        $targetPath = if ($Path) {
            (Resolve-Path -LiteralPath $Path -ErrorAction Stop | Select-Object -First 1).ProviderPath
        } else {
            (Get-Location).ProviderPath
        }

        # Quick check: are we in a git repo?
        $null = git -C $targetPath rev-parse --is-inside-work-tree 2>$null
        if ($LASTEXITCODE -ne 0) {
            return [PSCustomObject]@{
                PSTypeName   = 'GitStatusSummary'
                IsGitRepo    = $false
                RepoName     = $null
                Branch       = $null
                Upstream     = $null
                WorktreePath = $null
                RelativePath = $null
                AheadBy      = 0
                BehindBy     = 0
                UpstreamGone = $false
                Operation    = $null
                IndexAdded    = 0
                IndexModified = 0
                IndexDeleted  = 0
                WorkingAdded    = 0
                WorkingModified = 0
                WorkingDeleted  = 0
                Conflicts    = 0
                Untracked    = 0
                StashCount   = 0
                HasChanges   = $false
                StatusString = $null
            }
        }

        # Parse git status
        $lines = git -C $targetPath status --porcelain=v1 --branch 2>$null
        $branch = $null; $upstream = $null; $ahead = 0; $behind = 0; $upstreamGone = $false
        $idxA = 0; $idxM = 0; $idxD = 0
        $wrkA = 0; $wrkM = 0; $wrkD = 0
        $untracked = 0; $conflicts = 0

        foreach ($line in $lines) {
            if ($line.StartsWith('## ')) {
                $branchLine = $line.Substring(3)
                if ($branchLine -match '^(.+?)\.\.\.(.+?)(?:\s+\[(.+)\])?$') {
                    $branch = $Matches[1]
                    $upstream = $Matches[2]
                    $trackInfo = $Matches[3]
                    if ($trackInfo) {
                        if ($trackInfo -match 'ahead (\d+)') { $ahead = [int]$Matches[1] }
                        if ($trackInfo -match 'behind (\d+)') { $behind = [int]$Matches[1] }
                        if ($trackInfo -match 'gone') { $upstreamGone = $true }
                    }
                } elseif ($branchLine -match '^(.+?)$') {
                    $branch = $branchLine.Trim()
                    if ($branch -eq 'HEAD (no branch)') { $branch = 'HEAD' }
                }
                continue
            }

            if ($line.Length -lt 2) { continue }
            $x = $line[0]
            $y = $line[1]

            # Untracked
            if ($x -eq '?' -and $y -eq '?') { $untracked++; continue }

            # Unmerged/conflicted (UU, AA, DD, AU, UA, DU, UD)
            if ($x -eq 'U' -or $y -eq 'U' -or ($x -eq 'A' -and $y -eq 'A') -or ($x -eq 'D' -and $y -eq 'D')) {
                $conflicts++; continue
            }

            # Index (staged) changes
            switch ($x) {
                'A' { $idxA++ }
                'M' { $idxM++ }
                'R' { $idxM++ }
                'C' { $idxA++ }
                'D' { $idxD++ }
            }

            # Working tree changes
            switch ($y) {
                'M' { $wrkM++ }
                'D' { $wrkD++ }
                'A' { $wrkA++ }
            }
        }

        # Worktree path. Git prints '/' separators even on Windows; normalize only
        # there so Unix paths are not corrupted by replacing path separators.
        $toplevel = ConvertTo-NativeGitPath (git -C $targetPath rev-parse --show-toplevel 2>$null)

        # Detect in-progress git operations via .git/ sentinel files
        $gitDir = ConvertTo-NativeGitPath (git -C $targetPath rev-parse --path-format=absolute --git-dir 2>$null)
        $operation = if ($gitDir) {
            $rebaseMergePath = Join-Path $gitDir 'rebase-merge'
            $rebaseApplyPath = Join-Path $gitDir 'rebase-apply'
            if (Test-Path -LiteralPath $rebaseMergePath) {
                $msgnumPath = Join-Path $rebaseMergePath 'msgnum'
                $endPath = Join-Path $rebaseMergePath 'end'
                $interactivePath = Join-Path $rebaseMergePath 'interactive'
                $step = if (Test-Path -LiteralPath $msgnumPath) { (Get-Content -LiteralPath $msgnumPath -Raw).Trim() }
                $total = if (Test-Path -LiteralPath $endPath) { (Get-Content -LiteralPath $endPath -Raw).Trim() }
                $type = if (Test-Path -LiteralPath $interactivePath) { 'REBASE-i' } else { 'REBASE-m' }
                if ($step -and $total) { "$type $step/$total" } else { $type }
            }
            elseif (Test-Path -LiteralPath $rebaseApplyPath) {
                $nextPath = Join-Path $rebaseApplyPath 'next'
                $lastPath = Join-Path $rebaseApplyPath 'last'
                $rebasingPath = Join-Path $rebaseApplyPath 'rebasing'
                $applyingPath = Join-Path $rebaseApplyPath 'applying'
                $step = if (Test-Path -LiteralPath $nextPath) { (Get-Content -LiteralPath $nextPath -Raw).Trim() }
                $total = if (Test-Path -LiteralPath $lastPath) { (Get-Content -LiteralPath $lastPath -Raw).Trim() }
                $type = if (Test-Path -LiteralPath $rebasingPath) { 'REBASE' }
                    elseif (Test-Path -LiteralPath $applyingPath) { 'AM' }
                    else { 'AM/REBASE' }
                if ($step -and $total) { "$type $step/$total" } else { $type }
            }
            elseif (Test-Path -LiteralPath (Join-Path $gitDir 'MERGE_HEAD')) { 'MERGING' }
            elseif (Test-Path -LiteralPath (Join-Path $gitDir 'REVERT_HEAD')) { 'REVERTING' }
            elseif (Test-Path -LiteralPath (Join-Path $gitDir 'CHERRY_PICK_HEAD')) { 'CHERRY-PICKING' }
            elseif (Test-Path -LiteralPath (Join-Path $gitDir 'BISECT_LOG')) { 'BISECTING' }
        }

        # Repo name from remote URL or directory name
        $remoteUrl = git -C $targetPath remote get-url origin 2>$null
        $repoName = if ($remoteUrl) {
            ($remoteUrl.Substring($remoteUrl.LastIndexOf('/') + 1)) -replace '\.git$', ''
        } elseif ($toplevel) {
            Split-Path $toplevel -Leaf
        } else {
            ''
        }

        # Stash count
        $stashCount = 0
        $stashOutput = git -C $targetPath rev-list --walk-reflogs --count refs/stash 2>$null
        if ($LASTEXITCODE -eq 0 -and $stashOutput) { $stashCount = [int]$stashOutput }

        # Relative path from worktree root
        $currentPath = $targetPath
        $relativePath = ''
        if ($toplevel -and $currentPath.StartsWith($toplevel, [System.StringComparison]::OrdinalIgnoreCase)) {
            $relativePath = $currentPath.Substring($toplevel.Length)
        }

        # Relation indicator
        $relation = if ($ahead -gt 0 -and $behind -gt 0) {
            "↓${behind} ↑${ahead}"
        } elseif ($ahead -gt 0) {
            "↑$ahead"
        } elseif ($behind -gt 0) {
            "↓$behind"
        } elseif ($upstreamGone) {
            '×'
        } elseif ($upstream) {
            '≡'
        } else {
            ''
        }

        # Build status string: [branch|OP ≡ +A ~M -D | +A ~M -D !C ?U] (S)
        $hasIndex = ($idxA + $idxM + $idxD) -gt 0
        $hasWorking = ($wrkA + $wrkM + $wrkD) -gt 0
        $hasUntracked = $untracked -gt 0
        $hasConflicts = $conflicts -gt 0

        $sb = [System.Text.StringBuilder]::new('[')
        [void]$sb.Append($branch)
        if ($operation) { [void]$sb.Append("|$operation") }
        if ($relation) { [void]$sb.Append(" $relation") }

        if ($hasIndex) {
            [void]$sb.Append(" +$idxA ~$idxM -$idxD")
        }
        if ($hasIndex -or $hasWorking) {
            [void]$sb.Append(' |')
        }
        if ($hasWorking) {
            [void]$sb.Append(" +$wrkA ~$wrkM -$wrkD")
        }
        if ($hasConflicts) {
            [void]$sb.Append(" !$conflicts")
        }
        if ($hasUntracked) {
            [void]$sb.Append(' ?')
        }

        [void]$sb.Append(']')

        [PSCustomObject]@{
            PSTypeName      = 'GitStatusSummary'
            IsGitRepo       = $true
            RepoName        = $repoName
            Branch          = $branch
            Upstream        = $upstream
            WorktreePath    = $toplevel
            RelativePath    = $relativePath
            AheadBy         = $ahead
            BehindBy        = $behind
            UpstreamGone    = $upstreamGone
            Operation       = $operation
            IndexAdded      = $idxA
            IndexModified   = $idxM
            IndexDeleted    = $idxD
            WorkingAdded    = $wrkA
            WorkingModified = $wrkM
            WorkingDeleted  = $wrkD
            Conflicts       = $conflicts
            Untracked       = $untracked
            StashCount      = $stashCount
            HasChanges      = ($hasIndex -or $hasWorking -or $hasUntracked -or $hasConflicts)
            StatusString    = $sb.ToString()
        }
    }
}
