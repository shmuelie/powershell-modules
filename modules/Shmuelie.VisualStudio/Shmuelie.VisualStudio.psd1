@{
    RootModule           = 'Shmuelie.VisualStudio.psm1'
    ModuleVersion        = '0.1.1'
    GUID                 = 'c6d193ef-cddd-4328-8bdd-06768188f1f3'
    Author               = 'Shmueli Englard'
    CompanyName          = 'Shmuelie'
    Copyright            = '(c) Shmueli Englard. All rights reserved.'
    Description          = 'Visual Studio developer shell helpers for PowerShell.'
    PowerShellVersion    = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @('Get-InstalledVsVersion', 'Start-DevShell')
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags       = @('VisualStudio', 'DeveloperTools', 'Windows')
            LicenseUri = 'https://github.com/shmuelie/powershell-modules/blob/main/LICENSE'
            ProjectUri = 'https://github.com/shmuelie/powershell-modules'
        }
    }
}
