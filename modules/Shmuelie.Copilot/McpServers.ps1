function Assert-CopilotMcpConfigNotSymbolicLink {
    [CmdletBinding()]
    param()

    $configDirectory = Join-Path (Get-CopilotHome) '.copilot'
    $configPath = Join-Path $configDirectory 'mcp-config.json'
    try {
        # Inspect the link itself, including dangling links, without resolving its target.
        $config = Get-Item -LiteralPath $configPath -Force -ErrorAction Stop
    } catch [System.Management.Automation.ItemNotFoundException] {
        return
    }

    if ($config.LinkType -eq 'SymbolicLink') {
        throw "Cannot modify Copilot MCP configuration '$configPath': it is a symbolic link to '$($config.LinkTarget)'. Manage the target file directly or use the tool that manages the link. Relative targets are based at '$configDirectory'. Native 'copilot mcp add/remove' would replace the link and was not run."
    }
}

function Assert-CopilotMcpToolFilter {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Tools,

        [Parameter(Mandatory)]
        [string]$ParameterName
    )

    if ($null -eq $Tools -or $Tools -eq '' -or $Tools -eq '*') {
        return
    }

    $filters = $Tools.Split(',', [System.StringSplitOptions]::None)
    if ($filters.Count -eq 0 -or ($filters | Where-Object { $_ -eq '' }).Count -gt 0) {
        throw [System.ArgumentException]::new(
            "Tools must be '*', an empty string, or a comma-separated list of non-empty tool names.",
            $ParameterName)
    }

    foreach ($filter in $filters) {
        if (-not (Test-CopilotShimArgument -Value $filter -Pattern '^[A-Za-z0-9][A-Za-z0-9._:-]*$')) {
            throw [System.ArgumentException]::new(
                "Unsafe $ParameterName value. Tool names passed to the copilot CLI may only contain allow-listed characters, and Tools must be '*', an empty string, or a comma-separated list.",
                $ParameterName)
        }
    }
}

function Get-CopilotMcpServerStringField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Server,

        [Parameter(Mandatory)]
        [string]$Name,

        [switch]$Required,

        [switch]$AllowEmpty
    )

    if (-not $Server.Contains($Name) -or $null -eq $Server[$Name]) {
        if ($Required) {
            throw [System.IO.InvalidDataException]::new("copilot mcp list --json returned server metadata without a '$Name' field.")
        }

        return ''
    }

    $value = $Server[$Name]
    if ($value -isnot [string]) {
        throw [System.IO.InvalidDataException]::new("copilot mcp list --json returned a non-string '$Name' field.")
    }

    if (-not $AllowEmpty -and [string]::IsNullOrEmpty($value)) {
        throw [System.IO.InvalidDataException]::new("copilot mcp list --json returned an empty '$Name' field.")
    }

    $value
}

function Get-CopilotMcpServerBooleanField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Server,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if (-not $Server.Contains($Name) -or $Server[$Name] -isnot [bool]) {
        throw [System.IO.InvalidDataException]::new("copilot mcp list --json returned server metadata without a Boolean '$Name' field.")
    }

    $Server[$Name]
}

function Get-CopilotMcpServerArgsText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Server
    )

    if (-not $Server.Contains('args') -or $null -eq $Server['args']) {
        return ''
    }

    $value = $Server['args']
    if ($value -is [string] -or $value -isnot [System.Collections.IEnumerable]) {
        throw [System.IO.InvalidDataException]::new("copilot mcp list --json returned a non-array 'args' field.")
    }

    $args = @($value)
    foreach ($arg in $args) {
        if ($arg -isnot [string]) {
            throw [System.IO.InvalidDataException]::new("copilot mcp list --json returned a non-string MCP argument.")
        }
    }

    $args -join ' '
}

function ConvertFrom-CopilotMcpServerListJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Json
    )

    if ([string]::IsNullOrWhiteSpace($Json)) {
        throw [System.IO.InvalidDataException]::new('copilot mcp list --json returned an empty response.')
    }

    try {
        $data = $Json | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    } catch {
        throw [System.IO.InvalidDataException]::new("copilot mcp list --json returned invalid JSON.", $_.Exception)
    }

    if ($data -isnot [System.Collections.IDictionary] -or -not $data.Contains('mcpServers') -or $data['mcpServers'] -isnot [System.Collections.IDictionary]) {
        throw [System.IO.InvalidDataException]::new("copilot mcp list --json did not return an object with an 'mcpServers' map.")
    }

    foreach ($entry in $data['mcpServers'].GetEnumerator()) {
        if ([string]::IsNullOrEmpty($entry.Key)) {
            throw [System.IO.InvalidDataException]::new('copilot mcp list --json returned an MCP server entry without a name.')
        }

        $server = $entry.Value
        if ($server -isnot [System.Collections.IDictionary]) {
            throw [System.IO.InvalidDataException]::new("copilot mcp list --json returned non-object metadata for MCP server '$($entry.Key)'.")
        }

        [PSCustomObject]@{
            PSTypeName = 'CopilotMcpServer'
            Name       = $entry.Key
            Type       = Get-CopilotMcpServerStringField -Server $server -Name type -Required
            Command    = Get-CopilotMcpServerStringField -Server $server -Name command
            Args       = Get-CopilotMcpServerArgsText -Server $server
            Url        = Get-CopilotMcpServerStringField -Server $server -Name url
            Source     = Get-CopilotMcpServerStringField -Server $server -Name source -Required
            Enabled    = Get-CopilotMcpServerBooleanField -Server $server -Name enabled
            Tools      = Get-CopilotMcpServerStringField -Server $server -Name tools -Required -AllowEmpty
        }
    }
}

function Get-CopilotMcpServer {
    <#
    .SYNOPSIS
        List configured Copilot CLI MCP servers.
    .DESCRIPTION
        Parses the JSON output of 'copilot mcp list' into typed objects with
        Name, Type, Source, Enabled, Tools, and connection details
        (Command/Args or URL). Native failures and invalid JSON fail closed and
        emit no server objects from that invocation.
    .PARAMETER Name
        Filter by server name. Supports wildcards.
    .PARAMETER Source
        Filter by source: user, workspace, plugin, or builtin.
    .EXAMPLE
        Get-CopilotMcpServer
        Lists all configured MCP servers.
    .EXAMPLE
        Get-CopilotMcpServer -Source user
        Lists only user-configured servers.
    .EXAMPLE
        Get-CopilotMcpServer Azure*
        Lists servers matching the filter.
    #>
    [OutputType('CopilotMcpServer')]
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Name = '*',

        [ValidateSet('user', 'workspace', 'plugin', 'builtin')]
        [string]$Source
    )
    $discoveryErrors = @()
    $output = @(Invoke-CopilotDiscovery -Arguments 'mcp', 'list', '--json' -ErrorVariable discoveryErrors)
    if ($discoveryErrors.Count -gt 0) {
        return
    }

    $json = $output | Out-String
    if ([string]::IsNullOrWhiteSpace($json)) {
        $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
            [System.IO.InvalidDataException]::new('copilot mcp list --json returned an empty response.'),
            'CopilotMcpServerJsonInvalid', [System.Management.Automation.ErrorCategory]::InvalidData, $null))
        return
    }

    try {
        $servers = @(ConvertFrom-CopilotMcpServerListJson -Json $json)
    } catch {
        Write-Error -Exception $_.Exception -ErrorId CopilotMcpServerJsonInvalid -Category InvalidData
        return
    }

    foreach ($server in $servers) {
        if ($server.Name -notlike $Name) { continue }
        if ($Source -and $server.Source -ne $Source) { continue }
        $server
    }
}

function Register-CopilotMcpServer {
    <#
    .SYNOPSIS
        Add an MCP server to the Copilot CLI user configuration.
    .DESCRIPTION
        Wraps 'copilot mcp add' with typed parameters for stdio and HTTP/SSE servers.
        Refuses to invoke the native command when ~/.copilot/mcp-config.json is a
        symbolic link, including relative, chained, and dangling links, because
        the native command would replace the link. Manage the target file directly
        or use the tool that manages the link. Regular files retain native CLI
        behavior and validation. WhatIf only previews the operation.
    .PARAMETER Name
        The server name.
    .PARAMETER Transport
        The transport type: stdio, http, or sse. Defaults to stdio.
    .PARAMETER Command
        The command to run for stdio servers.
    .PARAMETER ArgumentList
        Arguments for the stdio command.
    .PARAMETER Url
        The URL for http/sse servers.
    .PARAMETER Env
        Environment variables as KEY=VALUE strings.
    .PARAMETER Header
        HTTP headers for remote servers.
    .PARAMETER Tools
        Tool filter: '*' for all, an empty string for none, or a comma-separated
        list of tool names.
    .PARAMETER TimeoutMilliseconds
        Timeout in milliseconds. Must be between 1 and 4294967295.
    .EXAMPLE
        Register-CopilotMcpServer -Name context7 -Transport http -Url https://mcp.context7.com/mcp
        Adds a remote HTTP MCP server.
    .EXAMPLE
        Register-CopilotMcpServer -Name myserver -Command npx -ArgumentList '-y', '@my/mcp-server'
        Adds a local stdio MCP server.
    .EXAMPLE
        Register-CopilotMcpServer -Name docs -Command npx -ArgumentList '-y', 'docs-mcp' -Tools '' -TimeoutMilliseconds 30000
        Adds a local MCP server with no exposed tools and a 30-second timeout.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Position = 0, Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [ValidateSet('stdio', 'http', 'sse')]
        [string]$Transport = 'stdio',

        [string]$Command,

        [string[]]$ArgumentList,

        [string]$Url,

        [string[]]$Env,

        [string[]]$Header,

        [AllowEmptyString()]
        [string]$Tools,

        [Alias('Timeout')]
        [ValidateRange(1, [uint32]::MaxValue)]
        [uint32]$TimeoutMilliseconds
    )
    Assert-CopilotShimArgument -Value $Name -ParameterName 'Name' -Pattern '^[A-Za-z0-9][A-Za-z0-9._-]*$'
    if ($Command) { Assert-CopilotShimTextArgument -Value $Command -ParameterName 'Command' }
    if ($ArgumentList) {
        foreach ($argument in $ArgumentList) {
            Assert-CopilotShimTextArgument -Value $argument -ParameterName 'ArgumentList'
        }
    }
    if ($Url) { Assert-CopilotShimTextArgument -Value $Url -ParameterName 'Url' }
    if ($Env) {
        foreach ($entry in $Env) {
            Assert-CopilotShimTextArgument -Value $entry -ParameterName 'Env'
        }
    }
    if ($Header) {
        foreach ($entry in $Header) {
            Assert-CopilotShimTextArgument -Value $entry -ParameterName 'Header'
        }
    }
    if ($PSBoundParameters.ContainsKey('Tools')) {
        Assert-CopilotMcpToolFilter -Tools $Tools -ParameterName 'Tools'
    }

    $copilotExe = Resolve-CliExe -Name copilot
    if ($PSCmdlet.ShouldProcess($Name, 'copilot mcp add')) {
        $addArgs = @('mcp', 'add', '--transport', $Transport)
        if ($Env) { foreach ($e in $Env) { $addArgs += '--env', $e } }
        if ($Header) { foreach ($h in $Header) { $addArgs += '--header', $h } }
        if ($PSBoundParameters.ContainsKey('Tools')) { $addArgs += '--tools', $Tools }
        if ($PSBoundParameters.ContainsKey('TimeoutMilliseconds')) { $addArgs += '--timeout', "$TimeoutMilliseconds" }
        $addArgs += $Name
        if ($Transport -eq 'stdio') {
            $addArgs += '--'
            if ($Command) { $addArgs += $Command }
            if ($ArgumentList) { $addArgs += $ArgumentList }
        } else {
            if ($Url) { $addArgs += $Url }
        }
        Assert-CopilotMcpConfigNotSymbolicLink
        & $copilotExe @addArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to add MCP server: $Name"
        }
    }
}

function Unregister-CopilotMcpServer {
    <#
    .SYNOPSIS
        Remove an MCP server from the Copilot CLI configuration.
    .DESCRIPTION
        Removes a server by name. Accepts pipeline input from Get-CopilotMcpServer.
        Refuses to invoke the native command when ~/.copilot/mcp-config.json is a
        symbolic link, including relative, chained, and dangling links, because
        the native command would replace the link. Manage the target file directly
        or use the tool that manages the link. The check applies to each pipeline
        item. Regular files retain native CLI behavior and validation. WhatIf only
        previews the operation.
    .PARAMETER InputObject
        A CopilotMcpServer object from Get-CopilotMcpServer.
    .PARAMETER Name
        The server name to remove.
    .EXAMPLE
        Unregister-CopilotMcpServer -Name old-server
        Removes the specified MCP server.
    .EXAMPLE
        Get-CopilotMcpServer old* | Unregister-CopilotMcpServer
        Removes servers matching the filter.
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'ByObject')]
    param(
        [Parameter(ParameterSetName = 'ByObject', ValueFromPipeline, Mandatory)]
        [PSObject]$InputObject,

        [Parameter(ParameterSetName = 'ByName', Position = 0, Mandatory)]
        [string]$Name
    )
    process {
        $removeName = if ($PSCmdlet.ParameterSetName -eq 'ByName') { $Name } else { $InputObject.Name }
        Assert-CopilotShimArgument -Value $removeName -ParameterName 'Name' -Pattern '^[A-Za-z0-9][A-Za-z0-9._-]*$'

        $copilotExe = Resolve-CliExe -Name copilot
        if ($PSCmdlet.ShouldProcess($removeName, 'copilot mcp remove')) {
            Assert-CopilotMcpConfigNotSymbolicLink
            & $copilotExe mcp remove $removeName 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Error "Failed to remove MCP server: $removeName"
            }
        }
    }
}