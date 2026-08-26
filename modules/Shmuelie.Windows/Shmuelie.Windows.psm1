$publicRoot = Join-Path $PSScriptRoot 'Public'
foreach ($script in Get-ChildItem $publicRoot -Filter '*.ps1' | Sort-Object Name) {
    . $script.FullName
}

Export-ModuleMember -Function @(
    'Get-AppInstallerApp', 'Get-InstalledApplications', 'Get-ServiceProcess',
    'Get-WindowsTerminalSettings', 'Get-WindowsTerminalProfile',
    'Start-WindowsPerformanceRecorder', 'Stop-WindowsPerformanceRecorder',
    'Update-AppInstallerApp'
)
