@{
    RootModule        = 'Shmuelie.Copilot.psm1'
    ModuleVersion     = '0.1.1'
    GUID              = 'f7928388-cc43-454f-8265-a7e1664422dd'
    Author            = 'Shmueli Englard'
    CompanyName       = 'Shmuelie'
    Copyright         = '(c) Shmueli Englard. All rights reserved.'
    Description       = 'GitHub Copilot CLI session, plugin, marketplace, and MCP helpers.'
    PowerShellVersion = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport = @(
        'Get-CopilotMarketplace',
        'Register-CopilotMarketplace', 'Unregister-CopilotMarketplace',
        'Get-CopilotMarketplacePlugin', 'Get-CopilotMcpServer',
        'Register-CopilotMcpServer', 'Unregister-CopilotMcpServer', 'Get-CopilotPlugin',
        'Update-CopilotPlugin', 'Install-CopilotPlugin', 'Uninstall-CopilotPlugin',
        'Merge-CopilotSession', 'Compress-CopilotSession', 'Repair-CopilotSessionEvents',
        'Get-CopilotSession', 'Remove-CopilotSession', 'Rename-CopilotSession',
        'Resume-CopilotSession', 'Get-CopilotLaunchPlan', 'Start-Copilot'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    FormatsToProcess  = @('CopilotHelpers.format.ps1xml')
    PrivateData = @{
        PSData = @{
            Tags         = @('GitHubCopilot', 'CopilotCLI', 'MCP', 'Plugins', 'DeveloperTools')
            LicenseUri   = 'https://github.com/shmuelie/powershell-modules/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/shmuelie/powershell-modules'
        }
    }
}
