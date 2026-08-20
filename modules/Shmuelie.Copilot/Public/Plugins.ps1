function Get-CopilotPlugin {
    <#
    .SYNOPSIS
        List installed Copilot CLI plugins.
    .DESCRIPTION
        Parses the output of 'copilot plugin list' into typed CopilotPlugin objects
        with Name, Marketplace, and Version properties.
    .PARAMETER Name
        Filter by plugin name. Supports wildcards.
    .EXAMPLE
        Get-CopilotPlugin
        Lists all installed plugins.
    .EXAMPLE
        Get-CopilotPlugin dotnet*
        Lists plugins whose name starts with 'dotnet'.
    .EXAMPLE
        Get-CopilotPlugin | Where-Object Marketplace
        Lists only marketplace-sourced plugins.
    #>
    [OutputType('CopilotPlugin')]
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Name = '*'
    )
    $exe = Resolve-CliExe -Name copilot
    $output = Invoke-WithUtf8Console { & $exe plugin list 2>&1 }
    foreach ($line in $output) {
        if ($line -match '^\s+[•]\s+(.+?)\s+\(v(.+?)\)\s*$') {
            $fullName = $Matches[1]
            $version = $Matches[2]
            $pluginName = $fullName
            $marketplace = ''
            if ($fullName -match '^(.+)@(.+)$') {
                $pluginName = $Matches[1]
                $marketplace = $Matches[2]
            }
            $plugin = [PSCustomObject]@{
                PSTypeName  = 'CopilotPlugin'
                Name        = $pluginName
                FullName    = $fullName
                Marketplace = $marketplace
                Version     = $version
            }
            if ($plugin.Name -like $Name -or $plugin.FullName -like $Name) {
                $plugin
            }
        }
    }
}

function Update-CopilotPlugin {
    <#
    .SYNOPSIS
        Update installed Copilot CLI plugins to the latest version.
    .DESCRIPTION
        Calls 'copilot plugin update <name>' for each plugin. Accepts pipeline
        input from Get-CopilotPlugin or explicit plugin names.

        When the update fails with EBUSY (file lock), retries once after a short
        delay and warns about running Copilot sessions that may hold locks.
    .PARAMETER InputObject
        A CopilotPlugin object from Get-CopilotPlugin.
    .PARAMETER Name
        The plugin name to update. For marketplace plugins, use the full
        'plugin@marketplace' format.
    .EXAMPLE
        Get-CopilotPlugin | Update-CopilotPlugin
        Updates all installed plugins.
    .EXAMPLE
        Update-CopilotPlugin -Name my-plugin
        Updates a specific plugin by name.
    #>
    [OutputType('CopilotPluginUpdateResult')]
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'ByObject')]
    param(
        [Parameter(ParameterSetName = 'ByObject', ValueFromPipeline, Mandatory)]
        [PSObject]$InputObject,

        [Parameter(ParameterSetName = 'ByName', Position = 0, Mandatory)]
        [string]$Name
    )
    process {
        $updateName = if ($PSCmdlet.ParameterSetName -eq 'ByName') { $Name } else { $InputObject.FullName }
        Assert-CopilotShimArgument -Value $updateName -ParameterName 'Name'

        $exe = Resolve-CliExe -Name copilot
        if (-not $PSCmdlet.ShouldProcess($updateName, 'copilot plugin update')) {
            return
        }

        Write-Verbose "Updating plugin: $updateName"
        $output = & $exe plugin update $updateName 2>&1
        $success = $LASTEXITCODE -eq 0
        $errorMsg = $null

        if (-not $success) {
            $errorMsg = ($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] -or $_ -match 'Failed|Error' }) -join '; '
            if (-not $errorMsg) { $errorMsg = ($output | Out-String).Trim() }

            # Retry once on EBUSY (file lock from running sessions)
            if ($errorMsg -match 'EBUSY') {
                Write-Verbose "EBUSY detected for $updateName — retrying in 2 seconds..."
                Start-Sleep -Seconds 2
                $output = & $exe plugin update $updateName 2>&1
                $success = $LASTEXITCODE -eq 0
                if (-not $success) {
                    $errorMsg = ($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] -or $_ -match 'Failed|Error' }) -join '; '
                    if (-not $errorMsg) { $errorMsg = ($output | Out-String).Trim() }
                } else {
                    $errorMsg = $null
                }
            }
        }

        if (-not $success) {
            if ($errorMsg -match 'EBUSY') {
                $sessionPids = Get-Process -Name copilot -ErrorAction SilentlyContinue |
                    Where-Object { $_.Id -ne $PID } |
                    ForEach-Object {
                        $cmdLine = (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" -ErrorAction SilentlyContinue).CommandLine
                        $sessionId = if ($cmdLine -match '--resume\s+(\S+)') { $Matches[1].Substring(0, 8) } else { $null }
                        "PID $($_.Id)$(if ($sessionId) { " (session $sessionId)" })"
                    }
                $pidList = ($sessionPids | Select-Object -Unique) -join ', '
                Write-Warning "Failed to update $updateName — plugin directory is locked by running sessions. Close other sessions and retry. Running: $pidList"
            } else {
                Write-Warning "Failed to update plugin: $updateName — $errorMsg"
            }
        }

        [PSCustomObject]@{
            PSTypeName = 'CopilotPluginUpdateResult'
            Name       = $updateName
            Success    = $success
            Error      = $errorMsg
        }
    }
}

function Install-CopilotPlugin {
    <#
    .SYNOPSIS
        Install a Copilot CLI plugin.
    .DESCRIPTION
        Installs a plugin from a GitHub repository, marketplace, or direct URL.
    .PARAMETER Source
        The plugin source: owner/repo (GitHub), plugin@marketplace, or a URL.
    .PARAMETER InputObject
        A marketplace plugin object (e.g. from Get-CopilotMarketplacePlugin) to
        install, accepted from the pipeline.
    .EXAMPLE
        Install-CopilotPlugin -Source shmuelie/shmuelie-skills
        Installs a plugin from a GitHub repository.
    .EXAMPLE
        Install-CopilotPlugin -Source dotnet@dotnet-agent-skills
        Installs a plugin from a registered marketplace.
    .EXAMPLE
        Get-CopilotMarketplacePlugin dotnet-agent-skills | Install-CopilotPlugin
        Installs all plugins from the dotnet-agent-skills marketplace.
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'BySource')]
    param(
        [Parameter(ParameterSetName = 'BySource', Position = 0, Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Source,

        [Parameter(ParameterSetName = 'ByObject', Mandatory, ValueFromPipeline)]
        [PSObject]$InputObject
    )
    process {
        $installSource = if ($PSCmdlet.ParameterSetName -eq 'ByObject') {
            Assert-CopilotShimArgument -Value $InputObject.Name -ParameterName 'InputObject.Name' -Pattern '^[A-Za-z0-9][A-Za-z0-9._#/-]*$'
            Assert-CopilotShimArgument -Value $InputObject.Marketplace -ParameterName 'InputObject.Marketplace' -Pattern '^[A-Za-z0-9][A-Za-z0-9._#/-]*$'
            "$($InputObject.Name)@$($InputObject.Marketplace)"
        } else {
            $Source
        }
        Assert-CopilotShimArgument -Value $installSource -ParameterName 'Source'

        $exe = Resolve-CliExe -Name copilot
        if ($PSCmdlet.ShouldProcess($installSource, 'copilot plugin install')) {
            # Skip if already installed.
            $checkName = if ($installSource -match '^(.+)@') { $Matches[1] }
                         elseif ($installSource -match '/([^/#]+)(?:#|$)') { $Matches[1] }
                         else { $installSource }
            $existing = Get-CopilotPlugin | Where-Object { $_.Name -eq $checkName -or $_.FullName -eq $installSource }
            if ($existing) {
                Write-Verbose "Plugin '$($existing.FullName)' is already installed."
                return
            }
            & $exe plugin install $installSource 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Error "Failed to install plugin: $installSource"
            }
        }
    }
}

function Uninstall-CopilotPlugin {
    <#
    .SYNOPSIS
        Uninstall a Copilot CLI plugin.
    .DESCRIPTION
        Removes an installed plugin by name. Accepts pipeline input from Get-CopilotPlugin.
    .PARAMETER InputObject
        A CopilotPlugin object from Get-CopilotPlugin.
    .PARAMETER Name
        The plugin name to uninstall.
    .EXAMPLE
        Uninstall-CopilotPlugin -Name my-plugin
        Uninstalls the specified plugin.
    .EXAMPLE
        Get-CopilotPlugin old-plugin | Uninstall-CopilotPlugin
        Uninstalls via pipeline.
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'ByObject')]
    param(
        [Parameter(ParameterSetName = 'ByObject', ValueFromPipeline, Mandatory)]
        [PSObject]$InputObject,

        [Parameter(ParameterSetName = 'ByName', Position = 0, Mandatory)]
        [string]$Name
    )
    process {
        $uninstallName = if ($PSCmdlet.ParameterSetName -eq 'ByName') { $Name } else { $InputObject.FullName }
        Assert-CopilotShimArgument -Value $uninstallName -ParameterName 'Name'

        $exe = Resolve-CliExe -Name copilot
        if ($PSCmdlet.ShouldProcess($uninstallName, 'copilot plugin uninstall')) {
            & $exe plugin uninstall $uninstallName 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Error "Failed to uninstall plugin: $uninstallName"
            }
        }
    }
}