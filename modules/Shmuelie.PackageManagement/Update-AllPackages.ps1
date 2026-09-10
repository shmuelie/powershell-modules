function Update-AllPackages {
    <#
    .SYNOPSIS
        Update packages through the available package-provider integrations.
    .DESCRIPTION
        Selects all known providers by default, in catalog order. Unsupported
        platforms, missing dependencies, and integrations not yet implemented
        produce Skipped results with reasons. Providers are imported only when
        selected; importing this module does not require any provider module.

        See the module README for provider availability and supported options.
        Unimplemented or unavailable integrations report Skipped.
        PSResourceGet updates configured module roots using Shmuelie.Utilities;
        no configured roots produces Skipped instead of scanning PSModulePath.

        Each integration discovers targets without mutation. ShouldProcess
        gates each target's update callback. WhatIf runs only discovery and
        returns Planned results; it never invokes an update callback.

        Provider failures, including nonterminating errors, are returned as
        typed Failed results rather than terminating independent providers.
        Invalid selection or options terminate before discovery or updates.
    .PARAMETER Provider
        Include only these provider names. Defaults to all known providers.
        Names are case-insensitive and support tab completion. Duplicates do
        not run a provider twice; execution always follows catalog order.
    .PARAMETER ExcludeProvider
        Remove these providers from the selected set. Exclusion wins.
    .PARAMETER ProviderOptions
        Hashtable keyed by provider name. Each value is a hashtable of options
        explicitly supported by that integration. Unknown providers, option
        names, or non-hashtable values are rejected before any work.
        Options for unselected providers are validated but not executed.
        Provider and option keys are case-insensitive, including JSON-derived
        hashtables. Case-equivalent duplicate keys are rejected. The caller's
        maps are not modified.
        Pip accepts Boolean User (default false) and TopLevelOnly (default
        true). User filters discovery and observation, not the installation
        destination; the existing updater has no user-install option.
    .PARAMETER StopOnFailure
        Stop after the first failing callback, before another target or
        provider starts. Preserve all results produced by that callback.
        Skipped providers are not failures.
    .OUTPUTS
        Shmuelie.PackageManagement.UpdateResult
        Provider, Target, PreviousVersion, ResultingVersion, Status, Error,
        and Reason. Status is Planned, Updated, Unchanged, Skipped, or Failed.
        Error is the original ErrorRecord when available. Unknown versions
        are null. Planned ResultingVersion is the proposed version, not an
        observed installed version.
    .EXAMPLE
        Update-AllPackages -WhatIf
        Preview all available integrations. Unimplemented integrations skip.
    .EXAMPLE
        Update-AllPackages -Provider Npm, DotNet -ExcludeProvider Npm -StopOnFailure
        Select only DotNet and stop if its integration fails.
    .EXAMPLE
        Update-AllPackages -Provider PSResourceGet -ProviderOptions @{
            PSResourceGet = @{ Path = (Join-Path $HOME 'PowerShellModules'); Name = 'MyTools.*'; Exclude = '*.Local' }
        } -WhatIf
        Preview locally discovered modules without contacting repositories.
        Proposed versions are unknown until the canonical update runs.
    .EXAMPLE
        Update-AllPackages -Provider Npm -WhatIf
        Preview outdated global npm packages without touching local dependencies.
    .EXAMPLE
        Update-AllPackages -Provider Pip -ProviderOptions @{ Pip = @{ User = $true } } -WhatIf
        Preview outdated top-level user-installed pip packages.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('Shmuelie.PackageManagement.UpdateResult')]
    param(
        [ValidateNotNullOrEmpty()]
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete)
            & (Get-Module Shmuelie.PackageManagement) { Get-PackageProvider } |
                Where-Object Name -Like "$wordToComplete*" | ForEach-Object { $_.Name }
        })]
        [string[]]$Provider = @(),

        [ValidateNotNullOrEmpty()]
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete)
            & (Get-Module Shmuelie.PackageManagement) { Get-PackageProvider } |
                Where-Object Name -Like "$wordToComplete*" | ForEach-Object { $_.Name }
        })]
        [string[]]$ExcludeProvider = @(),

        [ValidateNotNull()]
        [hashtable]$ProviderOptions = @{},

        [switch]$StopOnFailure
    )

    # JSON-derived and custom hashtables can use case-sensitive comparers.
    $normalizedProviderOptions = [hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $ProviderOptions.Keys) {
        if ($normalizedProviderOptions.ContainsKey($name)) {
            throw "Duplicate provider key '$name' in ProviderOptions; provider keys are case-insensitive."
        }
        $options = $ProviderOptions[$name]
        if ($options -isnot [hashtable]) {
            throw "Options for provider '$name' must be a hashtable."
        }
        $normalizedOptions = [hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($option in $options.Keys) {
            if ($normalizedOptions.ContainsKey($option)) {
                throw "Duplicate option key '$option' for provider '$name'; option keys are case-insensitive."
            }
            $normalizedOptions.Add($option, $options[$option])
        }
        $normalizedProviderOptions.Add($name, $normalizedOptions)
    }

    $catalog = @(Get-PackageProvider)
    $names = @($catalog.Name)
    foreach ($name in @($Provider) + @($ExcludeProvider) + @($normalizedProviderOptions.Keys)) {
        if ($name -notin $names) {
            throw "Unknown provider '$name'. Valid providers: $($names -join ', ')."
        }
    }
    foreach ($name in $normalizedProviderOptions.Keys) {
        $options = $normalizedProviderOptions[$name]
        $descriptor = $catalog | Where-Object Name -EQ $name
        foreach ($option in $options.Keys) {
            if ($option -notin $descriptor.OptionNames) {
                throw "Unknown option '$option' for provider '$name'. Supported options: $($descriptor.OptionNames -join ', ')."
            }
        }
    }

    foreach ($descriptor in $catalog) {
        $name = $descriptor.Name
        if (($Provider -and $name -notin $Provider) -or $name -in $ExcludeProvider) { continue }
        $options = if ($normalizedProviderOptions.ContainsKey($name)) { $normalizedProviderOptions[$name].Clone() } else { @{} }
        $availability = @(Invoke-PackageProviderCallback -Callback {
            param($Descriptor, $Options)
            Get-PackageProviderAvailability -Descriptor $Descriptor -Options $Options
        } -Arguments @{ Descriptor = $descriptor; Options = $options })
        $errors = @($availability | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
        if ($errors.Count) {
            foreach ($providerError in $errors) {
                New-PackageUpdateResult -Provider $name -Target $name -Status Failed -Error $providerError
            }
            if ($StopOnFailure) { return }
            continue
        }
        if ($availability.Count -ne 1 -or $availability[0].Available -isnot [bool] -or
            (-not $availability[0].Available -and [string]::IsNullOrWhiteSpace($availability[0].Reason))) {
            New-PackageProviderFailure -Provider $name -Target $name -Message "Provider '$name' returned invalid availability; expected Available (Boolean) and a Reason when unavailable."
            if ($StopOnFailure) { return }
            continue
        }
        if (-not $availability[0].Available) {
            New-PackageUpdateResult -Provider $name -Target $name -Status Skipped -Reason $availability[0].Reason
            continue
        }

        $targets = @(Invoke-PackageProviderCallback -Callback $descriptor.GetTargets -Arguments @{ Options = $options })
        $errors = @($targets | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
        if ($errors.Count) {
            foreach ($providerError in $errors) {
                New-PackageUpdateResult -Provider $name -Target $name -Status Failed -Error $providerError
            }
            if ($StopOnFailure) { return }
            continue
        }
        $invalidTargets = @($targets | Where-Object {
            $_.PSTypeNames -notcontains 'Shmuelie.PackageManagement.UpdateTarget' -or
            $_.Target -isnot [string] -or
            [string]::IsNullOrWhiteSpace($_.Target) -or
            -not $_.PSObject.Properties['PreviousVersion'] -or
            -not $_.PSObject.Properties['ProposedVersion'] -or
            -not $_.PSObject.Properties['Data'] -or
            ($null -ne $_.PreviousVersion -and $_.PreviousVersion -isnot [string]) -or
            ($null -ne $_.ProposedVersion -and $_.ProposedVersion -isnot [string])
        })
        if ($invalidTargets.Count) {
            New-PackageProviderFailure -Provider $name -Target $name -Message "Provider '$name' returned invalid targets; use New-PackageUpdateTarget."
            if ($StopOnFailure) { return }
            continue
        }
        if (-not $targets.Count) {
            New-PackageUpdateResult -Provider $name -Target $name -Status Unchanged -Reason 'Provider reported no update targets.'
            continue
        }
        foreach ($target in $targets) {
            if (-not $PSCmdlet.ShouldProcess("$name / $($target.Target)", 'Update package')) {
                if ($WhatIfPreference) {
                    New-PackageUpdateResult -Provider $name -Target $target.Target -PreviousVersion $target.PreviousVersion -ResultingVersion $target.ProposedVersion -Status Planned
                } else {
                    New-PackageUpdateResult -Provider $name -Target $target.Target -PreviousVersion $target.PreviousVersion -Status Skipped -Reason 'Update was not confirmed.'
                }
                continue
            }

            $results = @(Invoke-PackageProviderCallback -Callback $descriptor.Update -Arguments @{ Target = $target; Options = $options })
            $failed = $false
            if (-not $results.Count) {
                New-PackageProviderFailure -Provider $name -Target $target.Target -PreviousVersion $target.PreviousVersion -Message "Provider '$name' returned no update result; the outcome is unknown."
                $failed = $true
            }
            foreach ($result in $results) {
                if ($result -is [System.Management.Automation.ErrorRecord]) {
                    New-PackageUpdateResult -Provider $name -Target $target.Target -PreviousVersion $target.PreviousVersion -Status Failed -Error $result
                    $failed = $true
                } elseif (-not (Test-PackageUpdateResult -Result $result -Provider $name -Target $target.Target)) {
                    New-PackageProviderFailure -Provider $name -Target $target.Target -PreviousVersion $target.PreviousVersion -Message "Provider '$name' returned invalid update output; use New-PackageUpdateResult for this target."
                    $failed = $true
                } else {
                    $result
                    if ($result.Status -eq 'Failed') { $failed = $true }
                }
            }
            if ($failed -and $StopOnFailure) { return }
        }
    }
}
