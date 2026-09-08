@{
    RootModule        = 'Shmuelie.PackageManagement.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'b3318a61-5eba-4ad0-8b92-95a06df87b80'
    Author            = 'Shmueli Englard'
    CompanyName       = 'Shmuelie'
    Copyright         = '(c) Shmueli Englard. All rights reserved.'
    Description       = 'Provider-neutral package update orchestration. Initial foundation; provider integrations ship separately.'
    PowerShellVersion = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport = @('Update-AllPackages')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData = @{
        PSData = @{
            Tags       = @('Packages', 'Updates', 'DeveloperTools')
            LicenseUri = 'https://github.com/shmuelie/powershell-modules/blob/main/LICENSE'
            ProjectUri = 'https://github.com/shmuelie/powershell-modules'
        }
    }
}
