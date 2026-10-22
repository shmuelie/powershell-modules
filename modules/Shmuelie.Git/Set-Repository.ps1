function Get-LocalRepositoryDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$Org
    )

    # Enumerate names instead of constructing wildcard paths. Do not follow
    # directory links while discovering repositories owned by this root.
    foreach ($owner in Get-ChildItem -LiteralPath $Root -Directory -Force -ErrorAction Stop) {
        if ($owner.Name -eq '.git' -or ($owner.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
        if ($Org -and $owner.Name -cne $Org) { continue }
        foreach ($repository in Get-ChildItem -LiteralPath $owner.FullName -Directory -Force -ErrorAction Stop) {
            if ($repository.Name -eq '.git' -or ($repository.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
            [pscustomobject]@{ Org = $owner.Name; Name = $repository.Name; Path = $repository.FullName }
        }
    }
}

function Get-LocalRepositoryWorkingTree {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    # Ambient repository overrides must not redirect validation to some other
    # repository. Overrides apply only to these read-only child processes.
    $environment = @{
        GIT_DIR = $null; GIT_WORK_TREE = $null; GIT_COMMON_DIR = $null
        GIT_INDEX_FILE = $null; GIT_OBJECT_DIRECTORY = $null
        GIT_ALTERNATE_OBJECT_DIRECTORIES = $null; GIT_NAMESPACE = $null
        GIT_CEILING_DIRECTORIES = $null; GIT_DISCOVERY_ACROSS_FILESYSTEM = $null
    }
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($Path)
    while ($pending.Count) {
        $directory = $pending.Pop()
        if (Test-Path -LiteralPath (Join-Path $directory '.git')) {
            $inside = Invoke-GitProcess -Arguments @(
                '-C', $directory, 'rev-parse', '--is-inside-work-tree', '--show-prefix'
            ) -Environment $environment
            # Require the actual root, not a subdirectory discovered through a
            # broken marker or through an enclosing repository.
            if ($inside.ExitCode -eq 0 -and
                $inside.StandardOutput.Replace("`r`n", "`n") -ceq "true`n`n") {
                $head = Invoke-GitProcess -Arguments @(
                    '-C', $directory, 'symbolic-ref', '--quiet', 'HEAD'
                ) -Environment $environment
                if ($head.ExitCode -notin 0, 1) { continue }
                $ref = $head.StandardOutput.TrimEnd("`r", "`n")
                $branch = if ($head.ExitCode -eq 0 -and $ref.StartsWith('refs/heads/', [StringComparison]::Ordinal)) {
                    $ref.Substring('refs/heads/'.Length)
                } else { $null }
                [pscustomobject]@{ Path = $directory; Branch = $branch }
            }
            # A working tree (even an invalid one) is a discovery boundary.
            continue
        }
        # A bare repository is not a working tree or a branch-folder container.
        if ((Test-Path -LiteralPath (Join-Path $directory 'HEAD') -PathType Leaf) -and
            (Test-Path -LiteralPath (Join-Path $directory 'objects') -PathType Container)) { continue }
        foreach ($child in Get-ChildItem -LiteralPath $directory -Directory -Force -ErrorAction Stop) {
            if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            $pending.Push($child.FullName)
        }
    }
}

function Set-Repository {
    <#
    .SYNOPSIS
    Navigate to an existing local repository's working tree.
    .DESCRIPTION
    Resolves <root>/<org>/<repo> from any current directory. Only actual Git
    working-tree roots at or below that repository directory are eligible,
    including nested branch folders and detached worktrees. Directory links,
    bare repositories and .git contents are not searched. Registered worktrees
    outside that directory are not discovered; use Set-Worktree -Path for those.

    A sole valid working tree is selected automatically. Multiple repository
    names or working trees are errors: qualify the organization and choose an
    exact -Branch or -Worktree. No default branch is assumed. All validation is
    local and read-only; this command never clones, fetches, pulls, checks out a
    branch or creates worktrees. Failures and -WhatIf leave location unchanged.
    .PARAMETER Name
    Literal repository directory name, optionally qualified as org/name.
    Names are case-sensitive, even on Windows. Wildcards are not expanded.
    .PARAMETER Org
    Literal organization directory name. May not be combined with org/name.
    .PARAMETER Root
    Existing filesystem repository root. Defaults to $env:SOURCE_REPOS.
    An explicitly supplied root always takes precedence, including invalid roots.
    .PARAMETER Branch
    Exact, case-sensitive checked-out local branch name, not a folder name.
    Detached trees must be selected by Worktree. Does not switch branches.
    .PARAMETER Worktree
    Exact working-tree root, either absolute or relative to <root>/<org>/<repo>.
    Must match a discovered candidate; subdirectories and outside paths fail.
    .EXAMPLE
    Set-Repository terminal -Org microsoft
    Enters the sole valid working tree of $env:SOURCE_REPOS/microsoft/terminal.
    .EXAMPLE
    Set-Repository dotnet/runtime -Branch release/10.0
    Enters the existing tree whose checked-out branch is release/10.0.
    .EXAMPLE
    Set-Repository 'my repo' -Org 'my org' -Root '/src/repos' -Worktree 'topic folder' -WhatIf
    Previews navigation to an exact local working tree without changing location.
    .EXAMPLE
    Set-Repository terminal -Org microsoft -Worktree 'main' -Confirm
    Requests native confirmation before entering that existing working tree.
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Automatic')]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [ValidateNotNullOrEmpty()]
        [string]$Org,

        [ValidateNotNullOrEmpty()]
        [string]$Root,

        [Parameter(Mandatory, ParameterSetName = 'Branch')]
        [ValidateNotNullOrEmpty()]
        [string]$Branch,

        [Parameter(Mandatory, ParameterSetName = 'Worktree')]
        [ValidateNotNullOrEmpty()]
        [string]$Worktree
    )

    if ($Name.Contains('/')) {
        $parts = $Name.Split('/')
        if ($Org -or $parts.Count -ne 2) {
            Write-Error 'Use either org/name or -Name with -Org, not both.'
            return
        }
        $Org, $Name = $parts
    }
    $segments = @($Name; if ($Org) { $Org })
    foreach ($segment in $segments) {
        if (-not $segment -or $segment -in '.', '..' -or $segment.IndexOfAny([char[]]"/\`0") -ge 0) {
            Write-Error 'Repository and organization names must be literal directory names, not paths.'
            return
        }
    }
    $reposRoot = if ($PSBoundParameters.ContainsKey('Root')) { $Root } else { $env:SOURCE_REPOS }
    if (-not $reposRoot) {
        Write-Error 'No repository root specified. Pass -Root or set $env:SOURCE_REPOS.'
        return
    }
    $resolved = Resolve-Path -LiteralPath $reposRoot -ErrorAction Ignore
    if (-not $resolved -or $resolved.Provider.Name -ne 'FileSystem' -or
        -not (Test-Path -LiteralPath $resolved.ProviderPath -PathType Container)) {
        Write-Error "Repository root must be an existing FileSystem directory: '$reposRoot'."
        return
    }
    $repositories = @(Get-LocalRepositoryDirectory -Root $resolved.ProviderPath -Org $Org -ErrorAction Stop |
        Where-Object Name -CEQ $Name)
    if ($repositories.Count -eq 0) {
        Write-Error "Repository '$Name' was not found under '$reposRoot' (organization '$Org')."
        return
    }
    if ($repositories.Count -gt 1) {
        Write-Error "Repository name '$Name' is ambiguous: $(($repositories | ForEach-Object { "$($_.Org)/$($_.Name)" }) -join ', '). Specify -Org."
        return
    }
    $container = $repositories[0].Path
    $targets = @(Get-LocalRepositoryWorkingTree -Path $container -ErrorAction Stop)
    if ($PSCmdlet.ParameterSetName -eq 'Branch') {
        $targets = @($targets | Where-Object Branch -CEQ $Branch)
    } elseif ($PSCmdlet.ParameterSetName -eq 'Worktree') {
        $targetPath = if ([IO.Path]::IsPathRooted($Worktree)) { $Worktree } else { Join-Path $container $Worktree }
        $targets = @($targets | Where-Object { Test-WorktreePathEquals -Left $_.Path -Right $targetPath })
    }
    if ($targets.Count -eq 0) {
        Write-Error "No valid Git working tree matches repository '$($repositories[0].Org)/$Name' and the supplied selection."
        return
    }
    if ($targets.Count -gt 1) {
        Write-Error "Working tree selection is ambiguous: $(($targets.Path | Sort-Object) -join ', '). Specify an exact -Branch or -Worktree."
        return
    }
    if ($PSCmdlet.ShouldProcess($targets[0].Path, 'Set current location')) {
        Set-Location -LiteralPath $targets[0].Path -ErrorAction Stop
    }
}

function Get-LocalRepositoryCompletion {
    [CmdletBinding()]
    param(
        [string]$ParameterName,
        [string]$WordToComplete,
        [System.Management.Automation.Language.CommandAst]$CommandAst,
        [System.Collections.IDictionary]$BoundParameters
    )

    try {
        $binding = [System.Management.Automation.Language.StaticParameterBinder]::BindCommand($CommandAst)
        foreach ($failure in $binding.BindingExceptions.Values) {
            # A trailing -Name/-Org is precisely where empty-prefix completion
            # is needed. Other binding errors must still fail closed.
            if ($failure.BindingException.ErrorId -ne 'MissingArgument' -or
                $failure.BindingException.ParameterName -ne $ParameterName) { return }
        }
        foreach ($parameter in 'Root', 'Org') {
            if ($binding.BoundParameters.ContainsKey($parameter) -and
                (-not $BoundParameters.Contains($parameter) -or
                 $BoundParameters[$parameter] -isnot [string] -or
                 -not $BoundParameters[$parameter])) { return }
        }
        $root = if ($BoundParameters.Contains('Root')) { $BoundParameters['Root'] } else { $env:SOURCE_REPOS }
        if (-not $root) { return }
        $resolved = Resolve-Path -LiteralPath $root -ErrorAction Ignore
        if (-not $resolved -or $resolved.Provider.Name -ne 'FileSystem' -or
            -not (Test-Path -LiteralPath $resolved.ProviderPath -PathType Container)) { return }
        $prefix = $WordToComplete
        if ($prefix.StartsWith("'")) { $prefix = $prefix.Trim("'").Replace("''", "'") }
        elseif ($prefix.StartsWith('"')) { $prefix = $prefix.Trim('"') }
        $org = $BoundParameters['Org']
        if ($ParameterName -eq 'Org') {
            $values = @(Get-ChildItem -LiteralPath $resolved.ProviderPath -Directory -Force -ErrorAction Stop |
                Where-Object { $_.Name -ne '.git' -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
                Select-Object -ExpandProperty Name)
        } else {
            $qualified = $prefix.Contains('/')
            if ($qualified) {
                if ($org -or $prefix.Split('/').Count -ne 2) { return }
                $org = $prefix.Split('/')[0]
            }
            $values = @(Get-LocalRepositoryDirectory -Root $resolved.ProviderPath -Org $org -ErrorAction Stop |
                ForEach-Object { if ($qualified) { "$($_.Org)/$($_.Name)" } else { $_.Name } })
        }
        foreach ($value in $values | Sort-Object -Unique -CaseSensitive) {
            if ($value.StartsWith($prefix, [StringComparison]::Ordinal)) {
                [System.Management.Automation.CompletionResult]::new(
                    "'" + $value.Replace("'", "''") + "'", $value, 'ParameterValue', $value)
            }
        }
    } catch {
        # Completion is best-effort, but never fall back to another root/org.
        return
    }
}
