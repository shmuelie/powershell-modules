function Resolve-DotNetToolCommand {
    param([string]$Name)

    # Source imports use the sibling checkout; installed modules use normal discovery.
    $siblingManifest = Join-Path (Split-Path $PSScriptRoot -Parent) 'Shmuelie.DotNet' 'Shmuelie.DotNet.psd1'
    if (Test-Path -LiteralPath $siblingManifest -PathType Leaf) {
        $module = Import-Module $siblingManifest -Scope Local -PassThru -ErrorAction Stop -Verbose:$false
    } else {
        $module = Get-Module -Name Shmuelie.DotNet | Select-Object -First 1
        if (-not $module) {
            if (-not (Get-Module -ListAvailable -Name Shmuelie.DotNet)) {
                throw "The Utilities .NET tool compatibility commands require Shmuelie.DotNet. Run 'Install-PSResource Shmuelie.DotNet' explicitly, or add its installed module directory to PSModulePath, then retry. Use Shmuelie.DotNet\$Name in new scripts; Utilities wrappers will be removed in Utilities 1.0."
            }
            $module = Import-Module Shmuelie.DotNet -Scope Local -PassThru -ErrorAction Stop -Verbose:$false
        }
    }

    # Export keys can include an import prefix; CommandInfo retains the original name.
    $command = $module.ExportedCommands.Values | Where-Object Name -EQ $Name | Select-Object -First 1
    if (-not $command) {
        throw "Shmuelie.DotNet does not export '$Name'. Reinstall or update Shmuelie.DotNet explicitly, then retry in a new PowerShell session."
    }
    $command
}

function Get-DotNetTool {
    <#
    .SYNOPSIS
        List installed .NET tools.
    .DESCRIPTION
        Parses the output of 'dotnet tool list' into typed DotNetTool objects.
        By default lists globally installed tools. Use -Local for local manifest tools.
        Compatibility wrapper for Shmuelie.DotNet\Get-DotNetTool, retained until
        Utilities 1.0. Install the dependency explicitly with
        'Install-PSResource Shmuelie.DotNet'; use Shmuelie.DotNet in new scripts.
        The dependency loads only when a .NET tool wrapper is called.
    .PARAMETER Name
        Filter by package ID. Supports wildcards.
    .PARAMETER Local
        List tools from the local tool manifest instead of global.
    .EXAMPLE
        Get-DotNetTool
        Lists all globally installed .NET tools.
    .EXAMPLE
        Get-DotNetTool -Name dotnet-ef*
        Lists global tools matching the filter.
    .EXAMPLE
        Get-DotNetTool -Local
        Lists tools from the local tool manifest.
    #>
    [OutputType('DotNetTool')]
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Name = '*',

        [switch]$Local
    )
    begin {
        $command = Resolve-DotNetToolCommand -Name 'Get-DotNetTool'
        # Capture variables belong to the outer command in the caller's scope.
        foreach ($parameter in 'PipelineVariable', 'OutVariable', 'ErrorVariable', 'WarningVariable', 'InformationVariable') {
            $null = $PSBoundParameters.Remove($parameter)
        }
        $pipeline = { & $command @PSBoundParameters }.GetSteppablePipeline($MyInvocation.CommandOrigin)
        $pipeline.Begin($PSCmdlet)
    }
    process { $pipeline.Process($_) }
    end { $pipeline.End() }
    clean {
        if ($null -ne $pipeline) { $pipeline.Clean() }
    }
}

function Update-DotNetTool {
    <#
    .SYNOPSIS
        Update one or more .NET tools to the latest version.
    .DESCRIPTION
        Wraps 'dotnet tool update' for global or local tools. Accepts pipeline
        input from Get-DotNetTool. Returns typed result objects.
        Compatibility wrapper for Shmuelie.DotNet\Update-DotNetTool, retained
        until Utilities 1.0. Install the dependency explicitly with
        'Install-PSResource Shmuelie.DotNet'; use Shmuelie.DotNet in new scripts.
        The dependency loads only when a .NET tool wrapper is called.
    .PARAMETER InputObject
        A DotNetTool object from Get-DotNetTool.
    .PARAMETER Name
        The package ID to update.
    .PARAMETER Local
        Update a local tool instead of global.
    .EXAMPLE
        Get-DotNetTool | Update-DotNetTool
        Updates all globally installed .NET tools.
    .EXAMPLE
        Update-DotNetTool -Name dotnet-ef
        Updates a specific tool by name.
    #>
    [OutputType('DotNetToolUpdateResult')]
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'ByObject')]
    param(
        [Parameter(ParameterSetName = 'ByObject', ValueFromPipeline, Mandatory)]
        [PSObject]$InputObject,

        [Parameter(ParameterSetName = 'ByName', Position = 0, Mandatory)]
        [string]$Name,

        [Parameter(ParameterSetName = 'ByName')]
        [switch]$Local
    )
    begin {
        $command = Resolve-DotNetToolCommand -Name 'Update-DotNetTool'
        foreach ($parameter in 'PipelineVariable', 'OutVariable', 'ErrorVariable', 'WarningVariable', 'InformationVariable') {
            $null = $PSBoundParameters.Remove($parameter)
        }
        # One canonical pipeline retains per-record binding and confirmation state.
        $pipeline = { & $command @PSBoundParameters }.GetSteppablePipeline($MyInvocation.CommandOrigin)
        $pipeline.Begin($PSCmdlet)
    }
    process { $pipeline.Process($_) }
    end { $pipeline.End() }
    clean {
        if ($null -ne $pipeline) { $pipeline.Clean() }
    }
}

function Install-DotNetTool {
    <#
    .SYNOPSIS
        Install a .NET global tool.
    .DESCRIPTION
        Wraps 'dotnet tool install -g'. Idempotent — skips if already installed.
        Compatibility wrapper for Shmuelie.DotNet\Install-DotNetTool, retained
        until Utilities 1.0. Install the dependency explicitly with
        'Install-PSResource Shmuelie.DotNet'; use Shmuelie.DotNet in new scripts.
        The dependency loads only when a .NET tool wrapper is called.
    .PARAMETER Name
        The package ID to install.
    .EXAMPLE
        Install-DotNetTool -Name dotnet-ef
        Installs dotnet-ef globally.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Position = 0, Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name
    )
    begin {
        $command = Resolve-DotNetToolCommand -Name 'Install-DotNetTool'
        foreach ($parameter in 'PipelineVariable', 'OutVariable', 'ErrorVariable', 'WarningVariable', 'InformationVariable') {
            $null = $PSBoundParameters.Remove($parameter)
        }
        $pipeline = { & $command @PSBoundParameters }.GetSteppablePipeline($MyInvocation.CommandOrigin)
        $pipeline.Begin($PSCmdlet)
    }
    process { $pipeline.Process($_) }
    end { $pipeline.End() }
    clean {
        if ($null -ne $pipeline) { $pipeline.Clean() }
    }
}

function Uninstall-DotNetTool {
    <#
    .SYNOPSIS
        Uninstall a .NET global tool.
    .DESCRIPTION
        Wraps 'dotnet tool uninstall -g'. Accepts pipeline input from Get-DotNetTool.
        Compatibility wrapper for Shmuelie.DotNet\Uninstall-DotNetTool, retained
        until Utilities 1.0. Install the dependency explicitly with
        'Install-PSResource Shmuelie.DotNet'; use Shmuelie.DotNet in new scripts.
        The dependency loads only when a .NET tool wrapper is called.
    .PARAMETER InputObject
        A DotNetTool object from Get-DotNetTool.
    .PARAMETER Name
        The package ID to uninstall.
    .EXAMPLE
        Uninstall-DotNetTool -Name dotnet-ef
        Uninstalls dotnet-ef globally.
    .EXAMPLE
        Get-DotNetTool old-tool | Uninstall-DotNetTool
        Uninstalls via pipeline.
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'ByObject')]
    param(
        [Parameter(ParameterSetName = 'ByObject', ValueFromPipeline, Mandatory)]
        [PSObject]$InputObject,

        [Parameter(ParameterSetName = 'ByName', Position = 0, Mandatory)]
        [string]$Name
    )
    begin {
        $command = Resolve-DotNetToolCommand -Name 'Uninstall-DotNetTool'
        foreach ($parameter in 'PipelineVariable', 'OutVariable', 'ErrorVariable', 'WarningVariable', 'InformationVariable') {
            $null = $PSBoundParameters.Remove($parameter)
        }
        $pipeline = { & $command @PSBoundParameters }.GetSteppablePipeline($MyInvocation.CommandOrigin)
        $pipeline.Begin($PSCmdlet)
    }
    process { $pipeline.Process($_) }
    end { $pipeline.End() }
    clean {
        if ($null -ne $pipeline) { $pipeline.Clean() }
    }
}
