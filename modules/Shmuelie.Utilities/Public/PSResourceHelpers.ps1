function Get-InstalledPSResourceNameInPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return
    }

    $resolvedPath = (Resolve-Path -LiteralPath $Path).ProviderPath
    Get-ChildItem -LiteralPath $resolvedPath -Directory -ErrorAction SilentlyContinue |
        ForEach-Object {
            $resourceName = $_.Name
            $resourceRoot = $_.FullName
            $directManifest = Join-Path $resourceRoot "$resourceName.psd1"

            if (Test-Path -LiteralPath $directManifest -PathType Leaf) {
                $resourceName
            }
            else {
                $versionedManifest = Get-ChildItem -LiteralPath $resourceRoot -Directory -ErrorAction SilentlyContinue |
                    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "$resourceName.psd1") -PathType Leaf } |
                    Select-Object -First 1

                if ($versionedManifest) {
                    $resourceName
                }
            }
        } |
        Sort-Object -Unique
}

function Invoke-UpdatePSResourceInPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $updatePSResource = Get-Command -Name Update-PSResource -ErrorAction Stop
    $previousModulePath = $env:PSModulePath
    try {
        $env:PSModulePath = $Path
        & $updatePSResource -Name $Name
    }
    finally {
        $env:PSModulePath = $previousModulePath
    }
}

function Update-InstalledPSResource {
    <#
    .SYNOPSIS
        Update PowerShell resources installed under a specific module path.
    .DESCRIPTION
        Finds installed module resources under the supplied path and updates each
        discovered resource by name. The update call runs with PSModulePath scoped
        to the supplied path so resources installed elsewhere are not selected.

        Missing or empty paths are treated as a no-op.
    .PARAMETER Path
        The module directory to scan for installed PowerShell resources.
    .EXAMPLE
        $modulePath = Join-Path $HOME 'PowerShellModules'
        Update-InstalledPSResource -Path $modulePath

        Updates each PowerShell module resource installed under the supplied module path.
    .EXAMPLE
        Update-InstalledPSResource -Path $env:PSModulePath.Split([IO.Path]::PathSeparator)[0] -WhatIf

        Shows which resources would be updated without changing installed modules.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    process {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            Write-Verbose "Module path '$Path' does not exist. Nothing to update."
            return
        }

        $resolvedPath = (Resolve-Path -LiteralPath $Path).ProviderPath
        $resourceNames = @(Get-InstalledPSResourceNameInPath -Path $resolvedPath)

        foreach ($resourceName in $resourceNames) {
            if ($PSCmdlet.ShouldProcess($resourceName, "Update PowerShell resource in '$resolvedPath'")) {
                Invoke-UpdatePSResourceInPath -Name $resourceName -Path $resolvedPath
            }
        }
    }
}
