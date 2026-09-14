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
    $appInstallModule = Join-Path $PSScriptRoot 'bin' 'Shmuelie.Windows.AppInstall.dll'
    if (Test-Path $appInstallModule) {
        # Resolve the shipped projection in the same load context even when a
        # consumer's assembly lives elsewhere. Loading is not native activation.
        foreach ($dependency in 'WinRT.Runtime.dll', 'Microsoft.Windows.SDK.NET.dll') {
            $dependencyPath = Join-Path $PSScriptRoot 'bin' $dependency
            if (-not (Test-Path -LiteralPath $dependencyPath -PathType Leaf)) {
                throw [System.IO.FileNotFoundException]::new("The AppInstall projection dependency '$dependency' is missing.", $dependencyPath)
            }
            [System.Reflection.Assembly]::LoadFrom($dependencyPath) | Out-Null
        }
        Import-Module $appInstallModule -Force -ErrorAction Stop
        $exportedCmdlets += 'New-AppInstallContext'
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
