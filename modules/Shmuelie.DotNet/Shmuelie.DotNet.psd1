@{
    RootModule        = 'Shmuelie.DotNet.psm1'
    ModuleVersion     = '0.2.0'
    GUID              = '9b4f9e06-2d53-4973-88a9-f7c16305e42b'
    Author            = 'Shmueli Englard'
    CompanyName       = 'Shmuelie'
    Copyright         = '(c) Shmueli Englard. All rights reserved.'
    Description       = 'User-local .NET SDK installation and .NET tool management helpers.'
    PowerShellVersion = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport = @(
        'Get-DotNetTool',
        'Install-DotNetSdk',
        'Install-DotNetTool',
        'Update-DotNetTool',
        'Uninstall-DotNetTool'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData = @{
        PSData = @{
            Tags         = @('DotNet', 'Tools', 'DeveloperTools')
            LicenseUri   = 'https://github.com/shmuelie/powershell-modules/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/shmuelie/powershell-modules'
        }
    }
}
