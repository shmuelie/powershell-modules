<#
.SYNOPSIS
    Enforce the repository publication catalog and Windows experimental boundary.
.DESCRIPTION
    Build eligibility is not release eligibility. Experimental modules can be
    built explicitly but cannot be published through repository entry points.
    Inspect a supplied artifact before any publish call; do not import it.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Module,
    [string]$Path
)

$ErrorActionPreference = 'Stop'
$publishedModules = @(
    'Shmuelie.Git', 'Shmuelie.Copilot', 'Shmuelie.Node', 'Shmuelie.DotNet',
    'Shmuelie.Utilities', 'Shmuelie.Dsc', 'Shmuelie.VisualStudio',
    'Shmuelie.Windows', 'Shmuelie.PackageManagement'
)
if ($Module -notin $publishedModules) {
    throw "Module '$Module' is not publishable. Experimental AppInstallManager development remains on hold."
}
if (-not $PSBoundParameters.ContainsKey('Path')) { return }

$manifest = Import-PowerShellDataFile -LiteralPath (Join-Path $Path "$Module.psd1")
if ($manifest.PrivateData -and $manifest.PrivateData.ContainsKey('Publishable') -and
    $manifest.PrivateData.Publishable -eq $false) {
    throw "Module '$Module' explicitly prohibits publication."
}
if ($Module -ne 'Shmuelie.Windows') { return }

$heldCommands = @(
    'New-AppInstallContext', 'Get-AppInstallItem', 'Get-AppInstallSettings',
    'Request-AppInstallUpdateSearch', 'Wait-AppInstallItem'
)
foreach ($command in @($manifest.CmdletsToExport) + @($manifest.FunctionsToExport)) {
    if ($command -in $heldCommands -or [System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($command)) {
        throw "Windows cannot publish experimental or wildcard export '$command'."
    }
}
foreach ($item in Get-ChildItem -LiteralPath $Path -Recurse -Force) {
    if ($item.Name -match '(?i)(^|\.)AppInstall(\.|$)') {
        throw "Windows artifact contains experimental AppInstall content: '$($item.Name)'."
    }
    if (-not $item.PSIsContainer -and $item.Extension -in '.psm1', '.ps1', '.ps1xml') {
        $content = Get-Content -LiteralPath $item.FullName -Raw
        if ($content -match 'Shmuelie\.Windows\.AppInstall\b|AppInstallManager' -or
            @($heldCommands | Where-Object { $content -match [regex]::Escape($_) }).Count -gt 0) {
            throw "Windows runtime asset references experimental AppInstall behavior: '$($item.Name)'."
        }
    }
}
