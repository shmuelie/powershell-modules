@{
    RootModule        = 'Shmuelie.DevTunnel.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '3fde4215-c99c-4b4d-a1ea-a05bb44d9ef9'
    Author            = 'Shmueli Englard'
    CompanyName       = 'Shmuelie'
    Copyright         = '(c) Shmueli Englard. All rights reserved.'
    Description       = 'PowerShell wrappers for the Microsoft devtunnel CLI.'
    PowerShellVersion = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport = @(
        'Get-DevTunnelVersion', 'Connect-DevTunnelAccount', 'Disconnect-DevTunnelAccount',
        'Get-DevTunnelAccount', 'Get-DevTunnel', 'New-DevTunnel', 'Set-DevTunnel',
        'Remove-DevTunnel', 'Start-DevTunnel', 'Connect-DevTunnel',
        'Get-DevTunnelPort', 'New-DevTunnelPort', 'Set-DevTunnelPort', 'Remove-DevTunnelPort',
        'Get-DevTunnelAccess', 'Add-DevTunnelAccess', 'Remove-DevTunnelAccess',
        'Reset-DevTunnelAccess', 'New-DevTunnelToken', 'Set-DevTunnelDefault',
        'Clear-DevTunnelDefault', 'Get-DevTunnelCluster', 'Get-DevTunnelLimit',
        'Start-DevTunnelEcho', 'Test-DevTunnel'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData = @{
        PSData = @{
            Tags       = @('DevTunnel', 'Tunnels', 'DeveloperTools', 'CrossPlatform')
            LicenseUri = 'https://github.com/shmuelie/powershell-modules/blob/main/LICENSE'
            ProjectUri = 'https://github.com/shmuelie/powershell-modules'
        }
    }
}
