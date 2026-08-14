function ConvertTo-RepositoryLayoutPathFragment {
    <#
    .SYNOPSIS
        Convert a git path fragment to a native file-system path fragment.
    .DESCRIPTION
        Git branch names use '/' to separate nested ref segments. Repository
        layout paths should use the current platform's directory separator.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    [System.IO.Path]::Combine([string[]]($Path -split '/'))
}

function Test-RepositoryLayoutPathContains {
    <#
    .SYNOPSIS
        Test whether a path is equal to or under another path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ReferencePath,

        [Parameter(Mandatory)]
        [string]$CandidatePath
    )

    $separator = [System.IO.Path]::DirectorySeparatorChar
    $normalizedRef = ([System.IO.Path]::GetFullPath($ReferencePath)).TrimEnd($separator)
    $normalizedCandidate = [System.IO.Path]::GetFullPath($CandidatePath)

    $normalizedCandidate.Equals($normalizedRef, [StringComparison]::OrdinalIgnoreCase) -or
        $normalizedCandidate.StartsWith("$normalizedRef$separator", [StringComparison]::OrdinalIgnoreCase)
}

function Repair-RepositoryLayout {
    <#
    .SYNOPSIS
    Conform git repositories to the New-Repository layout (`<org>/<repo>/<branch>`).
    .DESCRIPTION
    Scans repositories under the repos root and moves any that don't follow the
    standard `<root>/<org>/<repo>/<branch>` layout into place, where the branch
    directory mirrors the checked-out branch (with '/' as nested subdirectories,
    using the platform's directory separator).

    Handles three non-conforming categories:
    - **git-at-repo-level**: a clone sitting directly at `<org>/<repo>` is moved
      down into a `<branch>` subdirectory.
    - **leaf-not-branch**: a working tree whose directory name doesn't match its
      checked-out branch is renamed (via `git worktree move` for linked worktrees,
      or a plain move for a standalone main clone with no dependent worktrees).
    - **detached / no-git**: reported only, never modified.

    Returns a RepositoryLayoutResult object per repository describing the action.
    Use -WhatIf to preview the full From->To plan without moving anything.
    .PARAMETER Root
    The repos root to scan. Defaults to $env:SOURCE_REPOS. Fails if neither is set.
    .PARAMETER Organization
    Optional organization-folder filter(s). Supports wildcards.
    .PARAMETER Name
    Optional repository-name filter(s). Supports wildcards.
    .EXAMPLE
    Repair-RepositoryLayout -WhatIf
    Previews the From->To plan for every repository without making changes.
    .EXAMPLE
    Repair-RepositoryLayout -Organization contoso -Name Platform.*
    Conforms only contoso/Platform.* repositories (prompting before each move).
    .EXAMPLE
    Repair-RepositoryLayout | Where-Object Status -like 'Skipped*'
    Lists repositories that were skipped (detached HEAD, no .git, or unsafe to move).
    #>
    [OutputType('RepositoryLayoutResult')]
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [string]$Root,

        [string[]]$Organization,

        [string[]]$Name
    )

    if (-not $Root) { $Root = $env:SOURCE_REPOS }
    if (-not $Root) {
        Write-Error 'No repository root specified. Pass -Root or set $env:SOURCE_REPOS.'
        return
    }
    if (-not (Test-Path $Root)) {
        Write-Error "Repos root not found: $Root"
        return
    }

    $cwd = (Get-Location).Path
    $separator = [System.IO.Path]::DirectorySeparatorChar
    $gitDirectorySegmentPattern = [regex]::Escape("$separator.git$separator")

    function New-Result {
        <#
        .SYNOPSIS
            Build a RepositoryLayoutResult object describing one repository's outcome.
        .PARAMETER Repo
            The repository path or identifier.
        .PARAMETER Category
            The non-conforming category (git-at-repo-level, leaf-not-branch, detached/no-git).
        .PARAMETER Action
            The action taken or planned (e.g. Move, Rename, None).
        .PARAMETER From
            The original path, when a move/rename applies.
        .PARAMETER To
            The destination path, when a move/rename applies.
        .PARAMETER Status
            The result status (e.g. Moved, Skipped, WhatIf, Reported).
        #>
        param($Repo, $Category, $Action, $From, $To, $Status)
        [PSCustomObject]@{
            PSTypeName = 'RepositoryLayoutResult'
            Repo       = $Repo
            Category   = $Category
            Action     = $Action
            From       = $From
            To         = $To
            Status     = $Status
        }
    }

    foreach ($org in Get-ChildItem $Root -Directory) {
        if ($Organization -and -not ($Organization | Where-Object { $org.Name -like $_ })) { continue }

        foreach ($repo in Get-ChildItem $org.FullName -Directory) {
            if ($Name -and -not ($Name | Where-Object { $repo.Name -like $_ })) { continue }

            $repoRel = "$($org.Name)/$($repo.Name)"

            # --- Category 1: .git directly at repo level (no branch dir) ---
            if (Test-Path (Join-Path $repo.FullName '.git')) {
                $branch = (git -C $repo.FullName rev-parse --abbrev-ref HEAD 2>$null)
                if (-not $branch -or $branch -eq 'HEAD') {
                    New-Result $repoRel 'git-at-repo-level' 'none' $repo.FullName '' 'Skipped-Detached'
                    continue
                }
                # Guard: don't move a repo we're sitting inside
                if (Test-RepositoryLayoutPathContains -ReferencePath $repo.FullName -CandidatePath $cwd) {
                    New-Result $repoRel 'git-at-repo-level' 'none' $repo.FullName '' 'Skipped-CwdInside'
                    continue
                }
                # Guard: multiple worktrees at repo level => complex, skip
                $wtCount = @(git -C $repo.FullName worktree list 2>$null).Count
                if ($wtCount -gt 1) {
                    New-Result $repoRel 'git-at-repo-level' 'none' $repo.FullName '' 'Skipped-HasWorktrees'
                    continue
                }

                $branchDir = ConvertTo-RepositoryLayoutPathFragment $branch
                $target = Join-Path $repo.FullName $branchDir

                if ($PSCmdlet.ShouldProcess($repo.FullName, "Move clone into '$branchDir' subdirectory")) {
                    try {
                        $tmp = Join-Path $org.FullName ("{0}__layout_tmp_{1}" -f $repo.Name, [guid]::NewGuid().ToString('N').Substring(0, 8))
                        Move-Item -LiteralPath $repo.FullName -Destination $tmp -ErrorAction Stop
                        # Recreate the repo dir and any multi-segment parent dirs
                        $targetParent = Split-Path $target -Parent
                        if (-not (Test-Path $targetParent)) {
                            New-Item -ItemType Directory -Path $targetParent -Force | Out-Null
                        }
                        Move-Item -LiteralPath $tmp -Destination $target -ErrorAction Stop
                        New-Result $repoRel 'git-at-repo-level' 'moved' $repo.FullName $target 'Converted'
                    } catch {
                        New-Result $repoRel 'git-at-repo-level' 'move-failed' $repo.FullName $target "Error: $($_.Exception.Message)"
                    }
                } else {
                    New-Result $repoRel 'git-at-repo-level' 'would-move' $repo.FullName $target 'WhatIf'
                }
                continue
            }

            # --- Category 2/3: branch-level working trees ---
            $gitItems = Get-ChildItem $repo.FullName -Force -Recurse -Depth 4 -Filter '.git' -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch $gitDirectorySegmentPattern }

            if (-not $gitItems) {
                New-Result $repoRel 'no-git' 'none' $repo.FullName '' 'Skipped-NoGit'
                continue
            }

            foreach ($g in $gitItems) {
                $wt = Split-Path $g.FullName -Parent
                if (-not $wt) { continue }
                # Skip submodules — a non-empty superproject means this working tree
                # belongs to a parent repo's submodule, not a worktree of this repo.
                $super = (git -C $wt rev-parse --show-superproject-working-tree 2>$null)
                if ($super) {
                    New-Result $repoRel 'submodule' 'none' $wt '' 'Skipped-Submodule'
                    continue
                }
                # Skip foreign nested clones — the git common dir must resolve under this repo.
                $commonDir = (git -C $wt rev-parse --git-common-dir 2>$null)
                if ($commonDir) {
                    $commonFull = $commonDir
                    if (-not [System.IO.Path]::IsPathRooted($commonFull)) {
                        $commonFull = Join-Path $wt $commonDir
                    }
                    try { $commonFull = (Resolve-Path -LiteralPath $commonFull -ErrorAction Stop).Path } catch { }
                    if (-not (Test-RepositoryLayoutPathContains -ReferencePath $repo.FullName -CandidatePath $commonFull)) {
                        New-Result $repoRel 'foreign-nested' 'none' $wt '' 'Skipped-ForeignClone'
                        continue
                    }
                }
                $rel = $wt.Substring($repo.FullName.Length).TrimStart($separator)
                $branch = (git -C $wt rev-parse --abbrev-ref HEAD 2>$null)
                if (-not $branch -or $branch -eq 'HEAD') {
                    New-Result $repoRel 'detached' 'none' $wt '' 'Skipped-Detached'
                    continue
                }
                $branchDir = ConvertTo-RepositoryLayoutPathFragment $branch
                if ($rel -eq $branchDir) { continue }   # conforms

                $target = Join-Path $repo.FullName $branchDir
                # Is this a linked worktree (.git is a file) or a main clone (.git is a dir)?
                $isLinkedWorktree = -not $g.PSIsContainer

                if (Test-RepositoryLayoutPathContains -ReferencePath $wt -CandidatePath $cwd) {
                    New-Result $repoRel 'leaf-not-branch' 'none' $wt $target 'Skipped-CwdInside'
                    continue
                }

                if ($isLinkedWorktree) {
                    if ($PSCmdlet.ShouldProcess($wt, "git worktree move -> '$branchDir'")) {
                        try {
                            $targetParent = Split-Path $target -Parent
                            if (-not (Test-Path $targetParent)) { New-Item -ItemType Directory -Path $targetParent -Force | Out-Null }
                            git -C $wt worktree move $wt $target 2>&1 | Out-Null
                            if ($LASTEXITCODE -eq 0) {
                                New-Result $repoRel 'leaf-not-branch' 'worktree-move' $wt $target 'Converted'
                            } else {
                                New-Result $repoRel 'leaf-not-branch' 'worktree-move-failed' $wt $target "git exit $LASTEXITCODE"
                            }
                        } catch {
                            New-Result $repoRel 'leaf-not-branch' 'worktree-move-failed' $wt $target "Error: $($_.Exception.Message)"
                        }
                    } else {
                        New-Result $repoRel 'leaf-not-branch' 'would-worktree-move' $wt $target 'WhatIf'
                    }
                } else {
                    # Main clone: only safe to rename if it has no dependent worktrees
                    $wtCount = @(git -C $wt worktree list 2>$null).Count
                    if ($wtCount -gt 1) {
                        New-Result $repoRel 'leaf-not-branch' 'none' $wt $target 'Skipped-HasWorktrees'
                        continue
                    }
                    if ($PSCmdlet.ShouldProcess($wt, "Rename main clone dir -> '$branchDir'")) {
                        try {
                            $targetParent = Split-Path $target -Parent
                            if (-not (Test-Path $targetParent)) { New-Item -ItemType Directory -Path $targetParent -Force | Out-Null }
                            Move-Item -LiteralPath $wt -Destination $target -ErrorAction Stop
                            New-Result $repoRel 'leaf-not-branch' 'renamed' $wt $target 'Converted'
                        } catch {
                            New-Result $repoRel 'leaf-not-branch' 'rename-failed' $wt $target "Error: $($_.Exception.Message)"
                        }
                    } else {
                        New-Result $repoRel 'leaf-not-branch' 'would-rename' $wt $target 'WhatIf'
                    }
                }
            }
        }
    }
}
