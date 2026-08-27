function Set-AdoNpmTokenOwnerOnlyAcl {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [switch]$Directory
    )

    if (-not $IsWindows) { return }

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) {
        [void]$acl.RemoveAccessRuleSpecific($rule)
    }

    if ($Directory) {
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            $identity,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            [System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit',
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow)
    } else {
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            $identity,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            [System.Security.AccessControl.AccessControlType]::Allow)
    }

    $acl.SetAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Clear-AdoNpmTokenFile {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }

    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($item.Length -gt 0) {
            [System.IO.File]::WriteAllBytes($item.FullName, [byte[]]::new([int]$item.Length))
        }
    } catch {
        Write-Verbose "Failed to overwrite temporary npm token file before deletion: $_"
    }
}

function Update-AdoNpmToken {
    <#
    .SYNOPSIS
        Updates ADO npm feed tokens using artifacts-npm-credprovider.
    .DESCRIPTION
        Runs the @microsoft/artifacts-npm-credprovider against a temporary .npmrc to
        authenticate with Azure DevOps and obtain fresh access tokens. The tokens are
        set as environment variables referenced by the user-level .npmrc.

        Use -Feed to select the feed and -Name to control the environment variable name.
    .PARAMETER Feed
        The ADO npm feed registry URL to authenticate against.
    .PARAMETER Name
        The environment variable name to set. Defaults to ADO_NPM_TOKEN.
    .PARAMETER Force
        Force credential refresh even if current authentication is valid.
    .EXAMPLE
        Update-AdoNpmToken -Feed "https://pkgs.dev.azure.com/myorg/_packaging/myfeed/npm/registry/"
        Refreshes a specific feed into ADO_NPM_TOKEN.
    .EXAMPLE
        Update-AdoNpmToken -Feed "https://pkgs.dev.azure.com/myorg/_packaging/myfeed/npm/registry/" -Name MY_TOKEN
        Refreshes a specific feed into a custom environment variable.
    .EXAMPLE
        Update-AdoNpmToken -Feed "https://pkgs.dev.azure.com/myorg/_packaging/myfeed/npm/registry/" -Force
        Forces a credential refresh for the selected feed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Feed,

        [Parameter()]
        [ValidatePattern('^[A-Za-z_][A-Za-z0-9_]*$')]
        [string]$Name,

        [Parameter()]
        [switch]$Force
    )

    $feedsToRefresh = @(@{
        Feed = $Feed
        Name = if ($Name) { $Name } else { 'ADO_NPM_TOKEN' }
    })

    $npmRoot = npm root -g 2>$null
    if (-not $npmRoot) {
        Write-Error "npm is not installed or not in PATH."
        return
    }
    $credProviderBin = Join-Path $npmRoot '@microsoft' 'artifacts-npm-credprovider' 'bin' 'index.js'
    if (-not (Test-Path $credProviderBin)) {
        Write-Error "artifacts-npm-credprovider is not installed globally. Install with: npm install -g @microsoft/artifacts-npm-credprovider"
        return
    }

    foreach ($entry in $feedsToRefresh) {
        if (-not $PSCmdlet.ShouldProcess($entry.Name, "Refresh token for feed $($entry.Feed)")) {
            continue
        }

        # Build a temporary .npmrc with the feed entry so the credprovider writes the token into it
        $tempDir = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) "ado-npm-$([System.IO.Path]::GetRandomFileName())")
        Set-AdoNpmTokenOwnerOnlyAcl -Path $tempDir.FullName -Directory
        $tempNpmrc = Join-Path $tempDir.FullName '.npmrc'
        New-Item -ItemType File -Path $tempNpmrc -Force | Out-Null
        Set-AdoNpmTokenOwnerOnlyAcl -Path $tempNpmrc
        Set-Content -Path $tempNpmrc -Value "//$($entry.Feed -replace '^https?://', ''):_authToken="

        try {
            Write-Verbose "Requesting token for feed: $($entry.Feed)"
            $arguments = @('-c', $tempNpmrc)
            if ($Force) {
                $arguments += '--force'
            }

            # Run from the temp directory so the credprovider doesn't walk up
            # to ~ and find the user-level .npmrc (which would conflict with -c)
            Push-Location $tempDir
            try {
                & node $credProviderBin @arguments 2>&1 | ForEach-Object {
                    Write-Verbose $_
                }
            } finally {
                Pop-Location
            }

            $npmrcContent = Get-Content $tempNpmrc -Raw
            if ($npmrcContent -match ':_authToken=(.+)') {
                [System.Environment]::SetEnvironmentVariable($entry.Name, $Matches[1].Trim(), 'Process')
                Write-Verbose "$($entry.Name) updated successfully."
            }
            else {
                Write-Error "Failed to obtain token for $($entry.Name) from artifacts-npm-credprovider."
            }
        }
        finally {
            Clear-AdoNpmTokenFile -Path $tempNpmrc
            Remove-Item $tempDir.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
