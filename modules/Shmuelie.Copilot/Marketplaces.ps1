function Get-CopilotMarketplace {
    <#
    .SYNOPSIS
        List registered Copilot CLI plugin marketplaces.
    .DESCRIPTION
        Parses the output of 'copilot plugin marketplace list' into typed objects
        with Name and Repository properties. Includes both built-in and registered marketplaces.
        Native failures write a PowerShell error with the exit code and diagnostics
        and emit no marketplaces. Use -ErrorAction Stop to terminate on failure.
        A successful empty list emits no marketplaces and no error.
    .PARAMETER Name
        Filter by marketplace name. Supports wildcards.
    .EXAMPLE
        Get-CopilotMarketplace
        Lists all marketplaces.
    .EXAMPLE
        Get-CopilotMarketplace dotnet*
        Lists marketplaces matching the filter.
    #>
    [OutputType('CopilotMarketplace')]
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Name = '*'
    )
    $output = Invoke-CopilotDiscovery -Arguments 'plugin', 'marketplace', 'list'
    foreach ($line in $output) {
        if ($line -match '^\s+[◆•]\s+(\S+)\s+\((GitHub|URL):\s+(.+?)\)') {
            $mktName = $Matches[1]
            $source = $Matches[3]
            if ($mktName -like $Name) {
                [PSCustomObject]@{
                    PSTypeName = 'CopilotMarketplace'
                    Name       = $mktName
                    Repository = $source
                }
            }
        }
    }
}

function Register-CopilotMarketplace {
    <#
    .SYNOPSIS
        Register a Copilot CLI plugin marketplace.
    .DESCRIPTION
        Adds a marketplace from a GitHub repository containing a marketplace.json.
        If discovery of registered marketplaces fails, terminates without registering.
    .PARAMETER Source
        The marketplace source (owner/repo format).
    .EXAMPLE
        Register-CopilotMarketplace -Source dotnet/skills
        Registers the dotnet skills marketplace.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Position = 0, Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Source
    )
    Assert-CopilotShimArgument -Value $Source -ParameterName 'Source'

    $exe = Resolve-CliExe -Name copilot
    if ($PSCmdlet.ShouldProcess($Source, 'copilot plugin marketplace add')) {
        $existing = Get-CopilotMarketplace -ErrorAction Stop | Where-Object Repository -eq $Source
        if ($existing) {
            Write-Verbose "Marketplace '$($existing.Name)' ($Source) is already registered."
            return
        }
        & $exe plugin marketplace add $Source 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to register marketplace: $Source"
        }
    }
}

function Unregister-CopilotMarketplace {
    <#
    .SYNOPSIS
        Remove a registered Copilot CLI plugin marketplace.
    .DESCRIPTION
        Removes a marketplace by name. Accepts pipeline input from Get-CopilotMarketplace.
    .PARAMETER InputObject
        A CopilotMarketplace object from Get-CopilotMarketplace.
    .PARAMETER Name
        The marketplace name to remove.
    .EXAMPLE
        Unregister-CopilotMarketplace -Name my-marketplace
        Removes the specified marketplace.
    .EXAMPLE
        Get-CopilotMarketplace old* | Unregister-CopilotMarketplace
        Removes marketplaces matching the filter.
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'ByObject')]
    param(
        [Parameter(ParameterSetName = 'ByObject', ValueFromPipeline, Mandatory)]
        [PSObject]$InputObject,

        [Parameter(ParameterSetName = 'ByName', Position = 0, Mandatory)]
        [string]$Name
    )
    process {
        $removeName = if ($PSCmdlet.ParameterSetName -eq 'ByName') { $Name } else { $InputObject.Name }
        Assert-CopilotShimArgument -Value $removeName -ParameterName 'Name' -Pattern '^[A-Za-z0-9][A-Za-z0-9._#/-]*$'

        $exe = Resolve-CliExe -Name copilot
        if ($PSCmdlet.ShouldProcess($removeName, 'copilot plugin marketplace remove')) {
            & $exe plugin marketplace remove $removeName 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Error "Failed to remove marketplace: $removeName"
            }
        }
    }
}

function Get-CopilotMarketplacePlugin {
    <#
    .SYNOPSIS
        Browse available plugins in a Copilot CLI marketplace.
    .DESCRIPTION
        Lists all plugins available in the specified marketplace.
        Accepts pipeline input from Get-CopilotMarketplace.
        Native failures write a PowerShell error with the exit code and diagnostics
        and emit no entries for that marketplace. Use -ErrorAction Stop to terminate
        on failure. A successful empty marketplace emits no entries and no error.
    .PARAMETER InputObject
        A CopilotMarketplace object from Get-CopilotMarketplace.
    .PARAMETER Name
        The marketplace name to browse.
    .EXAMPLE
        Get-CopilotMarketplacePlugin -Name copilot-plugins
        Lists all plugins in the copilot-plugins marketplace.
    .EXAMPLE
        Get-CopilotMarketplace dotnet* | Get-CopilotMarketplacePlugin
        Browses the dotnet marketplace via pipeline.
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByName')]
    param(
        [Parameter(ParameterSetName = 'ByObject', ValueFromPipeline, Mandatory)]
        [PSObject]$InputObject,

        [Parameter(ParameterSetName = 'ByName', Position = 0, Mandatory)]
        [string]$Name
    )
    process {
        $mktName = if ($PSCmdlet.ParameterSetName -eq 'ByName') { $Name } else { $InputObject.Name }
        Assert-CopilotShimArgument -Value $mktName -ParameterName 'Name' -Pattern '^[A-Za-z0-9][A-Za-z0-9._#/-]*$'

        $output = Invoke-CopilotDiscovery -Arguments 'plugin', 'marketplace', 'browse', $mktName
        foreach ($line in $output) {
            if ($line -match '^\s+[•]\s+(\S+)\s+-\s+(.+)$') {
                [PSCustomObject]@{
                    PSTypeName  = 'CopilotMarketplaceEntry'
                    Name        = $Matches[1]
                    Description = $Matches[2].Trim()
                    Marketplace = $mktName
                }
            }
        }
    }
}