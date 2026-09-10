function Get-PSResourceGetPackageProvider {
    [CmdletBinding()]
    param()

    [pscustomobject]@{
        Name             = 'PSResourceGet'
        Platforms        = @('Windows', 'Linux', 'MacOS')
        RequiredModules  = @('Microsoft.PowerShell.PSResourceGet', 'Shmuelie.Utilities')
        RequiredCommands = @(
            'Microsoft.PowerShell.PSResourceGet\Find-PSResource'
            'Microsoft.PowerShell.PSResourceGet\Save-PSResource'
            'Microsoft.PowerShell.PSResourceGet\Get-PSResourceRepository'
            'Shmuelie.Utilities\Update-InstalledPSResource'
        )
        OptionNames      = @('Path', 'Name', 'Exclude', 'Repository')
        TestAvailable    = {
            param([hashtable]$Options)
            $paths = @(Resolve-PSResourceGetPackagePath -Options $Options)
            if (-not $paths.Count) {
                return [pscustomobject]@{
                    Available = $false
                    Reason = 'Configure ProviderOptions.PSResourceGet.Path with one or more existing module root directories previously used with Save-PSResource.'
                }
            }
            $module = (Get-Command 'Shmuelie.Utilities\Update-InstalledPSResource' -ListImported -ErrorAction Stop).Module
            $compatible = & $module {
                foreach ($name in 'Get-InstalledPSResourceInPath', 'Compare-PSResourceVersion') {
                    if (-not (Get-Command $name -CommandType Function -ListImported -ErrorAction Ignore)) { return $false }
                }
                return $true
            }
            [pscustomobject]@{
                Available = $compatible
                Reason = if (-not $compatible) { 'Update Shmuelie.Utilities to a version providing the PSResource discovery and version-comparison helpers.' } else { $null }
            }
        }
        GetTargets       = {
            param([hashtable]$Options)
            foreach ($path in Resolve-PSResourceGetPackagePath -Options $Options) {
                foreach ($resource in Get-PSResourceGetPackageResource -Path $path -Name $Options.Name -Exclude $Options.Exclude) {
                    # The canonical Name selector splits commas, even in literal names.
                    if ($resource.Name.Contains(',')) {
                        throw "Module '$($resource.Name)' cannot be individually selected by Update-InstalledPSResource because its name contains a comma."
                    }
                    New-PackageUpdateTarget -Target (Join-Path $path $resource.Name) -PreviousVersion $resource.Version -Data @{
                        Path = $path
                        Resource = $resource
                    }
                }
            }
        }
        Update           = {
            param($Target, [hashtable]$Options)
            $parameters = @{
                Path = $Target.Data.Path
                Name = [System.Management.Automation.WildcardPattern]::Escape($Target.Data.Resource.Name)
                Confirm = $false
                ErrorAction = 'Stop'
                WarningVariable = 'providerWarnings'
                WarningAction = 'Continue'
            }
            if ($Options.ContainsKey('Repository')) { $parameters.Repository = $Options.Repository }
            $providerWarnings = @()
            # Relay warnings in this module's scope so aggregate warning preferences
            # and WarningVariable apply across the optional module boundary.
            Shmuelie.Utilities\Update-InstalledPSResource @parameters 3>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.WarningRecord]) { Write-Warning $_.Message }
            }

            $observed = @(Get-PSResourceGetPackageResource -Path $parameters.Path -Name $parameters.Name)
            if ($observed.Count -ne 1) {
                throw "Could not observe the installed version of '$($Target.Target)' after Update-InstalledPSResource; the update outcome is unknown."
            }
            $module = (Get-Command 'Shmuelie.Utilities\Update-InstalledPSResource' -ListImported -ErrorAction Stop).Module
            $comparison = & $module {
                param($Left, $Right)
                Compare-PSResourceVersion -Left $Left -Right $Right
            } $observed[0] $Target.Data.Resource
            if ($comparison -lt 0) {
                throw "The installed version of '$($Target.Target)' decreased from '$($Target.PreviousVersion)' to '$($observed[0].Version)' during the update."
            }
            $status = if ($comparison -gt 0) { 'Updated' } elseif ($providerWarnings.Count) { 'Skipped' } else { 'Unchanged' }
            $reason = if ($providerWarnings.Count) {
                ($providerWarnings | ForEach-Object { $_.Message }) -join [Environment]::NewLine
            } elseif ($comparison -eq 0) {
                'No newer installed version was observed. The canonical command does not distinguish current modules from silent skips (for example, a module not found in its repository).'
            } else { $null }
            New-PackageUpdateResult -Provider PSResourceGet -Target $Target.Target -PreviousVersion $Target.PreviousVersion `
                -ResultingVersion $observed[0].Version -Status $status -Reason $reason
        }
    }
}

function Resolve-PSResourceGetPackagePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Options)

    foreach ($name in 'Path', 'Name', 'Exclude') {
        if (-not $Options.ContainsKey($name)) { continue }
        $value = $Options[$name]
        if ($null -eq $value -or ($value -isnot [string] -and $value -isnot [array])) {
            throw "PSResourceGet option '$name' must be a string or an array of strings."
        }
        foreach ($entry in @($value)) {
            if ($entry -isnot [string] -or [string]::IsNullOrWhiteSpace($entry)) {
                throw "PSResourceGet option '$name' must contain only nonempty strings."
            }
        }
    }
    if ($Options.ContainsKey('Repository') -and
        ($Options.Repository -isnot [string] -or [string]::IsNullOrWhiteSpace($Options.Repository))) {
        throw "PSResourceGet option 'Repository' must be a nonempty string."
    }

    $comparer = if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
    $seen = [System.Collections.Generic.HashSet[string]]::new($comparer)
    foreach ($path in $Options.Path) {
        if (-not (Test-Path -LiteralPath $path -PathType Container -ErrorAction Stop)) {
            Write-Warning "Configured PSResourceGet module root '$path' does not exist or is not a directory; skipping this root."
            continue
        }
        $resolved = Resolve-Path -LiteralPath $path -ErrorAction Stop
        if ($resolved.Provider.Name -ne 'FileSystem') {
            throw "PSResourceGet module root '$path' must be a filesystem directory."
        }
        $root = [IO.Path]::TrimEndingDirectorySeparator($resolved.ProviderPath)
        if ($seen.Add($root)) { $root }
    }
}

function Get-PSResourceGetPackageResource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Name,
        [string[]]$Exclude
    )

    # Keep layout, filtering, provenance, and prerelease rules owned by Utilities.
    $module = (Get-Command 'Shmuelie.Utilities\Update-InstalledPSResource' -ListImported -ErrorAction Stop).Module
    & $module {
        param($Path, $Name, $Exclude)
        Get-InstalledPSResourceInPath -Path $Path -Name $Name -Exclude $Exclude -ErrorAction Stop
    } $Path $Name $Exclude
}
