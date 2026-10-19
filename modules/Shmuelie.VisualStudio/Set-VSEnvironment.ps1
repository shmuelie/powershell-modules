function Set-VS2017 {
    <#
    .SYNOPSIS
        Initializes Visual Studio 2017 in the current PowerShell session.
    .DESCRIPTION
        Uses the newest complete, launchable release installation for this year,
        including Build Tools, and its VsDevCmd.bat. No PSVSEnv is required.
        Repeating the same environment is a no-op. Conflicting active toolsets
        fail; use Start-DevShell for a fresh session. Windows-only.
    .PARAMETER Architecture
        Target architecture: x86, amd64, arm, or arm64. Defaults to x86.
    .PARAMETER HostArchitecture
        Host architecture: x86, amd64, or arm64. Defaults to x86. The selected
        toolset must support the requested combination.
    .EXAMPLE
        Set-VS2017 -Architecture amd64 -HostArchitecture amd64
        Initializes the current session for 64-bit development.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Alias('Arch')]
        [ValidateSet('x86', 'amd64', 'arm', 'arm64')]
        [string]$Architecture = 'x86',
        [Alias('HostArch')]
        [ValidateSet('x86', 'amd64', 'arm64')]
        [string]$HostArchitecture = 'x86'
    )
    Set-VsYearEnvironment -Year 2017 -Architecture $Architecture -HostArchitecture $HostArchitecture -Caller $PSCmdlet
}

function Set-VS2019 {
    <#
    .SYNOPSIS
        Initializes Visual Studio 2019 in the current PowerShell session.
    .DESCRIPTION
        Uses the newest complete, launchable release installation for this year,
        including Build Tools, and its VsDevCmd.bat. No PSVSEnv is required.
        Repeating the same environment is a no-op. Conflicting active toolsets
        fail; use Start-DevShell for a fresh session. Windows-only.
    .PARAMETER Architecture
        Target architecture: x86, amd64, arm, or arm64. Defaults to x86.
    .PARAMETER HostArchitecture
        Host architecture: x86, amd64, or arm64. Defaults to x86. The selected
        toolset must support the requested combination.
    .EXAMPLE
        Set-VS2019 -WhatIf
        Previews initialization without modifying the current environment.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Alias('Arch')]
        [ValidateSet('x86', 'amd64', 'arm', 'arm64')]
        [string]$Architecture = 'x86',
        [Alias('HostArch')]
        [ValidateSet('x86', 'amd64', 'arm64')]
        [string]$HostArchitecture = 'x86'
    )
    Set-VsYearEnvironment -Year 2019 -Architecture $Architecture -HostArchitecture $HostArchitecture -Caller $PSCmdlet
}

function Set-VS2022 {
    <#
    .SYNOPSIS
        Initializes Visual Studio 2022 in the current PowerShell session.
    .DESCRIPTION
        Uses the newest complete, launchable release installation for this year,
        including Build Tools, and its VsDevCmd.bat. No PSVSEnv is required.
        Repeating the same environment is a no-op. Conflicting active toolsets
        fail; use Start-DevShell for a fresh session. Windows-only.
    .PARAMETER Architecture
        Target architecture: x86, amd64, arm, or arm64. Defaults to x86.
    .PARAMETER HostArchitecture
        Host architecture: x86, amd64, or arm64. Defaults to x86. The selected
        toolset must support the requested combination.
    .EXAMPLE
        Shmuelie.VisualStudio\Set-VS2022 -Arch amd64 -HostArch amd64
        Initializes the current session without relying on another provider.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Alias('Arch')]
        [ValidateSet('x86', 'amd64', 'arm', 'arm64')]
        [string]$Architecture = 'x86',
        [Alias('HostArch')]
        [ValidateSet('x86', 'amd64', 'arm64')]
        [string]$HostArchitecture = 'x86'
    )
    Set-VsYearEnvironment -Year 2022 -Architecture $Architecture -HostArchitecture $HostArchitecture -Caller $PSCmdlet
}

function Set-VS2026 {
    <#
    .SYNOPSIS
        Initializes Visual Studio 2026 in the current PowerShell session.
    .DESCRIPTION
        Uses the newest complete, launchable release installation for this year,
        including Build Tools, and its VsDevCmd.bat. No PSVSEnv is required.
        Repeating the same environment is a no-op. Conflicting active toolsets
        fail; use Start-DevShell for a fresh session. Windows-only.
    .PARAMETER Architecture
        Target architecture: x86, amd64, arm, or arm64. Defaults to x86.
    .PARAMETER HostArchitecture
        Host architecture: x86, amd64, or arm64. Defaults to x86. The selected
        toolset must support the requested combination.
    .EXAMPLE
        Set-VS2026 -Architecture arm64 -HostArchitecture amd64
        Initializes an ARM64 target using 64-bit host tools.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Alias('Arch')]
        [ValidateSet('x86', 'amd64', 'arm', 'arm64')]
        [string]$Architecture = 'x86',
        [Alias('HostArch')]
        [ValidateSet('x86', 'amd64', 'arm64')]
        [string]$HostArchitecture = 'x86'
    )
    Set-VsYearEnvironment -Year 2026 -Architecture $Architecture -HostArchitecture $HostArchitecture -Caller $PSCmdlet
}
