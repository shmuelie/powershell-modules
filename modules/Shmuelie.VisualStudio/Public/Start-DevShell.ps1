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
        [hashtable]$Environment
    )

    Start-Process -FilePath 'pwsh' -ArgumentList @('-NoLogo') -NoNewWindow -Wait -Environment $Environment
}

function Start-DevShell {
    <#
    .SYNOPSIS
        Starts a nested PowerShell session for a Visual Studio developer environment.

    .DESCRIPTION
        Starts pwsh inline in the current window and waits until the nested shell
        exits. The selected Visual Studio year is passed to the child process via
        VSDEV_VERSION, with VSDEV_ARCH and VSDEV_HOSTARCH carrying architecture
        choices. The child process receives a clean login PATH composed from the
        Machine and User PATH values plus the Visual Studio Installer directory,
        so an already-loaded toolset in the parent process is not inherited.

        This cmdlet is only a launcher. A profile or provider module in the child
        session is expected to honor VSDEV_VERSION by invoking the matching
        Set-VS<year> command.

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

        [ValidateNotNullOrEmpty()]
        [string]$Arch = 'amd64',

        [ValidateNotNullOrEmpty()]
        [string]$HostArch = 'amd64'
    )

    Assert-WindowsOnly -CommandName $MyInvocation.MyCommand.Name

    $installedVersions = @(Get-InstalledVsVersion | ForEach-Object { [int]$_ } | Sort-Object -Descending -Unique)
    if ($installedVersions.Count -eq 0) {
        throw 'No installed Visual Studio developer environments were found. Install Visual Studio and a provider that exposes Set-VS<year> commands.'
    }

    $selectedVersion = if ($PSBoundParameters.ContainsKey('Version')) { $Version } else { $installedVersions[0] }
    if ($selectedVersion -notin $installedVersions) {
        throw "Visual Studio $selectedVersion is not available. Available versions: $($installedVersions -join ', ')."
    }

    $environment = @{
        VSDEV_VERSION  = [string]$selectedVersion
        VSDEV_ARCH     = $Arch
        VSDEV_HOSTARCH = $HostArch
        PATH           = Get-CleanLoginPath
    }

    $target = "Visual Studio $selectedVersion ($Arch, host $HostArch) in $((Get-Location).Path)"
    if ($PSCmdlet.ShouldProcess($target, 'Start nested developer shell')) {
        Invoke-DevShellProcess -Environment $environment
    }
}
