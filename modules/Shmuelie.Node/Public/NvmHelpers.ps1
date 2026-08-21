# https://github.com/coreybutler/nvm-windows

function Get-NodeVersion {
    <#
    .SYNOPSIS
        Lists installed Node.js versions or shows current version on Windows with nvm-windows
    .DESCRIPTION
        Windows-only wrapper for 'nvm list' and 'nvm current' commands provided by nvm-windows
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
    

    Assert-WindowsOnly -CommandName $MyInvocation.MyCommand.Name
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
        Installs a specific Node.js version on Windows with nvm-windows
    .DESCRIPTION
        Windows-only wrapper for 'nvm install' command provided by nvm-windows
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
    

    Assert-WindowsOnly -CommandName $MyInvocation.MyCommand.Name
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
        Uninstalls a specific Node.js version on Windows with nvm-windows
    .DESCRIPTION
        Windows-only wrapper for 'nvm uninstall' command provided by nvm-windows
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
    

    Assert-WindowsOnly -CommandName $MyInvocation.MyCommand.Name
    if ($PSCmdlet.ShouldProcess("Node.js version $Version", "Uninstall")) {
        nvm uninstall $Version
    }
}

function Set-NodeVersion {
    <#
    .SYNOPSIS
        Switches to a specific Node.js version on Windows with nvm-windows
    .DESCRIPTION
        Windows-only wrapper for 'nvm use' command provided by nvm-windows
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


    Assert-WindowsOnly -CommandName $MyInvocation.MyCommand.Name
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
        Sets an alias for a Node.js version on Windows with nvm-windows
    .DESCRIPTION
        Windows-only wrapper for 'nvm alias' command provided by nvm-windows
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
    

    Assert-WindowsOnly -CommandName $MyInvocation.MyCommand.Name
    if ($PSCmdlet.ShouldProcess("Alias '$Name' -> $Version", 'Set')) {
        nvm alias $Name $Version
    }
}

function Remove-NodeAlias {
    <#
    .SYNOPSIS
        Removes an alias for a Node.js version on Windows with nvm-windows
    .DESCRIPTION
        Windows-only wrapper for 'nvm unalias' command provided by nvm-windows
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
    

    Assert-WindowsOnly -CommandName $MyInvocation.MyCommand.Name
    if ($PSCmdlet.ShouldProcess("Alias '$Name'", "Remove")) {
        nvm unalias $Name
    }
}

function Enable-Nvm {
    <#
    .SYNOPSIS
        Enables nvm-windows management
    .DESCRIPTION
        Windows-only wrapper for 'nvm on' command provided by nvm-windows
    .EXAMPLE
        Enable-Nvm
        Enables nvm to manage Node.js versions
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    

    Assert-WindowsOnly -CommandName $MyInvocation.MyCommand.Name
    if ($PSCmdlet.ShouldProcess('nvm', 'Enable')) {
        nvm on
    }
}

function Disable-Nvm {
    <#
    .SYNOPSIS
        Disables nvm-windows management
    .DESCRIPTION
        Windows-only wrapper for 'nvm off' command provided by nvm-windows
    .EXAMPLE
        Disable-Nvm
        Disables nvm version management
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    

    Assert-WindowsOnly -CommandName $MyInvocation.MyCommand.Name
    if ($PSCmdlet.ShouldProcess('nvm', 'Disable')) {
        nvm off
    }
}

function Set-NvmProxy {
    <#
    .SYNOPSIS
        Sets proxy for nvm-windows downloads
    .DESCRIPTION
        Windows-only wrapper for 'nvm proxy' command provided by nvm-windows
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
    

    Assert-WindowsOnly -CommandName $MyInvocation.MyCommand.Name
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
        Sets the Node.js download mirror for nvm-windows
    .DESCRIPTION
        Windows-only wrapper for 'nvm node_mirror' command provided by nvm-windows
    .PARAMETER Url
        The mirror URL. If not specified, shows current mirror
    .EXAMPLE
        Set-NvmNodeMirror -Url "https://nodejs.org/dist/"
        Sets the Node.js download mirror for nvm-windows
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter()]
        [string]$Url
    )
    

    Assert-WindowsOnly -CommandName $MyInvocation.MyCommand.Name
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
        Sets the npm download mirror for nvm-windows
    .DESCRIPTION
        Windows-only wrapper for 'nvm npm_mirror' command provided by nvm-windows
    .PARAMETER Url
        The mirror URL. If not specified, shows current mirror
    .EXAMPLE
        Set-NvmNpmMirror -Url "https://github.com/npm/cli/archive/"
        Sets the npm download mirror for nvm-windows
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter()]
        [string]$Url
    )
    

    Assert-WindowsOnly -CommandName $MyInvocation.MyCommand.Name
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
        Shows the nvm-windows installation root directory
    .DESCRIPTION
        Windows-only wrapper for 'nvm root' command provided by nvm-windows
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
    

    Assert-WindowsOnly -CommandName $MyInvocation.MyCommand.Name
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
        Shows the nvm-windows version
    .DESCRIPTION
        Windows-only wrapper for 'nvm version' command provided by nvm-windows
    .EXAMPLE
        Get-NvmVersion
        Shows the current nvm for Windows version
    #>
    [CmdletBinding()]
    param()
    

    Assert-WindowsOnly -CommandName $MyInvocation.MyCommand.Name
    nvm version
}

function Test-NvmInstalled {
    <#
    .SYNOPSIS
        Tests if nvm-windows is installed and available
    .DESCRIPTION
        Windows-only check for the nvm-windows command in the system
    .EXAMPLE
        Test-NvmInstalled
        Returns $true if nvm is installed, $false otherwise
    #>
    [CmdletBinding()]
    param()
    

    Assert-WindowsOnly -CommandName $MyInvocation.MyCommand.Name
    try {
        $null = Get-Command nvm -ErrorAction Stop
        return $true
    }
    catch {
        Write-Warning "nvm is not installed or not in PATH. Install from: https://github.com/coreybutler/nvm-windows"
        return $false
    }
}