$publicRoot = Join-Path $PSScriptRoot 'Public'
foreach ($script in Get-ChildItem $publicRoot -Filter '*.ps1' | Sort-Object Name) {
    . $script.FullName
}

Export-ModuleMember -Function @(
    'Get-DotNetTool', 'Update-DotNetTool', 'Install-DotNetTool',
    'Uninstall-DotNetTool', 'Get-InstalledApplications', 'Get-PipPackages',
    'Update-PipPackage', 'Test-IsElevated', 'New-GlobalConstant',
    'New-PathVariable', 'Get-SessionTitle', 'Reset-TerminalModes',
    'Import-ModuleSafe', 'Invoke-InLocation', 'Repair-GlobalJson',
    'Format-Duration',
    'Get-ServiceProcess', 'Get-UvPackages', 'Update-UvPackage', 'Start-VsCode',
    'Start-VsCodeChat', 'Get-VsCodeExtension', 'Install-VsCodeExtension',
    'Uninstall-VsCodeExtension', 'Update-VsCodeExtension',
    'Get-WindowsTerminalSettings', 'Get-WindowsTerminalProfile',
    'Start-WindowsPerformanceRecorder', 'Stop-WindowsPerformanceRecorder'
)
