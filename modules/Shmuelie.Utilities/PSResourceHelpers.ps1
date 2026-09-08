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

function Get-PSResourceMetadata {
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
        Import-Clixml -LiteralPath $metadataPath -ErrorAction Stop
    }
    catch {
        Write-Verbose "Could not read PSResourceGet metadata from '$metadataPath': $_"
        return $null
    }
}

function ConvertTo-PSResourceVersion {
    [CmdletBinding()]
    param(
        [PSObject]$Resource,

        [string]$FallbackVersion
    )

    $prerelease = [string]$Resource.Prerelease
    if (-not $prerelease) { $prerelease = [string]$Resource.AdditionalMetadata.Prerelease }
    $isPrerelease = $prerelease -or
        [string]$Resource.IsPrerelease -eq 'true' -or
        [string]$Resource.AdditionalMetadata.IsPrerelease -eq 'true'

    foreach ($text in @(
        [string]$Resource.AdditionalMetadata.NormalizedVersion
        [string]$Resource.NormalizedVersion
        [string]$Resource.Version
        $FallbackVersion
    )) {
        if (-not $text) { continue }

        # PSResourceInfo splits Version and Prerelease; serialized metadata may
        # instead carry the complete version in Version or NormalizedVersion.
        if ($prerelease -and ($text -split '\+', 2)[0] -notmatch '-') {
            $parts = $text -split '\+', 2
            $text = "$($parts[0])-$prerelease"
            if ($parts.Count -gt 1) { $text += "+$($parts[1])" }
        }

        if ($text -notmatch '^(?<Core>[0-9]+(?:\.[0-9]+){1,3})(?:-(?<Label>[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$') {
            Write-Verbose "Could not parse PSResource version '$text'."
            continue
        }
        $label = $Matches.Label
        $core = $null
        if (-not [version]::TryParse($Matches.Core, [ref]$core)) {
            Write-Verbose "Could not parse PSResource numeric version '$text'."
            continue
        }
        if ($isPrerelease -and -not $label) {
            Write-Verbose "PSResource version '$text' is marked prerelease but has no prerelease label."
            continue
        }

        [PSCustomObject]@{
            Version        = $text
            NumericVersion = [version]::new($core.Major, $core.Minor, [Math]::Max(0, $core.Build), [Math]::Max(0, $core.Revision))
            Prerelease     = [string]$label
            IsPrerelease   = [bool]$label
        }
        return
    }
}

function Compare-PSResourceVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSObject]$Left,

        [Parameter(Mandatory)]
        [PSObject]$Right
    )

    $comparison = $Left.NumericVersion.CompareTo($Right.NumericVersion)
    if ($comparison -ne 0) { return $comparison }
    if (-not $Left.IsPrerelease) {
        if ($Right.IsPrerelease) { return 1 }
        return 0
    }
    if (-not $Right.IsPrerelease) { return -1 }

    $leftLabels = $Left.Prerelease.Split('.')
    $rightLabels = $Right.Prerelease.Split('.')
    for ($index = 0; $index -lt [Math]::Min($leftLabels.Count, $rightLabels.Count); $index++) {
        $leftLabel = $leftLabels[$index]
        $rightLabel = $rightLabels[$index]
        $leftNumeric = $leftLabel -match '^[0-9]+$'
        $rightNumeric = $rightLabel -match '^[0-9]+$'
        if ($leftNumeric -and $rightNumeric) {
            # Numeric identifiers are unbounded in SemVer, not Int32 values.
            $comparison = ([System.Numerics.BigInteger]::Parse($leftLabel)).CompareTo(
                [System.Numerics.BigInteger]::Parse($rightLabel))
        }
        elseif ($leftNumeric) { return -1 }
        elseif ($rightNumeric) { return 1 }
        else {
            $comparison = [StringComparer]::OrdinalIgnoreCase.Compare($leftLabel, $rightLabel)
        }
        if ($comparison -ne 0) { return $comparison }
    }
    return $leftLabels.Count.CompareTo($rightLabels.Count)
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

        $metadata = Get-PSResourceMetadata -Directory $versionDirectory.FullName
        # The directory carries only the numeric version for prerelease saves.
        # Keep it as the fallback so dynamic manifests remain discoverable.
        $version = ConvertTo-PSResourceVersion -Resource $metadata -FallbackVersion $versionDirectory.Name

        if ($null -eq $version) {
            try {
                $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath -ErrorAction Stop
                $version = ConvertTo-PSResourceVersion -Resource ([PSCustomObject]@{
                    Version      = $manifest.ModuleVersion
                    Prerelease   = $manifest.PrivateData.PSData.Prerelease
                    IsPrerelease = ([string]$metadata.IsPrerelease -eq 'true' -or
                        [string]$metadata.AdditionalMetadata.IsPrerelease -eq 'true')
                })
            }
            catch {
                Write-Verbose "Could not read module version from '$manifestPath': $_"
            }
        }
        if ($null -eq $version) {
            Write-Warning "Could not determine module version from '$versionDirectory' or '$manifestPath'; skipping this version."
            continue
        }

        $candidates.Add([PSCustomObject]@{
            Name                     = $Name
            Version                  = $version.Version
            NumericVersion           = $version.NumericVersion
            Prerelease               = $version.Prerelease
            IsPrerelease             = $version.IsPrerelease
            Repository               = $metadata.Repository
            RepositorySourceLocation = $metadata.RepositorySourceLocation
            ManifestPath             = $manifestPath
        })
    }

    $directManifest = Join-Path $moduleRoot "$Name.psd1"
    if (Test-Path -LiteralPath $directManifest -PathType Leaf) {
        $metadata = Get-PSResourceMetadata -Directory $moduleRoot
        $version = ConvertTo-PSResourceVersion -Resource $metadata
        if ($null -eq $version) {
            try {
                $manifest = Import-PowerShellDataFile -LiteralPath $directManifest -ErrorAction Stop
                $version = ConvertTo-PSResourceVersion -Resource ([PSCustomObject]@{
                    Version      = $manifest.ModuleVersion
                    Prerelease   = $manifest.PrivateData.PSData.Prerelease
                    IsPrerelease = ([string]$metadata.IsPrerelease -eq 'true' -or
                        [string]$metadata.AdditionalMetadata.IsPrerelease -eq 'true')
                })
            }
            catch {
                Write-Verbose "Could not read module version from '$directManifest': $_"
            }
        }
        if ($null -ne $version) {
            $candidates.Add([PSCustomObject]@{
                Name                     = $Name
                Version                  = $version.Version
                NumericVersion           = $version.NumericVersion
                Prerelease               = $version.Prerelease
                IsPrerelease             = $version.IsPrerelease
                Repository               = $metadata.Repository
                RepositorySourceLocation = $metadata.RepositorySourceLocation
                ManifestPath             = $directManifest
            })
        }
        else {
            Write-Warning "Could not determine module version from '$directManifest'; skipping this version."
        }
    }

    $highest = $null
    $recorded = $null
    foreach ($candidate in $candidates) {
        if ($null -eq $highest -or (Compare-PSResourceVersion $candidate $highest) -gt 0) {
            $highest = $candidate
        }
        if ($candidate.Repository -or $candidate.RepositorySourceLocation) {
            if ($null -eq $recorded -or (Compare-PSResourceVersion $candidate $recorded) -gt 0) {
                $recorded = $candidate
            }
        }
    }
    if ($null -eq $highest) { return $null }
    if (-not $highest.Repository -and -not $highest.RepositorySourceLocation -and $recorded) {
        $highest.Repository = $recorded.Repository
        $highest.RepositorySourceLocation = $recorded.RepositorySourceLocation
    }

    return $highest
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

        Write-Warning "Could not resolve recorded repository source '$($Resource.RepositorySourceLocation)' for '$($Resource.Name)'; skipping instead of falling back to '$Repository'."
        return $null
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

        Prerelease versions are recovered from PSGetModuleInfo.xml, including
        NormalizedVersion and prerelease metadata. Only modules whose highest
        installed version is a prerelease include prereleases in repository queries.
        Prerelease labels are compared semantically (for example, beta.10 is newer
        than beta.2); a stable release is newer than a prerelease with the same
        numeric version. Stable installations stay on stable releases. Older
        versions can supply missing repository provenance, but not prerelease state.

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

        Checks each module's recorded repository (or PSGallery when absent) for
        newer versions and saves updates in place, retaining prerelease tracking
        for modules whose highest installed version is a prerelease.
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
        [ValidateNotNullOrEmpty()]
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
            if (-not $selectedRepository) { continue }

            $latestRemote = $null
            try {
                $findParameters = @{
                    Name        = $resourceName
                    Repository  = $selectedRepository
                    ErrorAction = 'Stop'
                }
                if ($resource.IsPrerelease) { $findParameters.Prerelease = $true }
                foreach ($remote in Find-PSResource @findParameters) {
                    $remoteVersion = ConvertTo-PSResourceVersion -Resource $remote
                    if ($null -eq $remoteVersion) {
                        Write-Warning "Could not determine version of '$resourceName' in repository '$selectedRepository'; skipping this result."
                        continue
                    }
                    if (-not $resource.IsPrerelease -and $remoteVersion.IsPrerelease) { continue }
                    if ($null -eq $latestRemote -or (Compare-PSResourceVersion $remoteVersion $latestRemote) -gt 0) {
                        $latestRemote = $remoteVersion
                    }
                }
            }
            catch {
                Write-Warning "Could not look up '$resourceName' in repository '$selectedRepository': $_"
                continue
            }

            if ($null -eq $latestRemote) {
                Write-Verbose "'$resourceName' was not found in repository '$selectedRepository'; skipping."
                continue
            }

            $remoteVersion = $latestRemote.Version
            if ((Compare-PSResourceVersion $resource $latestRemote) -ge 0) {
                Write-Verbose "'$resourceName' $installedVersion is already current (latest: $remoteVersion)."
                continue
            }

            if ($PSCmdlet.ShouldProcess($resourceName, "Update from $installedVersion to $remoteVersion from '$selectedRepository' in '$resolvedPath'")) {
                Save-PSResource -Name $resourceName -Version $remoteVersion -Path $resolvedPath `
                    -Repository $selectedRepository -TrustRepository -IncludeXml -AcceptLicense `
                    -SkipDependencyCheck -ErrorAction Stop
            }
        }
    }
}
