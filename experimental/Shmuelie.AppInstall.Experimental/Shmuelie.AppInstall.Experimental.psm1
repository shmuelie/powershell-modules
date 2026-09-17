$exportedCmdlets = @()
if ($IsWindows) {
    $binary = Join-Path $PSScriptRoot 'bin' 'Shmuelie.Windows.AppInstall.dll'
    if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) {
        throw [System.IO.FileNotFoundException]::new('The experimental AppInstall assembly is missing. Build it explicitly only after validation is authorized.', $binary)
    }
    # Keep projection loading in the original context; loading is not activation.
    foreach ($dependency in 'WinRT.Runtime.dll', 'Microsoft.Windows.SDK.NET.dll') {
        $dependencyPath = Join-Path $PSScriptRoot 'bin' $dependency
        if (-not (Test-Path -LiteralPath $dependencyPath -PathType Leaf)) {
            throw [System.IO.FileNotFoundException]::new("The AppInstall projection dependency '$dependency' is missing.", $dependencyPath)
        }
        [System.Reflection.Assembly]::LoadFrom($dependencyPath) | Out-Null
    }
    Import-Module $binary -Force -ErrorAction Stop
    $exportedCmdlets = @(
        'New-AppInstallContext', 'Get-AppInstallItem', 'Get-AppInstallSettings',
        'Request-AppInstallUpdateSearch', 'Wait-AppInstallItem'
    )
}
Export-ModuleMember -Function @() -Cmdlet $exportedCmdlets -Alias @() -Variable @()
