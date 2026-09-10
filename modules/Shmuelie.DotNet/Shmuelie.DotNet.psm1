foreach ($script in Get-ChildItem $PSScriptRoot -Filter '*.ps1' -File | Sort-Object Name) {
    . $script.FullName
}

Export-ModuleMember -Function @(
    'Get-DotNetTool',
    'Install-DotNetSdk',
    'Install-DotNetTool',
    'Update-DotNetTool',
    'Uninstall-DotNetTool'
)
