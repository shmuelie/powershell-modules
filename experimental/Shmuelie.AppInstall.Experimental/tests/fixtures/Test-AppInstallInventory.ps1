param(
    [Parameter(Mandatory)][string]$ManifestPath,
    [Parameter(Mandatory)][string]$HelperPath
)
$ErrorActionPreference = 'Stop'
$env:PSModulePath = Join-Path $PSHOME 'Modules'
Import-Module $ManifestPath -Force -ErrorAction Stop
[Reflection.Assembly]::LoadFrom($HelperPath) | Out-Null
[Shmuelie.Windows.AppInstall.Tests.InventoryScenarios]::VerifyCommand($ManifestPath)
'Fake inventory command passed.'
