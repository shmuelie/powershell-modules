function Expand-UpdateAllWorktreesPattern {
    <#
    .SYNOPSIS
        Expand string-array wildcard arguments that may contain comma-separated values.
    #>
    [CmdletBinding()]
    param([string[]]$Pattern)

    foreach ($entry in $Pattern) {
        foreach ($part in ($entry -split ',')) {
            $trimmed = $part.Trim()
            if ($trimmed) { $trimmed }
        }
    }
}

function Test-UpdateAllWorktreesPattern {
    <#
    .SYNOPSIS
        Test whether any wildcard pattern matches any candidate value.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Candidate,
        [string[]]$Pattern
    )

    if (-not $Pattern -or $Pattern.Count -eq 0) { return $true }

    foreach ($candidateValue in $Candidate) {
        foreach ($patternValue in $Pattern) {
            if ($candidateValue -like $patternValue) { return $true }
        }
    }

    $false
}

function Get-UpdateAllWorktreesRepository {
    <#
    .SYNOPSIS
        Discover git working trees below a repository root and group them by org/repo.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [string[]]$Organization,
        [string[]]$Name,
        [string[]]$Exclude
    )

    $resolvedRoot = (Resolve-Path -LiteralPath $Root -ErrorAction Stop).Path
    $rootDirectory = Get-Item -LiteralPath $resolvedRoot -ErrorAction Stop
    $pending = [System.Collections.Generic.Stack[System.IO.DirectoryInfo]]::new()
    $pending.Push($rootDirectory)
    $repositories = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)

    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        $gitPath = Join-Path $directory.FullName '.git'

        if (Test-Path -LiteralPath $gitPath) {
            $relativePath = [System.IO.Path]::GetRelativePath($resolvedRoot, $directory.FullName)
            $segments = if ($relativePath -eq '.') {
                @()
            } else {
                @($relativePath -split "[/\\]+" | Where-Object { $_ })
            }

            if ($segments.Count -ge 2) {
                $org = $segments[0]
                $repo = $segments[1]
            } elseif ($segments.Count -eq 1) {
                $org = Split-Path -Leaf $resolvedRoot
                $repo = $segments[0]
            } else {
                $org = Split-Path -Leaf (Split-Path -Parent $directory.FullName)
                $repo = Split-Path -Leaf $directory.FullName
            }

            $key = "$org/$repo"
            if (-not $repositories.ContainsKey($key)) {
                $repositories[$key] = [PSCustomObject]@{
                    PSTypeName   = 'AllWorktreesRepository'
                    Organization = $org
                    Repository   = $repo
                    Path         = $directory.FullName
                }
            }

            continue
        }

        foreach ($child in Get-ChildItem -LiteralPath $directory.FullName -Directory -Force -ErrorAction SilentlyContinue) {
            if ($child.Name -eq '.git') { continue }
            $pending.Push($child)
        }
    }

    $orgPatterns = @(Expand-UpdateAllWorktreesPattern $Organization)
    $namePatterns = @(Expand-UpdateAllWorktreesPattern $Name)
    $excludePatterns = @(Expand-UpdateAllWorktreesPattern $Exclude)

    $repositories.Values |
        Where-Object { Test-UpdateAllWorktreesPattern -Candidate @($_.Organization) -Pattern $orgPatterns } |
        Where-Object { Test-UpdateAllWorktreesPattern -Candidate @($_.Repository) -Pattern $namePatterns } |
        Where-Object {
            $excludePatterns.Count -eq 0 -or
                -not (Test-UpdateAllWorktreesPattern -Candidate @($_.Organization, $_.Repository, "$($_.Organization)/$($_.Repository)") -Pattern $excludePatterns)
        } |
        Sort-Object Organization, Repository
}

function Update-AllWorktrees {
    <#
    .SYNOPSIS
    Update every discovered repository under a standard repos root.
    .DESCRIPTION
    Discovers git repositories under a root directory using the standard
    `<root>/<org>/<repo>/<branch>` worktree layout, then updates each repository
    in parallel by importing this module in each worker runspace and invoking
    Update-Worktrees. Returns one AllWorktreesUpdateResult object per repository
    with the organization, repository name, selected path, overall status, and
    the underlying WorktreeUpdateResult objects.

    The default root is `$env:SOURCE_REPOS` when it is set; otherwise the current
    directory is used. A missing root produces a clear non-terminating error and
    no repository is updated.
    .PARAMETER Path
    Root directory to scan. Defaults to `$env:SOURCE_REPOS`, then the current
    directory. Alias: Root.
    .PARAMETER Organization
    Organization folder filter(s). Values are wildcard matched and may be passed
    as an array or comma-separated list.
    .PARAMETER Name
    Repository name filter(s). Values are wildcard matched and may be passed as
    an array or comma-separated list.
    .PARAMETER Exclude
    Exclusion filter(s). Values are wildcard matched against organization,
    repository, and `organization/repository`, and may be passed as an array or
    comma-separated list.
    .PARAMETER ThrottleLimit
    Maximum number of repositories to update in parallel. Defaults to 4.
    .PARAMETER CheckRemote
    Forwarded to Update-Worktrees for each repository.
    .PARAMETER GitHubAccountMap
    Forwarded to Update-Worktrees for each repository.
    .PARAMETER GitHubAccountResolver
    Forwarded to Update-Worktrees for each repository.
    .PARAMETER NoGitHubAccountResolve
    Forwarded to Update-Worktrees for each repository.
    .EXAMPLE
    Update-AllWorktrees
    Updates every repository under `$env:SOURCE_REPOS`, or the current directory
    when that environment variable is not set.
    .EXAMPLE
    Update-AllWorktrees -Path ~/src -Organization microsoft,shmuelie -Name 'powershell-*'
    Updates matching repositories below `~/src`.
    .EXAMPLE
    Update-AllWorktrees -Exclude 'archive/*','*-old' -ThrottleLimit 8
    Updates repositories in parallel except excluded organization/repository or
    repository-name matches.
    .EXAMPLE
    Update-AllWorktrees -Path ~/src -WhatIf
    Shows which repositories would be updated without fetching or merging.
    #>
    [OutputType('AllWorktreesUpdateResult')]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Alias('Root')]
        [string]$Path,

        [string[]]$Organization,

        [string[]]$Name,

        [string[]]$Exclude,

        [ValidateRange(1, 128)]
        [int]$ThrottleLimit = 4,

        [switch]$CheckRemote,

        [hashtable]$GitHubAccountMap,

        [scriptblock]$GitHubAccountResolver,

        [switch]$NoGitHubAccountResolve
    )

    if (-not $Path) {
        $Path = if ($env:SOURCE_REPOS) { $env:SOURCE_REPOS } else { (Get-Location).Path }
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        Write-Error "Repository root not found: $Path"
        return
    }

    $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Shmuelie.Git.psd1'
    $repositories = @(Get-UpdateAllWorktreesRepository -Root $Path -Organization $Organization -Name $Name -Exclude $Exclude)
    if ($repositories.Count -eq 0) { return }

    $whatIfResults = [System.Collections.Generic.List[object]]::new()
    $repositoriesToUpdate = [System.Collections.Generic.List[object]]::new()

    foreach ($repository in $repositories) {
        if ($PSCmdlet.ShouldProcess("$($repository.Organization)/$($repository.Repository)", 'Update all worktrees')) {
            $repositoriesToUpdate.Add($repository)
        } else {
            $whatIfResults.Add([PSCustomObject]@{
                PSTypeName      = 'AllWorktreesUpdateResult'
                Organization    = $repository.Organization
                Repository      = $repository.Repository
                Path            = $repository.Path
                Status          = 'WhatIf'
                WorktreeResults = @()
                Error           = $null
            })
        }
    }

    foreach ($result in $whatIfResults) { $result }
    if ($repositoriesToUpdate.Count -eq 0) { return }

    $forwardCheckRemote = $CheckRemote.IsPresent
    $forwardGitHubAccountMap = $PSBoundParameters.ContainsKey('GitHubAccountMap')
    $forwardGitHubAccountResolver = $PSBoundParameters.ContainsKey('GitHubAccountResolver')
    $forwardNoGitHubAccountResolve = $NoGitHubAccountResolve.IsPresent
    $accountMap = $GitHubAccountMap
    $accountResolver = $GitHubAccountResolver

    $repositoriesToUpdate | ForEach-Object -Parallel {
        $repository = $_
        $errors = @()

        try {
            Import-Module $using:modulePath -Force -ErrorAction Stop

            $updateParams = @{ Path = $repository.Path }
            if ($using:forwardCheckRemote) { $updateParams.CheckRemote = $true }
            if ($using:forwardGitHubAccountMap) { $updateParams.GitHubAccountMap = $using:accountMap }
            if ($using:forwardGitHubAccountResolver) { $updateParams.GitHubAccountResolver = $using:accountResolver }
            if ($using:forwardNoGitHubAccountResolve) { $updateParams.NoGitHubAccountResolve = $true }

            $updateErrors = @()
            $worktreeResults = @(Update-Worktrees @updateParams -ErrorAction SilentlyContinue -ErrorVariable updateErrors)
            foreach ($updateError in $updateErrors) { $errors += $updateError.Exception.Message }

            $failedWorktrees = @($worktreeResults | Where-Object { $_.Status -in @('Failed', 'StashFailed') })
            foreach ($failedWorktree in $failedWorktrees) {
                $errors += "Worktree '$($failedWorktree.Branch)' reported status '$($failedWorktree.Status)'."
            }

            [PSCustomObject]@{
                PSTypeName      = 'AllWorktreesUpdateResult'
                Organization    = $repository.Organization
                Repository      = $repository.Repository
                Path            = $repository.Path
                Status          = if ($errors.Count -gt 0) { 'Failed' } else { 'Completed' }
                WorktreeResults = $worktreeResults
                Error           = if ($errors.Count -gt 0) { $errors -join [Environment]::NewLine } else { $null }
            }
        } catch {
            [PSCustomObject]@{
                PSTypeName      = 'AllWorktreesUpdateResult'
                Organization    = $repository.Organization
                Repository      = $repository.Repository
                Path            = $repository.Path
                Status          = 'Failed'
                WorktreeResults = @()
                Error           = $_.Exception.Message
            }
        }
    } -ThrottleLimit $ThrottleLimit
}
