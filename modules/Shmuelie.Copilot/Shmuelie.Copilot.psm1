$publicRoot = Join-Path $PSScriptRoot 'Public'
foreach ($scriptName in @(
    'CliExeHelpers.ps1',
    'CopilotHome.ps1',
    'Get-CopilotLaunchPlan.ps1',
    'Marketplaces.ps1',
    'McpServers.ps1',
    'Plugins.ps1',
    'SessionMaintenance.ps1',
    'Sessions.ps1',
    'Start-Copilot.ps1',
    'WorkspaceYaml.ps1'
)) {
    . (Join-Path $publicRoot $scriptName)
}

Register-ArgumentCompleter -CommandName Get-CopilotSession, Remove-CopilotSession, Rename-CopilotSession, Resume-CopilotSession, Merge-CopilotSession, Compress-CopilotSession, Repair-CopilotSessionEvents -ParameterName Id -ScriptBlock {
    param($commandName, $parameterName, $wordToComplete)
    $sessionStateDir = Join-Path (Get-CopilotHome) '.copilot' 'session-state'
    if (-not (Test-Path $sessionStateDir)) { return }
    Get-ChildItem $sessionStateDir -Directory |
        Where-Object { $_.Name -like "$wordToComplete*" } |
        ForEach-Object {
            [System.Management.Automation.CompletionResult]::new($_.Name, $_.Name, 'ParameterValue', $_.Name)
        }
}

Export-ModuleMember -Function @(
    'Get-CopilotMarketplace', 'Register-CopilotMarketplace',
    'Unregister-CopilotMarketplace', 'Get-CopilotMarketplacePlugin',
    'Get-CopilotMcpServer', 'Register-CopilotMcpServer', 'Unregister-CopilotMcpServer',
    'Get-CopilotPlugin', 'Update-CopilotPlugin', 'Install-CopilotPlugin',
    'Uninstall-CopilotPlugin', 'Merge-CopilotSession', 'Compress-CopilotSession',
    'Repair-CopilotSessionEvents', 'Get-CopilotSession', 'Remove-CopilotSession',
    'Rename-CopilotSession', 'Resume-CopilotSession', 'Get-CopilotLaunchPlan', 'Start-Copilot'
)
