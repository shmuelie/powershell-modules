@{
    RootModule        = 'Shmuelie.Utilities.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'ebba55f0-7da9-4b2b-811f-e325c1124bdb'
    Author            = 'Shmueli Englard'
    CompanyName       = 'Shmuelie'
    Copyright         = '(c) Shmueli Englard. All rights reserved.'
    Description       = 'General developer utilities for PowerShell, .NET, Python, VS Code, Windows Terminal, services, and WPR.'
    PowerShellVersion = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport = @(
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
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @('code', 'Get-GlobalDotNetTools')
    FormatsToProcess  = @('Utilities.format.ps1xml')
    PrivateData = @{
        PSData = @{
            Tags         = @('PowerShell', 'DotNet', 'Python', 'VSCode', 'WindowsTerminal', 'WPR')
            LicenseUri   = 'https://github.com/shmuelie/powershell-modules/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/shmuelie/powershell-modules'
            ReleaseNotes = 'Initial private preview.'
        }
    }
}
