# Agency plugin cmdlets — thin wrappers over the native `agency plugin ...`
# commands (install / uninstall / list / cache), exposing their options as
# PowerShell parameters. (Copilot CLI plugin cmdlets live in Plugins.ps1.)

function Get-AgencyPlugin {
    <#
    .SYNOPSIS
        List installed Agency plugins.
    .DESCRIPTION
        Parses the output of 'agency plugin list' into typed AgencyPlugin objects
        (Name, FullName, Source, Marketplace, Engines, Scope — no Version).
    .PARAMETER Name
        Filter by plugin name. Supports wildcards (client-side).
    .PARAMETER Engine
        Filter by engine: claude and/or copilot (native --engine).
    .PARAMETER Catalog
        Filter by catalog membership name (native --catalog).
    .PARAMETER NoConfigCache
        Bypass the on-disk cache for remote_config fetches (native --no-config-cache).
    .EXAMPLE
        Get-AgencyPlugin
        Lists all installed plugins via Agency.
    .EXAMPLE
        Get-AgencyPlugin dotnet* -Engine copilot
        Lists copilot-engine plugins whose name starts with 'dotnet'.
    #>
    [OutputType('AgencyPlugin')]
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Name = '*',

        [ValidateSet('claude', 'copilot')]
        [string[]]$Engine,

        [string]$Catalog,

        [switch]$NoConfigCache
    )
    $exe = Resolve-CliExe -Name agency
    $cliArgs = @('plugin', 'list')
    foreach ($e in $Engine) { $cliArgs += '--engine', $e }
    if ($Catalog) { $cliArgs += '--catalog', $Catalog }
    if ($NoConfigCache) { $cliArgs += '--no-config-cache' }

    $output = & $exe @cliArgs 2>&1
    foreach ($line in $output) {
        # e.g. "  my-plugin — market:my-plugin@https://… (engines: Copilot) [global]"
        # \p{Pd} matches the em-dash separator; the (engines: …) [scope] anchors
        # reject the header / "Sources:" / summary lines.
        if ($line -match '^\s+(\S+)\s+\p{Pd}\s+(.+?)\s+\(engines:\s+(.+?)\)\s+\[(.+?)\]\s*$') {
            $pluginName = $Matches[1]
            $source = $Matches[2].Trim()
            $engines = $Matches[3].Trim()
            $scope = $Matches[4].Trim()
            $marketplace = if ($source -match '@(.+)$') { $Matches[1] } else { '' }

            $plugin = [PSCustomObject]@{
                PSTypeName  = 'AgencyPlugin'
                Name        = $pluginName
                FullName    = $pluginName
                Source      = $source
                Marketplace = $marketplace
                Engines     = $engines
                Scope       = $scope
            }
            if ($plugin.Name -like $Name -or $plugin.FullName -like $Name) {
                $plugin
            }
        }
    }
}

function Install-AgencyPlugin {
    <#
    .SYNOPSIS
        Install a plugin via Agency.
    .DESCRIPTION
        Installs a plugin (or catalog) using the native 'agency plugin install'
        command. Provide either a raw plugin/catalog spec via -Source, or the
        plugin -Name plus its -Marketplace (composed into 'market:<Name>@<Marketplace>').
    .PARAMETER Source
        A raw plugin or catalog spec, e.g. 'github:owner/repo:path',
        'market:name@location', or 'cat:name@location'.
    .PARAMETER Name
        The plugin name (used with -Marketplace to compose a market: spec).
    .PARAMETER Marketplace
        The marketplace location (preset, owner/repo, GitHub/ADO URL, or a
        registered marketplace) that provides the plugin named by -Name.
    .PARAMETER Engine
        Restrict to specific engines: claude and/or copilot (native --engine,
        additive on re-install).
    .PARAMETER CachePolicy
        Cache policy in agency-managed sessions (native --cache-policy).
    .PARAMETER CacheTtl
        Cache TTL override in seconds (native --cache-ttl).
    .PARAMETER FetchMode
        Fetch mode: foreground or background (native --fetch-mode).
    .PARAMETER NoConfigCache
        Bypass the on-disk cache for remote_config fetches (native --no-config-cache).
    .PARAMETER Profile
        After installing, also add the plugin to the named Agency profile(s) in the
        tracked Configuration/agency-profiles.toml (via Add-AgencyProfilePlugin) and
        re-sync to the global agency.toml. Agency has no native install-to-profile,
        so this manages profile membership through the tracked file.
    .EXAMPLE
        Install-AgencyPlugin -Source github:shmuelie/shmuelie-skills
        Installs a plugin from a raw spec.
    .EXAMPLE
        Install-AgencyPlugin -Name my-plugin -Marketplace https://github.com/myorg/plugins -Engine copilot
        Composes 'market:my-plugin@<url>' and installs it for the copilot engine.
    .EXAMPLE
        Install-AgencyPlugin -Name diagnostics -Marketplace https://github.com/myorg/plugins -Profile development
        Installs the plugin and adds it to the 'os' profile.
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'BySpec')]
    param(
        [Parameter(ParameterSetName = 'BySpec', Position = 0, Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Source,

        [Parameter(ParameterSetName = 'ByName', Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(ParameterSetName = 'ByName', Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Marketplace,

        [ValidateSet('claude', 'copilot')]
        [string[]]$Engine,

        [ValidateSet('auto', 'no-refresh', 'cache-only', 'force-refresh', 'skip')]
        [string]$CachePolicy,

        [int]$CacheTtl,

        [ValidateSet('foreground', 'background')]
        [string]$FetchMode,

        [switch]$NoConfigCache,

        [string[]]$Profile
    )
    $spec = if ($PSCmdlet.ParameterSetName -eq 'ByName') { "market:$Name@$Marketplace" } else { $Source }

    $cliArgs = @('plugin', 'install', $spec)
    foreach ($e in $Engine) { $cliArgs += '--engine', $e }
    if ($CachePolicy) { $cliArgs += '--cache-policy', $CachePolicy }
    if ($PSBoundParameters.ContainsKey('CacheTtl')) { $cliArgs += '--cache-ttl', $CacheTtl }
    if ($FetchMode) { $cliArgs += '--fetch-mode', $FetchMode }
    if ($NoConfigCache) { $cliArgs += '--no-config-cache' }

    $exe = Resolve-CliExe -Name agency
    if ($PSCmdlet.ShouldProcess($spec, 'agency plugin install')) {
        & $exe @cliArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to install plugin: $spec"
            return
        }
        foreach ($p in $Profile) {
            Add-AgencyProfilePlugin -Profile $p -Plugin $spec
        }
    }
}

function Uninstall-AgencyPlugin {
    <#
    .SYNOPSIS
        Uninstall a plugin via Agency.
    .DESCRIPTION
        Removes an installed plugin (or catalog) using the native
        'agency plugin uninstall' command. Accepts pipeline input from Get-AgencyPlugin.
    .PARAMETER InputObject
        An AgencyPlugin object from Get-AgencyPlugin.
    .PARAMETER Name
        The plugin (or catalog) spec/name to uninstall.
    .PARAMETER Engine
        Remove only from specific engines: claude and/or copilot (native --engine).
    .PARAMETER Force
        Skip the confirmation prompt (catalog uninstall only; native -f/--force).
    .PARAMETER NoConfigCache
        Bypass the on-disk cache for remote_config fetches (native --no-config-cache).
    .EXAMPLE
        Uninstall-AgencyPlugin -Name my-plugin
        Uninstalls the specified plugin.
    .EXAMPLE
        Get-AgencyPlugin old-plugin | Uninstall-AgencyPlugin
        Uninstalls via pipeline.
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'ByObject')]
    param(
        [Parameter(ParameterSetName = 'ByObject', ValueFromPipeline, Mandatory)]
        [PSObject]$InputObject,

        [Parameter(ParameterSetName = 'ByName', Position = 0, Mandatory)]
        [string]$Name,

        [ValidateSet('claude', 'copilot')]
        [string[]]$Engine,

        [switch]$Force,

        [switch]$NoConfigCache
    )
    process {
        $uninstallName = if ($PSCmdlet.ParameterSetName -eq 'ByName') { $Name } else { $InputObject.FullName }

        $cliArgs = @('plugin', 'uninstall', $uninstallName)
        foreach ($e in $Engine) { $cliArgs += '--engine', $e }
        if ($Force) { $cliArgs += '--force' }
        if ($NoConfigCache) { $cliArgs += '--no-config-cache' }

        $exe = Resolve-CliExe -Name agency
        if ($PSCmdlet.ShouldProcess($uninstallName, 'agency plugin uninstall')) {
            & $exe @cliArgs 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Error "Failed to uninstall plugin: $uninstallName"
            }
        }
    }
}

function Get-AgencyPluginCache {
    <#
    .SYNOPSIS
        Show Agency's plugin download cache.
    .DESCRIPTION
        Parses 'agency plugin cache list' into typed AgencyPluginCacheEntry objects.
        With -Info, returns the cache summary ('agency plugin cache info': location,
        entry count, disk usage) instead of the per-entry list.
    .PARAMETER Info
        Return the cache summary instead of the per-entry list.
    .PARAMETER NoConfigCache
        Bypass the on-disk cache for remote_config fetches (native --no-config-cache).
    .EXAMPLE
        Get-AgencyPluginCache
        Lists cached plugin entries.
    .EXAMPLE
        Get-AgencyPluginCache -Info
        Shows the cache location, entry count, and disk usage.
    #>
    [OutputType('AgencyPluginCacheEntry')]
    [CmdletBinding()]
    param(
        [switch]$Info,

        [switch]$NoConfigCache
    )
    $exe = Resolve-CliExe -Name agency
    $cliArgs = @('plugin', 'cache', $(if ($Info) { 'info' } else { 'list' }))
    if ($NoConfigCache) { $cliArgs += '--no-config-cache' }
    $output = & $exe @cliArgs 2>&1

    if ($Info) {
        # Emit the raw summary lines (Location / Entries / Total size / ...).
        $output | ForEach-Object { $_.ToString() } | Where-Object { $_ -match '^\s{2,}\S' }
        return
    }

    foreach ($line in $output) {
        # e.g. "  market:name@loc (Copilot) — cached 1d ago, ..., fetch: background [installed, standalone, stale]"
        if ($line -match '^\s+(\S+)\s+\(([^)]+)\)\s+\p{Pd}\s+(.+?)\s+\[(.+?)\]\s*$') {
            $spec = $Matches[1]
            $engines = $Matches[2].Trim()
            $detail = $Matches[3].Trim()
            $flags = $Matches[4].Trim()
            $name = if ($spec -match '^market:([^@]+)@') { $Matches[1] } else { $spec }
            $marketplace = if ($spec -match '@(.+)$') { $Matches[1] } else { '' }
            $fetch = if ($detail -match 'fetch:\s*(\S+)') { $Matches[1] } else { '' }

            [PSCustomObject]@{
                PSTypeName  = 'AgencyPluginCacheEntry'
                Name        = $name
                Spec        = $spec
                Marketplace = $marketplace
                Engines     = $engines
                Fetch       = $fetch
                Flags       = $flags
                Detail      = $detail
            }
        }
    }
}

function Clear-AgencyPluginCache {
    <#
    .SYNOPSIS
        Remove all cached plugin data (native 'agency plugin cache clean').
    .PARAMETER NoConfigCache
        Bypass the on-disk cache for remote_config fetches (native --no-config-cache).
    .EXAMPLE
        Clear-AgencyPluginCache
        Clears the entire Agency plugin cache.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [switch]$NoConfigCache
    )
    $exe = Resolve-CliExe -Name agency
    $cliArgs = @('plugin', 'cache', 'clean')
    if ($NoConfigCache) { $cliArgs += '--no-config-cache' }
    if ($PSCmdlet.ShouldProcess('Agency plugin cache', 'agency plugin cache clean')) {
        & $exe @cliArgs 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Error 'Failed to clean the Agency plugin cache.' }
    }
}

function Remove-AgencyPluginCache {
    <#
    .SYNOPSIS
        Remove a specific plugin from the Agency cache (native 'agency plugin cache remove').
    .DESCRIPTION
        Removes one cached plugin (or every cached entry for a catalog spec).
        Accepts pipeline input from Get-AgencyPluginCache.
    .PARAMETER InputObject
        An AgencyPluginCacheEntry object from Get-AgencyPluginCache.
    .PARAMETER Spec
        The plugin spec / cache folder shorthand, or a catalog spec.
    .PARAMETER Force
        Skip the confirmation prompt (native -f/--force).
    .PARAMETER NoConfigCache
        Bypass the on-disk cache for remote_config fetches (native --no-config-cache).
    .EXAMPLE
        Remove-AgencyPluginCache -Spec market:dotnet@dotnet/skills -Force
        Removes a single cached plugin without prompting.
    .EXAMPLE
        Get-AgencyPluginCache | Where-Object Flags -match 'stale' | Remove-AgencyPluginCache -Force
        Removes all stale cached entries.
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'BySpec')]
    param(
        [Parameter(ParameterSetName = 'ByObject', ValueFromPipeline, Mandatory)]
        [PSObject]$InputObject,

        [Parameter(ParameterSetName = 'BySpec', Position = 0, Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Spec,

        [switch]$Force,

        [switch]$NoConfigCache
    )
    process {
        $target = if ($PSCmdlet.ParameterSetName -eq 'ByObject') { $InputObject.Spec } else { $Spec }
        $cliArgs = @('plugin', 'cache', 'remove', $target)
        if ($Force) { $cliArgs += '--force' }
        if ($NoConfigCache) { $cliArgs += '--no-config-cache' }
        $exe = Resolve-CliExe -Name agency
        if ($PSCmdlet.ShouldProcess($target, 'agency plugin cache remove')) {
            & $exe @cliArgs 2>&1
            if ($LASTEXITCODE -ne 0) { Write-Error "Failed to remove cached plugin: $target" }
        }
    }
}

function Optimize-AgencyPluginCache {
    <#
    .SYNOPSIS
        Run garbage collection on the Agency plugin cache (native 'agency plugin cache gc').
    .PARAMETER NoConfigCache
        Bypass the on-disk cache for remote_config fetches (native --no-config-cache).
    .EXAMPLE
        Optimize-AgencyPluginCache
        Manually runs cache garbage collection.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [switch]$NoConfigCache
    )
    $exe = Resolve-CliExe -Name agency
    $cliArgs = @('plugin', 'cache', 'gc')
    if ($NoConfigCache) { $cliArgs += '--no-config-cache' }
    if ($PSCmdlet.ShouldProcess('Agency plugin cache', 'agency plugin cache gc')) {
        & $exe @cliArgs 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Error 'Failed to run Agency plugin cache gc.' }
    }
}
