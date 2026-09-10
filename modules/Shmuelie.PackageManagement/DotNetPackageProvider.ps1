function Invoke-DotNetPackageCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$Command,
        [Parameter(Mandatory)][string]$Operation
    )

    # The canonical tool commands do not check every native exit code.
    # Isolate stale caller state, and restore it even when a command throws.
    $previousExitCode = $global:LASTEXITCODE
    try {
        $global:LASTEXITCODE = 0
        $output = @(& $Command)
        if ($global:LASTEXITCODE -ne 0) {
            throw "$Operation failed with dotnet exit code $global:LASTEXITCODE."
        }
        $output
    } finally {
        $global:LASTEXITCODE = $previousExitCode
    }
}

function Assert-DotNetPackageTool {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Tool)

    if ($Tool.PSTypeNames -notcontains 'DotNetTool' -or
        $Tool.PackageId -isnot [string] -or $Tool.PackageId -notmatch '\A[A-Za-z0-9][A-Za-z0-9._-]*\z' -or
        $Tool.Global -isnot [bool] -or -not $Tool.Global -or
        -not $Tool.PSObject.Properties['Version'] -or
        ($null -ne $Tool.Version -and $Tool.Version -isnot [string])) {
        throw 'Shmuelie.DotNet returned an invalid global tool.'
    }
}

function Get-DotNetPackageProvider {
    [CmdletBinding()]
    param()

    [pscustomobject]@{
        Name             = 'DotNet'
        Platforms        = @('Windows', 'Linux', 'MacOS')
        RequiredModules  = @('Shmuelie.DotNet')
        RequiredCommands = @('dotnet', 'Shmuelie.DotNet\Get-DotNetTool', 'Shmuelie.DotNet\Update-DotNetTool')
        OptionNames      = @('Name')
        TestAvailable    = {
            param([hashtable]$Options)
            $sdks = @(Invoke-DotNetPackageCommand -Operation 'SDK discovery' -Command { dotnet --list-sdks })
            if (-not ($sdks | Where-Object { $_ -match '^\d+\.\d+\.\d+\S*\s+\[.+\]\s*$' })) {
                return [pscustomobject]@{ Available = $false; Reason = 'Install a .NET SDK accessible through dotnet on PATH; a runtime alone cannot update tools.' }
            }
            [pscustomobject]@{ Available = $true; Reason = $null }
        }
        GetTargets       = {
            param([hashtable]$Options)
            $name = '*'
            if ($Options.ContainsKey('Name')) {
                if ($Options.Name -isnot [string] -or [string]::IsNullOrWhiteSpace($Options.Name)) {
                    throw "DotNet option 'Name' must be a nonempty wildcard string."
                }
                $name = $Options.Name
                $null = [System.Management.Automation.WildcardPattern]::new($name).IsMatch('')
            }
            $tools = @(Invoke-DotNetPackageCommand -Operation 'Global tool discovery' -Command {
                Shmuelie.DotNet\Get-DotNetTool -Name $name -ErrorAction Stop
            })
            foreach ($tool in $tools) {
                Assert-DotNetPackageTool -Tool $tool
            }
            # The public API cannot discover latest versions without an update.
            foreach ($tool in $tools) {
                New-PackageUpdateTarget -Target $tool.PackageId -PreviousVersion $tool.Version -Data $tool
            }
        }
        Update           = {
            param($Target, [hashtable]$Options)
            $results = @(Invoke-DotNetPackageCommand -Operation "Update of '$($Target.Target)'" -Command {
                Shmuelie.DotNet\Update-DotNetTool -InputObject $Target.Data -Confirm:$false -ErrorAction Stop
            })
            if ($results.Count -ne 1 -or $results[0].PSTypeNames -notcontains 'DotNetToolUpdateResult' -or
                $results[0].PackageId -ne $Target.Target -or $results[0].Updated -isnot [bool] -or
                -not $results[0].PSObject.Properties['Version'] -or
                ($null -ne $results[0].Version -and $results[0].Version -isnot [string])) {
                throw "Shmuelie.DotNet returned invalid update output for '$($Target.Target)'; the outcome is unknown."
            }
            $installed = @(Invoke-DotNetPackageCommand -Operation "Version discovery for '$($Target.Target)'" -Command {
                Shmuelie.DotNet\Get-DotNetTool -Name $Target.Target -ErrorAction Stop
            })
            if ($installed.Count -ne 1 -or $installed[0].PackageId -ne $Target.Target) {
                throw "Cannot observe the installed global tool '$($Target.Target)' after its update."
            }
            Assert-DotNetPackageTool -Tool $installed[0]
            $version = $installed[0].Version
            if ($Target.PreviousVersion -and $version) {
                $status = if ($version -eq $Target.PreviousVersion) { 'Unchanged' } else { 'Updated' }
            } elseif ($results[0].Updated) {
                $status = 'Updated'
            } else {
                throw "Cannot determine whether '$($Target.Target)' changed; the canonical command reported no update and installed versions are unknown."
            }
            New-PackageUpdateResult -Provider DotNet -Target $Target.Target -PreviousVersion $Target.PreviousVersion -ResultingVersion $version -Status $status
        }
    }
}
