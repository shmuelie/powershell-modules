# https://github.com/coreybutler/nvm-windows

function Get-NodeVersion {
    <#
    .SYNOPSIS
        Lists installed Node.js versions or shows current version
    .DESCRIPTION
        Wrapper for 'nvm list' and 'nvm current' commands
    .PARAMETER Current
        If specified, shows only the currently active Node.js version
    .PARAMETER Available
        If specified, shows available Node.js versions for download
    .EXAMPLE
        Get-NodeVersion
        Lists all installed Node.js versions
    .EXAMPLE
        Get-NodeVersion -Current
        Shows the currently active Node.js version
    .EXAMPLE
        Get-NodeVersion -Available
        Lists available Node.js versions for download
    #>
    [CmdletBinding(DefaultParameterSetName = 'List')]
    param(
        [Parameter(ParameterSetName = 'Current')]
        [switch]$Current,
        
        [Parameter(ParameterSetName = 'Available')]
        [switch]$Available
    )
    
    if ($Current) {
        nvm current
    }
    elseif ($Available) {
        nvm list available
    }
    else {
        nvm list
    }
}

function Install-NodeVersion {
    <#
    .SYNOPSIS
        Installs a specific Node.js version
    .DESCRIPTION
        Wrapper for 'nvm install' command
    .PARAMETER Version
        The Node.js version to install (e.g., '18.17.0', 'latest', 'lts')
    .PARAMETER Architecture
        The architecture to install (32 or 64 bit). Defaults to system architecture
    .EXAMPLE
        Install-NodeVersion -Version 18.17.0
        Installs Node.js version 18.17.0
    .EXAMPLE
        Install-NodeVersion -Version latest
        Installs the latest Node.js version
    .EXAMPLE
        Install-NodeVersion -Version lts -Architecture 64
        Installs the latest LTS version for 64-bit
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Version,
        
        [Parameter()]
        [ValidateSet('32', '64')]
        [string]$Architecture
    )
    
    $arguments = @('install', $Version)
    if ($Architecture) {
        $arguments += $Architecture
    }
    
    if ($PSCmdlet.ShouldProcess("Node.js version $Version", 'Install')) {
        & nvm @arguments
    }
}

function Uninstall-NodeVersion {
    <#
    .SYNOPSIS
        Uninstalls a specific Node.js version
    .DESCRIPTION
        Wrapper for 'nvm uninstall' command
    .PARAMETER Version
        The Node.js version to uninstall
    .EXAMPLE
        Uninstall-NodeVersion -Version 14.17.0
        Uninstalls Node.js version 14.17.0
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Version
    )
    
    if ($PSCmdlet.ShouldProcess("Node.js version $Version", "Uninstall")) {
        nvm uninstall $Version
    }
}

function Set-NodeVersion {
    <#
    .SYNOPSIS
        Switches to a specific Node.js version
    .DESCRIPTION
        Wrapper for 'nvm use' command
    .PARAMETER Version
        The Node.js version to use
    .PARAMETER Architecture
        The architecture to use (32 or 64 bit)
    .PARAMETER Latest
        Switch to the newest available Node.js version.
    .EXAMPLE
        Set-NodeVersion -Version 18.17.0
        Switches to Node.js version 18.17.0
    .EXAMPLE
        Set-NodeVersion -Version 16.20.1 -Architecture 64
        Switches to Node.js version 16.20.1 64-bit
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'ExplicitVersion')]
        [string]$Version,
        
        [Parameter(ParameterSetName = 'ExplicitVersion')]
        [ValidateSet('32', '64')]
        [string]$Architecture,

        [Parameter(ParameterSetName = 'LatestVersion')]
        [switch]$Latest
    )

    if ($Latest) {
        $Version = 'newest'
    }
    
    $arguments = @('use', $Version)
    if ($Architecture) {
        $arguments += $Architecture
    }
    
    if ($PSCmdlet.ShouldProcess("Node.js version $Version", 'Use')) {
        & nvm @arguments
    }
}

function Set-NodeAlias {
    <#
    .SYNOPSIS
        Sets an alias for a Node.js version
    .DESCRIPTION
        Wrapper for 'nvm alias' command
    .PARAMETER Name
        The alias name
    .PARAMETER Version
        The Node.js version to alias
    .EXAMPLE
        Set-NodeAlias -Name default -Version 18.17.0
        Creates an alias 'default' for Node.js version 18.17.0
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        
        [Parameter(Mandatory = $true)]
        [string]$Version
    )
    
    if ($PSCmdlet.ShouldProcess("Alias '$Name' -> $Version", 'Set')) {
        nvm alias $Name $Version
    }
}

function Remove-NodeAlias {
    <#
    .SYNOPSIS
        Removes an alias for a Node.js version
    .DESCRIPTION
        Wrapper for 'nvm unalias' command
    .PARAMETER Name
        The alias name to remove
    .EXAMPLE
        Remove-NodeAlias -Name default
        Removes the 'default' alias
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )
    
    if ($PSCmdlet.ShouldProcess("Alias '$Name'", "Remove")) {
        nvm unalias $Name
    }
}

function Enable-Nvm {
    <#
    .SYNOPSIS
        Enables nvm management
    .DESCRIPTION
        Wrapper for 'nvm on' command
    .EXAMPLE
        Enable-Nvm
        Enables nvm to manage Node.js versions
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    
    if ($PSCmdlet.ShouldProcess('nvm', 'Enable')) {
        nvm on
    }
}

function Disable-Nvm {
    <#
    .SYNOPSIS
        Disables nvm management
    .DESCRIPTION
        Wrapper for 'nvm off' command
    .EXAMPLE
        Disable-Nvm
        Disables nvm version management
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    
    if ($PSCmdlet.ShouldProcess('nvm', 'Disable')) {
        nvm off
    }
}

function Set-NvmProxy {
    <#
    .SYNOPSIS
        Sets proxy for nvm downloads
    .DESCRIPTION
        Wrapper for 'nvm proxy' command
    .PARAMETER Url
        The proxy URL. If not specified, shows current proxy setting
    .EXAMPLE
        Set-NvmProxy -Url "http://proxy.example.com:8080"
        Sets the proxy URL
    .EXAMPLE
        Set-NvmProxy
        Shows the current proxy setting
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter()]
        [string]$Url
    )
    
    if ($Url) {
        if ($PSCmdlet.ShouldProcess('nvm proxy', "Set to '$Url'")) {
            nvm proxy $Url
        }
    }
    else {
        nvm proxy
    }
}

function Set-NvmNodeMirror {
    <#
    .SYNOPSIS
        Sets the Node.js download mirror
    .DESCRIPTION
        Wrapper for 'nvm node_mirror' command
    .PARAMETER Url
        The mirror URL. If not specified, shows current mirror
    .EXAMPLE
        Set-NvmNodeMirror -Url "https://nodejs.org/dist/"
        Sets the Node.js download mirror
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter()]
        [string]$Url
    )
    
    if ($Url) {
        if ($PSCmdlet.ShouldProcess('nvm node_mirror', "Set to '$Url'")) {
            nvm node_mirror $Url
        }
    }
    else {
        nvm node_mirror
    }
}

function Set-NvmNpmMirror {
    <#
    .SYNOPSIS
        Sets the npm download mirror
    .DESCRIPTION
        Wrapper for 'nvm npm_mirror' command
    .PARAMETER Url
        The mirror URL. If not specified, shows current mirror
    .EXAMPLE
        Set-NvmNpmMirror -Url "https://github.com/npm/cli/archive/"
        Sets the npm download mirror
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter()]
        [string]$Url
    )
    
    if ($Url) {
        if ($PSCmdlet.ShouldProcess('nvm npm_mirror', "Set to '$Url'")) {
            nvm npm_mirror $Url
        }
    }
    else {
        nvm npm_mirror
    }
}

function Get-NvmRoot {
    <#
    .SYNOPSIS
        Shows the nvm installation root directory
    .DESCRIPTION
        Wrapper for 'nvm root' command
    .PARAMETER Path
        If specified, sets a new root directory
    .EXAMPLE
        Get-NvmRoot
        Shows the current nvm root directory
    .EXAMPLE
        Get-NvmRoot -Path "C:\nvm"
        Sets a new nvm root directory
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter()]
        [string]$Path
    )
    
    if ($Path) {
        if ($PSCmdlet.ShouldProcess('nvm root', "Set to '$Path'")) {
            nvm root $Path
        }
    }
    else {
        nvm root
    }
}

function Get-NvmVersion {
    <#
    .SYNOPSIS
        Shows the nvm version
    .DESCRIPTION
        Wrapper for 'nvm version' command
    .EXAMPLE
        Get-NvmVersion
        Shows the current nvm for Windows version
    #>
    [CmdletBinding()]
    param()
    
    nvm version
}

function Test-NvmInstalled {
    <#
    .SYNOPSIS
        Tests if nvm is installed and available
    .DESCRIPTION
        Checks if nvm command is available in the system
    .EXAMPLE
        Test-NvmInstalled
        Returns $true if nvm is installed, $false otherwise
    #>
    [CmdletBinding()]
    param()
    
    try {
        $null = Get-Command nvm -ErrorAction Stop
        return $true
    }
    catch {
        Write-Warning "nvm is not installed or not in PATH. Install from: https://github.com/coreybutler/nvm-windows"
        return $false
    }
}