function Get-InstalledPSResourceNameInPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return
    }

    $resolvedPath = (Resolve-Path -LiteralPath $Path).ProviderPath
    Get-ChildItem -LiteralPath $resolvedPath -Directory -ErrorAction SilentlyContinue |
        ForEach-Object {
            $resourceName = $_.Name
            $resourceRoot = $_.FullName
            $directManifest = Join-Path $resourceRoot "$resourceName.psd1"

            if (Test-Path -LiteralPath $directManifest -PathType Leaf) {
                $resourceName
            }
            else {
                $versionedManifest = Get-ChildItem -LiteralPath $resourceRoot -Directory -ErrorAction SilentlyContinue |
                    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "$resourceName.psd1") -PathType Leaf } |
                    Select-Object -First 1

                if ($versionedManifest) {
                    $resourceName
                }
            }
        } |
        Sort-Object -Unique
}

function Get-InstalledPSResourceVersionInPath {
    # Returns the highest installed [version] for a named resource in the given
    # module root, or $null when no recognisable layout is found.
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

    # Versioned layout: <Root>/<Name>/<Version>/<Name>.psd1 — version is the directory name.
    $versions = @(
        Get-ChildItem -LiteralPath $moduleRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "$Name.psd1") -PathType Leaf } |
            ForEach-Object {
                try { [version]$_.Name }
                catch { $null }
            } |
            Where-Object { $null -ne $_ }
    )

    if ($versions.Count -gt 0) {
        return ($versions | Sort-Object -Descending)[0]
    }

    # Direct layout: <Root>/<Name>/<Name>.psd1 — read version from manifest.
    $directManifest = Join-Path $moduleRoot "$Name.psd1"
    if (Test-Path -LiteralPath $directManifest -PathType Leaf) {
        try {
            return [version](Import-PowerShellDataFile -LiteralPath $directManifest -ErrorAction Stop).ModuleVersion
        }
        catch {
            Write-Verbose "Could not read module version from '$directManifest': $_"
        }
    }

    return $null
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

        No-op when the path does not exist, when no modules are found, or when all
        discovered modules are already at the latest version. A repository lookup
        failure for one module is reported as a non-terminating warning; processing
        continues for the remaining modules.
    .PARAMETER Path
        The module root directory to scan for installed PowerShell resources. This
        should be the same root directory that was passed to Save-PSResource when the
        modules were deployed.
    .PARAMETER Repository
        PSResourceGet repository to query for available updates. Defaults to 'PSGallery'.
    .EXAMPLE
        Update-InstalledPSResource -Path (Join-Path $HOME 'PowerShellModules')

        Checks PSGallery for newer versions of every module found under the custom
        module path and saves updates in place.
    .EXAMPLE
        Update-InstalledPSResource -Path $env:PSModulePath.Split([IO.Path]::PathSeparator)[0] -WhatIf

        Shows which resources would be updated without making any changes.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter()]
        [string]$Repository = 'PSGallery'
    )

    process {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            Write-Verbose "Module path '$Path' does not exist. Nothing to update."
            return
        }

        $resolvedPath = (Resolve-Path -LiteralPath $Path).ProviderPath
        $resourceNames = @(Get-InstalledPSResourceNameInPath -Path $resolvedPath)

        foreach ($resourceName in $resourceNames) {
            $installedVersion = Get-InstalledPSResourceVersionInPath -Path $resolvedPath -Name $resourceName
            if ($null -eq $installedVersion) {
                Write-Verbose "Could not determine installed version of '$resourceName'; skipping."
                continue
            }

            $latestRemote = $null
            try {
                $latestRemote = @(Find-PSResource -Name $resourceName -Repository $Repository -ErrorAction Stop) |
                    Sort-Object { [version]$_.Version } -Descending |
                    Select-Object -First 1
            }
            catch {
                Write-Warning "Could not look up '$resourceName' in repository '$Repository': $_"
                continue
            }

            if ($null -eq $latestRemote) {
                Write-Verbose "'$resourceName' was not found in repository '$Repository'; skipping."
                continue
            }

            $remoteVersion = [version]$latestRemote.Version.ToString()
            if ($installedVersion -ge $remoteVersion) {
                Write-Verbose "'$resourceName' $installedVersion is already current (latest: $remoteVersion)."
                continue
            }

            if ($PSCmdlet.ShouldProcess($resourceName, "Update from $installedVersion to $remoteVersion in '$resolvedPath'")) {
                Save-PSResource -Name $resourceName -Version $remoteVersion.ToString() -Path $resolvedPath `
                    -Repository $Repository -TrustRepository -IncludeXml -AcceptLicense `
                    -SkipDependencyCheck -ErrorAction Stop
            }
        }
    }
}
