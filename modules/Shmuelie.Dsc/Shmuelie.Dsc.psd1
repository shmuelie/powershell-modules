@{
    RootModule           = 'Shmuelie.Dsc.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = 'd4406e2b-fd8f-4311-aa4e-178d2794102a'
    Author               = 'Shmueli Englard'
    CompanyName          = 'Shmuelie'
    Copyright            = '(c) Shmueli Englard. All rights reserved.'
    Description          = 'Class-based DSC v3 resources for developer machine setup: save PowerShell modules to a path, manage symbolic links, install GitHub Copilot CLI plugins and marketplaces, and install uv Python tools.'
    PowerShellVersion    = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @()
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    DscResourcesToExport = @('SavePSResource', 'SymbolicLink', 'CopilotPlugin', 'CopilotMarketplace', 'UvTool')
    PrivateData          = @{
        PSData = @{
            Tags       = @('DSC', 'DSCv3', 'DesiredStateConfiguration', 'PSDscResource', 'Setup', 'DeveloperTools')
            LicenseUri = 'https://github.com/shmuelie/powershell-modules/blob/main/LICENSE'
            ProjectUri = 'https://github.com/shmuelie/powershell-modules'
        }
    }
}
