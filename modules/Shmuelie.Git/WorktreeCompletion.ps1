function Get-WorktreeBranchCompletion {
    [CmdletBinding()]
    param(
        [string]$WordToComplete,
        [System.Management.Automation.Language.CommandAst]$CommandAst,
        [System.Collections.IDictionary]$BoundParameters,
        [switch]$AvailableBranch
    )

    # Static binding recognizes aliases and positional paths without evaluating
    # expressions. An unresolved explicit path must not fall back to the caller.
    $binding = [System.Management.Automation.Language.StaticParameterBinder]::BindCommand($CommandAst)
    if ($binding.BindingExceptions.Count) { return }
    $path = $null
    if ($binding.BoundParameters.ContainsKey('Path') -or $BoundParameters.Contains('Path')) {
        if (-not $AvailableBranch) { return } # These commands use Path as an alternative target.
        if (-not $BoundParameters.Contains('Path') -or
            $BoundParameters['Path'] -isnot [string] -or
            [string]::IsNullOrWhiteSpace($BoundParameters['Path'])) { return }
        $path = $BoundParameters['Path']
    }

    $repository = Resolve-GitRepositoryPath -Path $path -ErrorAction Ignore
    if (-not $repository) { return }
    $worktreeBranches = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($worktree in @(Get-Worktrees -Path $repository -ErrorAction Ignore)) {
        if (-not $worktree.Detached -and $worktree.Branch) {
            $null = $worktreeBranches.Add($worktree.Branch)
        }
    }
    $branches = if ($AvailableBranch) {
        $result = Invoke-Git -Path $repository -Arguments @('for-each-ref', '--format=%(refname:short)', 'refs/heads/') -ErrorAction Ignore
        if ($null -eq $result) { return }
        $result.StandardOutput -split '\r?\n' | Where-Object { $_ -and -not $worktreeBranches.Contains($_) }
    } else {
        $worktreeBranches
    }
    foreach ($branch in $branches) {
        if ($branch.StartsWith($WordToComplete, [StringComparison]::OrdinalIgnoreCase)) {
            $text = if ($branch -match '[^\w./-]') { "'" + $branch.Replace("'", "''") + "'" } else { $branch }
            [System.Management.Automation.CompletionResult]::new($text, $branch, 'ParameterValue', $branch)
        }
    }
}
