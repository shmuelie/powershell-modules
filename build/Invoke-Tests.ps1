<#
.SYNOPSIS
    Run the repository's Pester unit test suite.
.DESCRIPTION
    Ensures Pester 5.2 (or newer) is available, discovers every *.Tests.ps1 under
    tests/, runs them, and fails (non-zero exit / terminating error) if any test
    fails. Complements build/Test-Modules.ps1, which covers build/import, docs,
    changelog, and version-consistency validation.

    Pester 5.2 is the floor because the runner relies on the Run.Throw
    configuration option, which was introduced in that release.
.PARAMETER Path
    Optional path to a specific test file or directory. Defaults to tests/.
.EXAMPLE
    ./build/Invoke-Tests.ps1
    Runs the full suite.
.EXAMPLE
    ./build/Invoke-Tests.ps1 -Path tests/Shmuelie.Git.Tests.ps1
    Runs a single test file.
#>
[CmdletBinding()]
param(
    [string]$Path
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $Path) {
    $Path = Join-Path $repoRoot 'tests'
}

function Get-PesterModule {
    Get-Module -ListAvailable -Name Pester |
        Where-Object { $_.Version -ge [version]'5.2.0' } |
        Sort-Object Version -Descending |
        Select-Object -First 1
}

$pester = Get-PesterModule
if (-not $pester) {
    Write-Information 'Pester 5.2+ not found; installing from PSGallery...' -InformationAction Continue
    Install-Module Pester -MinimumVersion 5.2.0 -Scope CurrentUser -Force
    $pester = Get-PesterModule
}
if (-not $pester) {
    throw 'Unable to locate or install Pester 5.2 or newer.'
}

Import-Module $pester -Force
Write-Information "Using Pester $($pester.Version)" -InformationAction Continue

$config = New-PesterConfiguration
$config.Run.Path = $Path
$config.Run.Throw = $true
$config.Output.Verbosity = 'Detailed'
$config.TestResult.Enabled = $false

Invoke-Pester -Configuration $config
