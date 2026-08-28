#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.2.0' }
<#
.SYNOPSIS
    Validates that Build-Module.ps1 can be called multiple times in the same
    PowerShell process without hitting DLL-lock errors on the stage directory,
    and that no temporary shadow-copy directories are leaked to $env:TEMP.

    Regression test for GitHub issue #154: a second Build-Module call would fail
    with "access denied" trying to delete the stage directory because the binary
    module DLL was held in the parent process's non-collectible ALC.  The fix
    uses a short-lived child pwsh process for staged-module validation so that
    every DLL handle is released on child exit.
#>

BeforeAll {
    $script:repoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent
    $script:buildScript = Join-Path $script:repoRoot 'build' 'Build-Module.ps1'
    $script:tempRoot = [System.IO.Path]::GetTempPath()
}

Describe 'Build-Module repeat invocations' {
    BeforeAll {
        $script:artifacts = Join-Path $TestDrive 'artifacts'
    }

    AfterAll {
        Remove-Item $script:artifacts -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'builds Shmuelie.Git twice in the same process without DLL lock errors' {
        # Snapshot any pre-existing psmod-validate-* dirs so we can detect leaks.
        $dirsBefore = @(Get-ChildItem $script:tempRoot -Filter 'psmod-validate-*' -Directory -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty FullName)

        # First build: compiles and validates WorktreePredictor.dll in a child process.
        { & $script:buildScript -Module Shmuelie.Git -OutputPath $script:artifacts } |
            Should -Not -Throw

        # Second build must delete the previous stage dir (containing the DLL)
        # without an access-denied error.
        { & $script:buildScript -Module Shmuelie.Git -OutputPath $script:artifacts } |
            Should -Not -Throw

        # Child-process validation must not leave psmod-validate-* directories behind.
        $dirsAfter = @(Get-ChildItem $script:tempRoot -Filter 'psmod-validate-*' -Directory -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty FullName)
        @($dirsAfter | Where-Object { $_ -notin $dirsBefore }) |
            Should -BeNullOrEmpty -Because 'child-process validation leaves no psmod-validate-* temp directories'
    }

    It 'builds Shmuelie.Windows twice in the same process without DLL lock errors' -Skip:(-not $IsWindows) {
        $dirsBefore = @(Get-ChildItem $script:tempRoot -Filter 'psmod-validate-*' -Directory -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty FullName)

        # Same scenario for the Windows binary cmdlet DLLs.
        { & $script:buildScript -Module Shmuelie.Windows -OutputPath $script:artifacts } |
            Should -Not -Throw
        { & $script:buildScript -Module Shmuelie.Windows -OutputPath $script:artifacts } |
            Should -Not -Throw

        $dirsAfter = @(Get-ChildItem $script:tempRoot -Filter 'psmod-validate-*' -Directory -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty FullName)
        @($dirsAfter | Where-Object { $_ -notin $dirsBefore }) |
            Should -BeNullOrEmpty -Because 'child-process validation leaves no psmod-validate-* temp directories'
    }
}