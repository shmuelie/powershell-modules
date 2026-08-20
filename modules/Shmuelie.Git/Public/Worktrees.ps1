function Get-Worktrees {
    <#
    .SYNOPSIS
    Get all worktrees for the current repository.
    .DESCRIPTION
    Parses the output of 'git worktree list --porcelain' and returns objects
    with Path, Commit, and Branch properties, plus the remaining porcelain
    state: Bare, Detached, Locked/LockReason, and Prunable/PrunableReason. The
    boolean state fields are always present (defaulting to $false) and the
    reason fields default to an empty string.
    .EXAMPLE
    Get-Worktrees
    Returns all worktrees for the current repository.
    .EXAMPLE
    Get-Worktrees | Where-Object Prunable
    Returns worktrees whose working directory is gone and can be pruned.
    #>
    [OutputType('Worktree')]
    [CmdletBinding()]
    param()

    $lines = git worktree list --porcelain
    $newEntry = {
        @{
            PSTypeName     = 'Worktree'
            Bare           = $false
            Detached       = $false
            Locked         = $false
            LockReason     = ''
            Prunable       = $false
            PrunableReason = ''
        }
    }
    $entry = & $newEntry
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            if ($entry.ContainsKey('Path')) {
                [PSCustomObject]$entry
                $entry = & $newEntry
            }
            continue
        }
        if ($line.StartsWith('worktree ')) {
            $rawPath = $line -replace '^worktree '
            # git lists worktrees whose directory was deleted manually; keep the
            # git-reported path when it no longer resolves rather than storing $null.
            $resolved = Resolve-Path -LiteralPath $rawPath -ErrorAction SilentlyContinue
            $entry['Path'] = if ($resolved) { $resolved.Path } else { $rawPath }
        } elseif ($line.StartsWith('HEAD ')) {
            $entry['Commit'] = $line -replace '^HEAD '
        } elseif ($line.StartsWith('branch refs/heads/')) {
            $entry['Branch'] = $line -replace '^branch refs/heads/'
        } elseif ($line -eq 'detached') {
            $entry['Branch'] = '(detached)'
            $entry['Detached'] = $true
        } elseif ($line -eq 'bare') {
            $entry['Bare'] = $true
        } elseif ($line -eq 'locked' -or $line.StartsWith('locked ')) {
            $entry['Locked'] = $true
            if ($line.Length -gt 'locked '.Length) {
                $entry['LockReason'] = $line.Substring('locked '.Length).Trim()
            }
        } elseif ($line -eq 'prunable' -or $line.StartsWith('prunable ')) {
            $entry['Prunable'] = $true
            if ($line.Length -gt 'prunable '.Length) {
                $entry['PrunableReason'] = $line.Substring('prunable '.Length).Trim()
            }
        }
    }
    # Emit the last entry
    if ($entry.ContainsKey('Path')) {
        [PSCustomObject]$entry
    }
}

function Test-PathContains {
    <#
    .SYNOPSIS
    Test if a reference path contains a candidate path.
    .DESCRIPTION
    Returns true if the candidate path is equal to or a child of the reference path.
    .PARAMETER ReferencePath
    The parent path to test against.
    .PARAMETER CandidatePath
    The path to check.
    .EXAMPLE
    Test-PathContains -ReferencePath 'C:\repos' -CandidatePath 'C:\repos\project'
    Returns $true because the candidate is a child of the reference.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ReferencePath,
        [Parameter(Mandatory)]
        [string]$CandidatePath
    )

    $separator = [IO.Path]::DirectorySeparatorChar
    $normalizedRef = ([IO.Path]::GetFullPath($ReferencePath)).TrimEnd($separator)
    $normalizedCand = [IO.Path]::GetFullPath($CandidatePath)
    $normalizedCand.Equals($normalizedRef, [System.StringComparison]::OrdinalIgnoreCase) -or
        $normalizedCand.StartsWith("$normalizedRef$separator", [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-CurrentWorktree {
    <#
    .SYNOPSIS
    Get the worktree that contains the current directory.
    .DESCRIPTION
    Returns the worktree whose path is equal to or a parent of the current working directory.
    .EXAMPLE
    Get-CurrentWorktree
    Returns the worktree object for the current location.
    #>
    [CmdletBinding()]
    param()

    $currentPath = (Get-Location).Path
    Get-Worktrees | Where-Object {
        Test-PathContains -ReferencePath $_.Path -CandidatePath $currentPath
    }
}

function Get-RepositoryName {
    <#
    .SYNOPSIS
    Get the name of the current git repository.
    .DESCRIPTION
    Extracts the repository name from the origin remote URL, stripping any trailing .git suffix.
    .EXAMPLE
    Get-RepositoryName
    Returns the repository name, e.g. 'MyRepo'.
    #>
    [CmdletBinding()]
    param()

    git remote get-url origin | ForEach-Object { 
        $_.SubString($_.LastIndexOf('/') + 1) -replace '\.git$',''
    }
}

function Get-RootWorktree {
    <#
    .SYNOPSIS
    Get the root (main) worktree for the current repository.
    .DESCRIPTION
    Resolves Git's common directory from any repository subdirectory, then matches
    its parent directory against the worktree list.
    .EXAMPLE
    Get-RootWorktree
    Returns the worktree object for the root of the repository.
    #>
    [CmdletBinding()]
    param()

    $commonDir = git rev-parse --path-format=absolute --git-common-dir 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $commonDir) {
        Write-Error 'Not in a git repository.'
        return
    }

    $rootPath = [IO.Path]::GetFullPath((Split-Path $commonDir -Parent))

    Get-Worktrees | Where-Object {
        [IO.Path]::GetFullPath("$($_.Path)").Equals($rootPath, [System.StringComparison]::OrdinalIgnoreCase)
    }
}

# Validate-set generator that supplies the current repo's worktree branch names
# for tab-completion / -ValidateSet on worktree parameters.
Class WorktreeSetValuesGenerator : System.Management.Automation.IValidateSetValuesGenerator {
    [string[]] GetValidValues() {
        <#
        .SYNOPSIS
            Return the branch name of every branch-backed worktree in the current
            repository, used to supply -ValidateSet/tab-completion values for
            worktree parameters. Detached worktrees are path-addressed because
            they all share the ambiguous '(detached)' branch label.
        #>
        return [string[]](
            Get-Worktrees |
                Where-Object { -not $_.Detached -and $_.Branch } |
                Select-Object -ExpandProperty Branch -Unique
        )
    }
}

function Get-WorktreePath {
    <#
    .SYNOPSIS
    Get the file system path for a worktree by branch name.
    .DESCRIPTION
    Constructs the worktree path from the repository container and branch name.
    .PARAMETER BranchName
    The branch name to resolve to a worktree path.
    .EXAMPLE
    Get-WorktreePath -BranchName feature/my-feature
    Returns the expected worktree path for the given branch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BranchName
    )

    $root = Get-RootWorktree | Select-Object -First 1
    if (-not $root) { return }

    $separator = [IO.Path]::DirectorySeparatorChar
    $rootPath = [IO.Path]::GetFullPath("$($root.Path)").TrimEnd($separator)
    $branchPath = ($root.Branch -replace '[/\\]', $separator).Trim($separator)
    $branchSuffix = "$separator$branchPath"
    $container = if ($rootPath.EndsWith($branchSuffix, [System.StringComparison]::OrdinalIgnoreCase)) {
        $rootPath.Substring(0, $rootPath.Length - $branchSuffix.Length)
    } else {
        Split-Path $rootPath -Parent
    }

    Join-Path $container $BranchName
}

function Add-Worktree {
    <#
    .SYNOPSIS
    Checkout an existing branch to a worktree
    .PARAMETER BranchName
    Name of the branch
    .PARAMETER SetLocation
    Whether to change the current directory to the new worktree
    .EXAMPLE
    Add-Worktree -BranchName feature/my-feature -SetLocation
    Checks out the existing branch to a new worktree and navigates to it.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$BranchName,
        [switch]$SetLocation = $false
    )
    process {
        $worktreePath = Get-WorktreePath -BranchName $BranchName
        if ($PSCmdlet.ShouldProcess($worktreePath, "Add worktree for branch '$BranchName'")) {
            git worktree add $worktreePath $BranchName
            if (($LASTEXITCODE -eq 0) -and $SetLocation) {
                Set-Location -Path $worktreePath
            }
        }
    }
}

function Get-GitBranchUser {
    [CmdletBinding()]
    param()

    $candidate = $env:GITHUB_USER
    if (-not $candidate) {
        $email = git config --get user.email 2>$null
        if ($email -match '^([^@]+)@') {
            $candidate = $Matches[1]
        }
    }
    if (-not $candidate) {
        $candidate = $env:USERNAME ?? $env:USER
    }

    $candidate = ($candidate -replace '[^A-Za-z0-9._-]', '-').Trim('-')
    if (-not $candidate) {
        throw 'Could not determine a branch user name. Set GITHUB_USER or configure git user.email.'
    }
    $candidate
}

function New-Worktree {
    <#
    .SYNOPSIS
    Create a new branch, checked out to a worktree.
    .DESCRIPTION
    Creates a new branch with a conventional prefix and checks it out to a worktree.
    The default kind is 'user', which produces user/<user>/<name>. The user
    segment comes from -UserName, GITHUB_USER, git user.email, or the OS user.
    .PARAMETER WorkName
    Name of the branch, without the kind prefix.
    .PARAMETER Kind
    The branch kind prefix. Defaults to 'user'.
    .PARAMETER UserName
    User segment for user branches. Defaults to the current Git or OS identity.
    .PARAMETER NoPrefix
    Use WorkName as the branch name verbatim, without the kind prefix
    (e.g. checking out an existing branch like 'main' or 'master').
    .PARAMETER SetLocation
    Whether to change the current directory to the new worktree.
    .EXAMPLE
    New-Worktree -WorkName my-feature -SetLocation
    Creates branch user/<user>/my-feature in a worktree and navigates to it.
    .EXAMPLE
    New-Worktree -WorkName search-improvements -Kind feature
    Creates branch feature/search-improvements in a worktree.
    .EXAMPLE
    New-Worktree -WorkName 2025.04 -Kind release -SetLocation
    Creates branch release/2025.04 in a worktree and navigates to it.
    .EXAMPLE
    New-Worktree -WorkName main -NoPrefix -SetLocation
    Creates a worktree for a branch named exactly 'main' with no kind prefix.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$WorkName,

        [Parameter(Position = 1)]
        [ValidateSet('user', 'feature', 'release')]
        [string]$Kind = 'user',

        [string]$UserName,

        [switch]$NoPrefix,

        [switch]$SetLocation = $false
    )
    process {
        $branchName = if ($NoPrefix) {
            $WorkName
        } else {
            switch ($Kind) {
                'user'    {
                    $branchUser = if ($UserName) { $UserName } else { Get-GitBranchUser }
                    "user/$branchUser/$WorkName"
                }
                'feature' { "feature/$WorkName" }
                'release' { "release/$WorkName" }
            }
        }
        $worktreePath = Get-WorktreePath -BranchName $branchName
        if ($PSCmdlet.ShouldProcess($worktreePath, "Create worktree for new branch '$branchName'")) {
            git worktree add -b $branchName $worktreePath
            if (($LASTEXITCODE -eq 0) -and $SetLocation) {
                Set-Location -Path $worktreePath
            }
        }
    }
}

function ConvertTo-ComparableWorktreePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue | Select-Object -First 1
    $fullPath = if ($resolved) {
        $resolved.ProviderPath
    } else {
        [IO.Path]::GetFullPath($Path)
    }

    $root = [IO.Path]::GetPathRoot($fullPath)
    if ($fullPath.Length -le $root.Length) {
        return $fullPath
    }

    $fullPath.TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
}

function Test-WorktreePathEquals {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Left,

        [Parameter(Mandatory)]
        [string]$Right
    )

    $comparison = if ([IO.Path]::DirectorySeparatorChar -eq '\') {
        [System.StringComparison]::OrdinalIgnoreCase
    } else {
        [System.StringComparison]::Ordinal
    }

    (ConvertTo-ComparableWorktreePath -Path $Left).Equals((ConvertTo-ComparableWorktreePath -Path $Right), $comparison)
}

function Resolve-WorktreeTarget {
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'BranchName')]
        [string]$BranchName,

        [Parameter(Mandatory, ParameterSetName = 'Path')]
        [string]$Path
    )

    $worktrees = @(Get-Worktrees)
    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        $matches = @($worktrees | Where-Object { Test-WorktreePathEquals -Left $_.Path -Right $Path })
        if ($matches.Count -eq 0) {
            Write-Error "No worktree was found at path '$Path'."
            return
        }
        if ($matches.Count -gt 1) {
            Write-Error "More than one worktree matched path '$Path'."
            return
        }
        return $matches[0]
    }

    $matches = @($worktrees | Where-Object Branch -eq $BranchName)
    if ($matches.Count -eq 0) {
        Write-Error "No worktree was found for branch '$BranchName'."
        return
    }
    if ($BranchName -eq '(detached)' -or ($matches | Where-Object Detached)) {
        Write-Error "Detached worktrees cannot be addressed by branch name because '(detached)' is ambiguous. Use -Path instead."
        return
    }
    if ($matches.Count -gt 1) {
        Write-Error "More than one worktree matched branch '$BranchName'. Use -Path instead."
        return
    }

    $matches[0]
}

function Remove-Worktree {
    <#
    .SYNOPSIS
    Remove a worktree by branch name or path.
    .PARAMETER BranchName
    Name of the branch. The branch is resolved through `Get-Worktrees`, so
    non-standard worktree locations are supported. Detached worktrees must be
    addressed by `-Path` because their branch label is ambiguous.
    .PARAMETER Path
    The actual filesystem path of the worktree to remove. Accepts pipeline input
    by property name from `Get-Worktrees` and related objects.
    .PARAMETER RemoveBranch
    Also remove the branch when the target worktree is backed by a branch.
    .PARAMETER Force
    Force the removal of the worktree.
    .EXAMPLE
    Remove-Worktree -BranchName feature/old -RemoveBranch
    Removes the worktree for the branch and deletes the branch.
    .EXAMPLE
    Get-Worktrees | Where-Object Detached | Remove-Worktree -Force
    Removes detached worktrees by their real paths from pipeline input.
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'BranchName', ValueFromPipelineByPropertyName)]
        [ValidateSet([WorktreeSetValuesGenerator])]
        [Alias('Branch')]
        [string]$BranchName,

        [Parameter(Mandatory, ParameterSetName = 'Path', ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [switch]$RemoveBranch,
        [switch]$Force = $false
    )
    process {
        $target = if ($PSCmdlet.ParameterSetName -eq 'Path') {
            Resolve-WorktreeTarget -Path $Path
        } else {
            Resolve-WorktreeTarget -BranchName $BranchName
        }
        if (-not $target) { return }

        $worktreePath = $target.Path
        if ($PSCmdlet.ShouldProcess($worktreePath, 'Remove worktree')) {
            $removeArgs = @('worktree', 'remove')
            if ($Force) { $removeArgs += '--force' }
            $removeArgs += '--'
            $removeArgs += $worktreePath
            git @removeArgs
            $worktreeRemoved = $LASTEXITCODE -eq 0
            if ($RemoveBranch) {
                if ($target.Detached -or $target.Branch -eq '(detached)' -or -not $target.Branch) {
                    Write-Warning 'The target worktree is detached; no branch was removed.'
                } elseif ($worktreeRemoved) {
                    git branch -D -- $target.Branch
                } else {
                    Write-Warning "Worktree removal failed; leaving branch '$($target.Branch)' in place."
                }
            }
        }
    }
}

function Set-Worktree {
    <#
    .SYNOPSIS
    Change the current directory to the directory for a worktree.
    .PARAMETER BranchName
    The name of the branch to change to. The branch is resolved through
    `Get-Worktrees`, so non-standard worktree locations are supported. Detached
    worktrees must be addressed by `-Path` because their branch label is ambiguous.
    .PARAMETER Path
    The actual filesystem path of the worktree to change to. Accepts pipeline
    input by property name from `Get-Worktrees` and related objects.
    .EXAMPLE
    Set-Worktree -BranchName main
    Changes the current directory to the main branch worktree.
    .EXAMPLE
    Get-Worktrees | Where-Object Detached | Select-Object -First 1 | Set-Worktree
    Changes to a detached worktree by using its real path from pipeline input.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'BranchName', ValueFromPipelineByPropertyName)]
        [ValidateSet([WorktreeSetValuesGenerator])]
        [Alias('Branch')]
        [string]$BranchName,

        [Parameter(Mandatory, ParameterSetName = 'Path', ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )
    process {
        $target = if ($PSCmdlet.ParameterSetName -eq 'Path') {
            Resolve-WorktreeTarget -Path $Path
        } else {
            Resolve-WorktreeTarget -BranchName $BranchName
        }
        if (-not $target) { return }

        if (Test-Path -LiteralPath $target.Path -PathType Container) {
            Set-Location -LiteralPath $target.Path
        } else {
            Write-Error "Worktree path '$($target.Path)' does not exist."
        }
    }
}
