function Get-DevTunnelVersion {
    <#
    .SYNOPSIS
        Get the supported devtunnel CLI version and executable path.
    .EXAMPLE
        Get-DevTunnelVersion
    #>
    [CmdletBinding()]
    [OutputType('Shmuelie.DevTunnel.Version')]
    param()
    $filePath = Resolve-DevTunnelCli
    [pscustomobject]@{
        PSTypeName = 'Shmuelie.DevTunnel.Version'
        Version = Get-DevTunnelCliVersion -FilePath $filePath
        Path = $filePath
    }
}

function Connect-DevTunnelAccount {
    <#
    .SYNOPSIS
        Log in through the CLI using browser or device-code authentication.
    .DESCRIPTION
        Uses a Microsoft account by default. GitHub selects GitHub login.
        Streams CLI authentication instructions; credentials remain CLI-owned.
    .EXAMPLE
        Connect-DevTunnelAccount -GitHub -DeviceCode
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([switch]$GitHub, [switch]$DeviceCode)
    if ($PSCmdlet.ShouldProcess('devtunnel account', 'Log in')) {
        Invoke-DevTunnelCommand -Arguments (New-DevTunnelArguments -Command user, login -Parameters $PSBoundParameters) -Stream -Sensitive
    }
}

function Disconnect-DevTunnelAccount {
    <#
    .SYNOPSIS
        Clear the credentials cached by the devtunnel CLI.
    .EXAMPLE
        Disconnect-DevTunnelAccount
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if ($PSCmdlet.ShouldProcess('devtunnel account', 'Log out')) {
        Invoke-DevTunnelCommand -Arguments @('user', 'logout', '--json') -Sensitive
    }
}

function Get-DevTunnelAccount {
    <#
    .SYNOPSIS
        Get the current CLI login status as a JSON-derived object.
    .EXAMPLE
        Get-DevTunnelAccount
    #>
    [CmdletBinding()]
    param()
    Invoke-DevTunnelCommand -Arguments @('user', 'show', '--json') -Sensitive
}
