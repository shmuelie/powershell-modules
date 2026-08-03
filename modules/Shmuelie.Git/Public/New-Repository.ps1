function New-Repository {
    <#
    .SYNOPSIS
    Clone a git repository into the standard worktree-ready directory layout.
    .DESCRIPTION
    Clones a repository from a GitHub or Azure DevOps URL into
    $env:SOURCE_REPOS\<org>\<repo>\<branch>, ready for worktree use.
    The org and repo name are extracted automatically from the URL.
    Submodules are recursively initialized by default.
    .PARAMETER Url
    The clone URL (HTTPS or SSH) for the repository.
    .PARAMETER Org
    Override the auto-detected organization/owner name.
    .PARAMETER Name
    Override the auto-detected repository name.
    .PARAMETER Branch
    Branch to clone. Defaults to the remote's default branch.
    .PARAMETER NoSetLocation
    Do not change to the cloned directory after cloning.
    .PARAMETER NoRecurseSubmodules
    Do not recursively initialize submodules.
    .PARAMETER Shallow
    Perform a partial (blobless) clone with --filter=blob:none.
    .EXAMPLE
    New-Repository https://github.com/microsoft/terminal
    Clones into D:\source\repos\microsoft\terminal\main and navigates there.
    .EXAMPLE
    New-Repository https://dev.azure.com/contoso/Platform/_git/runtime -Branch release/v2
    Clones the release/v2 branch into D:\source\repos\contoso\runtime\release\v2.
    .EXAMPLE
    New-Repository https://github.com/dotnet/runtime -Org dotnet -Shallow
    Performs a blobless clone into D:\source\repos\dotnet\runtime\<default-branch>.
    .EXAMPLE
    New-Repository git@github.com:spectreconsole/spectre.console.git -NoSetLocation
    Clones without changing the current directory.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Url,

        [string]$Org,

        [string]$Name,

        [string]$Branch,

        [switch]$NoSetLocation,

        [switch]$NoRecurseSubmodules,

        [switch]$Shallow
    )

    # Parse org and repo name from URL if not provided
    # Supports: https://github.com/<org>/<repo>[.git]
    #           https://dev.azure.com/<org>/<project>/_git/<repo>
    #           https://<org>.visualstudio.com/[DefaultCollection/]<project>/_git/<repo>
    #           git@github.com:<org>/<repo>.git
    #           <org>@vs-ssh.visualstudio.com:v3/<org>/<project>/<repo>
    if (-not $Name -or -not $Org) {
        $parsed = $false

        # Azure DevOps HTTPS: https://dev.azure.com/<org>/<project>/_git/<repo>
        if ($Url -match 'dev\.azure\.com/([^/]+)/[^/]+/_git/([^/?]+)') {
            if (-not $Org) { $Org = $Matches[1] }
            if (-not $Name) { $Name = $Matches[2] -replace '\.git$', '' }
            $parsed = $true
        }
        # Azure DevOps legacy HTTPS: https://<org>.visualstudio.com/[DefaultCollection/]<project>/_git/<repo>
        elseif ($Url -match '([^/]+)\.visualstudio\.com(?:/DefaultCollection)?/[^/]+/_git/([^/?]+)') {
            if (-not $Org) { $Org = $Matches[1] }
            if (-not $Name) { $Name = $Matches[2] -replace '\.git$', '' }
            $parsed = $true
        }
        # Azure DevOps SSH: <org>@vs-ssh.visualstudio.com:v3/<org>/<project>/<repo>
        elseif ($Url -match 'vs-ssh\.visualstudio\.com:v3/([^/]+)/[^/]+/([^/?]+)') {
            if (-not $Org) { $Org = $Matches[1] }
            if (-not $Name) { $Name = $Matches[2] -replace '\.git$', '' }
            $parsed = $true
        }
        # GitHub/generic HTTPS: https://<host>/<org>/<repo>[.git]
        elseif ($Url -match 'https?://[^/]+/([^/]+)/([^/?]+)') {
            if (-not $Org) { $Org = $Matches[1] }
            if (-not $Name) { $Name = $Matches[2] -replace '\.git$', '' }
            $parsed = $true
        }
        # GitHub/generic SSH: git@<host>:<org>/<repo>.git
        elseif ($Url -match 'git@[^:]+:([^/]+)/([^/?]+)') {
            if (-not $Org) { $Org = $Matches[1] }
            if (-not $Name) { $Name = $Matches[2] -replace '\.git$', '' }
            $parsed = $true
        }

        if (-not $parsed -or -not $Org -or -not $Name) {
            Write-Error "Unable to parse org and repo name from URL: $Url. Use -Org and -Name to specify manually."
            return
        }
    }

    $reposRoot = $env:SOURCE_REPOS
    if (-not $reposRoot) {
        $reposRoot = 'D:\source\repos'
    }

    # Clone to a temp directory first, then determine the branch name for the final path
    $cloneArgs = @('clone', $Url)
    if ($Branch) {
        $cloneArgs += '--branch', $Branch
    }
    if (-not $NoRecurseSubmodules) {
        $cloneArgs += '--recurse-submodules'
    }
    if ($Shallow) {
        $cloneArgs += '--filter=blob:none'
    }

    # Determine the target branch name for the directory
    if ($Branch) {
        $branchDir = $Branch
    } else {
        # Query the remote for the default branch
        $remoteBranch = git ls-remote --symref $Url HEAD 2>&1 |
            Select-String 'ref: refs/heads/(\S+)\s+HEAD' |
            ForEach-Object { $_.Matches[0].Groups[1].Value }
        if (-not $remoteBranch) {
            $branchDir = 'main'
            Write-Warning "Could not detect default branch, using 'main'."
        } else {
            $branchDir = $remoteBranch
        }
    }

    $targetPath = Join-Path $reposRoot $Org $Name $branchDir

    if (Test-Path $targetPath) {
        Write-Error "Target path already exists: $targetPath"
        return
    }

    if ($PSCmdlet.ShouldProcess("$Org/$Name", "Clone repository to '$targetPath'")) {
        # Ensure parent directory exists
        $parentPath = Split-Path $targetPath -Parent
        if (-not (Test-Path $parentPath)) {
            New-Item -ItemType Directory -Path $parentPath -Force | Out-Null
        }

        $cloneArgs += $targetPath
        Write-Verbose "Cloning $Org/$Name into $targetPath"
        & git @cloneArgs

        if ($LASTEXITCODE -ne 0) {
            Write-Error "git clone failed with exit code $LASTEXITCODE"
            return
        }

        if (-not $NoSetLocation) {
            Set-Location -Path $targetPath
        }
    }
}