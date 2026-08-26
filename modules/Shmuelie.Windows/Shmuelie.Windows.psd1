@{
    RootModule           = 'Shmuelie.Windows.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '1378be2e-a233-4d0d-b260-876317e77565'
    Author               = 'Shmueli Englard'
    CompanyName          = 'Shmuelie'
    Copyright            = '(c) Shmueli Englard. All rights reserved.'
    Description          = 'Windows-only developer utilities: installed applications, Windows Terminal, Windows Performance Recorder, service host processes, and app-installer packages.'
    PowerShellVersion    = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @(
        'Get-WindowsTerminalSettings', 'Get-WindowsTerminalProfile',
        'Start-WindowsPerformanceRecorder', 'Stop-WindowsPerformanceRecorder'
    )
    CmdletsToExport      = @('Get-AppInstallerApp', 'Get-InstalledApplications', 'Get-ServiceProcess', 'Get-SubstDrive', 'New-SubstDrive', 'Remove-SubstDrive', 'Update-AppInstallerApp')
    VariablesToExport    = @()
    AliasesToExport      = @()
    FormatsToProcess  = @('Windows.format.ps1xml')
    PrivateData          = @{
        PSData = @{
            Tags       = @('Windows', 'MSIX', 'WindowsTerminal', 'WPR', 'DeveloperTools')
            LicenseUri = 'https://github.com/shmuelie/powershell-modules/blob/main/LICENSE'
            ProjectUri = 'https://github.com/shmuelie/powershell-modules'
        }
    }
}
