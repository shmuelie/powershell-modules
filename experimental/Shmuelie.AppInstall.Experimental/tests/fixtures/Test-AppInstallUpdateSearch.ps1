param(
    [Parameter(Mandatory)][string]$ManifestPath,
    [Parameter(Mandatory)][string]$HelperPath,
    [switch]$ReportFormatting
)
$ErrorActionPreference = 'Stop'
$env:PSModulePath = Join-Path $PSHOME 'Modules'
Import-Module $ManifestPath -Force -ErrorAction Stop
[System.Reflection.Assembly]::LoadFrom($HelperPath) | Out-Null
$request = [Shmuelie.Windows.AppInstall.Tests.UpdateSearchScenarios]::VerifyCommand($ManifestPath)
if ($ReportFormatting) {
    [PSCustomObject]@{
        DefaultOutput = $request | Out-String -Width 4096
        DeserializedDefaultOutput = [System.Management.Automation.PSSerializer]::Deserialize(
            [System.Management.Automation.PSSerializer]::Serialize($request)) | Out-String -Width 4096
        ExplicitOutput = $request | Format-List * | Out-String -Width 4096
        CorrelationVector = $request.CorrelationVector
        ClientId = $request.ClientId
        Json = [System.Text.Json.JsonSerializer]::Serialize($request, $request.GetType(), [System.Text.Json.JsonSerializerOptions]::new())
    } | ConvertTo-Json -Depth 5 -Compress
    return
}
'Fake update search command passed.'
