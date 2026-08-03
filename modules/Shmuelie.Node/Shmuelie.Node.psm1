$publicRoot = Join-Path $PSScriptRoot 'Public'
foreach ($script in Get-ChildItem $publicRoot -Filter '*.ps1' | Sort-Object Name) {
    . $script.FullName
}

Export-ModuleMember -Function @(
    'Get-NpmPackage', 'Update-NpmPackage', 'Get-NodeVersion', 'Install-NodeVersion',
    'Uninstall-NodeVersion', 'Set-NodeVersion', 'Set-NodeAlias', 'Remove-NodeAlias',
    'Enable-Nvm', 'Disable-Nvm', 'Set-NvmProxy', 'Set-NvmNodeMirror',
    'Set-NvmNpmMirror', 'Get-NvmRoot', 'Get-NvmVersion', 'Test-NvmInstalled',
    'Update-AdoNpmToken'
)
