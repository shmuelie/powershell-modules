function Invoke-MSBuildVsWhere {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $PSNativeCommandUseErrorActionPreference = $false
    $output = & $Path -products '*' -requires Microsoft.Component.MSBuild -format json -utf8 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Cannot discover Visual Studio MSBuild: vswhere.exe exited with code $LASTEXITCODE. $($output -join "`n")"
    }
    $output
}

function Get-MSBuildDefaultArchitecture {
    [CmdletBinding()]
    param()

    $architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
    if ($architecture -notin @('x86', 'x64', 'arm64')) {
        throw "No supported Visual Studio MSBuild architecture for this operating system: $architecture."
    }
    $architecture
}

function Resolve-MSBuild {
    <#
    .SYNOPSIS
        Resolves an installed Visual Studio MSBuild.exe without running it.

    .DESCRIPTION
        Uses Visual Studio Installer's vswhere.exe to discover complete,
        launchable release installations containing Microsoft.Component.MSBuild,
        including standalone Build Tools. Preview installations are excluded.
        Selects the newest installationVersion with an existing MSBuild.exe for
        the requested architecture; equal versions are ordered by installation
        path ascending. Supports Visual Studio 2017 and later.

        Returns the real Visual Studio MSBuild.exe, not dotnet msbuild. This is
        useful for Visual Studio workloads and packaging targets that require
        full MSBuild. Discovery does not guarantee that any particular workload,
        SDK, or project target is installed. No Set-VS<year> provider is needed,
        no developer shell is started, and PATH is not modified.

        This command requires Windows; importing the module does not.

    .PARAMETER Version
        Optional Visual Studio year (2017, 2019, 2022, or 2026) or numeric
        installation version prefix, such as 17, 17.10, or 18.0. This is the
        Visual Studio version, not an MSBuild or .NET SDK version. Omit to
        select the newest compatible installation. Ranges are not accepted.

    .PARAMETER Architecture
        Architecture of the MSBuild executable (not the project's target).
        Accepts x86, x64, amd64 (an alias value for x64), or arm64. Defaults
        to the native operating system architecture, even in an emulated
        PowerShell process. Never falls back to a different architecture.

    .PARAMETER PathOnly
        Returns only the executable path as a string, suitable for the call
        operator, instead of an MSBuildInstallation object.

    .OUTPUTS
        MSBuildInstallation
        Path (string), VisualStudioVersion (System.Version), VisualStudioYear
        (integer, or null for an unrecognized future major), InstallationPath
        (string), and Architecture (x86, x64, or arm64).

        System.String
        With PathOnly, the executable path.

    .EXAMPLE
        Resolve-MSBuild
        Describes the newest installed release MSBuild for the native OS
        architecture without executing it.

    .EXAMPLE
        $msbuild = Resolve-MSBuild -Version 2022 -Architecture x64
        & $msbuild.Path .\App.sln -restore
        Explicitly invokes Visual Studio MSBuild rather than dotnet msbuild.

    .EXAMPLE
        & (Resolve-MSBuild -Version 18 -PathOnly) .\App.sln -t:Build
        Invokes MSBuild from the newest compatible Visual Studio 18.x instance.

    .LINK
        https://learn.microsoft.com/visualstudio/install/tools-for-managing-visual-studio-instances

    .LINK
        https://github.com/microsoft/setup-msbuild
    #>
    [CmdletBinding()]
    [OutputType('MSBuildInstallation', [string])]
    param(
        [Parameter(Position = 0)]
        [ValidatePattern('^(2017|2019|2022|2026|(?:1[5-9]|[2-9][0-9])(?:\.[0-9]+){0,3})$')]
        [ValidateScript({
            $parsed = $null
            $candidate = if ($_ -notmatch '\.') { "$_.0" } else { $_ }
            if (-not [version]::TryParse($candidate, [ref]$parsed)) {
                throw 'Version components must fit in a System.Version value.'
            }
            $true
        })]
        [string]$Version,

        [Alias('Arch')]
        [ValidateSet('x86', 'x64', 'amd64', 'arm64')]
        [string]$Architecture,

        [switch]$PathOnly
    )

    Assert-WindowsOnly -CommandName $MyInvocation.MyCommand.Name

    $selectedArchitecture = if ($Architecture) { $Architecture.ToLowerInvariant() } else { Get-MSBuildDefaultArchitecture }
    if ($selectedArchitecture -eq 'amd64') { $selectedArchitecture = 'x64' }

    $versionParts = if ($Version) { @($Version -split '\.' | ForEach-Object { [int]$_ }) }
    $instances = @(Invoke-VsWhere -MSBuild -ErrorAction Stop)
    $instances = $instances | Sort-Object -Property @(
        @{ Expression = { [version]$_.installationVersion }; Descending = $true },
        @{ Expression = { [string]$_.installationPath }; Ascending = $true }
    )

    foreach ($instance in $instances) {
        $installationVersion = [version]$instance.installationVersion
        if ($installationVersion.Major -lt 15) { continue }
        $year = ConvertTo-VsYear -InstallationVersion $instance.installationVersion
        if ($Version) {
            if ($versionParts[0] -ge 2000) {
                if ($year -ne $versionParts[0]) { continue }
            } else {
                $installedParts = @($installationVersion.Major, $installationVersion.Minor, $installationVersion.Build, $installationVersion.Revision)
                $matches = $true
                for ($index = 0; $index -lt $versionParts.Count; $index++) {
                    if ($versionParts[$index] -ne $installedParts[$index]) {
                        $matches = $false
                        break
                    }
                }
                if (-not $matches) { continue }
            }
        }

        $toolset = if ($installationVersion.Major -eq 15) { '15.0' } else { 'Current' }
        $binPath = Join-Path $instance.installationPath 'MSBuild' $toolset 'Bin'
        $binPath = switch ($selectedArchitecture) {
            'x64' { Join-Path $binPath 'amd64' }
            'arm64' { Join-Path $binPath 'arm64' }
            default { $binPath }
        }
        $path = Join-Path $binPath 'MSBuild.exe'
        if (-not (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction Stop)) { continue }

        if ($PathOnly) { return $path }
        return [pscustomobject]@{
            PSTypeName          = 'MSBuildInstallation'
            Path                = $path
            VisualStudioVersion = $installationVersion
            VisualStudioYear    = $year
            InstallationPath    = [string]$instance.installationPath
            Architecture        = $selectedArchitecture
        }
    }

    $versionDescription = if ($Version) { " matching Visual Studio '$Version'" } else { '' }
    throw "No compatible Visual Studio MSBuild.exe installation found$versionDescription for architecture '$selectedArchitecture'. A complete release installation of Visual Studio 2017 or later (or Build Tools) with the MSBuild component and requested executable is required."
}
