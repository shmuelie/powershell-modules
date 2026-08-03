function Get-CopilotMcpServer {
    <#
    .SYNOPSIS
        List configured Copilot CLI MCP servers.
    .DESCRIPTION
        Parses the JSON output of 'copilot mcp list' into typed objects with
        Name, Type, Source, and connection details (Command/Args or URL).
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
    $copilotExe = (Get-Command copilot -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $json = & $copilotExe mcp list --json 2>&1 | Out-String
    $data = $json | ConvertFrom-Json
    foreach ($prop in $data.mcpServers.PSObject.Properties) {
        $server = $prop.Value
        if ($prop.Name -notlike $Name) { continue }
        if ($Source -and $server.source -ne $Source) { continue }
        [PSCustomObject]@{
            PSTypeName = 'CopilotMcpServer'
            Name       = $prop.Name
            Type       = $server.type
            Command    = if ($server.command) { $server.command } else { '' }
            Args       = if ($server.args) { $server.args -join ' ' } else { '' }
            Url        = if ($server.url) { $server.url } else { '' }
            Source     = $server.source
        }
    }
}

function Register-CopilotMcpServer {
    <#
    .SYNOPSIS
        Add an MCP server to the Copilot CLI user configuration.
    .DESCRIPTION
        Wraps 'copilot mcp add' with typed parameters for stdio and HTTP/SSE servers.
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
    .EXAMPLE
        Register-CopilotMcpServer -Name context7 -Transport http -Url https://mcp.context7.com/mcp
        Adds a remote HTTP MCP server.
    .EXAMPLE
        Register-CopilotMcpServer -Name myserver -Command npx -ArgumentList '-y', '@my/mcp-server'
        Adds a local stdio MCP server.
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

        [string[]]$Header
    )
    $copilotExe = (Get-Command copilot -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    if ($PSCmdlet.ShouldProcess($Name, 'copilot mcp add')) {
        $addArgs = @('mcp', 'add', '--transport', $Transport)
        if ($Env) { foreach ($e in $Env) { $addArgs += '--env', $e } }
        if ($Header) { foreach ($h in $Header) { $addArgs += '--header', $h } }
        $addArgs += $Name
        if ($Transport -eq 'stdio') {
            $addArgs += '--'
            if ($Command) { $addArgs += $Command }
            if ($ArgumentList) { $addArgs += $ArgumentList }
        } else {
            if ($Url) { $addArgs += $Url }
        }
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
        $copilotExe = (Get-Command copilot -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        $removeName = if ($PSCmdlet.ParameterSetName -eq 'ByName') { $Name } else { $InputObject.Name }
        if ($PSCmdlet.ShouldProcess($removeName, 'copilot mcp remove')) {
            & $copilotExe mcp remove $removeName 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Error "Failed to remove MCP server: $removeName"
            }
        }
    }
}