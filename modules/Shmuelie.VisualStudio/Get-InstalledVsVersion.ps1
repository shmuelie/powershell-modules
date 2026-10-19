function Invoke-VsWhere {
    [CmdletBinding()]
    param(
        [switch]$MSBuild
    )

    if ($MSBuild) {
        $installerPath = Get-VsInstallerPath
        $vsWhere = if ($installerPath) { Join-Path $installerPath 'vswhere.exe' }
        if (-not $vsWhere -or -not (Test-Path -LiteralPath $vsWhere -PathType Leaf -ErrorAction Stop)) {
            throw 'Cannot discover Visual Studio MSBuild: vswhere.exe was not found in the Visual Studio Installer directory. Install or repair Visual Studio Installer.'
        }

        $json = Invoke-MSBuildVsWhere -Path $vsWhere
        if (-not $json) {
            throw 'Cannot discover Visual Studio MSBuild: vswhere.exe returned no JSON.'
        }
        $instances = ConvertFrom-Json -InputObject ($json -join "`n") -NoEnumerate -ErrorAction Stop
        if ($instances -isnot [array]) {
            throw 'Cannot discover Visual Studio MSBuild: vswhere.exe did not return a JSON array.'
        }
        foreach ($instance in $instances) {
            $installationVersion = $null
            if (-not $instance.installationPath -or
                -not [System.IO.Path]::IsPathFullyQualified([string]$instance.installationPath) -or
                -not [version]::TryParse([string]$instance.installationVersion, [ref]$installationVersion)) {
                throw 'Cannot discover Visual Studio MSBuild: vswhere.exe returned invalid installation metadata.'
            }
            $instance
        }
        return
    }

    $installerPath = Get-VsInstallerPath
    $vsWhere = if ($installerPath) { Join-Path $installerPath 'vswhere.exe' }
    if (-not $vsWhere -or -not (Test-Path -LiteralPath $vsWhere -PathType Leaf -ErrorAction Stop)) {
        throw 'Cannot discover Visual Studio developer environments: vswhere.exe was not found. Install or repair Visual Studio Installer.'
    }

    $json = Invoke-DeveloperVsWhere -Path $vsWhere
    if (-not $json) {
        throw 'Cannot discover Visual Studio developer environments: vswhere.exe returned no JSON.'
    }
    $instances = ConvertFrom-Json -InputObject ($json -join "`n") -NoEnumerate -ErrorAction Stop
    if ($instances -isnot [array]) {
        throw 'Cannot discover Visual Studio developer environments: vswhere.exe did not return a JSON array.'
    }
    $instances
}

function Invoke-DeveloperVsWhere {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $PSNativeCommandUseErrorActionPreference = $false
    $output = & $Path -products '*' -format json -utf8 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Cannot discover Visual Studio developer environments: vswhere.exe exited with code $LASTEXITCODE. $($output -join "`n")"
    }
    $output
}

function Get-VsDeveloperInstallation {
    [CmdletBinding()]
    param(
        [ValidateSet(2017, 2019, 2022, 2026)]
        [int]$Year
    )

    $installations = foreach ($instance in @(Invoke-VsWhere -ErrorAction Stop)) {
        $version = $null
        if (-not [version]::TryParse([string]$instance.installationVersion, [ref]$version) -or
            -not $instance.installationPath -or
            -not [IO.Path]::IsPathFullyQualified([string]$instance.installationPath)) {
            throw 'Cannot discover Visual Studio developer environments: invalid installation metadata.'
        }
        $installedYear = ConvertTo-VsYear -InstallationVersion ([string]$instance.installationVersion)
        if (-not $installedYear -or ($Year -and $Year -ne $installedYear)) { continue }
        if ($instance.isComplete -ne $true -or $instance.isLaunchable -ne $true -or $instance.isPrerelease -eq $true) { continue }

        $scriptPath = Join-Path $instance.installationPath 'Common7' 'Tools' 'VsDevCmd.bat'
        if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf -ErrorAction Stop)) { continue }
        [pscustomobject]@{
            Year             = $installedYear
            Version          = $version.ToString()
            InstallationPath = [IO.Path]::GetFullPath([string]$instance.installationPath)
            ScriptPath       = $scriptPath
        }
    }
    $installations | Sort-Object -Property @(
        @{ Expression = { [version]$_.Version }; Descending = $true },
        @{ Expression = { $_.InstallationPath }; Ascending = $true }
    )
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
        Uses vswhere.exe to enumerate complete, launchable release installations,
        including Build Tools, that contain Common7/Tools/VsDevCmd.bat. Returns
        sorted unique years for Visual Studio 2017, 2019, 2022, and 2026.
        No PSVSEnv or Set-VS provider command is required. Preview installations
        are excluded. Discovery errors terminate rather than hiding failures.

        The catalog_productLineVersion field is intentionally ignored because it
        can be inconsistent across Visual Studio products.

    .EXAMPLE
        Get-InstalledVsVersion
        Returns years such as 2022 or 2026 for eligible installed toolsets.
    #>
    [OutputType([int])]
    [CmdletBinding()]
    param()

    Assert-WindowsOnly -CommandName $MyInvocation.MyCommand.Name

    Get-VsDeveloperInstallation | Select-Object -ExpandProperty Year | Sort-Object -Unique
}
