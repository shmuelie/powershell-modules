$publicRoot = Join-Path $PSScriptRoot 'Public'
foreach ($script in Get-ChildItem $publicRoot -Filter '*.ps1' | Sort-Object Name) {
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

Export-ModuleMember -Function @('Get-InstalledVsVersion', 'Start-DevShell')
