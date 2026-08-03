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
    $credProviderBin = Join-Path $npmRoot '@microsoft\artifacts-npm-credprovider\bin\index.js'
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
        $tempNpmrc = Join-Path $tempDir '.npmrc'
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
            Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}