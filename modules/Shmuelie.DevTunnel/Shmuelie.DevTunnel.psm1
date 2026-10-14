foreach ($script in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File) {
    . $script.FullName
}

Export-ModuleMember -Function @(
    'Get-DevTunnelVersion', 'Connect-DevTunnelAccount', 'Disconnect-DevTunnelAccount',
    'Get-DevTunnelAccount', 'Get-DevTunnel', 'New-DevTunnel', 'Set-DevTunnel',
    'Remove-DevTunnel', 'Start-DevTunnel', 'Connect-DevTunnel',
    'Get-DevTunnelPort', 'New-DevTunnelPort', 'Set-DevTunnelPort', 'Remove-DevTunnelPort',
    'Get-DevTunnelAccess', 'Add-DevTunnelAccess', 'Remove-DevTunnelAccess',
    'Reset-DevTunnelAccess', 'New-DevTunnelToken', 'Set-DevTunnelDefault',
    'Clear-DevTunnelDefault', 'Get-DevTunnelCluster', 'Get-DevTunnelLimit',
    'Start-DevTunnelEcho', 'Test-DevTunnel'
)
