function Get-VsInstallerPath {
    [CmdletBinding()]
    param()

    $programFilesX86 = ${env:ProgramFiles(x86)}
    if (-not $programFilesX86) {
        $programFilesX86 = [Environment]::GetFolderPath('ProgramFilesX86')
    }
    if (-not $programFilesX86) { return $null }

    Join-Path $programFilesX86 'Microsoft Visual Studio\Installer'
}

function Get-CleanLoginPath {
    [CmdletBinding()]
    param()

    $separator = [System.IO.Path]::PathSeparator
    $segments = foreach ($pathValue in @(
            [Environment]::GetEnvironmentVariable('Path', 'Machine'),
            [Environment]::GetEnvironmentVariable('Path', 'User')
        )) {
        if ($pathValue) {
            $pathValue -split [regex]::Escape($separator) | Where-Object { $_ }
        }
    }

    $installerPath = Get-VsInstallerPath
    if ($installerPath) {
        $segments += $installerPath
    }

    ($segments | Select-Object -Unique) -join $separator
}

function Invoke-DevShellProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Environment,

        [Parameter(Mandatory)]
        [string[]]$ArgumentList,

        [Parameter(Mandatory)]
        [string]$WorkingDirectory
    )

    $process = [Diagnostics.Process]::new()
    try {
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = Join-Path $PSHOME 'pwsh.exe'
        $start.UseShellExecute = $false
        $start.WorkingDirectory = $WorkingDirectory
        foreach ($argument in $ArgumentList) { $start.ArgumentList.Add($argument) }
        foreach ($key in $Environment.Keys) {
            if ($null -eq $Environment[$key]) {
                $null = $start.Environment.Remove($key)
            } else {
                $start.Environment[$key] = [string]$Environment[$key]
            }
        }
        $process.StartInfo = $start
        if (-not $process.Start()) { throw 'Could not start the Visual Studio developer shell.' }
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            throw "Visual Studio developer shell exited with code $($process.ExitCode)."
        }
    } finally {
        $process.Dispose()
    }
}

function Get-VsCleanChildEnvironment {
    [CmdletBinding()]
    param()

    $environment = @{}
    foreach ($entry in (Get-VsEnvironmentSnapshot).GetEnumerator()) {
        if ($entry.Key -match '^(?:VSCMD_|__VSCMD_|VSINSTALLDIR$|VCINSTALLDIR$|VCTools|DevEnvDir$|VisualStudioVersion$|WindowsSDK|WindowsSdk|UniversalCRTSdkDir$|UCRTVersion$|ExtensionSdkDir$|NETFXSDKDir$|FrameworkDir|FrameworkVersion|Framework40Version$|DevShellId$|INCLUDE$|LIB$|LIBPATH$|__DOTNET_)') {
            $value = [Environment]::GetEnvironmentVariable($entry.Key, 'User')
            if ($null -eq $value) { $value = [Environment]::GetEnvironmentVariable($entry.Key, 'Machine') }
            $environment[$entry.Key] = $value
        }
    }
    $originals = Get-Variable -Name VsEnvironmentOriginals -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($originals) {
        foreach ($key in $originals.Keys) { $environment[$key] = $originals[$key] }
    }
    $environment['PATH'] = Get-CleanLoginPath
    $environment
}

function Get-VsDevShellArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Installation,
        [Parameter(Mandatory)]
        [string]$Architecture,
        [Parameter(Mandatory)]
        [string]$HostArchitecture,
        [Parameter(Mandatory)]
        [string]$WorkingDirectory
    )

    $request = @{
        Installation     = $Installation
        Architecture     = $Architecture
        HostArchitecture = $HostArchitecture
        WorkingDirectory = $WorkingDirectory
        ModuleManifest   = Join-Path $PSScriptRoot 'Shmuelie.VisualStudio.psd1'
    } | ConvertTo-Json -Depth 5 -Compress
    $data = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($request))
    $bootstrap = @'
try {
    $request = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__REQUEST__')) | ConvertFrom-Json -ErrorAction Stop
    $module = Import-Module -Name $request.ModuleManifest -PassThru -ErrorAction Stop
    Set-Location -LiteralPath $request.WorkingDirectory -ErrorAction Stop
    & $module {
        param($request)
        Initialize-VsDeveloperEnvironment -Installation $request.Installation -Architecture $request.Architecture -HostArchitecture $request.HostArchitecture
    } $request
} catch {
    [Console]::Error.WriteLine("Cannot initialize Visual Studio developer shell: $_")
    exit 1
}
'@
    $bootstrap = $bootstrap.Replace('__REQUEST__', $data)
    @('-NoLogo', '-NoExit', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap)))
}

function Start-DevShell {
    <#
    .SYNOPSIS
        Starts a nested PowerShell session for a Visual Studio developer environment.

    .DESCRIPTION
        Starts pwsh inline in the current window and waits until the nested shell
        exits. The selected Visual Studio year is passed to the child process via
        VSDEV_VERSION, with VSDEV_ARCH and VSDEV_HOSTARCH carrying architecture
        choices. Normal PowerShell profiles run first; the module then initializes
        the exact selected installation using VsDevCmd.bat before interactive use.
        No PSVSEnv or custom profile initialization is required. A profile may
        use this module's Set-VS commands with the VSDEV_* values; an exactly
        matching environment is reused, while conflicting toolsets fail.

        The child receives a clean login PATH and restored or cleared inherited
        toolset variables. The parent's environment is unchanged. The caller's
        filesystem working directory is restored after profiles have run.
        Complete, launchable releases of Visual Studio 2017, 2019, 2022, and
        2026, including Build Tools, are supported; previews are excluded.

    .PARAMETER Version
        Visual Studio year to request, such as 2022 or 2026. Defaults to the
        latest year returned by Get-InstalledVsVersion.

    .PARAMETER Arch
        Target architecture to pass to the child session through VSDEV_ARCH.
        Defaults to amd64.

    .PARAMETER HostArch
        Host architecture to pass to the child session through VSDEV_HOSTARCH.
        Defaults to amd64.

    .EXAMPLE
        Start-DevShell
        Starts a nested PowerShell session for the latest discoverable Visual
        Studio developer environment.

    .EXAMPLE
        Start-DevShell 2022
        Starts a nested PowerShell session requesting Visual Studio 2022.
    .EXAMPLE
        Start-DevShell 2022 -WhatIf
        Shows the nested developer shell that would be launched without
        starting a child process.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Position = 0)]
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
            Get-InstalledVsVersion |
                Where-Object { "$_" -like "$wordToComplete*" } |
                ForEach-Object { "$_" }
        })]
        [int]$Version,

        [ValidateSet('x86', 'amd64', 'arm', 'arm64')]
        [string]$Arch = 'amd64',

        [ValidateSet('x86', 'amd64', 'arm64')]
        [string]$HostArch = 'amd64'
    )

    Assert-WindowsOnly -CommandName $MyInvocation.MyCommand.Name

    $installations = @(Get-VsDeveloperInstallation)
    if ($installations.Count -eq 0) {
        throw 'No complete, launchable Visual Studio release installations with VsDevCmd.bat were found.'
    }

    $selectedVersion = if ($PSBoundParameters.ContainsKey('Version')) { $Version } else { $installations[0].Year }
    $installation = $installations | Where-Object Year -EQ $selectedVersion | Select-Object -First 1
    if (-not $installation) {
        $installedVersions = @($installations.Year | Sort-Object -Descending -Unique)
        throw "Visual Studio $selectedVersion is not available. Available versions: $($installedVersions -join ', ')."
    }

    $location = Get-Location
    if ($location.Provider.Name -ne 'FileSystem') {
        throw 'Start-DevShell requires a filesystem working directory.'
    }
    $target = "Visual Studio $selectedVersion ($Arch, host $HostArch) in $($location.Path)"
    if ($PSCmdlet.ShouldProcess($target, 'Start nested developer shell')) {
        $environment = Get-VsCleanChildEnvironment
        $environment['VSDEV_VERSION'] = [string]$selectedVersion
        $environment['VSDEV_ARCH'] = $Arch
        $environment['VSDEV_HOSTARCH'] = $HostArch
        $arguments = Get-VsDevShellArguments -Installation $installation -Architecture $Arch -HostArchitecture $HostArch -WorkingDirectory $location.Path
        Invoke-DevShellProcess -Environment $environment -ArgumentList $arguments -WorkingDirectory $location.Path
    }
}
