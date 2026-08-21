$publicRoot = Join-Path $PSScriptRoot 'Public'
foreach ($scriptName in @(
    'DotNetHelpers.ps1',
    'Get-InstalledApplications.ps1',
    'PythonHelpers.ps1',
    'Utilities.ps1',
    'UvHelpers.ps1',
    'VsCodeHelpers.ps1',
    'WindowsTerminalHelpers.ps1',
    'WprHelpers.ps1'
)) {
    . (Join-Path $publicRoot $scriptName)
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
