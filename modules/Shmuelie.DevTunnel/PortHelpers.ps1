function Get-DevTunnelPort {
    <#
    .SYNOPSIS
        List tunnel ports or show a specified port.
    .EXAMPLE
        Get-DevTunnelPort -TunnelId my-tunnel -PortNumber 3000
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipelineByPropertyName)][Alias('Id')]
        [ValidatePattern('\A[a-zA-Z0-9][a-zA-Z0-9.-]*\z')][string]$TunnelId,
        [ValidateRange(1, 65535)][int]$PortNumber
    )
    process {
        $verb = if ($PSBoundParameters.ContainsKey('PortNumber')) { 'show' } else { 'list' }
        Invoke-DevTunnelCommand -Arguments (New-DevTunnelArguments -Command port, $verb -Parameters $PSBoundParameters -Json)
    }
}

function New-DevTunnelPort {
    <#
    .SYNOPSIS
        Add a port to a persistent or last-used tunnel.
    .EXAMPLE
        New-DevTunnelPort -TunnelId my-tunnel -PortNumber 3000 -Protocol http
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(ValueFromPipelineByPropertyName)][Alias('Id')]
        [ValidatePattern('\A[a-zA-Z0-9][a-zA-Z0-9.-]*\z')][string]$TunnelId,
        [Parameter(Mandatory)][ValidateRange(1, 65535)][int]$PortNumber,
        [ValidateSet('http', 'https', 'auto')][string]$Protocol,
        [ValidateNotNullOrEmpty()][string]$Description,
        [ValidateNotNullOrEmpty()][string[]]$Label
    )
    process {
        if ($PSCmdlet.ShouldProcess("$TunnelId port $PortNumber (omitted ID uses last-used tunnel)", 'Create port')) {
            Invoke-DevTunnelCommand -Arguments (New-DevTunnelArguments -Command port, create -Parameters $PSBoundParameters -Json)
        }
    }
}

function Set-DevTunnelPort {
    <#
    .SYNOPSIS
        Update a tunnel port's description or labels.
    .EXAMPLE
        Set-DevTunnelPort -TunnelId my-tunnel -PortNumber 3000 -Description 'Frontend'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(ValueFromPipelineByPropertyName)][Alias('Id')]
        [ValidatePattern('\A[a-zA-Z0-9][a-zA-Z0-9.-]*\z')][string]$TunnelId,
        [Parameter(Mandatory)][ValidateRange(1, 65535)][int]$PortNumber,
        [AllowEmptyString()][string]$Description,
        [ValidateNotNullOrEmpty()][string[]]$AddLabel,
        [ValidateNotNullOrEmpty()][string[]]$RemoveLabel
    )
    process {
        if ($PSCmdlet.ShouldProcess("$TunnelId port $PortNumber (omitted ID uses last-used tunnel)", 'Update port')) {
            Invoke-DevTunnelCommand -Arguments (New-DevTunnelArguments -Command port, update -Parameters $PSBoundParameters -Json)
        }
    }
}

function Remove-DevTunnelPort {
    <#
    .SYNOPSIS
        Delete a tunnel port.
    .EXAMPLE
        Remove-DevTunnelPort -TunnelId my-tunnel -PortNumber 3000
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(ValueFromPipelineByPropertyName)][Alias('Id')]
        [ValidatePattern('\A[a-zA-Z0-9][a-zA-Z0-9.-]*\z')][string]$TunnelId,
        [Parameter(Mandatory)][ValidateRange(1, 65535)][int]$PortNumber
    )
    process {
        if ($PSCmdlet.ShouldProcess("$TunnelId port $PortNumber (omitted ID uses last-used tunnel)", 'Delete port')) {
            Invoke-DevTunnelCommand -Arguments (New-DevTunnelArguments -Command port, delete -Parameters $PSBoundParameters -Json)
        }
    }
}
