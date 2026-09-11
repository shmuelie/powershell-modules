<#
.SYNOPSIS
    Run the repository's Pester unit test suite.
.DESCRIPTION
    Ensures stable Pester >=6.2.0 and <7.0.0 is available, discovers every
    *.Tests.ps1 under tests/, runs them, and fails (non-zero exit / terminating
    error) if any test fails. Complements build/Test-Modules.ps1, which covers
    build/import, docs, changelog, and version-consistency validation.

    The suite targets Pester 6.2's strict parameter-filtered mock behavior.
    Prereleases and higher major versions are excluded until explicitly adopted.
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
        Where-Object {
            $_.Version -ge [version]'6.2.0' -and $_.Version -lt [version]'7.0.0' -and
            -not $_.PrivateData.PSData.Prerelease
        } |
        Sort-Object Version -Descending |
        Select-Object -First 1
}

$pester = Get-PesterModule
if (-not $pester) {
    Write-Information 'Stable Pester >=6.2.0 and <7.0.0 not found; installing from PSGallery...' -InformationAction Continue
    # Install-Module has an inclusive upper bound; cover every valid 6.x version.
    $maximumVersion = [version]::new(6, [int]::MaxValue, [int]::MaxValue, [int]::MaxValue)
    Install-Module Pester -MinimumVersion 6.2.0 -MaximumVersion $maximumVersion -Scope CurrentUser -Force
    $pester = Get-PesterModule
}
if (-not $pester) {
    throw 'Unable to locate or install stable Pester >=6.2.0 and <7.0.0.'
}

Import-Module $pester.Path -Force
Write-Information "Using Pester $($pester.Version)" -InformationAction Continue

$config = New-PesterConfiguration
$config.Run.Path = $Path
$config.Run.Throw = $true
$config.Output.Verbosity = 'Detailed'
$config.TestResult.Enabled = $false

Invoke-Pester -Configuration $config
