foreach ($script in Get-ChildItem $PSScriptRoot -Filter '*.ps1' -File | Sort-Object Name) {
    . $script.FullName
}

$exportedCmdlets = @()
$binaryModule = Join-Path $PSScriptRoot 'bin' 'Shmuelie.Windows.Cmdlets.dll'
if (Test-Path $binaryModule) {
    Import-Module $binaryModule -Force -ErrorAction Stop
    $exportedCmdlets = @('Get-InstalledApplications', 'Get-ServiceProcess', 'Get-SubstDrive', 'New-SubstDrive', 'Remove-SubstDrive')
}

# The App Installer cmdlets depend on the WinRT PackageManager projection, which
# requires a Windows-targeted assembly that cannot load on Linux/macOS. Load that
# second DLL only on Windows; off Windows the two cmdlets are simply absent.
if ($IsWindows) {
    $appInstallerModule = Join-Path $PSScriptRoot 'bin' 'Shmuelie.Windows.AppInstaller.dll'
    if (Test-Path $appInstallerModule) {
        Import-Module $appInstallerModule -Force -ErrorAction Stop
        $exportedCmdlets += 'Get-AppInstallerApp', 'Update-AppInstallerApp'
    }
}

$exportParams = @{
    Function = @(
        'Get-WindowsTerminalSettings', 'Get-WindowsTerminalProfile',
        'Start-WindowsPerformanceRecorder', 'Stop-WindowsPerformanceRecorder'
    )
}
if ($exportedCmdlets.Count -gt 0) {
    $exportParams.Cmdlet = $exportedCmdlets
}

Export-ModuleMember @exportParams
