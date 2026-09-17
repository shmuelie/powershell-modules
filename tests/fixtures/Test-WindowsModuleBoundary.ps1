param([Parameter(Mandatory)][string]$ManifestPath)

$ErrorActionPreference = 'Stop'
$env:PSModulePath = Join-Path $PSHOME 'Modules'
$module = Import-Module $ManifestPath -Force -PassThru -ErrorAction Stop
try {
    $heldCommands = @(
        'New-AppInstallContext', 'Get-AppInstallItem', 'Get-AppInstallSettings',
        'Request-AppInstallUpdateSearch', 'Wait-AppInstallItem'
    )
    foreach ($name in $heldCommands) {
        if (Get-Command $name -ListImported -ErrorAction Ignore) {
            throw "Windows unexpectedly imported experimental command '$name'."
        }
    }
    if (@([AppDomain]::CurrentDomain.GetAssemblies() |
        Where-Object { $_.GetName().Name -eq 'Shmuelie.Windows.AppInstall' }).Count) {
        throw 'Windows loaded the experimental assembly.'
    }
    $commands = @(Get-Command -Module $module.Name -CommandType Cmdlet)
    $expected = @('Get-InstalledApplications', 'Get-ServiceProcess', 'Get-SubstDrive', 'New-SubstDrive', 'Remove-SubstDrive')
    if ($IsWindows) { $expected += 'Get-AppInstallerApp', 'Update-AppInstallerApp' }
    if (Compare-Object ($commands.Name | Sort-Object) ($expected | Sort-Object)) {
        throw 'The supported Windows command surface changed.'
    }
    'Windows supported boundary passed.'
} finally {
    Remove-Module -ModuleInfo $module -Force -ErrorAction Stop
}
