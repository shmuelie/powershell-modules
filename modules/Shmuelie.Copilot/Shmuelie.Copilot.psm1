$publicRoot = Join-Path $PSScriptRoot 'Public'
foreach ($script in Get-ChildItem $publicRoot -Filter '*.ps1' | Sort-Object Name) {
    . $script.FullName
}

Set-Alias -Name copilot -Value Start-Copilot

Register-ArgumentCompleter -CommandName Get-CopilotSession, Remove-CopilotSession, Rename-CopilotSession, Resume-CopilotSession, Merge-CopilotSession, Compress-CopilotSession, Repair-CopilotSessionEvents -ParameterName Id -ScriptBlock {
    param($commandName, $parameterName, $wordToComplete)
    $sessionStateDir = Join-Path $env:USERPROFILE '.copilot\session-state'
    if (-not (Test-Path $sessionStateDir)) { return }
    Get-ChildItem $sessionStateDir -Directory |
        Where-Object { $_.Name -like "$wordToComplete*" } |
        ForEach-Object {
            [System.Management.Automation.CompletionResult]::new($_.Name, $_.Name, 'ParameterValue', $_.Name)
        }
}

Register-ArgumentCompleter -CommandName Start-Copilot -ParameterName AgencyProfile -ScriptBlock {
    param($commandName, $parameterName, $wordToComplete)
    try {
        Get-AgencyProfile |
            Where-Object { $_.Name -like "$wordToComplete*" } |
            ForEach-Object {
                [System.Management.Automation.CompletionResult]::new($_.Name, $_.Name, 'ParameterValue', $_.Name)
            }
    } catch {
    }
}

Export-ModuleMember -Function @(
    'Register-AgencyMarketplace',
    'Get-AgencyPlugin', 'Install-AgencyPlugin', 'Uninstall-AgencyPlugin',
    'Get-AgencyPluginCache', 'Clear-AgencyPluginCache', 'Remove-AgencyPluginCache',
    'Optimize-AgencyPluginCache', 'Get-AgencyProfilePath', 'Get-AgencyGlobalConfigPath',
    'Get-AgencyProfile', 'Update-AgencyProfile', 'Add-AgencyProfilePlugin',
    'Remove-AgencyProfilePlugin', 'Get-CopilotMarketplace', 'Register-CopilotMarketplace',
    'Unregister-CopilotMarketplace', 'Get-CopilotMarketplacePlugin',
    'Get-CopilotMcpServer', 'Register-CopilotMcpServer', 'Unregister-CopilotMcpServer',
    'Get-CopilotPlugin', 'Update-CopilotPlugin', 'Install-CopilotPlugin',
    'Uninstall-CopilotPlugin', 'Merge-CopilotSession', 'Compress-CopilotSession',
    'Repair-CopilotSessionEvents', 'Get-CopilotSession', 'Remove-CopilotSession',
    'Rename-CopilotSession', 'Resume-CopilotSession', 'Start-Copilot'
) -Alias 'copilot'
