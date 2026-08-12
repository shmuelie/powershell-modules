#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.2.0' }

BeforeAll {
    $repoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent
    Import-Module (Join-Path $repoRoot 'modules\Shmuelie.Copilot\Shmuelie.Copilot.psd1') -Force

    $script:OriginalUserProfile = $env:USERPROFILE
    $script:OriginalPath = $env:PATH

    function Add-FakeCopilot {
        param([Parameter(Mandatory)][string]$Path)

        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        Set-Content -Path (Join-Path $Path 'copilot.cmd') -Value '@echo off'
        $env:PATH = "$Path$([IO.Path]::PathSeparator)$script:OriginalPath"
    }

    function New-CopilotSessionState {
        param(
            [Parameter(Mandatory)][string]$SessionRoot,
            [Parameter(Mandatory)][string]$Id,
            [Parameter(Mandatory)][string]$Cwd,
            [Parameter(Mandatory)][string]$Summary
        )

        $sessionDir = Join-Path $SessionRoot $Id
        New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
        Set-Content -Path (Join-Path $sessionDir 'workspace.yaml') -Value @(
            "cwd: $Cwd"
            'updated_at: 2026-08-12T22:00:00.000Z'
            "summary: $Summary"
        )
    }
}

AfterAll {
    $env:USERPROFILE = $script:OriginalUserProfile
    $env:PATH = $script:OriginalPath
    Remove-Module Shmuelie.Copilot -Force -ErrorAction SilentlyContinue
}

Describe 'Get-CopilotLaunchPlan' {
    BeforeEach {
        $env:USERPROFILE = Join-Path $TestDrive 'home'
        New-Item -ItemType Directory -Path $env:USERPROFILE -Force | Out-Null
        Add-FakeCopilot -Path (Join-Path $TestDrive 'bin')
    }

    It 'auto-resumes a single matching session when SessionId is omitted' {
        $cwd = Join-Path $TestDrive 'workspace'
        New-Item -ItemType Directory -Path $cwd -Force | Out-Null
        $sessionRoot = Join-Path $env:USERPROFILE '.copilot\session-state'
        $existingSessionId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        New-CopilotSessionState `
            -SessionRoot $sessionRoot `
            -Id $existingSessionId `
            -Cwd $cwd `
            -Summary 'Existing session'

        Push-Location $cwd
        try {
            $plan = Get-CopilotLaunchPlan
        } finally {
            Pop-Location
        }

        $resumeArg = [array]::IndexOf($plan.Args, '--resume')
        $resumeArg | Should -BeGreaterOrEqual 0
        $plan.Args[$resumeArg + 1] | Should -Be $existingSessionId
    }

    It 'maps SessionId to --session-id without adding an auto-resume argument' {
        $cwd = Join-Path $TestDrive 'workspace'
        New-Item -ItemType Directory -Path $cwd -Force | Out-Null
        $sessionRoot = Join-Path $env:USERPROFILE '.copilot\session-state'
        New-CopilotSessionState `
            -SessionRoot $sessionRoot `
            -Id 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' `
            -Cwd $cwd `
            -Summary 'Existing session'

        $sessionId = '11111111-2222-3333-4444-555555555555'
        Push-Location $cwd
        try {
            $plan = Get-CopilotLaunchPlan -SessionId $sessionId
        } finally {
            Pop-Location
        }

        $sessionIdArg = [array]::IndexOf($plan.Args, '--session-id')
        $sessionIdArg | Should -BeGreaterOrEqual 0
        $plan.Args[$sessionIdArg + 1] | Should -Be $sessionId
        $plan.Args | Should -Not -Contain '--resume'
    }

    It 'maps SessionId to --session-id without invoking the multi-session picker' {
        $cwd = Join-Path $TestDrive 'workspace'
        New-Item -ItemType Directory -Path $cwd -Force | Out-Null
        $sessionRoot = Join-Path $env:USERPROFILE '.copilot\session-state'
        New-CopilotSessionState `
            -SessionRoot $sessionRoot `
            -Id 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' `
            -Cwd $cwd `
            -Summary 'First existing session'
        New-CopilotSessionState `
            -SessionRoot $sessionRoot `
            -Id 'ffffffff-1111-2222-3333-444444444444' `
            -Cwd $cwd `
            -Summary 'Second existing session'

        $sessionId = '11111111-2222-3333-4444-555555555555'
        Push-Location $cwd
        try {
            $plan = Get-CopilotLaunchPlan -SessionId $sessionId
        } finally {
            Pop-Location
        }

        $sessionIdArg = [array]::IndexOf($plan.Args, '--session-id')
        $sessionIdArg | Should -BeGreaterOrEqual 0
        $plan.Args[$sessionIdArg + 1] | Should -Be $sessionId
        $plan.Args | Should -Not -Contain '--resume'
    }
}
