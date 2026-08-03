# Shared helper for Copilot CLI and Agency cmdlets.
#
# Only Resolve-CliExe is shared now. The plugin/marketplace operations are no
# longer shared: Agency uses the native `agency plugin ...` / `agency marketplace
# add` commands (with their own flags) inline in AgencyPlugins.ps1 /
# AgencyMarketplaces.ps1, and the Copilot cmdlets own their `copilot plugin ...`
# calls inline in Plugins.ps1 / Marketplaces.ps1.

function Resolve-CliExe {
    <#
    .SYNOPSIS
        Resolve the path to copilot.exe or agency.exe.
    .PARAMETER Name
        Which executable to resolve: 'copilot' or 'agency'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('copilot', 'agency')]
        [string]$Name
    )
    (Get-Command $Name -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
}
