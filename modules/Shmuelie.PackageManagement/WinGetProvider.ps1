function Get-WinGetPackageProvider {
    <#
    .SYNOPSIS
        Describe the Windows-only WinGet adapter without probing dependencies.
    .DESCRIPTION
        Uses Microsoft.WinGet.Client 1.8.1911+ for structured installed-package
        discovery, including its default acceptance of source agreements.
        Source restricts discovery; Include and Exclude are package-ID wildcards.
        AcceptPackageAgreements is Boolean and defaults to false.
        The core approves each exact package/source target before native upgrade.
    #>
    [CmdletBinding()]
    param()

    [pscustomobject]@{
        Name = 'WinGet'
        Platforms = @('Windows')
        RequiredModules = @()
        RequiredCommands = @()
        OptionNames = @('Source', 'Include', 'Exclude', 'AcceptPackageAgreements')
        TestAvailable = {
            param([hashtable]$Options)
            $null = Resolve-WinGetProviderOptions -Options $Options
            $cli = Get-Command winget.exe -CommandType Application -ListImported -ErrorAction Ignore |
                Select-Object -First 1
            if (-not $cli -or [IO.Path]::GetExtension($cli.Path) -ine '.exe') {
                return [pscustomobject]@{ Available = $false; Reason = "Install WinGet 1.8.1911 or later and expose winget.exe on PATH." }
            }
            $versionResult = Invoke-WinGetProviderNative -FilePath $cli.Path -Arguments @('--version')
            $versionText = ($versionResult.Output -join '').Trim()
            if ($versionText -notmatch '\Av(\d+\.\d+\.\d+(?:\.\d+)?)\z' -or
                [version]$Matches[1] -lt [version]'1.8.1911') {
                return [pscustomobject]@{ Available = $false; Reason = "WinGet requires a stable CLI version 1.8.1911 or later for silent authentication; found '$versionText'." }
            }
            $module = Get-Module Microsoft.WinGet.Client | Sort-Object Version -Descending | Select-Object -First 1
            if (-not $module) {
                $module = Get-Module -ListAvailable Microsoft.WinGet.Client -ErrorAction Stop |
                    Where-Object Version -GE ([version]'1.8.1911') | Sort-Object Version -Descending | Select-Object -First 1
            }
            if (-not $module -or $module.Version -lt [version]'1.8.1911') {
                return [pscustomobject]@{ Available = $false; Reason = "Install Microsoft.WinGet.Client 1.8.1911 or later separately. If an older version is loaded, start a new session after upgrading." }
            }
            Import-Module -Name $module.Path -ErrorAction Stop
            $command = Get-Command 'Microsoft.WinGet.Client\Get-WinGetPackage' -ListImported -ErrorAction Ignore
            if (-not $command -or @('Id', 'Source', 'MatchOption' | Where-Object { -not $command.Parameters.ContainsKey($_) }).Count) {
                return [pscustomobject]@{ Available = $false; Reason = "Microsoft.WinGet.Client must provide Get-WinGetPackage with Id, Source and MatchOption parameters." }
            }
            [pscustomobject]@{ Available = $true; Reason = $null }
        }
        GetTargets = {
            param([hashtable]$Options)
            $settings = Resolve-WinGetProviderOptions -Options $Options
            $arguments = @{ ErrorAction = 'Stop' }
            if ($settings.Source) { $arguments.Source = $settings.Source }
            $cli = Get-Command winget.exe -CommandType Application -ListImported -ErrorAction Stop | Select-Object -First 1
            $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($package in @(Microsoft.WinGet.Client\Get-WinGetPackage @arguments)) {
                if ($package.Id -isnot [string] -or $package.IsUpdateAvailable -isnot [bool]) {
                    throw 'WinGet discovery returned invalid structured package data.'
                }
                if (-not $package.IsUpdateAvailable -or -not (Test-WinGetProviderFilter -Id $package.Id -Settings $settings)) { continue }
                Assert-WinGetProviderIdentity -Id $package.Id -Source $package.Source
                if ($settings.Source -and $settings.Source -ine $package.Source) {
                    throw "WinGet returned package '$($package.Id)' from a different source than requested."
                }
                $identity = "$($package.Id) (source: $($package.Source))"
                if (-not $seen.Add($identity)) { throw "WinGet returned an ambiguous installed target '$identity'." }
                New-PackageUpdateTarget -Target $identity -PreviousVersion (Get-WinGetProviderVersion -Value $package.InstalledVersion) -Data @{
                    Id = $package.Id
                    Source = $package.Source
                    FilePath = $cli.Path
                }
            }
        }
        Update = {
            param($Target, [hashtable]$Options)
            Update-WinGetProviderTarget -Target $Target -Options $Options
        }
    }
}

function Resolve-WinGetProviderOptions {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Options)

    $source = $null
    if ($Options.ContainsKey('Source')) {
        Assert-WinGetProviderIdentity -Id 'Validation' -Source $Options.Source
        $source = $Options.Source
    }
    $filters = @{}
    foreach ($name in 'Include', 'Exclude') {
        $patterns = if ($name -eq 'Include') { @('*') } else { @() }
        if ($Options.ContainsKey($name)) {
            if ($Options[$name] -isnot [string] -and $Options[$name] -isnot [array]) {
                throw "WinGet $name must be a package-ID wildcard string or an array of strings."
            }
            $patterns = @($Options[$name])
        }
        $filters[$name] = @(
            foreach ($pattern in $patterns) {
                if ($pattern -isnot [string] -or [string]::IsNullOrWhiteSpace($pattern) -or $pattern -match '[\x00-\x1f\x7f]') {
                    throw "WinGet $name must contain nonempty wildcard strings without control characters."
                }
                $wildcard = [System.Management.Automation.WildcardPattern]::new($pattern, 'IgnoreCase')
                $null = $wildcard.IsMatch('')
                $wildcard
            }
        )
    }
    $acceptPackages = $false
    if ($Options.ContainsKey('AcceptPackageAgreements')) {
        if ($Options.AcceptPackageAgreements -isnot [bool]) { throw 'WinGet AcceptPackageAgreements must be a Boolean.' }
        $acceptPackages = $Options.AcceptPackageAgreements
    }
    [pscustomobject]@{
        Source = $source
        Include = $filters.Include
        Exclude = $filters.Exclude
        AcceptPackageAgreements = $acceptPackages
    }
}

function Test-WinGetProviderFilter {
    param([string]$Id, [psobject]$Settings)

    foreach ($pattern in $Settings.Exclude) { if ($pattern.IsMatch($Id)) { return $false } }
    foreach ($pattern in $Settings.Include) { if ($pattern.IsMatch($Id)) { return $true } }
    return $false
}

function Assert-WinGetProviderIdentity {
    param([AllowNull()][object]$Id, [AllowNull()][object]$Source)

    if ($Id -isnot [string] -or $Id -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9._+-]*\z') {
        throw 'WinGet package IDs must contain only ASCII letters, digits, periods, underscores, plus signs and hyphens, starting with a letter or digit.'
    }
    if ($Source -isnot [string] -or $Source -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9._ -]*\z' -or $Source.Trim() -cne $Source) {
        throw 'WinGet source names must contain only ASCII letters, digits, periods, underscores, spaces and hyphens, starting with a letter or digit, without trailing spaces.'
    }
}

function Get-WinGetProviderVersion {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value -or ($Value -is [string] -and ([string]::IsNullOrWhiteSpace($Value) -or $Value -ieq 'Unknown'))) { return $null }
    if ($Value -isnot [string]) { throw 'WinGet returned an invalid installed version.' }
    return $Value
}

function Invoke-WinGetProviderNative {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowNoUpdate
    )

    if ([IO.Path]::GetExtension($FilePath) -ine '.exe') { throw 'WinGet requires a native .exe, not a batch shim or shell command.' }
    $PSNativeCommandUseErrorActionPreference = $false
    $previousExitCode = Get-Variable LASTEXITCODE -Scope Global -ErrorAction Ignore
    $previousValue = if ($previousExitCode) { $previousExitCode.Value } else { $null }
    try {
        $global:LASTEXITCODE = $null
        $output = @(& $FilePath @Arguments 2>&1)
        $exitCode = $global:LASTEXITCODE
        if ($exitCode -isnot [int]) { throw 'WinGet did not report a numeric native exit code; the outcome is unknown.' }
        # APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE is the sole benign nonzero result.
        $noUpdate = $AllowNoUpdate -and $exitCode -eq ([int]0x8A15002B)
        if ($exitCode -ne 0 -and -not $noUpdate) {
            throw "WinGet $($Arguments[0]) failed (exit $exitCode): $($output -join [Environment]::NewLine)"
        }
        [pscustomobject]@{ NoUpdate = [bool]$noUpdate; Output = @($output | ForEach-Object { $_.ToString() }) }
    } finally {
        if ($previousExitCode) { $global:LASTEXITCODE = $previousValue }
        else { Remove-Variable LASTEXITCODE -Scope Global -ErrorAction Ignore -WhatIf:$false -Confirm:$false }
    }
}

function Update-WinGetProviderTarget {
    <#
    .SYNOPSIS
        Upgrade one source-bound target already approved by the aggregate command.
    .DESCRIPTION
        Private callback: core ShouldProcess is the only confirmation boundary.
        Source agreements are accepted by default, matching structured discovery.
        Package agreements are accepted only when explicitly enabled.
        Native completion and a fresh installed-package observation are required.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Target,
        [Parameter(Mandatory)][hashtable]$Options
    )

    $settings = Resolve-WinGetProviderOptions -Options $Options
    $id = $Target.Data.Id
    $source = $Target.Data.Source
    Assert-WinGetProviderIdentity -Id $id -Source $source
    if ($Target.Target -cne "$id (source: $source)" -or
        ($settings.Source -and $settings.Source -ine $source) -or
        -not (Test-WinGetProviderFilter -Id $id -Settings $settings)) {
        throw 'WinGet target identity does not match its approved package, source or filters.'
    }
    $arguments = @('upgrade', '--id', $id, '--exact', '--source', $source,
        '--silent', '--disable-interactivity', '--authentication-mode', 'silent', '--accept-source-agreements')
    if ($settings.AcceptPackageAgreements) { $arguments += '--accept-package-agreements' }
    $completion = Invoke-WinGetProviderNative -FilePath $Target.Data.FilePath -Arguments $arguments -AllowNoUpdate
    foreach ($line in $completion.Output) { Write-Verbose $line }
    $observed = @(Microsoft.WinGet.Client\Get-WinGetPackage -Id $id -Source $source -MatchOption Equals -ErrorAction Stop)
    if ($observed.Count -ne 1 -or $observed[0].Id -cne $id -or $observed[0].Source -ine $source) {
        throw "Cannot observe exactly one installed WinGet package '$id' from source '$source' after upgrade."
    }
    $version = Get-WinGetProviderVersion -Value $observed[0].InstalledVersion
    $reason = $null
    if ($completion.NoUpdate) {
        $status = 'Unchanged'
        $reason = 'WinGet reported no applicable update (0x8A15002B).'
    } elseif ($version -and $Target.PreviousVersion -and $version -ceq $Target.PreviousVersion) {
        $status = 'Unchanged'
    } else {
        $status = 'Updated'
        if (-not $version -or -not $Target.PreviousVersion) {
            $reason = 'WinGet completed the upgrade successfully; unknown installed versions prevent a version comparison.'
        }
    }
    New-PackageUpdateResult -Provider WinGet -Target $Target.Target -PreviousVersion $Target.PreviousVersion -ResultingVersion $version -Status $status -Reason $reason
}
