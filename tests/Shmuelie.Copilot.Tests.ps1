#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.2.0' }

BeforeAll {
    $repoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent
    Import-Module (Join-Path $repoRoot 'modules\Shmuelie.Copilot\Shmuelie.Copilot.psd1') -Force

    $script:OriginalUserProfile = $env:USERPROFILE
    $script:OriginalPath = $env:PATH

    function Add-FakeCopilot {
        param([Parameter(Mandatory)][string]$Path)

        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        Set-Content -Path (Join-Path $Path 'copilot.cmd') -Value @(
            '@echo off'
            'if defined COPILOT_TEST_LOG echo %*>>"%COPILOT_TEST_LOG%"'
            'exit /b 0'
        )
        $copilot = Join-Path $Path 'copilot'
        Set-Content -Path $copilot -Value '#!/usr/bin/env sh'
        if (-not $IsWindows) { & chmod +x $copilot }
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

Describe 'Copilot CLI shim argument validation' {
    BeforeEach {
        $env:USERPROFILE = Join-Path $TestDrive 'home'
        New-Item -ItemType Directory -Path $env:USERPROFILE -Force | Out-Null
        $script:CopilotTestLog = Join-Path $TestDrive 'copilot.log'
        Remove-Item $script:CopilotTestLog -Force -ErrorAction SilentlyContinue
        $env:COPILOT_TEST_LOG = $script:CopilotTestLog
        Add-FakeCopilot -Path (Join-Path $TestDrive 'bin')
    }

    AfterEach {
        Remove-Item Env:\COPILOT_TEST_LOG -ErrorAction SilentlyContinue
    }

    It 'rejects an unsafe marketplace source before invoking copilot' {
        { Register-CopilotMarketplace -Source 'owner/repo&echo-bad' -Confirm:$false } |
            Should -Throw '*Unsafe Source value*'
        Test-Path $script:CopilotTestLog | Should -BeFalse
    }

    It 'allows a normal plugin source through to copilot' {
        Install-CopilotPlugin -Source 'owner/repo' -Confirm:$false

        Get-Content $script:CopilotTestLog -Raw | Should -Match 'plugin install owner/repo'
    }

    It 'rejects unsafe marketplace-derived plugin names before invoking copilot' {
        $entry = [PSCustomObject]@{
            PSTypeName   = 'CopilotMarketplaceEntry'
            Name         = 'plugin&echo-bad'
            Marketplace  = 'safe-marketplace'
            Description  = 'test'
        }

        { $entry | Install-CopilotPlugin -Confirm:$false } | Should -Throw '*Unsafe InputObject.Name value*'
        Test-Path $script:CopilotTestLog | Should -BeFalse
    }

    It 'rejects unsafe MCP command arguments before invoking copilot' {
        { Register-CopilotMcpServer -Name 'safe-server' -Command 'node' -ArgumentList 'server&echo-bad' -Confirm:$false } |
            Should -Throw '*Unsafe ArgumentList value*'
        Test-Path $script:CopilotTestLog | Should -BeFalse
    }
}

AfterAll {
    $env:USERPROFILE = $script:OriginalUserProfile
    $env:PATH = $script:OriginalPath
    Remove-Module Shmuelie.Copilot -Force -ErrorAction SilentlyContinue
}

Describe 'Get-CopilotHome' {
    It 'returns the current home directory' {
        $result = InModuleScope Shmuelie.Copilot { Get-CopilotHome }

        $result | Should -Be $HOME
        $result | Should -Not -BeNullOrEmpty
        Test-Path $result | Should -BeTrue
    }
}

Describe 'Shmuelie.Copilot source' {
    It 'does not reference the Windows-only USERPROFILE environment variable' {
        $moduleRoot = Join-Path $repoRoot 'modules\Shmuelie.Copilot'
        $matches = @(Get-ChildItem -Path $moduleRoot -Recurse -Include *.ps1, *.psm1 | Select-String -Pattern '\$env:USERPROFILE')

        $matches.Count | Should -Be 0
    }
}

Describe 'Get-CopilotLaunchPlan' {
    BeforeEach {
        $testHome = Join-Path $TestDrive 'home'
        $env:USERPROFILE = Join-Path $TestDrive 'legacy-userprofile'
        New-Item -ItemType Directory -Path $testHome -Force | Out-Null
        Mock -ModuleName Shmuelie.Copilot -CommandName Get-CopilotHome -MockWith { $testHome }
        Add-FakeCopilot -Path (Join-Path $TestDrive 'bin')
    }
    It 'auto-resumes a single matching session when SessionId is omitted' {
        $cwd = Join-Path $TestDrive 'workspace'
        New-Item -ItemType Directory -Path $cwd -Force | Out-Null
        $sessionRoot = Join-Path $testHome '.copilot' 'session-state'
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
        $sessionRoot = Join-Path $testHome '.copilot' 'session-state'
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
        $sessionRoot = Join-Path $testHome '.copilot' 'session-state'
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
