function Get-DevTunnel {
    <#
    .SYNOPSIS
        List tunnels or show an explicitly selected tunnel.
    .DESCRIPTION
        With no TunnelId, lists tunnels. Specify LastUsed to show the CLI default.
        Preserves the CLI JSON envelope rather than parsing display tables.
    .EXAMPLE
        Get-DevTunnel -Label web
    .EXAMPLE
        Get-DevTunnel -TunnelId my-tunnel
    #>
    [CmdletBinding(DefaultParameterSetName = 'List')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Show', ValueFromPipelineByPropertyName)]
        [Alias('Id')][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9.-]*$')][string]$TunnelId,
        [Parameter(Mandatory, ParameterSetName = 'LastUsed')][switch]$LastUsed,
        [Parameter(ParameterSetName = 'List')][ValidateNotNullOrEmpty()][string[]]$Label,
        [Parameter(ParameterSetName = 'List')][ValidateNotNullOrEmpty()][string[]]$AllLabel,
        [Parameter(ParameterSetName = 'List')][ValidateRange(1, [int]::MaxValue)][int]$Limit
    )
    process {
        if ($PSCmdlet.ParameterSetName -eq 'LastUsed' -and -not $LastUsed) {
            throw 'LastUsed must be explicitly enabled.'
        }
        $command = if ($PSCmdlet.ParameterSetName -eq 'List') { 'list' } else { 'show' }
        Invoke-DevTunnelCommand -Arguments (New-DevTunnelArguments -Command $command -Parameters $PSBoundParameters -Json)
    }
}

function New-DevTunnel {
    <#
    .SYNOPSIS
        Create a persistent tunnel with authenticated access by default.
    .EXAMPLE
        New-DevTunnel -TunnelId my-tunnel -Description 'Local web service' -Label web
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9.-]*$')][string]$TunnelId,
        [ValidateNotNullOrEmpty()][string]$Description,
        [ValidateNotNullOrEmpty()][string[]]$Label,
        [ValidateScript({ Test-DevTunnelExpiration $_ })][string]$Expiration,
        [switch]$AllowAnonymous
    )
    if ($PSCmdlet.ShouldProcess($(if ($TunnelId) { $TunnelId } else { 'new persistent tunnel' }), 'Create tunnel')) {
        if ($AllowAnonymous) { Write-DevTunnelAnonymousWarning }
        Invoke-DevTunnelCommand -Arguments (New-DevTunnelArguments -Command create -Parameters $PSBoundParameters -Json)
    }
}

function Set-DevTunnel {
    <#
    .SYNOPSIS
        Update tunnel metadata; an omitted ID uses the CLI's last-used tunnel.
    .EXAMPLE
        Set-DevTunnel -TunnelId my-tunnel -Description 'Updated description' -AddLabel web
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(ValueFromPipelineByPropertyName)][Alias('Id')]
        [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9.-]*$')][string]$TunnelId,
        [AllowEmptyString()][string]$Description,
        [ValidateNotNullOrEmpty()][string[]]$AddLabel,
        [ValidateNotNullOrEmpty()][string[]]$RemoveLabel,
        [ValidateScript({ Test-DevTunnelExpiration $_ })][string]$Expiration
    )
    process {
        if ($PSCmdlet.ShouldProcess($(if ($TunnelId) { $TunnelId } else { 'last-used tunnel' }), 'Update tunnel')) {
            Invoke-DevTunnelCommand -Arguments (New-DevTunnelArguments -Command update -Parameters $PSBoundParameters -Json)
        }
    }
}

function Remove-DevTunnel {
    <#
    .SYNOPSIS
        Delete the selected tunnel, or all owned tunnels with All.
    .DESCRIPTION
        Uses PowerShell confirmation; CLI force only suppresses a second prompt.
        Omitting TunnelId selects the last-used tunnel.
    .EXAMPLE
        Remove-DevTunnel -TunnelId my-tunnel
    .EXAMPLE
        Remove-DevTunnel -All -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Single')]
    param(
        [Parameter(ParameterSetName = 'Single', ValueFromPipelineByPropertyName)][Alias('Id')]
        [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9.-]*$')][string]$TunnelId,
        [Parameter(Mandatory, ParameterSetName = 'All')][switch]$All
    )
    process {
        if ($PSCmdlet.ParameterSetName -eq 'All' -and -not $All) { throw 'All must be explicitly enabled.' }
        $target = if ($All) { 'all owned tunnels' } elseif ($TunnelId) { $TunnelId } else { 'last-used tunnel' }
        if ($PSCmdlet.ShouldProcess($target, 'Delete tunnel')) {
            $command = if ($All) { 'delete-all' } else { 'delete' }
            $arguments = @(New-DevTunnelArguments -Command $command -Parameters $PSBoundParameters -Json) + '--force'
            Invoke-DevTunnelCommand -Arguments $arguments
        }
    }
}

function Set-DevTunnelDefault {
    <#
    .SYNOPSIS
        Set the CLI's last-used tunnel.
    .EXAMPLE
        Set-DevTunnelDefault -TunnelId my-tunnel
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)][Alias('Id')]
        [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9.-]*$')][string]$TunnelId
    )
    process {
        if ($PSCmdlet.ShouldProcess($TunnelId, 'Set default tunnel')) {
            Invoke-DevTunnelCommand -Arguments (New-DevTunnelArguments -Command set -Parameters $PSBoundParameters -Json)
        }
    }
}

function Clear-DevTunnelDefault {
    <#
    .SYNOPSIS
        Clear the CLI's last-used tunnel selection.
    .EXAMPLE
        Clear-DevTunnelDefault
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if ($PSCmdlet.ShouldProcess('last-used tunnel', 'Clear default tunnel')) {
        Invoke-DevTunnelCommand -Arguments @('unset', '--json')
    }
}
