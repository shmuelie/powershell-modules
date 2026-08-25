function Invoke-VsWhere {
    [CmdletBinding()]
    param()

    $programFilesX86 = ${env:ProgramFiles(x86)}
    if (-not $programFilesX86) {
        $programFilesX86 = [Environment]::GetFolderPath('ProgramFilesX86')
    }
    if (-not $programFilesX86) { return @() }

    $vsWhere = Join-Path $programFilesX86 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vsWhere)) { return @() }

    $json = & $vsWhere -all -format json -utf8 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $json) { return @() }

    $parsed = $json | ConvertFrom-Json -ErrorAction SilentlyContinue
    if ($null -eq $parsed) { return @() }
    return @($parsed)
}

function ConvertTo-VsYear {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$InstallationVersion
    )

    $majorText = ($InstallationVersion -split '\.')[0]
    $major = 0
    if (-not [int]::TryParse($majorText, [ref]$major)) { return $null }

    switch ($major) {
        15 { 2017 }
        16 { 2019 }
        17 { 2022 }
        18 { 2026 }
        default { $null }
    }
}

function Get-InstalledVsVersion {
    <#
    .SYNOPSIS
        Lists installed Visual Studio years that can be loaded in PowerShell.

    .DESCRIPTION
        Uses vswhere.exe to enumerate Visual Studio instances, maps each
        instance's installationVersion major number to a Visual Studio year, and
        returns only years that also have a matching Set-VS<year> command
        available. This makes the output suitable for Start-DevShell tab
        completion.

        The catalog_productLineVersion field is intentionally ignored because it
        can be inconsistent across Visual Studio products.

    .EXAMPLE
        Get-InstalledVsVersion
        Returns years such as 2022 or 2026 when both Visual Studio and the
        matching Set-VS<year> command are available.
    #>
    [OutputType([int])]
    [CmdletBinding()]
    param()

    Assert-WindowsOnly -CommandName $MyInvocation.MyCommand.Name

    $instances = @(Invoke-VsWhere)
    if ($instances.Count -eq 0) { return }

    $years = foreach ($instance in $instances) {
        if ($instance.installationVersion) {
            ConvertTo-VsYear -InstallationVersion ([string]$instance.installationVersion)
        }
    }

    $years |
        Where-Object { $null -ne $_ -and (Get-Command "Set-VS$_" -ErrorAction SilentlyContinue) } |
        Sort-Object -Unique
}
