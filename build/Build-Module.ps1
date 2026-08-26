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

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$source = Join-Path $repoRoot "modules\$Module"
$manifestPath = Join-Path $source "$Module.psd1"
$manifest = Test-ModuleManifest $manifestPath

if (-not $OutputPath) {
    $OutputPath = Join-Path $repoRoot 'artifacts'
}

$stage = Join-Path $OutputPath $Module $manifest.Version
if (Test-Path $stage) {
    Remove-Item $stage -Recurse -Force
}
New-Item $stage -ItemType Directory -Force | Out-Null

foreach ($name in @("$Module.psd1", "$Module.psm1", 'README.md', 'CHANGELOG.md')) {
    Copy-Item (Join-Path $source $name) $stage
}
$public = Join-Path $source 'Public'
if (Test-Path $public) {
    Copy-Item $public $stage -Recurse
}
if ($manifest.ExportedFunctions.Count -gt 0 -and -not (Test-Path $public)) {
    throw "$Module declares FunctionsToExport but has no Public folder to stage."
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
    dotnet build (Join-Path $source 'Predictor\WorktreePredictor.csproj') `
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
    dotnet build (Join-Path $source 'Cmdlets\Shmuelie.Windows.Cmdlets.csproj') `
        --configuration Release `
        --output $cmdletsBuild `
        --nologo
    if ($LASTEXITCODE -ne 0) {
        throw 'Shmuelie.Windows.Cmdlets build failed.'
    }
    Copy-Item (Join-Path $cmdletsBuild 'Shmuelie.Windows.Cmdlets.dll') $bin
    Remove-Item $cmdletsBuild -Recurse -Force
}

$stagedManifest = Join-Path $stage "$Module.psd1"
Test-ModuleManifest $stagedManifest -ErrorAction Stop | Out-Null
Import-Module $stagedManifest -Force -ErrorAction Stop
Remove-Module $Module -Force -ErrorAction Stop

Get-Item $stage
