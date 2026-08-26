$publicRoot = Join-Path $PSScriptRoot 'Public'
foreach ($script in Get-ChildItem $publicRoot -Filter '*.ps1' | Sort-Object Name) {
    . $script.FullName
}

$exportedCmdlets = @()
$binaryModule = Join-Path $PSScriptRoot 'bin\Shmuelie.Windows.Cmdlets.dll'
if (Test-Path $binaryModule) {
    Import-Module $binaryModule -Force -ErrorAction Stop
    $exportedCmdlets = @('Get-InstalledApplications', 'Get-ServiceProcess', 'Get-SubstDrive', 'New-SubstDrive', 'Remove-SubstDrive')
}

$exportParams = @{
    Function = @(
        'Get-AppInstallerApp',
        'Get-WindowsTerminalSettings', 'Get-WindowsTerminalProfile',
        'Start-WindowsPerformanceRecorder', 'Stop-WindowsPerformanceRecorder',
        'Update-AppInstallerApp'
    )
}
if ($exportedCmdlets.Count -gt 0) {
    $exportParams.Cmdlet = $exportedCmdlets
}

Export-ModuleMember @exportParams
