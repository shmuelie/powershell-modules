function Start-DevTunnel {
    <#
    .SYNOPSIS
        Host a temporary or existing tunnel in the foreground.
    .DESCRIPTION
        Omitting TunnelId creates a temporary tunnel, not the last-used tunnel.
        Cancellation stops only the invocation's process tree. Forced termination
        may leave a temporary tunnel until its service expiration; see README.
    .EXAMPLE
        Start-DevTunnel -PortNumber 3000, 5000 -Protocol http -Expiration 1h
    .EXAMPLE
        Start-DevTunnel -TunnelId my-tunnel
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9.-]*$')][string]$TunnelId,
        [ValidateNotNullOrEmpty()][ValidateRange(1, 65535)][int[]]$PortNumber,
        [ValidateSet('http', 'https', 'auto')][string]$Protocol,
        [ValidateNotNullOrEmpty()][string]$Description,
        [ValidateNotNullOrEmpty()][string[]]$Label,
        [ValidateScript({ Test-DevTunnelExpiration $_ })][string]$Expiration,
        [switch]$AllowAnonymous
    )
    if ($PSCmdlet.ShouldProcess($(if ($TunnelId) { $TunnelId } else { 'new temporary tunnel' }), 'Host tunnel in foreground')) {
        if ($AllowAnonymous) { Write-DevTunnelAnonymousWarning }
        Invoke-DevTunnelCommand -Arguments (New-DevTunnelArguments -Command host -Parameters $PSBoundParameters) -Stream
    }
}

function Connect-DevTunnel {
    <#
    .SYNOPSIS
        Connect local forwarding ports to an existing tunnel in the foreground.
    .EXAMPLE
        Connect-DevTunnel -TunnelId my-tunnel
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9.-]*$')][string]$TunnelId
    )
    if ($PSCmdlet.ShouldProcess($(if ($TunnelId) { $TunnelId } else { 'last-used tunnel' }), 'Connect tunnel in foreground')) {
        Invoke-DevTunnelCommand -Arguments (New-DevTunnelArguments -Command connect -Parameters $PSBoundParameters) -Stream
    }
}

function Get-DevTunnelCluster {
    <#
    .SYNOPSIS
        List service clusters, optionally measuring latency.
    .EXAMPLE
        Get-DevTunnelCluster -Ping
    #>
    [CmdletBinding()]
    param([switch]$Ping)
    Invoke-DevTunnelCommand -Arguments (New-DevTunnelArguments -Command clusters -Parameters $PSBoundParameters -Json)
}

function Get-DevTunnelLimit {
    <#
    .SYNOPSIS
        Get the current user's service limits.
    .EXAMPLE
        Get-DevTunnelLimit
    #>
    [CmdletBinding()]
    param()
    Invoke-DevTunnelCommand -Arguments @('limits', '--json')
}

function Start-DevTunnelEcho {
    <#
    .SYNOPSIS
        Start a foreground diagnostic echo server, bound to loopback by default.
    .EXAMPLE
        Start-DevTunnelEcho -Protocol http -PortNumber 8080
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [ValidateSet('http', 'https', 'ssh', 'tcp', 'udp')][string]$Protocol = 'http',
        [Parameter(Mandatory)][ValidateRange(1, 65535)][int]$PortNumber,
        [ValidateScript({ $null = [System.Net.IPAddress]::Parse($_); $true })][string]$Interface = '127.0.0.1'
    )
    if ($PSCmdlet.ShouldProcess("${Interface}:$PortNumber", 'Start foreground echo server')) {
        Invoke-DevTunnelCommand -Arguments @('echo', $Protocol, "--port=$PortNumber", "--interface=$Interface") -Stream
    }
}

function Test-DevTunnel {
    <#
    .SYNOPSIS
        Send foreground diagnostic messages to an explicit echo server URI.
    .DESCRIPTION
        Streams CLI text rather than returning a Boolean connectivity result.
        Cancel the pipeline to stop sending messages.
    .EXAMPLE
        Test-DevTunnel -Uri http://localhost:8080 -Size 64 -Interval 1000
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][ValidateScript({
            if (-not $_.IsAbsoluteUri -or $_.Scheme -notin 'http', 'https', 'ws', 'wss', 'tcp', 'udp', 'ssh' -or $_.UserInfo) {
                throw 'Specify an absolute echo server URI without embedded credentials.'
            }
            $true
        })][uri]$Uri,
        [ValidateRange(1, [int]::MaxValue)][int]$Size,
        [ValidateRange(1, [int]::MaxValue)][int]$Interval
    )
    if ($PSCmdlet.ShouldProcess($Uri.AbsoluteUri, 'Send diagnostic messages')) {
        Invoke-DevTunnelCommand -Arguments (New-DevTunnelArguments -Command @('ping', $Uri.AbsoluteUri) -Parameters $PSBoundParameters) -Stream
    }
}
