function Get-DotNetTool {
    <#
    .SYNOPSIS
        List installed .NET tools.
    .DESCRIPTION
        Parses the output of 'dotnet tool list' into typed DotNetTool objects.
        By default lists globally installed tools. Use -Local for local manifest tools.
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
    $scope = if ($Local) { '--local' } else { '-g' }
    Invoke-InLocation -Location ~ -ScriptBlock {
        dotnet tool list $scope 2>$null | Select-Object -Skip 2 | ForEach-Object {
            $parts = $_ -split '\s{2,}'
            if ($parts.Count -ge 3) {
                $tool = [PSCustomObject]@{
                    PSTypeName = 'DotNetTool'
                    PackageId  = $parts[0].Trim()
                    Version    = $parts[1].Trim()
                    Commands   = $parts[2].Trim()
                    Global     = -not $Local
                }
                if ($tool.PackageId -like $Name) { $tool }
            }
        }
    }
}

function Update-DotNetTool {
    <#
    .SYNOPSIS
        Update one or more .NET tools to the latest version.
    .DESCRIPTION
        Wraps 'dotnet tool update' for global or local tools. Accepts pipeline
        input from Get-DotNetTool. Returns typed result objects.
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
    process {
        $toolName = if ($PSCmdlet.ParameterSetName -eq 'ByName') { $Name } else { $InputObject.PackageId }
        $isGlobal = if ($PSCmdlet.ParameterSetName -eq 'ByName') { -not $Local } else { $InputObject.Global }
        $scope = if ($isGlobal) { '-g' } else { '--local' }

        if ($PSCmdlet.ShouldProcess($toolName, 'dotnet tool update')) {
            Write-Verbose "Updating $toolName"
            $previousVersion = if ($PSCmdlet.ParameterSetName -eq 'ByObject') { $InputObject.Version } else { $null }
            $output = dotnet tool update $toolName $scope 2>&1
            $output | ForEach-Object { Write-Verbose $_ }
            $outputText = $output -join "`n"

            # Parse the new version from output
            $newVersion = if ($outputText -match "version '([^']+)'\.\s*$") { $Matches[1] }
                          elseif ($outputText -match "version '([^']+)' to version '([^']+)'") { $Matches[2] }
                          else { $null }
            $updated = $outputText -match 'was successfully updated from version'

            [PSCustomObject]@{
                PSTypeName = 'DotNetToolUpdateResult'
                PackageId  = $toolName
                Version    = $newVersion
                Updated    = $updated
            }
        }
    }
}

function Install-DotNetTool {
    <#
    .SYNOPSIS
        Install a .NET global tool.
    .DESCRIPTION
        Wraps 'dotnet tool install -g'. Idempotent — skips if already installed.
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
    if ($PSCmdlet.ShouldProcess($Name, 'dotnet tool install -g')) {
        $existing = Get-DotNetTool -Name $Name
        if ($existing) {
            Write-Verbose "Tool '$Name' is already installed (v$($existing.Version))."
            return
        }
        dotnet tool install -g $Name 2>&1 | ForEach-Object { Write-Verbose $_ }
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to install tool: $Name"
        }
    }
}

function Uninstall-DotNetTool {
    <#
    .SYNOPSIS
        Uninstall a .NET global tool.
    .DESCRIPTION
        Wraps 'dotnet tool uninstall -g'. Accepts pipeline input from Get-DotNetTool.
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
    process {
        $toolName = if ($PSCmdlet.ParameterSetName -eq 'ByName') { $Name } else { $InputObject.PackageId }
        if ($PSCmdlet.ShouldProcess($toolName, 'dotnet tool uninstall -g')) {
            dotnet tool uninstall -g $toolName 2>&1 | ForEach-Object { Write-Verbose $_ }
            if ($LASTEXITCODE -ne 0) {
                Write-Error "Failed to uninstall tool: $toolName"
            }
        }
    }
}

