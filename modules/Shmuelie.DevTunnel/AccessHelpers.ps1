function Get-DevTunnelAccess {
    <#
    .SYNOPSIS
        Get access control entries for a tunnel or port.
    .EXAMPLE
        Get-DevTunnelAccess -TunnelId my-tunnel
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipelineByPropertyName)][Alias('Id')]
        [ValidatePattern('\A[a-zA-Z0-9][a-zA-Z0-9.-]*\z')][string]$TunnelId,
        [ValidateRange(1, 65535)][int]$PortNumber
    )
    process {
        Invoke-DevTunnelCommand -Arguments (New-DevTunnelArguments -Command access, list -Parameters $PSBoundParameters -Json)
    }
}

function Add-DevTunnelAccess {
    <#
    .SYNOPSIS
        Add an explicit anonymous, tenant, organization, or repository access rule.
    .DESCRIPTION
        Exactly one access subject is required. Anonymous access is never implicit.
        Deny changes the selected rule from allow to deny.
    .EXAMPLE
        Add-DevTunnelAccess -TunnelId my-tunnel -Organization example -Scope connect
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Anonymous')]
    param(
        [Parameter(ValueFromPipelineByPropertyName)][Alias('Id')]
        [ValidatePattern('\A[a-zA-Z0-9][a-zA-Z0-9.-]*\z')][string]$TunnelId,
        [ValidateRange(1, 65535)][int]$PortNumber,
        [Parameter(Mandatory, ParameterSetName = 'Anonymous')][switch]$Anonymous,
        [Parameter(Mandatory, ParameterSetName = 'Tenant')][switch]$Tenant,
        [Parameter(Mandatory, ParameterSetName = 'Organization')][ValidateNotNullOrEmpty()][string]$Organization,
        [Parameter(Mandatory, ParameterSetName = 'Repository')][ValidateNotNullOrEmpty()][string]$Repository,
        [switch]$Deny,
        [ValidateSet('create', 'manage', 'manage:ports', 'host', 'inspect', 'connect')][string[]]$Scope,
        [ValidateScript({ Test-DevTunnelExpiration $_ })][string]$Expiration,
        [ValidateRange(0, [int]::MaxValue)][int]$Index
    )
    process {
        if (($PSCmdlet.ParameterSetName -eq 'Anonymous' -and -not $Anonymous) -or
            ($PSCmdlet.ParameterSetName -eq 'Tenant' -and -not $Tenant)) {
            throw 'The selected access subject must be explicitly enabled.'
        }
        if ($PSCmdlet.ShouldProcess("$TunnelId access (omitted ID uses last-used tunnel)", 'Add access rule')) {
            if ($Anonymous -and -not $Deny) { Write-DevTunnelAnonymousWarning }
            Invoke-DevTunnelCommand -Arguments (New-DevTunnelArguments -Command access, create -Parameters $PSBoundParameters -Json)
        }
    }
}

function Remove-DevTunnelAccess {
    <#
    .SYNOPSIS
        Delete an access control entry by its zero-based index.
    .EXAMPLE
        Remove-DevTunnelAccess -TunnelId my-tunnel -Index 0
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(ValueFromPipelineByPropertyName)][Alias('Id')]
        [ValidatePattern('\A[a-zA-Z0-9][a-zA-Z0-9.-]*\z')][string]$TunnelId,
        [ValidateRange(1, 65535)][int]$PortNumber,
        [Parameter(Mandatory)][ValidateRange(0, [int]::MaxValue)][int]$Index
    )
    process {
        if ($PSCmdlet.ShouldProcess("$TunnelId access rule $Index (omitted ID uses last-used tunnel)", 'Delete access rule')) {
            Invoke-DevTunnelCommand -Arguments (New-DevTunnelArguments -Command access, delete -Parameters $PSBoundParameters -Json)
        }
    }
}

function Reset-DevTunnelAccess {
    <#
    .SYNOPSIS
        Reset a tunnel or port to the CLI's default access controls.
    .EXAMPLE
        Reset-DevTunnelAccess -TunnelId my-tunnel -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(ValueFromPipelineByPropertyName)][Alias('Id')]
        [ValidatePattern('\A[a-zA-Z0-9][a-zA-Z0-9.-]*\z')][string]$TunnelId,
        [ValidateRange(1, 65535)][int]$PortNumber
    )
    process {
        if ($PSCmdlet.ShouldProcess("$TunnelId access (omitted ID uses last-used tunnel)", 'Reset access rules')) {
            Invoke-DevTunnelCommand -Arguments (New-DevTunnelArguments -Command access, reset -Parameters $PSBoundParameters -Json)
        }
    }
}

function New-DevTunnelToken {
    <#
    .SYNOPSIS
        Issue an access token for explicitly selected scopes.
    .DESCRIPTION
        The returned CLI JSON object contains a secret. Do not log or publish it.
        This module does not cache tokens or accept tokens on the command line.
    .EXAMPLE
        $token = New-DevTunnelToken -TunnelId my-tunnel -Scope connect
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(ValueFromPipelineByPropertyName)][Alias('Id')]
        [ValidatePattern('\A[a-zA-Z0-9][a-zA-Z0-9.-]*\z')][string]$TunnelId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()]
        [ValidateSet('create', 'manage', 'manage:ports', 'host', 'inspect', 'connect')][string[]]$Scope
    )
    process {
        if ($PSCmdlet.ShouldProcess($(if ($TunnelId) { $TunnelId } else { 'last-used tunnel' }), 'Issue access token')) {
            Invoke-DevTunnelCommand -Arguments (New-DevTunnelArguments -Command token -Parameters $PSBoundParameters -Json) -Sensitive
        }
    }
}
