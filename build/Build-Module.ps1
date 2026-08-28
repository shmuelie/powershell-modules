<#
.SYNOPSIS
    Build one independently versioned module into a publishable staging directory.
.PARAMETER Module
    Module directory name under modules/.
.PARAMETER OutputPath
    Artifact root. Defaults to artifacts/.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Shmuelie.Git', 'Shmuelie.Copilot', 'Shmuelie.Node', 'Shmuelie.Utilities', 'Shmuelie.Dsc', 'Shmuelie.VisualStudio', 'Shmuelie.Windows')]
    [string]$Module,

    [string]$OutputPath
)

function Invoke-RetryingDelete {
    # Safety net for transient lock errors (e.g. antivirus briefly holding a
    # file).  Only catches IO/access-denied errors; other errors still propagate.
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$MaxAttempts = 3,
        [int]$DelayMs = 300
    )
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            Remove-Item $Path -Recurse -Force -ErrorAction Stop
            return
        }
        catch [System.IO.IOException], [System.UnauthorizedAccessException] {
            if ($attempt -ge $MaxAttempts) { throw }
            Start-Sleep -Milliseconds $DelayMs
        }
    }
}

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$source = Join-Path $repoRoot 'modules' $Module
$manifestPath = Join-Path $source "$Module.psd1"
$manifest = Test-ModuleManifest $manifestPath

if (-not $OutputPath) {
    $OutputPath = Join-Path $repoRoot 'artifacts'
}

$stage = Join-Path $OutputPath $Module $manifest.Version
if (Test-Path $stage) {
    Invoke-RetryingDelete $stage
}
New-Item $stage -ItemType Directory -Force | Out-Null

foreach ($name in @("$Module.psd1", "$Module.psm1", 'README.md', 'CHANGELOG.md')) {
    Copy-Item (Join-Path $source $name) $stage
}
$scripts = @(Get-ChildItem $source -Filter '*.ps1' -File)
if ($scripts.Count -gt 0) {
    $scripts | Copy-Item -Destination $stage
}
if ($manifest.ExportedFunctions.Count -gt 0 -and $scripts.Count -eq 0) {
    throw "$Module declares FunctionsToExport but has no root-level script files to stage."
}
$classes = Join-Path $source 'Classes'
if (Test-Path $classes) {
    Copy-Item $classes $stage -Recurse
}
Get-ChildItem $source -Filter '*.format.ps1xml' | Copy-Item -Destination $stage

if ($Module -eq 'Shmuelie.Git') {
    $bin = Join-Path $stage 'bin'
    $predictorBuild = Join-Path $OutputPath '.predictor-build'
    if (Test-Path $predictorBuild) {
        Remove-Item $predictorBuild -Recurse -Force
    }
    New-Item $bin -ItemType Directory -Force | Out-Null
    dotnet build (Join-Path $source 'Predictor' 'WorktreePredictor.csproj') `
        --configuration Release `
        --output $predictorBuild `
        --nologo
    if ($LASTEXITCODE -ne 0) {
        throw 'WorktreePredictor build failed.'
    }
    Copy-Item (Join-Path $predictorBuild 'WorktreePredictor.dll') $bin
    Remove-Item $predictorBuild -Recurse -Force
}

if ($Module -eq 'Shmuelie.Windows') {
    $bin = Join-Path $stage 'bin'
    $cmdletsBuild = Join-Path $OutputPath '.windows-cmdlets-build'
    if (Test-Path $cmdletsBuild) {
        Remove-Item $cmdletsBuild -Recurse -Force
    }
    New-Item $bin -ItemType Directory -Force | Out-Null
    dotnet build (Join-Path $source 'Cmdlets' 'Shmuelie.Windows.Cmdlets.csproj') `
        --configuration Release `
        --output $cmdletsBuild `
        --nologo
    if ($LASTEXITCODE -ne 0) {
        throw 'Shmuelie.Windows.Cmdlets build failed.'
    }
    Copy-Item (Join-Path $cmdletsBuild 'Shmuelie.Windows.Cmdlets.dll') $bin
    Remove-Item $cmdletsBuild -Recurse -Force

    $appInstallerBuild = Join-Path $OutputPath '.windows-appinstaller-build'
    if (Test-Path $appInstallerBuild) {
        Remove-Item $appInstallerBuild -Recurse -Force
    }
    # Publish (not build) so the WinRT projection runtime assemblies
    # (Microsoft.Windows.SDK.NET.dll / WinRT.Runtime.dll) are emitted alongside
    # the cmdlet assembly; a plain build leaves them out and the WinRT calls fail
    # to load at runtime.
    dotnet publish (Join-Path $source 'Cmdlets.AppInstaller' 'Shmuelie.Windows.AppInstaller.csproj') `
        --configuration Release `
        --output $appInstallerBuild `
        --nologo
    if ($LASTEXITCODE -ne 0) {
        throw 'Shmuelie.Windows.AppInstaller publish failed.'
    }
    foreach ($dll in 'Shmuelie.Windows.AppInstaller.dll', 'Microsoft.Windows.SDK.NET.dll', 'WinRT.Runtime.dll') {
        Copy-Item (Join-Path $appInstallerBuild $dll) $bin
    }
    Remove-Item $appInstallerBuild -Recurse -Force
}

# Validate the staged module in a short-lived child pwsh process so that every
# DLL file handle is released when the child exits.  The stage directory is
# never locked in the parent process, allowing a same-process rebuild to delete
# it freely without shadow copies, GC tricks, or temp-directory leakage.
# The manifest path is forwarded through an environment variable rather than
# interpolated into the command string, eliminating any path-injection risk.
$stagedManifest = Join-Path $stage "$Module.psd1"
$envKey = 'PSMOD_VALIDATE_MANIFEST'
$savedEnv = [System.Environment]::GetEnvironmentVariable($envKey)
try {
    [System.Environment]::SetEnvironmentVariable($envKey, $stagedManifest)
    $childOut = & pwsh -NoProfile -NonInteractive -Command {
        $ErrorActionPreference = 'Stop'
        Test-ModuleManifest $env:PSMOD_VALIDATE_MANIFEST -ErrorAction Stop | Out-Null
        Import-Module $env:PSMOD_VALIDATE_MANIFEST -Force -ErrorAction Stop
    } 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Staged module validation failed (exit $LASTEXITCODE):`n$($childOut -join [System.Environment]::NewLine)"
    }
} finally {
    [System.Environment]::SetEnvironmentVariable($envKey, $savedEnv)
}

Get-Item $stage