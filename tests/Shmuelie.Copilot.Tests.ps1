#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.2.0' }

BeforeAll {
    $repoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent
    Import-Module (Join-Path $repoRoot 'modules\Shmuelie.Copilot\Shmuelie.Copilot.psd1') -Force

    $script:OriginalUserProfile = $env:USERPROFILE
    $script:OriginalPath = $env:PATH

    function Add-FakeCopilot {
        param([Parameter(Mandatory)][string]$Path)

        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        $pwsh = (Get-Process -Id $PID).Path -replace '"', '""'
        Set-Content -Path (Join-Path $Path 'copilot.cmd') -Value @(
            '@echo off'
            'if defined COPILOT_TEST_LOG echo %*>>"%COPILOT_TEST_LOG%"'
            "if defined COPILOT_TEST_STDOUT `"$pwsh`" -NoLogo -NoProfile -NonInteractive -Command `"[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new(`$false); [Console]::Out.Write(`$env:COPILOT_TEST_STDOUT)`""
            'exit /b 0'
        )
        $copilot = Join-Path $Path 'copilot'
        Set-Content -Path $copilot -Value @(
            '#!/usr/bin/env sh'
            'if [ -n "$COPILOT_TEST_LOG" ]; then printf "%s\n" "$*" >> "$COPILOT_TEST_LOG"; fi'
            'if [ -n "$COPILOT_TEST_STDOUT" ]; then printf "%s" "$COPILOT_TEST_STDOUT"; fi'
            'exit 0'
        )
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

Describe 'Invoke-WithUtf8Console' {
    It 'sets UTF-8 while running the script block and restores the previous encoding' {
        $originalEncoding = [Console]::OutputEncoding
        $legacyEncoding = [System.Text.Encoding]::GetEncoding(28591)

        try {
            [Console]::OutputEncoding = $legacyEncoding

            $insideCodePage = InModuleScope Shmuelie.Copilot {
                Invoke-WithUtf8Console { [Console]::OutputEncoding.CodePage }
            }

            $insideCodePage | Should -Be 65001
            [Console]::OutputEncoding.CodePage | Should -Be $legacyEncoding.CodePage
        } finally {
            [Console]::OutputEncoding = $originalEncoding
        }
    }

    It 'restores the previous encoding when the script block throws' {
        $originalEncoding = [Console]::OutputEncoding
        $legacyEncoding = [System.Text.Encoding]::GetEncoding(28591)

        try {
            [Console]::OutputEncoding = $legacyEncoding

            {
                InModuleScope Shmuelie.Copilot {
                    Invoke-WithUtf8Console { throw 'intentional failure' }
                }
            } | Should -Throw '*intentional failure*'

            [Console]::OutputEncoding.CodePage | Should -Be $legacyEncoding.CodePage
        } finally {
            [Console]::OutputEncoding = $originalEncoding
        }
    }
}

Describe 'Copilot CLI UTF-8 output parsing' {
    BeforeEach {
        $script:OriginalOutputEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(28591)
        $env:USERPROFILE = Join-Path $TestDrive 'home'
        New-Item -ItemType Directory -Path $env:USERPROFILE -Force | Out-Null
        $script:CopilotTestLog = Join-Path $TestDrive 'copilot.log'
        Remove-Item $script:CopilotTestLog -Force -ErrorAction SilentlyContinue
        $env:COPILOT_TEST_LOG = $script:CopilotTestLog
        Add-FakeCopilot -Path (Join-Path $TestDrive 'bin')
    }

    AfterEach {
        [Console]::OutputEncoding = $script:OriginalOutputEncoding
        Remove-Item Env:\COPILOT_TEST_LOG -ErrorAction SilentlyContinue
        Remove-Item Env:\COPILOT_TEST_STDOUT -ErrorAction SilentlyContinue
    }

    It 'parses plugin list output emitted as UTF-8 while the console starts non-UTF-8' {
        $env:COPILOT_TEST_STDOUT = "  • dotnet@test-market (v1.2.3)$([Environment]::NewLine)"

        $plugins = @(Get-CopilotPlugin)

        $plugins | Should -HaveCount 1
        $plugins[0].Name | Should -Be 'dotnet'
        $plugins[0].FullName | Should -Be 'dotnet@test-market'
        $plugins[0].Marketplace | Should -Be 'test-market'
        $plugins[0].Version | Should -Be '1.2.3'
    }

    It 'parses marketplace list output emitted as UTF-8 while the console starts non-UTF-8' {
        $env:COPILOT_TEST_STDOUT = "  ◆ curated (GitHub: github/copilot)$([Environment]::NewLine)  • local (URL: https://example.test/marketplace.json)$([Environment]::NewLine)"

        $marketplaces = @(Get-CopilotMarketplace)

        $marketplaces | Should -HaveCount 2
        $marketplaces[0].Name | Should -Be 'curated'
        $marketplaces[0].Repository | Should -Be 'github/copilot'
        $marketplaces[1].Name | Should -Be 'local'
        $marketplaces[1].Repository | Should -Be 'https://example.test/marketplace.json'
    }

    It 'parses marketplace plugin output emitted as UTF-8 while the console starts non-UTF-8' {
        $env:COPILOT_TEST_STDOUT = "  • dotnet-test - Generate deterministic .NET tests$([Environment]::NewLine)"

        $entries = @(Get-CopilotMarketplacePlugin -Name 'curated')

        $entries | Should -HaveCount 1
        $entries[0].Name | Should -Be 'dotnet-test'
        $entries[0].Description | Should -Be 'Generate deterministic .NET tests'
        $entries[0].Marketplace | Should -Be 'curated'
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

Describe 'Start-Copilot' {
    BeforeEach {
        $testHome = Join-Path $TestDrive 'home'
        $env:USERPROFILE = Join-Path $TestDrive 'legacy-userprofile'
        New-Item -ItemType Directory -Path $testHome -Force | Out-Null
        Mock -ModuleName Shmuelie.Copilot -CommandName Get-CopilotHome -MockWith { $testHome }

        $script:CopilotTestLog = Join-Path $TestDrive 'copilot.log'
        Remove-Item $script:CopilotTestLog -Force -ErrorAction SilentlyContinue
        $env:COPILOT_TEST_LOG = $script:CopilotTestLog
        Add-FakeCopilot -Path (Join-Path $TestDrive 'bin')
        $script:FakeCopilotExe = (Get-Command copilot -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source

        $script:ObservedDeferResume = @()
        Mock -ModuleName Shmuelie.Copilot -CommandName Get-CopilotLaunchPlan -MockWith {
            param([string]$Model, [switch]$DeferResume)

            $script:ObservedDeferResume += [bool]$DeferResume
            [pscustomobject]@{
                PSTypeName  = 'CopilotLaunchPlan'
                Exe         = $script:FakeCopilotExe
                Args        = @('--model', $Model)
                Passthrough = $false
            }
        }
    }

    AfterEach {
        Remove-Item Env:\COPILOT_TEST_LOG -ErrorAction SilentlyContinue
    }

    It 'defers resume while rendering WhatIf output without invoking copilot' {
        $transcriptPath = Join-Path $TestDrive 'whatif-transcript.txt'
        Start-Transcript -Path $transcriptPath | Out-Null
        try {
            Start-Copilot -Model 'gpt-5.4' -WhatIf
        } finally {
            Stop-Transcript | Out-Null
        }

        Should -Invoke -ModuleName Shmuelie.Copilot -CommandName Get-CopilotLaunchPlan -Exactly -Times 1
        $script:ObservedDeferResume | Should -HaveCount 1
        $script:ObservedDeferResume[0] | Should -BeTrue
        Test-Path $script:CopilotTestLog | Should -BeFalse

        $renderedOutput = Get-Content $transcriptPath -Raw
        $renderedOutput | Should -Match ([regex]::Escape($script:FakeCopilotExe))
        $renderedOutput | Should -Match ([regex]::Escape('--model gpt-5.4'))
    }

    It 'keeps normal launches interactive by not deferring resume by default' {
        Start-Copilot -Model 'gpt-5.4' -Confirm:$false

        Should -Invoke -ModuleName Shmuelie.Copilot -CommandName Get-CopilotLaunchPlan -Exactly -Times 1
        $script:ObservedDeferResume | Should -HaveCount 1
        $script:ObservedDeferResume[0] | Should -BeFalse
        Get-Content $script:CopilotTestLog -Raw | Should -Match ([regex]::Escape('--model gpt-5.4'))
    }
}
