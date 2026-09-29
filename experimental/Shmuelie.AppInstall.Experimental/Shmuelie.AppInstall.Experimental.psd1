@{
    RootModule        = 'Shmuelie.AppInstall.Experimental.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'a5b03b1b-9a8e-4c5d-8249-fba68f118bdf'
    Author            = 'Shmueli Englard'
    CompanyName       = 'Shmuelie'
    Copyright         = '(c) Shmueli Englard. All rights reserved.'
    Description       = 'Unpublished AppInstallManager development. Private-capability support remains unresolved; not a supported distribution.'
    PowerShellVersion = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport = @()
    CmdletsToExport   = @(
        'New-AppInstallContext', 'Get-AppInstallItem', 'Get-AppInstallSettings',
        'Request-AppInstallUpdateSearch', 'Wait-AppInstallItem'
    )
    VariablesToExport = @()
    AliasesToExport   = @()
    FormatsToProcess  = @('AppInstall.format.ps1xml')
    PrivateData = @{
        Publishable = $false
        PSData = @{
            Tags       = @('Experimental', 'DoNotPublish')
            LicenseUri = 'https://github.com/shmuelie/powershell-modules/blob/main/LICENSE'
            ProjectUri = 'https://github.com/shmuelie/powershell-modules/issues/233'
        }
    }
}
