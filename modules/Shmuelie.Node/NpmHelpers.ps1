function ConvertFrom-NpmJsonOutput {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true)]
        [AllowNull()]
        [string]$InputObject
    )

    process {
        if ([string]::IsNullOrWhiteSpace($InputObject)) { return }

        $start = $InputObject.IndexOf('{')
        $end = $InputObject.LastIndexOf('}')
        if ($start -lt 0 -or $end -lt $start) { return }

        $json = $InputObject.Substring($start, $end - $start + 1)
        if ([string]::IsNullOrWhiteSpace($json)) { return }

        $json | ConvertFrom-Json
    }
}

function Get-NpmPackage {
    <#
    .SYNOPSIS
        Gets installed NPM packages
    .DESCRIPTION
        Returns objects representing globally or locally installed NPM packages
        with Name, Version, and Description properties. Use -Outdated to return
        only packages that have a newer version available.
    .PARAMETER Global
        If specified, lists globally installed packages instead of local
    .PARAMETER Outdated
        If specified, returns only packages with available updates, including
        Current and Latest version properties.
    .EXAMPLE
        Get-NpmPackage
        Lists locally installed NPM packages as objects
    .EXAMPLE
        Get-NpmPackage -Global
        Lists globally installed NPM packages as objects
    .EXAMPLE
        Get-NpmPackage -Global -Outdated
        Lists only globally installed packages that have updates available
    .EXAMPLE
        Get-NpmPackage -Global -Outdated | Update-NpmPackage -Global
        Updates only outdated globally installed packages
    #>
    [OutputType('NpmPackage')]
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$Global,

        [Parameter()]
        [switch]$Outdated
    )

    if ($Outdated) {
        $arguments = @('outdated', '--json')
        if ($Global) {
            $arguments += '--global'
        }

        $jsonOutput = & npm @arguments 2>$null | Out-String
        $parsed = $jsonOutput | ConvertFrom-NpmJsonOutput
        if (-not $parsed) { return }

        $parsed.PSObject.Properties | ForEach-Object {
            [PSCustomObject]@{
                PSTypeName  = 'NpmPackage'
                Name        = $_.Name
                Version     = $_.Value.current
                Latest      = $_.Value.latest
                Global      = [bool]$Global
            }
        }
    } else {
        $arguments = @('list', '--json', '--depth=0')
        if ($Global) {
            $arguments += '--global'
        }

        $jsonOutput = & npm @arguments 2>$null | Out-String
        $parsed = $jsonOutput | ConvertFrom-NpmJsonOutput

        if ($parsed -and $parsed.dependencies) {
            $parsed.dependencies.PSObject.Properties | ForEach-Object {
                [PSCustomObject]@{
                    PSTypeName  = 'NpmPackage'
                    Name        = $_.Name
                    Version     = $_.Value.version
                    Description = $_.Value.description
                    Global      = [bool]$Global
                }
            }
        }
    }
}

function Update-NpmPackage {
    <#
    .SYNOPSIS
        Updates one or more NPM packages
    .DESCRIPTION
        Updates NPM packages by name. Supports pipeline input from Get-NpmPackage.
        Returns an NpmUpdateResult object per package with the name and success status.
    .PARAMETER Name
        The name of the package to update. Accepts pipeline input.
    .PARAMETER Global
        If specified, updates the package globally
    .EXAMPLE
        Update-NpmPackage -Name typescript
        Updates the typescript package locally
    .EXAMPLE
        Update-NpmPackage -Name typescript -Global
        Updates the typescript package globally
    .EXAMPLE
        Get-NpmPackage -Global | Update-NpmPackage
        Updates all globally installed packages
    .EXAMPLE
        Get-NpmPackage -Global | Update-NpmPackage | Where-Object Success -eq $false
        Shows only packages that failed to update
    #>
    [OutputType('NpmUpdateResult')]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipelineByPropertyName = $true)]
        [string]$Name,

        [Parameter(ValueFromPipelineByPropertyName = $true)]
        [switch]$Global
    )

    process {
        # npm update -g doesn't reliably work for scoped packages from private registries.
        # Use npm install -g <name>@latest instead for global updates.
        if ($Global) {
            $arguments = @('install', '-g', "$Name@latest")
        } else {
            $arguments = @('update', $Name)
        }

        if ($PSCmdlet.ShouldProcess("$Name", "npm update")) {
            Write-Verbose "Updating $Name"
            & npm @arguments 2>&1 | ForEach-Object { Write-Verbose $_ }
            [PSCustomObject]@{
                PSTypeName = 'NpmUpdateResult'
                Name       = $Name
                Global     = [bool]$Global
                Success    = ($LASTEXITCODE -eq 0)
            }
        }
    }
}