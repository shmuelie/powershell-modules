function Expand-PSResourcePattern {
    [CmdletBinding()]
    param(
        [string[]]$Pattern
    )

    foreach ($entry in $Pattern) {
        foreach ($part in ($entry -split ',')) {
            $trimmed = $part.Trim()
            if ($trimmed) { $trimmed }
        }
    }
}

function Test-PSResourcePattern {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Value,

        [string[]]$Pattern
    )

    if (-not $Pattern -or $Pattern.Count -eq 0) { return $true }
    foreach ($item in $Pattern) {
        if ($Value -like $item) { return $true }
    }
    return $false
}

function Get-PSResourceProvenance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Directory
    )

    $metadataPath = Join-Path $Directory 'PSGetModuleInfo.xml'
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        return $null
    }

    try {
        $metadata = Import-Clixml -LiteralPath $metadataPath -ErrorAction Stop
        [PSCustomObject]@{
            Repository               = [string]$metadata.Repository
            RepositorySourceLocation = [string]$metadata.RepositorySourceLocation
        }
    }
    catch {
        Write-Verbose "Could not read PSResourceGet metadata from '$metadataPath': $_"
        return $null
    }
}

function Get-InstalledPSResourceInfoInPath {
    <#
    .SYNOPSIS
        Gets the highest installed version and repository provenance for a module.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $moduleRoot = Join-Path $Path $Name
    if (-not (Test-Path -LiteralPath $moduleRoot -PathType Container)) {
        return $null
    }

    $candidates = [System.Collections.Generic.List[PSObject]]::new()

    foreach ($versionDirectory in Get-ChildItem -LiteralPath $moduleRoot -Directory -ErrorAction SilentlyContinue) {
        $manifestPath = Join-Path $versionDirectory.FullName "$Name.psd1"
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { continue }

        try {
            $version = [version](Import-PowerShellDataFile -LiteralPath $manifestPath -ErrorAction Stop).ModuleVersion
        }
        catch {
            Write-Verbose "Could not read module version from '$manifestPath': $_"
            continue
        }

        $provenance = Get-PSResourceProvenance -Directory $versionDirectory.FullName
        $candidates.Add([PSCustomObject]@{
            Name                     = $Name
            Version                  = $version
            Repository               = $provenance.Repository
            RepositorySourceLocation = $provenance.RepositorySourceLocation
            ManifestPath             = $manifestPath
        })
    }

    $directManifest = Join-Path $moduleRoot "$Name.psd1"
    if (Test-Path -LiteralPath $directManifest -PathType Leaf) {
        try {
            $version = [version](Import-PowerShellDataFile -LiteralPath $directManifest -ErrorAction Stop).ModuleVersion
            $provenance = Get-PSResourceProvenance -Directory $moduleRoot
            $candidates.Add([PSCustomObject]@{
                Name                     = $Name
                Version                  = $version
                Repository               = $provenance.Repository
                RepositorySourceLocation = $provenance.RepositorySourceLocation
                ManifestPath             = $directManifest
            })
        }
        catch {
            Write-Verbose "Could not read module version from '$directManifest': $_"
        }
    }

    $candidates |
        Sort-Object Version -Descending |
        Select-Object -First 1
}

function Get-InstalledPSResourceInPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [string[]]$Name,

        [string[]]$Exclude
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return
    }

    $namePatterns = @(Expand-PSResourcePattern $Name)
    $excludePatterns = @(Expand-PSResourcePattern $Exclude)

    Get-ChildItem -LiteralPath $Path -Directory -ErrorAction SilentlyContinue |
        ForEach-Object {
            $resourceName = $_.Name
            if (-not (Test-PSResourcePattern -Value $resourceName -Pattern $namePatterns)) { return }
            if ($excludePatterns.Count -gt 0 -and
                (Test-PSResourcePattern -Value $resourceName -Pattern $excludePatterns)) {
                return
            }

            Get-InstalledPSResourceInfoInPath -Path $Path -Name $resourceName
        } |
        Where-Object { $null -ne $_ } |
        Sort-Object Name
}

function Resolve-PSResourceRepository {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSObject]$Resource,

        [string]$Repository = 'PSGallery',

        [switch]$Override
    )

    if ($Override) { return $Repository }
    if ($Resource.Repository) { return [string]$Resource.Repository }

    if ($Resource.RepositorySourceLocation) {
        try {
            $source = ([string]$Resource.RepositorySourceLocation).TrimEnd('/')
            $match = Get-PSResourceRepository -ErrorAction Stop |
                Where-Object { "$($_.Uri)".TrimEnd('/') -eq $source } |
                Select-Object -First 1
            if ($match) { return [string]$match.Name }
        }
        catch {
            Write-Verbose "Could not resolve repository source '$($Resource.RepositorySourceLocation)': $_"
        }
    }

    return $Repository
}

function Update-InstalledPSResource {
    <#
    .SYNOPSIS
        Update PowerShell resources deployed to a custom module path via Save-PSResource.
    .DESCRIPTION
        Enumerates modules discovered under the supplied path — as deployed by
        Save-PSResource — determines each module's highest installed version from the
        on-disk layout (<Path>/<Name>/<Version>/<Name>.psd1 for versioned layouts, or
        <Path>/<Name>/<Name>.psd1 for direct layouts), compares it to the latest version
        available in the given repository, and saves a newer version alongside the
        existing ones using Save-PSResource with the same root path.

        No Install-PSResource tracking or PSModulePath manipulation is required; this
        approach works correctly for modules deployed with Save-PSResource to any
        arbitrary directory.

        By default, each module is queried and updated from the repository recorded
        in the highest installed version's PSGetModuleInfo.xml. If only a recorded
        repository source URI is available, the registered repository with that URI
        is used. Modules without provenance fall back to PSGallery. An explicitly
        supplied -Repository overrides recorded provenance for every selected module.

        Use -Name and -Exclude wildcard filters to select managed modules and skip
        local/product-owned modules without repository lookup warnings.

        No-op when the path does not exist, when no selected modules are found, or
        when all selected modules are current. A repository lookup failure for one
        selected module is reported as a warning; other modules continue.
    .PARAMETER Path
        The module root directory to scan for installed PowerShell resources. This
        should be the same root directory that was passed to Save-PSResource when the
        modules were deployed.
    .PARAMETER Repository
        Explicit repository override. When supplied, all selected modules are queried
        and updated from this repository. When omitted, recorded metadata is honored
        and modules without provenance fall back to PSGallery.
    .PARAMETER Name
        Optional wildcard pattern(s) selecting module names to update. Accepts arrays
        and comma-separated values.
    .PARAMETER Exclude
        Optional wildcard pattern(s) excluding module names before repository lookup.
        Accepts arrays and comma-separated values.
    .EXAMPLE
        Update-InstalledPSResource -Path (Join-Path $HOME 'PowerShellModules')

        Checks PSGallery for newer versions of every module found under the custom
        module path and saves updates in place.
    .EXAMPLE
        Update-InstalledPSResource -Path $env:PSModulePath.Split([IO.Path]::PathSeparator)[0] -WhatIf

        Shows which resources would be updated without making any changes.
    .EXAMPLE
        Update-InstalledPSResource -Path D:\PowerShell\Modules -Name 'Shmuelie.*' -Exclude '*.Local'

        Updates matching modules from their recorded repositories while skipping
        local modules before any repository lookup.
    .EXAMPLE
        Update-InstalledPSResource -Path D:\PowerShell\Modules -Repository PSGallery

        Explicitly overrides recorded provenance and queries every selected module
        from PSGallery.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter()]
        [string]$Repository = 'PSGallery',

        [string[]]$Name,

        [string[]]$Exclude
    )

    begin {
        $repositoryOverride = $PSBoundParameters.ContainsKey('Repository')
    }

    process {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            Write-Verbose "Module path '$Path' does not exist. Nothing to update."
            return
        }

        $resolvedPath = (Resolve-Path -LiteralPath $Path).ProviderPath
        $resources = @(Get-InstalledPSResourceInPath -Path $resolvedPath -Name $Name -Exclude $Exclude)

        foreach ($resource in $resources) {
            $resourceName = $resource.Name
            $installedVersion = $resource.Version
            $selectedRepository = Resolve-PSResourceRepository `
                -Resource $resource `
                -Repository $Repository `
                -Override:$repositoryOverride

            $latestRemote = $null
            try {
                $latestRemote = @(Find-PSResource -Name $resourceName -Repository $selectedRepository -ErrorAction Stop) |
                    Sort-Object { [version]$_.Version } -Descending |
                    Select-Object -First 1
            }
            catch {
                Write-Warning "Could not look up '$resourceName' in repository '$selectedRepository': $_"
                continue
            }

            if ($null -eq $latestRemote) {
                Write-Verbose "'$resourceName' was not found in repository '$selectedRepository'; skipping."
                continue
            }

            $remoteVersion = [version]$latestRemote.Version.ToString()
            if ($installedVersion -ge $remoteVersion) {
                Write-Verbose "'$resourceName' $installedVersion is already current (latest: $remoteVersion)."
                continue
            }

            if ($PSCmdlet.ShouldProcess($resourceName, "Update from $installedVersion to $remoteVersion in '$resolvedPath'")) {
                Save-PSResource -Name $resourceName -Version $remoteVersion.ToString() -Path $resolvedPath `
                    -Repository $selectedRepository -TrustRepository -IncludeXml -AcceptLicense `
                    -SkipDependencyCheck -ErrorAction Stop
            }
        }
    }
}
