function Get-PipPackages {
    <#
    .SYNOPSIS
    List installed pip packages.
    .DESCRIPTION
    Lists packages installed via pip, with optional filtering by user scope and package state.
    .PARAMETER User
    If specified, lists only packages installed with --user.
    .PARAMETER PackageState
    Filter packages by state: Any (default), Outdated, or UpToDate.
    .PARAMETER TopLevelOnly
    If specified, excludes packages that are dependencies of other installed packages
    (passes --not-required to pip).
    .EXAMPLE
    Get-PipPackages
    Lists all installed pip packages.
    .EXAMPLE
    Get-PipPackages -PackageState Outdated
    Lists only packages with available updates.
    .EXAMPLE
    Get-PipPackages -PackageState Outdated -TopLevelOnly
    Lists only top-level packages (not dependencies) with available updates.
    .EXAMPLE
    Get-PipPackages -User -PackageState UpToDate
    Lists user-installed packages that are up to date.
    #>
    [CmdletBinding()]
    param (
        [switch]$User,
        [ValidateSet('Any','Outdated','UpToDate')]
        [string]$PackageState,
        [switch]$TopLevelOnly
    )
    process {
        $arguments = @('list', '--format', 'json', '--disable-pip-version-check')
        if ($User) {
            $arguments += '--user'
        }
        if ($TopLevelOnly) {
            $arguments += '--not-required'
        }
        if ($PackageState -eq 'Outdated') {
            $arguments += '--outdated'
        }
        elseif ($PackageState -eq 'UpToDate') {
            $arguments += '--uptodate'
        }

        & pip @arguments | ConvertFrom-Json
    }
}

function Update-PipPackage {
    <#
    .SYNOPSIS
    Update a pip package to the latest version.
    .DESCRIPTION
    Upgrades a package installed via pip using pip install --upgrade.
    Returns a typed result object with the package name and success status.
    .PARAMETER PackageName
    The name of the package to update. Accepts pipeline input from Get-PipPackages.
    .EXAMPLE
    Update-PipPackage -PackageName requests
    .EXAMPLE
    Get-PipPackages -PackageState Outdated | Update-PipPackage
    Updates all outdated pip packages.
    #>
    [OutputType('PipUpdateResult')]
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(ValueFromPipeline=$true,ValueFromPipelineByPropertyName=$true)]
        [ValidateNotNullOrEmpty()]
        [Alias('name')]
        [string]$PackageName
    )
    process {
        if ($PSCmdlet.ShouldProcess($PackageName, 'pip install --upgrade')) {
            Write-Verbose "Updating $PackageName"
            pip install --upgrade $PackageName 2>&1 | ForEach-Object { Write-Verbose $_ }
            [PSCustomObject]@{
                PSTypeName = 'PipUpdateResult'
                Name       = $PackageName
                Success    = $LASTEXITCODE -eq 0
            }
        }
    }
}