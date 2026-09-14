param(
    [Parameter(Mandatory)][string]$ManifestPath,
    [switch]$SimulateNonWindows
)

$ErrorActionPreference = 'Stop'
$env:PSModulePath = Join-Path $PSHOME 'Modules'
if ($SimulateNonWindows) {
    # Exercise the loader branch, not a claim of native Linux/macOS execution.
    Set-Variable -Name IsWindows -Value $false -Scope Global -Force
}
Import-Module $ManifestPath -Force -ErrorAction Stop
$command = @(Get-Command -Module Shmuelie.Windows -CommandType Cmdlet |
    Where-Object Name -EQ 'New-AppInstallContext')
$assemblyLoaded = @([AppDomain]::CurrentDomain.GetAssemblies() |
    Where-Object { $_.GetName().Name -eq 'Shmuelie.Windows.AppInstall' }).Count -ne 0

if ($SimulateNonWindows) {
    if ($command.Count -ne 0 -or $assemblyLoaded) {
        throw 'The portable loader imported Windows-only AppInstall behavior.'
    }
    [PSCustomObject]@{ CommandCount = 0; AssemblyLoaded = $false; SimulatedPlatform = $true } |
        ConvertTo-Json -Compress
    return
}

if ($command.Count -ne 1) { throw 'The compiled context factory was not exported.' }
$context = New-AppInstallContext
try {
    if ($context.IsActivated) { throw 'Context creation unexpectedly activated the native manager.' }
    $help = Get-Help New-AppInstallContext -Full
    if (($help.description.Text -join ' ') -notmatch 'private capability restricted to Microsoft-developed apps') {
        throw 'The native access restriction is missing from compiled command help.'
    }
    [PSCustomObject]@{
        CommandCount = $command.Count
        AssemblyLoaded = $assemblyLoaded
        IsActivated = $context.IsActivated
        HelpAvailable = $true
        SimulatedPlatform = $false
    } | ConvertTo-Json -Compress
}
finally {
    $context.Dispose()
    Remove-Module Shmuelie.Windows -Force
}
