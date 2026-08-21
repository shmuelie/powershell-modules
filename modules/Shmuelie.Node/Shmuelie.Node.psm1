$publicRoot = Join-Path $PSScriptRoot 'Public'
foreach ($scriptName in @(
    'NpmHelpers.ps1',
    'NvmHelpers.ps1',
    'Update-AdoNpmToken.ps1'
)) {
    . (Join-Path $publicRoot $scriptName)
}

Export-ModuleMember -Function @(
    'Get-NpmPackage', 'Update-NpmPackage', 'Get-NodeVersion', 'Install-NodeVersion',
    'Uninstall-NodeVersion', 'Set-NodeVersion', 'Set-NodeAlias', 'Remove-NodeAlias',
    'Enable-Nvm', 'Disable-Nvm', 'Set-NvmProxy', 'Set-NvmNodeMirror',
    'Set-NvmNpmMirror', 'Get-NvmRoot', 'Get-NvmVersion', 'Test-NvmInstalled',
    'Update-AdoNpmToken'
)
