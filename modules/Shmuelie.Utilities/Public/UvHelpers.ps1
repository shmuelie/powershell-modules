function Get-UvPackages {
    <#
    .SYNOPSIS
    List installed uv packages.
    .DESCRIPTION
    Lists packages installed via uv pip in the system Python environment, with optional filtering for outdated packages.
    .PARAMETER Outdated
    If specified, only lists packages that have a newer version available.
    .PARAMETER TopLevelOnly
    If specified, excludes packages that are dependencies of other installed packages.
    Checks each package's Required-by field via uv pip show.
    .EXAMPLE
    Get-UvPackages
    Lists all installed uv packages.
    .EXAMPLE
    Get-UvPackages -Outdated
    Lists only packages with available updates.
    .EXAMPLE
    Get-UvPackages -Outdated -TopLevelOnly
    Lists only top-level packages (not dependencies) with available updates.
    #>
    [CmdletBinding()]
    param(
        [switch]$Outdated,
        [switch]$TopLevelOnly
    )
    process {
        $packages = if ($Outdated) {
            uv pip list --no-progress --outdated --format json --system | ConvertFrom-Json
        }
        else {
            uv pip list --no-progress --format json --system | ConvertFrom-Json
        }

        if ($TopLevelOnly -and $packages) {
            # Filter to packages where Required-by is empty (no other package depends on them)
            $packages | Where-Object {
                $showOutput = uv pip show $_.name --system 2>$null | Out-String
                -not ($showOutput -match 'Required-by:\s+\S')
            }
        } else {
            $packages
        }
    }
}

function Update-UvPackage {
    <#
    .SYNOPSIS
    Update a uv package to the latest version.
    .DESCRIPTION
    Upgrades a package installed via uv pip in the system Python environment.
    Returns a typed result object with the package name and success status.
    .PARAMETER PackageName
    The name of the package to update. Accepts pipeline input from Get-UvPackages.
    .EXAMPLE
    Update-UvPackage -PackageName requests
    .EXAMPLE
    Get-UvPackages -Outdated | Update-UvPackage
    Updates all outdated uv packages.
    #>
    [OutputType('UvUpdateResult')]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(ValueFromPipeline=$true,ValueFromPipelineByPropertyName=$true)]
        [ValidateNotNullOrEmpty()]
        [Alias('name')]
        [string]$PackageName
    )
    process {
        if ($PSCmdlet.ShouldProcess($PackageName, 'uv pip install --upgrade')) {
            Write-Verbose "Updating $PackageName"
            uv pip install --upgrade $PackageName --system 2>&1 | ForEach-Object { Write-Verbose $_ }
            [PSCustomObject]@{
                PSTypeName = 'UvUpdateResult'
                Name       = $PackageName
                Success    = $LASTEXITCODE -eq 0
            }
        }
    }
}