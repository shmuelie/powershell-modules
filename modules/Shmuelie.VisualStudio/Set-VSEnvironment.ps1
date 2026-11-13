function Set-VS2017 {
    <#
    .SYNOPSIS
        Initializes Visual Studio 2017 in the current PowerShell session.
    .DESCRIPTION
        Uses the newest complete, launchable installation for this year and channel,
        including Build Tools, and its VsDevCmd.bat. No PSVSEnv is required.
        Repeating the same environment is a no-op. Conflicting active toolsets
        fail; use Start-DevShell for a fresh session. Windows-only.
    .PARAMETER Architecture
        Target architecture: x86, amd64, arm, or arm64. Defaults to x86.
    .PARAMETER HostArchitecture
        Host architecture: x86, amd64, or arm64. Defaults to x86. The selected
        toolset must support the requested combination.
    .PARAMETER Channel
        Release (default) or Preview. When omitted, honors VSDEV_CHANNEL set by
        Start-DevShell so profile initialization uses the requested channel.
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
        [string]$HostArchitecture = 'x86',
        [ValidateSet('Release', 'Preview')]
        [string]$Channel = 'Release'
    )
    Set-VsYearEnvironment -Year 2017 -Architecture $Architecture -HostArchitecture $HostArchitecture -Channel $Channel -Caller $PSCmdlet
}

function Set-VS2019 {
    <#
    .SYNOPSIS
        Initializes Visual Studio 2019 in the current PowerShell session.
    .DESCRIPTION
        Uses the newest complete, launchable installation for this year and channel,
        including Build Tools, and its VsDevCmd.bat. No PSVSEnv is required.
        Repeating the same environment is a no-op. Conflicting active toolsets
        fail; use Start-DevShell for a fresh session. Windows-only.
    .PARAMETER Architecture
        Target architecture: x86, amd64, arm, or arm64. Defaults to x86.
    .PARAMETER HostArchitecture
        Host architecture: x86, amd64, or arm64. Defaults to x86. The selected
        toolset must support the requested combination.
    .PARAMETER Channel
        Release (default) or Preview. When omitted, honors VSDEV_CHANNEL set by
        Start-DevShell so profile initialization uses the requested channel.
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
        [string]$HostArchitecture = 'x86',
        [ValidateSet('Release', 'Preview')]
        [string]$Channel = 'Release'
    )
    Set-VsYearEnvironment -Year 2019 -Architecture $Architecture -HostArchitecture $HostArchitecture -Channel $Channel -Caller $PSCmdlet
}

function Set-VS2022 {
    <#
    .SYNOPSIS
        Initializes Visual Studio 2022 in the current PowerShell session.
    .DESCRIPTION
        Uses the newest complete, launchable installation for this year and channel,
        including Build Tools, and its VsDevCmd.bat. No PSVSEnv is required.
        Repeating the same environment is a no-op. Conflicting active toolsets
        fail; use Start-DevShell for a fresh session. Windows-only.
    .PARAMETER Architecture
        Target architecture: x86, amd64, arm, or arm64. Defaults to x86.
    .PARAMETER HostArchitecture
        Host architecture: x86, amd64, or arm64. Defaults to x86. The selected
        toolset must support the requested combination.
    .PARAMETER Channel
        Release (default) or Preview. When omitted, honors VSDEV_CHANNEL set by
        Start-DevShell so profile initialization uses the requested channel.
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
        [string]$HostArchitecture = 'x86',
        [ValidateSet('Release', 'Preview')]
        [string]$Channel = 'Release'
    )
    Set-VsYearEnvironment -Year 2022 -Architecture $Architecture -HostArchitecture $HostArchitecture -Channel $Channel -Caller $PSCmdlet
}

function Set-VS2026 {
    <#
    .SYNOPSIS
        Initializes Visual Studio 2026 in the current PowerShell session.
    .DESCRIPTION
        Uses the newest complete, launchable installation for this year and channel,
        including Build Tools, and its VsDevCmd.bat. No PSVSEnv is required.
        Repeating the same environment is a no-op. Conflicting active toolsets
        fail; use Start-DevShell for a fresh session. Windows-only.
    .PARAMETER Architecture
        Target architecture: x86, amd64, arm, or arm64. Defaults to x86.
    .PARAMETER HostArchitecture
        Host architecture: x86, amd64, or arm64. Defaults to x86. The selected
        toolset must support the requested combination.
    .PARAMETER Channel
        Release (default) or Preview. When omitted, honors VSDEV_CHANNEL set by
        Start-DevShell so profile initialization uses the requested channel.
    .EXAMPLE
        Set-VS2026 -Architecture arm64 -HostArchitecture amd64
        Initializes an ARM64 target using 64-bit host tools.
    .EXAMPLE
        Set-VS2026 -Channel Preview -Architecture amd64 -HostArchitecture amd64
        Initializes the newest eligible VS 2026 Preview installation.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Alias('Arch')]
        [ValidateSet('x86', 'amd64', 'arm', 'arm64')]
        [string]$Architecture = 'x86',
        [Alias('HostArch')]
        [ValidateSet('x86', 'amd64', 'arm64')]
        [string]$HostArchitecture = 'x86',
        [ValidateSet('Release', 'Preview')]
        [string]$Channel = 'Release'
    )
    Set-VsYearEnvironment -Year 2026 -Architecture $Architecture -HostArchitecture $HostArchitecture -Channel $Channel -Caller $PSCmdlet
}
