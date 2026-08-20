using module ../Classes/WorktreeSetValuesGenerator.psm1

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

function Remove-Worktree {
    <#
    .SYNOPSIS
    Remove a worktree by branch name
    .PARAMETER BranchName
    Name of the branch
    .PARAMETER RemoveBranch
    Also remove the branch
    .PARAMETER Force
    Force the removal of the worktree
    .EXAMPLE
    Remove-Worktree -BranchName feature/old -RemoveBranch
    Removes the worktree and deletes the branch.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet([WorktreeSetValuesGenerator])]
        [Alias('Branch')]
        [string]$BranchName,
        [switch]$RemoveBranch,
        [switch]$Force = $false
    )
    process {
        $worktreePath = Get-WorktreePath -BranchName $BranchName
        if ($PSCmdlet.ShouldProcess($worktreePath, 'Remove worktree')) {
            if ($Force) {
                git worktree remove $worktreePath --force
            } else {
                git worktree remove $worktreePath
            }
            $worktreeRemoved = $LASTEXITCODE -eq 0
            if ($RemoveBranch) {
                if ($worktreeRemoved) {
                    git branch -D $BranchName
                } else {
                    Write-Warning "Worktree removal failed; leaving branch '$BranchName' in place."
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
    The name of the branch to change to.
    .EXAMPLE
    Set-Worktree -BranchName main
    Changes the current directory to the main branch worktree.
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateSet([WorktreeSetValuesGenerator])]
        [Alias('Branch')]
        [string]$BranchName
    )
    process {
        $worktreePath = Get-Worktrees | Where-Object Branch -eq $BranchName | Select-Object -ExpandProperty Path
        if ($worktreePath -and (Test-Path -Path $worktreePath)) {
            Set-Location -Path $worktreePath
        }
    }
}
