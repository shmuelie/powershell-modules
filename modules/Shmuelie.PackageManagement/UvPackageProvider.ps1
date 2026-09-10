function Get-UvPackageProvider {
    <#
    .SYNOPSIS
        Describe the optional uv package and tool adapter without probing dependencies.
    .DESCRIPTION
        Scope defaults to All (Packages and Tools). Packages are outdated system
        Python packages, with TopLevelOnly defaulting to true. Tools are installed
        uv tools, upgraded individually with their recorded constraints intact.
        TopLevelOnly is Boolean and is not supported with Scope Tools.
        Custom Python interpreters, virtual environments and arbitrary uv arguments
        are not supported. The core approves each target before calling Update.
    #>
    [CmdletBinding()]
    param()

    [pscustomobject]@{
        Name = 'Uv'
        Platforms = @('Windows', 'Linux', 'MacOS')
        RequiredModules = @()
        RequiredCommands = @('uv')
        OptionNames = @('Scope', 'TopLevelOnly')
        TestAvailable = {
            param([hashtable]$Options)
            $settings = Resolve-UvProviderOptions -Options $Options
            if ($settings.Scope -ne 'Tools') {
                # Tools alone do not need the optional package-command module.
                $dependency = [pscustomobject]@{
                    Name = 'Uv'
                    Platforms = @('Windows', 'Linux', 'MacOS')
                    RequiredModules = @('Shmuelie.Utilities')
                    RequiredCommands = @('Shmuelie.Utilities\Get-UvPackages', 'Shmuelie.Utilities\Update-UvPackage')
                    TestAvailable = $null
                    GetTargets = {}
                    Update = {}
                }
                Get-PackageProviderAvailability -Descriptor $dependency -Options $Options
            } else {
                [pscustomobject]@{ Available = $true; Reason = $null }
            }
        }
        GetTargets = {
            param([hashtable]$Options)
            $settings = Resolve-UvProviderOptions -Options $Options
            if ($settings.Scope -ne 'Tools') {
                $packages = @(Get-UvProviderPackages -Outdated -TopLevelOnly:$settings.TopLevelOnly -ErrorAction Stop)
                foreach ($package in $packages) {
                    Assert-UvProviderPackage -Package $package
                    New-PackageUpdateTarget -Target "pip:system:$($package.name)" -PreviousVersion $package.version -ProposedVersion $package.latest_version -Data @{
                        Kind = 'Package'
                        Name = $package.name
                    }
                }
            }
            if ($settings.Scope -ne 'Packages') {
                foreach ($tool in @(Get-UvProviderTools)) {
                    New-PackageUpdateTarget -Target "tool:$($tool.name)" -PreviousVersion $tool.version -Data @{
                        Kind = 'Tool'
                        Name = $tool.name
                    }
                }
            }
        }
        Update = {
            param($Target, [hashtable]$Options)
            Update-UvProviderTarget -Target $Target -Confirm:$false
        }
    }
}

function Resolve-UvProviderOptions {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Options)

    $scope = 'All'
    if ($Options.ContainsKey('Scope')) {
        if ($Options.Scope -isnot [string] -or $Options.Scope -notin 'All', 'Packages', 'Tools') {
            throw "Uv Scope must be All, Packages or Tools; custom Python environments are not supported."
        }
        $scope = $Options.Scope
    }
    $topLevelOnly = $true
    if ($Options.ContainsKey('TopLevelOnly')) {
        if ($Options.TopLevelOnly -isnot [bool]) {
            throw 'Uv TopLevelOnly must be a Boolean.'
        }
        if ($scope -eq 'Tools') {
            throw 'Uv TopLevelOnly applies only to Packages or All, not Tools.'
        }
        $topLevelOnly = $Options.TopLevelOnly
    }
    [pscustomobject]@{ Scope = $scope; TopLevelOnly = $topLevelOnly }
}

function Assert-UvProviderPackage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Package)

    if ($Package.name -isnot [string] -or $Package.name -cnotmatch '\A[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?\z') {
        throw 'Uv returned an invalid package name; only Python distribution names are supported.'
    }
    foreach ($field in 'version', 'latest_version') {
        if ($null -ne $Package.$field -and ($Package.$field -isnot [string] -or [string]::IsNullOrWhiteSpace($Package.$field))) {
            throw "Uv returned an invalid $field for '$($Package.name)'."
        }
    }
}

function Get-UvProviderPackages {
    [CmdletBinding()]
    param([switch]$Outdated, [switch]$TopLevelOnly)

    $module = Get-Module Shmuelie.Utilities -ErrorAction Stop
    if (-not $module) { throw 'Shmuelie.Utilities must be loaded before uv package discovery.' }
    # Preference variables do not flow across module boundaries. Set them in a
    # child scope of Utilities so failed native reads cannot resemble empty data.
    & $module {
        param($Outdated, $TopLevelOnly)
        $PSNativeCommandUseErrorActionPreference = $true
        $ErrorActionPreference = 'Stop'
        Shmuelie.Utilities\Get-UvPackages -Outdated:$Outdated -TopLevelOnly:$TopLevelOnly -ErrorAction Stop
    } $Outdated $TopLevelOnly
}

function Invoke-UvProviderCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Arguments)

    # uv writes normal diagnostics to stderr; use its exit code, not that stream.
    $PSNativeCommandUseErrorActionPreference = $false
    $previousExitCode = Get-Variable LASTEXITCODE -Scope Global -ErrorAction Ignore
    $previousValue = if ($previousExitCode) { $previousExitCode.Value } else { $null }
    try {
        $global:LASTEXITCODE = $null
        $output = @(& uv @Arguments 2>&1)
        $exitCode = $global:LASTEXITCODE
        if ($exitCode -isnot [int]) {
            throw 'uv did not report a numeric exit code.'
        }
        if ($exitCode -ne 0) {
            throw "uv $($Arguments[0]) $($Arguments[1]) failed (exit $exitCode): $($output -join [Environment]::NewLine)"
        }
        $output | ForEach-Object { $_.ToString() }
    } finally {
        if ($previousExitCode) { $global:LASTEXITCODE = $previousValue }
        else { Remove-Variable LASTEXITCODE -Scope Global -ErrorAction Ignore }
    }
}

function Get-UvProviderTools {
    [CmdletBinding()]
    param()

    # uv tool list has no JSON output option. Accept its documented plain format
    # strictly, including only tool headings and their entrypoint rows.
    $lines = @(Invoke-UvProviderCommand -Arguments @('tool', 'list', '--color', 'never', '--no-progress'))
    $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $hasTool = $false
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -ceq 'No tools installed' -and $lines.Count -eq 1) { return }
        if ($line -cmatch '\A([A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?) v(\S+)\z') {
            $name = $Matches[1]
            $version = $Matches[2]
            if (-not $names.Add(($name -replace '[-_.]+', '-'))) {
                throw "uv tool list returned duplicate tool '$name'."
            }
            $hasTool = $true
            [pscustomobject]@{ name = $name; version = $version }
        } elseif (-not ($hasTool -and $line -cmatch '\A- \S+\z')) {
            throw "Unsupported uv tool list output: $line"
        }
    }
}

function Update-UvProviderTarget {
    <#
    .SYNOPSIS
        Update one approved uv system package or installed tool and observe its version.
    .DESCRIPTION
        Private adapter callback. The aggregate command supplies Confirm false
        after approving this exact target. Native tool diagnostics are verbose;
        malformed output and failed updates propagate to the core as failures.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][psobject]$Target)

    $name = $Target.Data.Name
    Assert-UvProviderPackage -Package ([pscustomobject]@{ name = $name })
    $kind = $Target.Data.Kind
    $expectedTarget = switch ($kind) {
        'Package' { "pip:system:$name" }
        'Tool' { "tool:$name" }
        default { throw "Unsupported uv target kind '$kind'." }
    }
    if ($Target.Target -cne $expectedTarget) { throw 'Uv target identity does not match its package or tool data.' }
    if (-not $PSCmdlet.ShouldProcess($Target.Target, 'Update uv package or tool')) {
        return New-PackageUpdateResult -Provider Uv -Target $Target.Target -PreviousVersion $Target.PreviousVersion -Status Skipped -Reason 'Update was not confirmed.'
    }

    if ($kind -eq 'Package') {
        $updates = @(Shmuelie.Utilities\Update-UvPackage -PackageName $name -Confirm:$false -ErrorAction Stop)
        if ($updates.Count -ne 1 -or $updates[0].PSTypeNames -notcontains 'UvUpdateResult' -or
            $updates[0].Name -cne $name -or $updates[0].Success -isnot [bool]) {
            throw "Update-UvPackage returned an invalid or missing result for '$name'."
        }
        if (-not $updates[0].Success) { throw "Update-UvPackage failed for '$name'." }
        $installed = @(Get-UvProviderPackages -ErrorAction Stop)
    } else {
        Invoke-UvProviderCommand -Arguments @('tool', 'upgrade', '--color', 'never', '--no-progress', '--', $name) |
            ForEach-Object { Write-Verbose $_ }
        $installed = @(Get-UvProviderTools)
    }
    $observed = @($installed | Where-Object { ($_.name -replace '[-_.]+', '-') -eq ($name -replace '[-_.]+', '-') })
    if ($observed.Count -ne 1) { throw "Cannot observe exactly one installed uv $kind '$name' after update." }
    Assert-UvProviderPackage -Package $observed[0]
    $version = $observed[0].version
    if (-not $version -or -not $Target.PreviousVersion) {
        throw "Cannot determine a version change for uv $kind '$name'; its previous or observed version is unknown."
    }
    $status = if ($version -ceq $Target.PreviousVersion) { 'Unchanged' } else { 'Updated' }
    New-PackageUpdateResult -Provider Uv -Target $Target.Target -PreviousVersion $Target.PreviousVersion -ResultingVersion $version -Status $status
}
