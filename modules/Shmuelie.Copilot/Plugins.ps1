function New-CopilotPluginRecord {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [AllowEmptyString()]
        [string]$Marketplace = '',

        [AllowEmptyString()]
        [string]$Version = '',

        [Parameter(Mandatory)]
        [bool]$Enabled,

        [AllowEmptyString()]
        [string]$Source = '',

        [AllowEmptyString()]
        [string]$InstalledFrom = ''
    )

    $fullName = if ($Marketplace) { "$Name@$Marketplace" } else { $Name }
    [PSCustomObject]@{
        PSTypeName    = 'CopilotPlugin'
        Name          = $Name
        FullName      = $fullName
        Marketplace   = $Marketplace
        Version       = $Version
        Enabled       = $Enabled
        Source        = $Source
        InstalledFrom = $InstalledFrom
        Managed       = -not [string]::Equals($Source, 'builtin', [StringComparison]::OrdinalIgnoreCase) -and
            -not [string]::Equals($Source, 'plugin-dir', [StringComparison]::OrdinalIgnoreCase)
    }
}

function Get-CopilotPluginJsonStringProperty {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Entry,

        [Parameter(Mandatory)]
        [string]$Name,

        [switch]$Required
    )

    if (-not $Entry.Contains($Name) -or $null -eq $Entry[$Name]) {
        if ($Required) {
            throw "Missing required '$Name' property."
        }
        return ''
    }

    if ($Entry[$Name] -isnot [string]) {
        throw "Property '$Name' must be a string."
    }

    $value = [string]$Entry[$Name]
    if ($Required -and [string]::IsNullOrWhiteSpace($value)) {
        throw "Property '$Name' must not be empty."
    }

    $value
}

function ConvertFrom-CopilotPluginJsonOutput {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Output
    )

    $json = ($Output | ForEach-Object { "$_" }) -join [Environment]::NewLine
    if ([string]::IsNullOrWhiteSpace($json)) {
        return @()
    }

    try {
        $parsed = $json | ConvertFrom-Json -AsHashtable -NoEnumerate -Depth 16
    } catch {
        throw "Invalid JSON. $($_.Exception.Message)"
    }

    if ($parsed -isnot [System.Collections.IList]) {
        throw 'The JSON result must be an array.'
    }

    foreach ($entry in $parsed) {
        if ($entry -isnot [System.Collections.IDictionary]) {
            throw 'Each plugin row must be an object.'
        }

        if (-not $entry.Contains('enabled') -or $entry.enabled -isnot [bool]) {
            throw "Property 'enabled' must be a Boolean."
        }

        New-CopilotPluginRecord -Name (Get-CopilotPluginJsonStringProperty -Entry $entry -Name 'name' -Required) `
            -Marketplace (Get-CopilotPluginJsonStringProperty -Entry $entry -Name 'marketplace') `
            -Version (Get-CopilotPluginJsonStringProperty -Entry $entry -Name 'version') `
            -Enabled ([bool]$entry.enabled) `
            -Source (Get-CopilotPluginJsonStringProperty -Entry $entry -Name 'source' -Required) `
            -InstalledFrom (Get-CopilotPluginJsonStringProperty -Entry $entry -Name 'installedFrom')
    }
}

function ConvertFrom-CopilotPluginTextOutput {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Output
    )

    $section = 'managed'
    foreach ($line in $Output) {
        switch -Regex ($line) {
            '^\s*Built-in plugins:\s*$' {
                $section = 'builtin'
                continue
            }
            '^\s*External Plugins \(via --plugin-dir\):\s*$' {
                $section = 'plugin-dir'
                continue
            }
            '^\s*$' {
                $section = 'managed'
                continue
            }
        }

        if ($line -match '^\s+[•]\s+(.+?)\s+\(v(.+?)\)(?:\s+\[(disabled)\])?\s*$') {
            $fullName = $Matches[1]
            $version = $Matches[2]
            $enabled = $Matches[3] -ne 'disabled'
            $pluginName = $fullName
            $marketplace = ''
            if ($fullName -match '^(.+)@(.+)$') {
                $pluginName = $Matches[1]
                $marketplace = $Matches[2]
            }
            $source = if ($section -eq 'managed' -and $marketplace) { 'marketplace' } else { $section }
            New-CopilotPluginRecord -Name $pluginName -Marketplace $marketplace -Version $version -Enabled $enabled -Source $source
        }
    }
}

function Test-CopilotPluginListJsonUnsupported {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Result
    )

    if ($Result.ExitCode -isnot [int] -or $Result.ExitCode -eq 0) {
        return $false
    }

    $diagnostics = ($Result.Output | ForEach-Object { "$_" }) -join [Environment]::NewLine
    [bool]($diagnostics -match '(?is)(?:unexpected|unknown|unrecognized|invalid)[^\r\n]*--json|--json[^\r\n]*(?:unexpected|unknown|unrecognized|invalid)')
}

function Get-CopilotPluginInstallCheckName {
    param(
        [Parameter(Mandatory)]
        [string]$Source
    )

    if ($Source -match '^[^@]+@[^@]+$') {
        return ($Source -split '@', 2)[0]
    }

    if ($Source -match '^[^:]+/[^:]+:(.+)$') {
        $pluginPath = $Matches[1].TrimEnd('\', '/')
        $leaf = [IO.Path]::GetFileName($pluginPath)
        if ($leaf) {
            return $leaf
        }
    }

    $uri = $null
    if ([Uri]::TryCreate($Source, [UriKind]::Absolute, [ref]$uri)) {
        $fileName = [IO.Path]::GetFileName($uri.AbsolutePath.TrimEnd('/'))
        if ($fileName) {
            return ($fileName -replace '\.(zip|tgz|tar\.gz|git)$', '')
        }
    }

    $trimmedSource = $Source.TrimEnd('\', '/')
    $fileLeaf = [IO.Path]::GetFileName($trimmedSource)
    if ($fileLeaf) {
        return ($fileLeaf -replace '\.(zip|tgz|tar\.gz|git)$', '')
    }

    if ($Source -match '/([^/#]+?)(?:\.git)?(?:#|$)') {
        return $Matches[1]
    }

    $Source
}

function Resolve-CopilotPluginInstallRequest {
    param(
        [Parameter(Mandatory)]
        [string]$Source
    )

    if ($Source -match '^(?<name>[^@]+)@(?<marketplace>[^@]+)$') {
        return [pscustomobject]@{
            Kind        = 'Marketplace'
            Name        = $Matches['name']
            FullName    = $Source
            Marketplace = $Matches['marketplace']
        }
    }

    [pscustomobject]@{
        Kind          = 'Direct'
        Name          = Get-CopilotPluginInstallCheckName -Source $Source
        FullName      = $Source
        Marketplace   = ''
        InstalledFrom = $Source
    }
}

function Get-CopilotUnmanagedPluginMessage {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [AllowEmptyString()]
        [string]$Source
    )

    $reason = if ([string]::Equals($Source, 'plugin-dir', [StringComparison]::OrdinalIgnoreCase)) {
        'it is mounted via --plugin-dir'
    } elseif ([string]::Equals($Source, 'builtin', [StringComparison]::OrdinalIgnoreCase)) {
        'it is built into the Copilot CLI'
    } else {
        "its source '$Source' is not a managed installation"
    }

    "Cannot manage plugin '$Name' with this cmdlet because $reason."
}

function Get-CopilotPlugin {
    <#
    .SYNOPSIS
        List installed Copilot CLI plugins.
    .DESCRIPTION
        Uses 'copilot plugin list --json' when available and falls back to the
        legacy text list on older CLIs. Returns typed CopilotPlugin objects with
        Name, FullName, Marketplace, Version, Enabled, Source, InstalledFrom,
        and Managed properties.
        Native failures write a PowerShell error with the exit code and diagnostics
        and emit no plugins. Use -ErrorAction Stop to terminate on failure.
        A successful empty list emits no plugins and no error. Invalid JSON or
        schema failures also write a PowerShell error and emit no plugins.
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
    $jsonResult = Invoke-CopilotCliCapture -Arguments @('plugin', 'list', '--json')
    $plugins = if ($jsonResult.ExitCode -is [int] -and $jsonResult.ExitCode -eq 0) {
        try {
            @(ConvertFrom-CopilotPluginJsonOutput -Output $jsonResult.Output)
        } catch {
            $jsonText = ($jsonResult.Output | ForEach-Object { "$_" }) -join [Environment]::NewLine
            $message = "copilot plugin list --json returned an invalid result. $($_.Exception.Message)"
            $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new($message, $_.Exception),
                'CopilotDiscoveryInvalidResult',
                [System.Management.Automation.ErrorCategory]::InvalidData,
                $jsonText)
            $PSCmdlet.WriteError($errorRecord)
            return
        }
    } elseif (Test-CopilotPluginListJsonUnsupported -Result $jsonResult) {
        @(ConvertFrom-CopilotPluginTextOutput -Output (Invoke-CopilotDiscovery -Arguments @('plugin', 'list')))
    } else {
        Write-CopilotDiscoveryFailure -Arguments @('plugin', 'list', '--json') -Result $jsonResult
        return
    }

    foreach ($plugin in $plugins) {
        if ($plugin.Name -like $Name -or $plugin.FullName -like $Name) {
            $plugin
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

        if ($PSCmdlet.ParameterSetName -eq 'ByObject' -and
            $InputObject.PSObject.Properties['Managed'] -and
            -not [bool]$InputObject.Managed) {
            $errorMsg = Get-CopilotUnmanagedPluginMessage -Name $updateName -Source ([string]$InputObject.Source)
            Write-Warning $errorMsg
            [PSCustomObject]@{
                PSTypeName = 'CopilotPluginUpdateResult'
                Name       = $updateName
                Success    = $false
                Error      = $errorMsg
            }
            return
        }

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
        If discovery of already-installed plugins fails, terminates without
        installing. Duplicate detection uses the installed plugin's full managed
        identity when the Copilot CLI reports it, so different marketplaces and
        unmanaged --plugin-dir mounts are not confused with the requested source.
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
            $requestedPlugin = Resolve-CopilotPluginInstallRequest -Source $installSource
            $installedPlugins = @(Get-CopilotPlugin -ErrorAction Stop)
            $existing = switch ($requestedPlugin.Kind) {
                'Marketplace' {
                    @($installedPlugins | Where-Object {
                        $_.Managed -and $_.FullName -eq $requestedPlugin.FullName
                    })
                    break
                }
                'Direct' {
                    $exact = @($installedPlugins | Where-Object {
                        $_.Managed -and $_.InstalledFrom -and $_.InstalledFrom -eq $requestedPlugin.InstalledFrom
                    })
                    if ($exact) {
                        $exact
                        break
                    }

                    $legacy = @($installedPlugins | Where-Object {
                        -not $_.Source -and ($_.Name -eq $requestedPlugin.Name -or $_.FullName -eq $installSource)
                    })
                    if ($legacy) {
                        $legacy
                        break
                    }

                    $ambiguous = @($installedPlugins | Where-Object {
                        $_.Managed -and
                        -not $_.Marketplace -and
                        $_.Name -eq $requestedPlugin.Name -and
                        -not $_.InstalledFrom
                    })
                    if ($ambiguous) {
                        throw "Cannot determine whether plugin '$($requestedPlugin.Name)' is already installed because the Copilot CLI did not report its install source."
                    }

                    @()
                    break
                }
                default { @() }
            }
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
        Removes an installed plugin by name. Accepts pipeline input from
        Get-CopilotPlugin. Built-in plugins and --plugin-dir mounts are reported
        by discovery but rejected from the object pipeline because they are not
        managed installations.
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

        if ($PSCmdlet.ParameterSetName -eq 'ByObject' -and
            $InputObject.PSObject.Properties['Managed'] -and
            -not [bool]$InputObject.Managed) {
            Write-Error (Get-CopilotUnmanagedPluginMessage -Name $uninstallName -Source ([string]$InputObject.Source))
            return
        }

        $exe = Resolve-CliExe -Name copilot
        if ($PSCmdlet.ShouldProcess($uninstallName, 'copilot plugin uninstall')) {
            & $exe plugin uninstall $uninstallName 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Error "Failed to uninstall plugin: $uninstallName"
            }
        }
    }
}