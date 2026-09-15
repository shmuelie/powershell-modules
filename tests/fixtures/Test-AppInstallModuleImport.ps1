param(
    [Parameter(Mandatory)][string]$ManifestPath,
    [switch]$SimulateNonWindows,
    [string]$ExpectedMissingDependency
)

$ErrorActionPreference = 'Stop'
$env:PSModulePath = Join-Path $PSHOME 'Modules'
if ($SimulateNonWindows) {
    # Exercise the loader branch, not a claim of native Linux/macOS execution.
    Set-Variable -Name IsWindows -Value $false -Scope Global -Force
}
if ($ExpectedMissingDependency) {
    try { Import-Module $ManifestPath -Force -ErrorAction Stop }
    catch [System.IO.FileNotFoundException] {
        if ($_.Exception.Message -notlike "*'$ExpectedMissingDependency' is missing.*") { throw }
        [PSCustomObject]@{ MissingDependency = $ExpectedMissingDependency } | ConvertTo-Json -Compress
        return
    }
    throw "The module imported without the required projection dependency '$ExpectedMissingDependency'."
}
Import-Module $ManifestPath -Force -ErrorAction Stop
$command = @(Get-Command -Module Shmuelie.Windows -CommandType Cmdlet |
    Where-Object Name -In 'New-AppInstallContext', 'Get-AppInstallItem', 'Get-AppInstallSettings', 'Request-AppInstallUpdateSearch', 'Wait-AppInstallItem')
$assemblyLoaded = @([AppDomain]::CurrentDomain.GetAssemblies() |
    Where-Object { $_.GetName().Name -eq 'Shmuelie.Windows.AppInstall' }).Count -ne 0
$projectionLoaded = @([AppDomain]::CurrentDomain.GetAssemblies() |
    Where-Object { $_.GetName().Name -in 'Microsoft.Windows.SDK.NET', 'WinRT.Runtime' }).Count

if ($SimulateNonWindows) {
    if ($command.Count -ne 0 -or $assemblyLoaded -or $projectionLoaded -ne 0) {
        throw 'The portable loader imported Windows-only AppInstall behavior.'
    }
    [PSCustomObject]@{ CommandCount = 0; AssemblyLoaded = $false; SimulatedPlatform = $true } |
        ConvertTo-Json -Compress
    return
}

if ($command.Count -ne 5) { throw 'The compiled context factory, both readers, paused search and bounded observation were not exported.' }
if ($projectionLoaded -ne 2) { throw 'The shipped WinRT projection dependencies were not loaded.' }
$context = New-AppInstallContext
try {
    if ($context.IsActivated) { throw 'Context creation unexpectedly activated the native manager.' }
    $help = Get-Help New-AppInstallContext -Full
    if (($help.description.Text -join ' ') -notmatch 'private capability restricted to Microsoft-developed apps') {
        throw 'The native access restriction is missing from compiled command help.'
    }
    $settingsHelp = Get-Help Get-AppInstallSettings -Full
    if (($settingsHelp.description.Text -join ' ') -notmatch 'AcquisitionIdentity is not read by default' -or
        ($settingsHelp.description.Text -join ' ') -notmatch 'private capability restricted to Microsoft-developed apps' -or
        ($settingsHelp.parameters.parameter | Where-Object Name -EQ 'Context').required -ne 'true') {
        throw 'Settings reader help must document explicit context, privacy and native access restrictions.'
    }
    $searchHelp = Get-Help Request-AppInstallUpdateSearch -Full
    if (($searchHelp.description.Text -join ' ') -notmatch 'queue mutation' -or
        ($searchHelp.parameters.parameter | Where-Object Name -EQ 'Context').required -ne 'true') {
        throw 'Update search help must document the queue mutation and explicit context.'
    }
    Remove-Module Shmuelie.Windows -Force -ErrorAction Stop
    if ($context.IsDisposed -or $context.IsActivated) {
        throw 'Removing the module changed caller-owned lazy context lifetime.'
    }
    [PSCustomObject]@{
        CommandCount = $command.Count
        AssemblyLoaded = $assemblyLoaded
        IsActivated = $context.IsActivated
        HelpAvailable = $true
        SettingsHelpAvailable = $true
        SearchHelpAvailable = $true
        SurvivesModuleRemoval = $true
        SimulatedPlatform = $false
    } | ConvertTo-Json -Compress
}
finally {
    $context.Dispose()
}
