function Get-PipPackageProvider {
    [CmdletBinding()]
    param()

    [pscustomobject]@{
        Name             = 'Pip'
        Platforms        = @('Windows', 'Linux', 'MacOS')
        RequiredModules  = @('Shmuelie.Utilities')
        RequiredCommands = @('Shmuelie.Utilities\Get-PipPackages', 'Shmuelie.Utilities\Update-PipPackage', 'pip')
        OptionNames      = @('User', 'TopLevelOnly')
        TestAvailable    = $null
        GetTargets       = {
            param([hashtable]$Options)

            $parameters = Get-PipProviderOptions -Options $Options
            $packages = @(Get-PipProviderPackages @parameters -PackageState Outdated)
            $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($package in $packages) {
                $name = Get-PipProviderPackageName -Name $package.name
                if (-not $names.Add($name)) {
                    throw "pip returned duplicate package '$($package.name)'."
                }
                New-PackageUpdateTarget -Target $package.name -PreviousVersion $package.version -ProposedVersion $package.latest_version
            }
        }
        Update           = {
            param($Target, [hashtable]$Options)

            $parameters = Get-PipProviderOptions -Options $Options
            $name = Get-PipProviderPackageName -Name $Target.Target
            $diagnostics = [System.Collections.Generic.List[string]]::new()
            # The public updater sends native output to verbose and has no User switch.
            $results = @(Shmuelie.Utilities\Update-PipPackage -PackageName $Target.Target -Confirm:$false -ErrorAction Stop -Verbose 4>&1 |
                ForEach-Object {
                    if ($_ -is [System.Management.Automation.VerboseRecord]) {
                        $diagnostics.Add($_.Message)
                        Write-Verbose $_.Message
                    } else {
                        $_
                    }
                })
            $exitCode = $LASTEXITCODE
            if ($exitCode -ne 0) {
                throw "pip update failed for '$($Target.Target)' (exit code $exitCode). $($diagnostics -join [Environment]::NewLine)"
            }
            if ($results.Count -ne 1 -or $results[0].PSTypeNames -notcontains 'PipUpdateResult' -or
                $results[0].Success -isnot [bool] -or
                (Get-PipProviderPackageName -Name $results[0].Name) -ne $name) {
                throw "Update-PipPackage returned an invalid result for '$($Target.Target)'; the outcome is unknown."
            }
            if (-not $results[0].Success) {
                throw "Update-PipPackage reported failure for '$($Target.Target)'. $($diagnostics -join [Environment]::NewLine)"
            }

            # Observe all installed packages in the selected scope, even if dependencies changed.
            $installed = @(Get-PipProviderPackages -User:$parameters.User -PackageState Any)
            $observed = @($installed | Where-Object { (Get-PipProviderPackageName -Name $_.name) -eq $name })
            if ($observed.Count -ne 1 -or [string]::IsNullOrWhiteSpace($observed[0].version)) {
                throw "Cannot observe one installed version for '$($Target.Target)' after the update."
            }
            $status = if ($observed[0].version -ceq $Target.PreviousVersion) { 'Unchanged' } else { 'Updated' }
            New-PackageUpdateResult -Provider Pip -Target $Target.Target -PreviousVersion $Target.PreviousVersion -ResultingVersion $observed[0].version -Status $status
        }
    }
}

function Get-PipProviderOptions {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Options)

    $parameters = @{ User = $false; TopLevelOnly = $true }
    foreach ($key in $Options.Keys) {
        if ($key -notin 'User', 'TopLevelOnly' -or
            ($Options[$key] -isnot [bool] -and $Options[$key] -isnot [System.Management.Automation.SwitchParameter])) {
            throw "Pip option '$key' must be User or TopLevelOnly with a Boolean value."
        }
        $parameters[$key] = [bool]$Options[$key]
    }
    $parameters
}

function Get-PipProviderPackageName {
    [CmdletBinding()]
    param([AllowNull()][object]$Name)

    # Distribution names only: never forward options, requirement specifiers, URLs, or shell syntax.
    if ($Name -isnot [string] -or $Name -cnotmatch '\A[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?\z') {
        throw "pip returned an invalid package name '$Name'."
    }
    ($Name -replace '[-_.]+', '-').ToLowerInvariant()
}

function Get-PipProviderPackages {
    [CmdletBinding()]
    param(
        [switch]$User,
        [switch]$TopLevelOnly,
        [ValidateSet('Any', 'Outdated')][string]$PackageState
    )

    $packages = @(Shmuelie.Utilities\Get-PipPackages -User:$User -TopLevelOnly:$TopLevelOnly -PackageState $PackageState -ErrorAction Stop)
    if ($LASTEXITCODE -ne 0) {
        throw "pip list failed (exit code $LASTEXITCODE)."
    }
    foreach ($package in $packages) {
        $null = Get-PipProviderPackageName -Name $package.name
        foreach ($property in 'version', 'latest_version') {
            if ($null -ne $package.$property -and $package.$property -isnot [string]) {
                throw "pip returned an invalid $property for '$($package.name)'."
            }
        }
    }
    $packages
}
