function Get-NpmProviderPackage {
    [CmdletBinding()]
    param([switch]$Outdated)

    $nodeModule = Get-Module -Name Shmuelie.Node -ErrorAction Stop
    if (-not $nodeModule) { throw "The required module 'Shmuelie.Node' is no longer loaded." }

    $previousExitCode = $global:LASTEXITCODE
    try {
        $global:LASTEXITCODE = $null
        # npm outdated uses exit 1 for available updates. Set the preference in
        # the owning module's invocation scope, without changing its session state.
        $packages = @(& $nodeModule {
            param([bool]$Outdated)
            $PSNativeCommandUseErrorActionPreference = $false
            Shmuelie.Node\Get-NpmPackage -Global -Outdated:$Outdated -ErrorAction Stop
        } ([bool]$Outdated))
        $exitCode = $global:LASTEXITCODE
        if ($null -ne $exitCode -and $exitCode -ne 0 -and -not ($Outdated -and $exitCode -eq 1 -and $packages.Count)) {
            throw "npm global package discovery failed with exit code $exitCode."
        }

        foreach ($package in $packages) {
            if ($package.PSTypeNames -notcontains 'NpmPackage' -or $package.Global -isnot [bool] -or -not $package.Global) {
                throw 'npm discovery returned an invalid or non-global package.'
            }
            if ($package.Name -isnot [string] -or ($null -ne $package.Version -and $package.Version -isnot [string])) {
                throw 'npm discovery returned invalid package identity or version data.'
            }
        }
        $packages
    } finally {
        $global:LASTEXITCODE = $previousExitCode
    }
}

function Assert-NpmProviderPackageName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)

    # Only registry package identifiers may reach npm.cmd, never package specs,
    # options, URLs, paths, or cmd.exe metacharacters.
    if ($Name.Length -gt 214 -or $Name -cnotmatch '\A(?:@[A-Za-z0-9_-][A-Za-z0-9._-]*/)?[A-Za-z0-9_-][A-Za-z0-9._-]*\z' -or $Name.StartsWith('-')) {
        throw "Invalid npm registry package name '$Name'."
    }
}

function Get-NpmPackageProvider {
    <#
    .SYNOPSIS
        Describe the global npm package update integration without probing tools.
    .DESCRIPTION
        Lazily uses Shmuelie.Node and npm to discover outdated global packages.
        No provider options or local dependency updates are supported. The core
        owns confirmation and failure continuation. Successful updates are
        verified against the installed global package list, not the proposed
        latest version; missing observations are failures with unknown versions.
    #>
    [CmdletBinding()]
    param()

    [pscustomobject]@{
        Name             = 'Npm'
        Platforms        = @('Windows', 'Linux', 'MacOS')
        RequiredModules  = @('Shmuelie.Node')
        RequiredCommands = @('npm', 'Shmuelie.Node\Get-NpmPackage', 'Shmuelie.Node\Update-NpmPackage')
        OptionNames      = @()
        TestAvailable    = $null
        GetTargets       = {
            param([hashtable]$Options)
            foreach ($package in Get-NpmProviderPackage -Outdated) {
                Assert-NpmProviderPackageName -Name $package.Name
                if ([string]::IsNullOrWhiteSpace($package.Version) -or $package.Latest -isnot [string] -or [string]::IsNullOrWhiteSpace($package.Latest)) {
                    throw "npm did not report installed and latest versions for '$($package.Name)'; outdated global discovery is incomplete."
                }
                if ($package.Version -eq $package.Latest) { continue }
                New-PackageUpdateTarget -Target $package.Name -PreviousVersion $package.Version -ProposedVersion $package.Latest
            }
        }
        Update           = {
            param($Target, [hashtable]$Options)
            Assert-NpmProviderPackageName -Name $Target.Target
            $updates = @(Shmuelie.Node\Update-NpmPackage -Name $Target.Target -Global -Confirm:$false -ErrorAction Stop)
            if ($updates.Count -ne 1 -or $updates[0].PSTypeNames -notcontains 'NpmUpdateResult' -or
                $updates[0].Name -cne $Target.Target -or $updates[0].Global -isnot [bool] -or
                -not $updates[0].Global -or $updates[0].Success -isnot [bool]) {
                throw "npm returned an invalid update result for '$($Target.Target)'; the outcome is unknown."
            }
            if (-not $updates[0].Success) { throw "npm failed to update global package '$($Target.Target)'." }

            $installed = @(Get-NpmProviderPackage | Where-Object Name -CEQ $Target.Target)
            if ($installed.Count -ne 1 -or [string]::IsNullOrWhiteSpace($installed[0].Version)) {
                throw "Cannot observe the installed global version of '$($Target.Target)' after its npm update."
            }
            if (-not $Target.PreviousVersion) {
                throw "Cannot establish a version change for '$($Target.Target)' because its previous version is unknown."
            }
            $status = if ($installed[0].Version -eq $Target.PreviousVersion) { 'Unchanged' } else { 'Updated' }
            New-PackageUpdateResult -Provider Npm -Target $Target.Target -PreviousVersion $Target.PreviousVersion -ResultingVersion $installed[0].Version -Status $status
        }
    }
}
