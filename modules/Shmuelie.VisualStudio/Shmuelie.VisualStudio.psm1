foreach ($script in Get-ChildItem $PSScriptRoot -Filter '*.ps1' -File | Sort-Object Name) {
    . $script.FullName
}

Register-ArgumentCompleter -CommandName Start-DevShell -ParameterName Version -ScriptBlock {
    param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)

    try {
        Get-InstalledVsVersion |
            Where-Object { "$_" -like "$wordToComplete*" } |
            ForEach-Object {
                [System.Management.Automation.CompletionResult]::new("$_", "$_", 'ParameterValue', "Visual Studio $_")
            }
    } catch {
        @()
    }
}

Export-ModuleMember -Function @('Get-InstalledVsVersion', 'Resolve-MSBuild', 'Set-VS2017', 'Set-VS2019', 'Set-VS2022', 'Set-VS2026', 'Start-DevShell')
