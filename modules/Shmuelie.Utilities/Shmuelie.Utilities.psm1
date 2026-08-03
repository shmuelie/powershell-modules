$publicRoot = Join-Path $PSScriptRoot 'Public'
foreach ($script in Get-ChildItem $publicRoot -Filter '*.ps1' | Sort-Object Name) {
    . $script.FullName
}

Set-Alias -Name code -Value Start-VsCode
Set-Alias -Name Get-GlobalDotNetTools -Value Get-DotNetTool

Export-ModuleMember -Function @(
    'Get-DotNetTool', 'Update-DotNetTool', 'Install-DotNetTool',
    'Uninstall-DotNetTool', 'Get-InstalledApplications', 'Get-PipPackages',
    'Update-PipPackage', 'Test-IsElevated', 'New-GlobalConstant',
    'New-PathVariable', 'Get-SessionTitle', 'Reset-TerminalModes',
    'Import-ModuleSafe', 'Invoke-InLocation', 'Repair-GlobalJson',
    'Get-ServiceProcess', 'Get-UvPackages', 'Update-UvPackage', 'Start-VsCode',
    'Start-VsCodeChat', 'Get-VsCodeExtension', 'Install-VsCodeExtension',
    'Uninstall-VsCodeExtension', 'Update-VsCodeExtension',
    'Get-WindowsTerminalSettings', 'Get-WindowsTerminalProfile',
    'Start-WindowsPerformanceRecorder', 'Stop-WindowsPerformanceRecorder'
) -Alias @('code', 'Get-GlobalDotNetTools')
