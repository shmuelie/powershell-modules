@{
    RootModule        = 'Shmuelie.Node.psm1'
    ModuleVersion = '0.1.2'
    GUID              = 'c2fc780d-9f68-49ec-997a-f15809c8b642'
    Author            = 'Shmueli Englard'
    CompanyName       = 'Shmuelie'
    Copyright         = '(c) Shmueli Englard. All rights reserved.'
    Description       = 'Node.js, nvm-windows, npm package, and Azure DevOps npm credential helpers.'
    PowerShellVersion = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport = @(
        'Get-NpmPackage', 'Update-NpmPackage', 'Get-NodeVersion', 'Install-NodeVersion',
        'Uninstall-NodeVersion', 'Set-NodeVersion', 'Set-NodeAlias', 'Remove-NodeAlias',
        'Enable-Nvm', 'Disable-Nvm', 'Set-NvmProxy', 'Set-NvmNodeMirror',
        'Set-NvmNpmMirror', 'Get-NvmRoot', 'Get-NvmVersion', 'Test-NvmInstalled',
        'Update-AdoNpmToken'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    FormatsToProcess  = @('NodeHelpers.format.ps1xml')
    PrivateData = @{
        PSData = @{
            Tags         = @('NodeJS', 'NVM', 'NPM', 'AzureDevOps', 'DeveloperTools')
            LicenseUri   = 'https://github.com/shmuelie/powershell-modules/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/shmuelie/powershell-modules'
        }
    }
}
