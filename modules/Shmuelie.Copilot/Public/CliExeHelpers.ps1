# Shared helper for the Copilot CLI cmdlets.
#
# Resolve-CliExe is the single place that resolves the copilot executable. The
# Copilot cmdlets own their `copilot plugin ...` / `copilot plugin marketplace
# ...` calls inline in Plugins.ps1 / Marketplaces.ps1.

function Resolve-CliExe {
    <#
    .SYNOPSIS
        Resolve the path to the copilot executable.
    .PARAMETER Name
        Which executable to resolve. Currently only 'copilot' is supported.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('copilot')]
        [string]$Name
    )
    (Get-Command $Name -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
}
