#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.2.0' }
<#
.SYNOPSIS
    Validates that Build-Module.ps1 can be called multiple times in the same
    PowerShell process without hitting DLL-lock errors on the stage directory.

    Regression test for GitHub issue #154: a second Build-Module call would fail
    with "access denied" trying to delete the stage directory because the binary
    module DLL loaded by the first build was still held by a collectible ALC
    until GC finalization.
#>

BeforeAll {
    $script:repoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent
    $script:buildScript = Join-Path $script:repoRoot 'build' 'Build-Module.ps1'
}

Describe 'Build-Module repeat invocations' {
    BeforeAll {
        $script:artifacts = Join-Path $TestDrive 'artifacts'
    }

    AfterAll {
        Remove-Item $script:artifacts -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'builds Shmuelie.Git twice in the same process without DLL lock errors' {
        # First build compiles and loads WorktreePredictor.dll.
        { & $script:buildScript -Module Shmuelie.Git -OutputPath $script:artifacts } |
            Should -Not -Throw

        # Second build must delete the previous stage dir (containing the DLL).
        # Before the fix this threw "The process cannot access the file ... because
        # it is being used by another process."
        { & $script:buildScript -Module Shmuelie.Git -OutputPath $script:artifacts } |
            Should -Not -Throw
    }

    It 'builds Shmuelie.Windows twice in the same process without DLL lock errors' -Skip:(-not $IsWindows) {
        # Same scenario for the Windows binary cmdlet DLLs.
        { & $script:buildScript -Module Shmuelie.Windows -OutputPath $script:artifacts } |
            Should -Not -Throw

        { & $script:buildScript -Module Shmuelie.Windows -OutputPath $script:artifacts } |
            Should -Not -Throw
    }
}