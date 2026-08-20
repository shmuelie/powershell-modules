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
            [Parameter(Mandatory)][string]$Summary,
            [string]$UpdatedAt = '2026-08-12T22:00:00.000Z'
        )

        $sessionDir = Join-Path $SessionRoot $Id
        New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
        Set-Content -Path (Join-Path $sessionDir 'workspace.yaml') -Value @(
            "id: $Id"
            "cwd: $Cwd"
            "updated_at: $UpdatedAt"
            "created_at: $UpdatedAt"
            "name: $Summary"
            "summary: $Summary"
            'summary_count: 1'
        )

        $sessionDir
    }

    function New-CopilotTestEventLine {
        param(
            [Parameter(Mandatory)][string]$Type,
            [Parameter(Mandatory)][string]$Id,
            [Parameter(Mandatory)][string]$Timestamp,
            [hashtable]$Data = @{}
        )

        [ordered]@{
            type      = $Type
            id        = $Id
            timestamp = $Timestamp
            data      = $Data
        } | ConvertTo-Json -Depth 10 -Compress
    }

    function Set-CopilotTestEvents {
        param(
            [Parameter(Mandatory)][string]$SessionPath,
            [Parameter(Mandatory)][string[]]$Lines
        )

        Set-Content -Path (Join-Path $SessionPath 'events.jsonl') -Value $Lines -Encoding UTF8
    }

    function New-CopilotTestConversationEvents {
        param(
            [Parameter(Mandatory)][string]$Prefix,
            [Parameter(Mandatory)][string]$SessionId,
            [Parameter(Mandatory)][int]$Count,
            [Parameter(Mandatory)][datetimeoffset]$Start
        )

        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add((New-CopilotTestEventLine -Type 'session.start' -Id "$Prefix-start" -Timestamp $Start.ToString('o') -Data @{ sessionId = $SessionId }))
        for ($i = 1; $i -le $Count; $i++) {
            $timestamp = $Start.AddMinutes($i).ToString('o')
            $lines.Add((New-CopilotTestEventLine -Type 'user.message' -Id "$Prefix-user-$i" -Timestamp $timestamp -Data @{ content = "$Prefix user $i" }))
            $lines.Add((New-CopilotTestEventLine -Type 'assistant.message' -Id "$Prefix-assistant-$i" -Timestamp $Start.AddMinutes($i).AddSeconds(10).ToString('o') -Data @{
                content       = "$Prefix assistant $i"
                interactionId = "$Prefix-interaction-$i"
                model         = 'test-model'
            }))
            $lines.Add((New-CopilotTestEventLine -Type 'assistant.turn_end' -Id "$Prefix-end-$i" -Timestamp $Start.AddMinutes($i).AddSeconds(20).ToString('o') -Data @{}))
        }

        [string[]]$lines
    }

    function Set-CopilotTestSnapshotIndex {
        param(
            [Parameter(Mandatory)][string]$SessionPath,
            [object[]]$Snapshots = @()
        )

        $snapshotRoot = Join-Path $SessionPath 'rewind-snapshots'
        New-Item -ItemType Directory -Path $snapshotRoot -Force | Out-Null
        [ordered]@{
            version   = 1
            snapshots = @($Snapshots)
        } | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $snapshotRoot 'index.json') -Encoding UTF8
    }

    function Get-CopilotTestEventObjects {
        param([Parameter(Mandatory)][string]$SessionPath)

        Get-Content -Path (Join-Path $SessionPath 'events.jsonl') |
            Where-Object { $_.Trim() } |
            ForEach-Object { $_ | ConvertFrom-Json }
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

Describe 'Merge-CopilotSession' {
    BeforeEach {
        $testHome = Join-Path $TestDrive 'home'
        $script:SessionRoot = Join-Path $testHome '.copilot' 'session-state'
        $script:Workspace = Join-Path $TestDrive 'workspace'
        New-Item -ItemType Directory -Path $script:SessionRoot, $script:Workspace -Force | Out-Null
        Mock -ModuleName Shmuelie.Copilot -CommandName Get-CopilotHome -MockWith { $testHome }
    }

    It 'merges sessions by event chronology while tolerating missing optional files and empty snapshot indexes' {
        $laterSession = '11111111-1111-1111-1111-111111111111'
        $earlierSession = '22222222-2222-2222-2222-222222222222'
        $laterPath = New-CopilotSessionState -SessionRoot $script:SessionRoot -Id $laterSession -Cwd $script:Workspace -Summary 'Later first event' -UpdatedAt '2026-08-20T12:30:00.000Z'
        $earlierPath = New-CopilotSessionState -SessionRoot $script:SessionRoot -Id $earlierSession -Cwd $script:Workspace -Summary 'Earlier first event' -UpdatedAt '2026-08-20T12:00:00.000Z'

        Set-CopilotTestEvents -SessionPath $laterPath -Lines (New-CopilotTestConversationEvents -Prefix 'later' -SessionId $laterSession -Count 1 -Start ([datetimeoffset]'2026-08-20T12:10:00Z'))
        Set-CopilotTestEvents -SessionPath $earlierPath -Lines (New-CopilotTestConversationEvents -Prefix 'earlier' -SessionId $earlierSession -Count 1 -Start ([datetimeoffset]'2026-08-20T12:00:00Z'))
        Set-CopilotTestSnapshotIndex -SessionPath $laterPath -Snapshots @()

        New-Item -ItemType Directory -Path (Join-Path $earlierPath 'checkpoints') -Force | Out-Null
        Set-Content -Path (Join-Path $earlierPath 'checkpoints' 'index.md') -Value @(
            '# Checkpoint History'
            '| # | Title | File |'
            '|---|-------|------|'
            '| 9 | Older checkpoint | checkpoint-9.json |'
        )

        $merged = Merge-CopilotSession -Id $laterSession, $earlierSession -Confirm:$false

        $merged | Should -Not -BeNullOrEmpty
        Test-Path (Join-Path $merged.Path 'events.jsonl') | Should -BeTrue
        Test-Path (Join-Path $merged.Path 'rewind-snapshots' 'index.json') | Should -BeTrue
        Test-Path (Join-Path $merged.Path 'files') | Should -BeTrue
        Test-Path (Join-Path $merged.Path 'research') | Should -BeTrue

        $events = @(Get-CopilotTestEventObjects -SessionPath $merged.Path)
        @($events | Where-Object type -EQ 'session.start') | Should -HaveCount 1
        @($events | Where-Object type -EQ 'user.message' | ForEach-Object { $_.data.content }) | Should -Be @('earlier user 1', 'later user 1')
        Get-Content (Join-Path $merged.Path 'checkpoints' 'index.md') | Should -Contain '| 1 | Older checkpoint | checkpoint-9.json |'

        $snapshotIndex = Get-Content (Join-Path $merged.Path 'rewind-snapshots' 'index.json') -Raw | ConvertFrom-Json
        @($snapshotIndex.snapshots) | Should -HaveCount 0
    }

    It 'honors WhatIf without creating a merged session or deleting sources' {
        $first = '33333333-3333-3333-3333-333333333333'
        $second = '44444444-4444-4444-4444-444444444444'
        $firstPath = New-CopilotSessionState -SessionRoot $script:SessionRoot -Id $first -Cwd $script:Workspace -Summary 'First'
        $secondPath = New-CopilotSessionState -SessionRoot $script:SessionRoot -Id $second -Cwd $script:Workspace -Summary 'Second'
        Set-CopilotTestEvents -SessionPath $firstPath -Lines (New-CopilotTestConversationEvents -Prefix 'first' -SessionId $first -Count 1 -Start ([datetimeoffset]'2026-08-20T13:00:00Z'))
        Set-CopilotTestEvents -SessionPath $secondPath -Lines (New-CopilotTestConversationEvents -Prefix 'second' -SessionId $second -Count 1 -Start ([datetimeoffset]'2026-08-20T13:10:00Z'))
        $beforeDirs = @(Get-ChildItem -Path $script:SessionRoot -Directory | Select-Object -ExpandProperty Name | Sort-Object)

        $result = Merge-CopilotSession -Id $first, $second -RemoveSource -WhatIf

        $result | Should -BeNullOrEmpty
        @(Get-ChildItem -Path $script:SessionRoot -Directory | Select-Object -ExpandProperty Name | Sort-Object) | Should -Be $beforeDirs
        Test-Path $firstPath | Should -BeTrue
        Test-Path $secondPath | Should -BeTrue
    }

    It 'removes source sessions only after a successful RemoveSource merge' {
        $first = '55555555-5555-5555-5555-555555555555'
        $second = '66666666-6666-6666-6666-666666666666'
        $firstPath = New-CopilotSessionState -SessionRoot $script:SessionRoot -Id $first -Cwd $script:Workspace -Summary 'First'
        $secondPath = New-CopilotSessionState -SessionRoot $script:SessionRoot -Id $second -Cwd $script:Workspace -Summary 'Second'
        Set-CopilotTestEvents -SessionPath $firstPath -Lines (New-CopilotTestConversationEvents -Prefix 'first' -SessionId $first -Count 1 -Start ([datetimeoffset]'2026-08-20T14:00:00Z'))
        Set-CopilotTestEvents -SessionPath $secondPath -Lines (New-CopilotTestConversationEvents -Prefix 'second' -SessionId $second -Count 1 -Start ([datetimeoffset]'2026-08-20T14:10:00Z'))

        $merged = Merge-CopilotSession -Id $first, $second -RemoveSource -Confirm:$false

        $merged | Should -Not -BeNullOrEmpty
        Test-Path $merged.Path | Should -BeTrue
        Test-Path $firstPath | Should -BeFalse
        Test-Path $secondPath | Should -BeFalse

        $third = '77777777-7777-7777-7777-777777777777'
        $fourth = '88888888-8888-8888-8888-888888888888'
        $thirdPath = New-CopilotSessionState -SessionRoot $script:SessionRoot -Id $third -Cwd $script:Workspace -Summary 'Third'
        $otherWorkspace = Join-Path $TestDrive 'other-workspace'
        New-Item -ItemType Directory -Path $otherWorkspace -Force | Out-Null
        $fourthPath = New-CopilotSessionState -SessionRoot $script:SessionRoot -Id $fourth -Cwd $otherWorkspace -Summary 'Fourth'

        $failed = Merge-CopilotSession -Id $third, $fourth -RemoveSource -Confirm:$false -ErrorAction SilentlyContinue

        $failed | Should -BeNullOrEmpty
        Test-Path $thirdPath | Should -BeTrue
        Test-Path $fourthPath | Should -BeTrue
    }
}

Describe 'Compress-CopilotSession' {
    BeforeEach {
        $testHome = Join-Path $TestDrive 'home'
        $script:SessionRoot = Join-Path $testHome '.copilot' 'session-state'
        $script:Workspace = Join-Path $TestDrive 'workspace'
        New-Item -ItemType Directory -Path $script:SessionRoot, $script:Workspace -Force | Out-Null
        Mock -ModuleName Shmuelie.Copilot -CommandName Get-CopilotHome -MockWith { $testHome }
    }

    It 'compacts to the requested recent conversations without requiring snapshot metadata' {
        $sessionId = '99999999-9999-9999-9999-999999999999'
        $sessionPath = New-CopilotSessionState -SessionRoot $script:SessionRoot -Id $sessionId -Cwd $script:Workspace -Summary 'Compact me'
        Set-CopilotTestEvents -SessionPath $sessionPath -Lines (New-CopilotTestConversationEvents -Prefix 'compact' -SessionId $sessionId -Count 4 -Start ([datetimeoffset]'2026-08-20T15:00:00Z'))

        Compress-CopilotSession -Id $sessionId -Keep 2 -NoBackup -Confirm:$false

        $events = @(Get-CopilotTestEventObjects -SessionPath $sessionPath)
        @($events | Where-Object type -EQ 'session.start') | Should -HaveCount 1
        @($events | Where-Object type -EQ 'user.message' | ForEach-Object { $_.data.content }) | Should -Be @('compact user 3', 'compact user 4')
        Test-Path (Join-Path $sessionPath 'events.jsonl.bak') | Should -BeFalse
    }

    It 'honors WhatIf without rewriting events, creating backups, or pruning empty snapshot indexes' {
        $sessionId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        $sessionPath = New-CopilotSessionState -SessionRoot $script:SessionRoot -Id $sessionId -Cwd $script:Workspace -Summary 'WhatIf compact'
        Set-CopilotTestEvents -SessionPath $sessionPath -Lines (New-CopilotTestConversationEvents -Prefix 'whatif' -SessionId $sessionId -Count 3 -Start ([datetimeoffset]'2026-08-20T16:00:00Z'))
        Set-CopilotTestSnapshotIndex -SessionPath $sessionPath -Snapshots @()
        $eventsFile = Join-Path $sessionPath 'events.jsonl'
        $snapshotFile = Join-Path $sessionPath 'rewind-snapshots' 'index.json'
        $beforeEvents = Get-Content $eventsFile -Raw
        $beforeSnapshots = Get-Content $snapshotFile -Raw

        Compress-CopilotSession -Id $sessionId -Keep 1 -WhatIf

        Get-Content $eventsFile -Raw | Should -Be $beforeEvents
        Get-Content $snapshotFile -Raw | Should -Be $beforeSnapshots
        Test-Path (Join-Path $sessionPath 'events.jsonl.bak') | Should -BeFalse
    }
}

Describe 'Repair-CopilotSessionEvents' {
    BeforeEach {
        $testHome = Join-Path $TestDrive 'home'
        $script:SessionRoot = Join-Path $testHome '.copilot' 'session-state'
        $script:Workspace = Join-Path $TestDrive 'workspace'
        New-Item -ItemType Directory -Path $script:SessionRoot, $script:Workspace -Force | Out-Null
        Mock -ModuleName Shmuelie.Copilot -CommandName Get-CopilotHome -MockWith { $testHome }
    }

    It 'relocates out-of-order tool events, removes warnings, and synthesizes missing completions' {
        $lines = @(
            (New-CopilotTestEventLine -Type 'session.start' -Id 'repair-start' -Timestamp '2026-08-20T17:00:00Z' -Data @{ sessionId = 'repair-session' })
            (New-CopilotTestEventLine -Type 'tool.execution_complete' -Id 'complete-before-request' -Timestamp '2026-08-20T17:00:01Z' -Data @{ toolCallId = 'tool-1'; model = 'test-model'; interactionId = 'repair-1'; success = $true; result = @{ content = 'done' } })
            (New-CopilotTestEventLine -Type 'session.warning' -Id 'warning' -Timestamp '2026-08-20T17:00:02Z' -Data @{ message = 'remove me' })
            (New-CopilotTestEventLine -Type 'assistant.message' -Id 'assistant-tool-1' -Timestamp '2026-08-20T17:00:03Z' -Data @{ interactionId = 'repair-1'; model = 'test-model'; toolRequests = @(@{ toolCallId = 'tool-1' }) })
            (New-CopilotTestEventLine -Type 'assistant.message' -Id 'assistant-tool-2' -Timestamp '2026-08-20T17:00:04Z' -Data @{ interactionId = 'repair-2'; model = 'test-model'; toolRequests = @(@{ toolCallId = 'tool-2' }) })
            (New-CopilotTestEventLine -Type 'assistant.turn_end' -Id 'turn-end' -Timestamp '2026-08-20T17:00:05Z' -Data @{})
        )

        $repaired = @(Repair-CopilotSessionEvents -EventLines $lines)
        $events = @($repaired | ForEach-Object { $_ | ConvertFrom-Json })

        $events.type | Should -Not -Contain 'session.warning'
        [array]::IndexOf($events.id, 'assistant-tool-1') | Should -BeLessThan ([array]::IndexOf($events.id, 'complete-before-request'))
        @($events | Where-Object { $_.type -eq 'tool.execution_complete' -and $_.data.toolCallId -eq 'tool-2' }) | Should -HaveCount 1
    }

    It 'honors WhatIf without rewriting or backing up file-backed repairs' {
        $sessionId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
        $sessionPath = New-CopilotSessionState -SessionRoot $script:SessionRoot -Id $sessionId -Cwd $script:Workspace -Summary 'Repair WhatIf'
        Set-CopilotTestEvents -SessionPath $sessionPath -Lines @(
            (New-CopilotTestEventLine -Type 'session.start' -Id 'whatif-repair-start' -Timestamp '2026-08-20T18:00:00Z' -Data @{ sessionId = $sessionId })
            (New-CopilotTestEventLine -Type 'session.warning' -Id 'whatif-warning' -Timestamp '2026-08-20T18:00:01Z' -Data @{ message = 'would be removed' })
        )
        $eventsFile = Join-Path $sessionPath 'events.jsonl'
        $before = Get-Content $eventsFile -Raw

        Repair-CopilotSessionEvents -Path $sessionPath -WhatIf

        Get-Content $eventsFile -Raw | Should -Be $before
        Test-Path (Join-Path $sessionPath 'events.jsonl.bak') | Should -BeFalse
    }
}

Describe 'Copilot session maintenance round trip' {
    BeforeEach {
        $testHome = Join-Path $TestDrive 'home'
        $script:SessionRoot = Join-Path $testHome '.copilot' 'session-state'
        $script:Workspace = Join-Path $TestDrive 'workspace'
        New-Item -ItemType Directory -Path $script:SessionRoot, $script:Workspace -Force | Out-Null
        Mock -ModuleName Shmuelie.Copilot -CommandName Get-CopilotHome -MockWith { $testHome }
    }

    It 'keeps events.jsonl as valid line-delimited JSON after merge, compact, and repair' {
        $first = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
        $second = 'dddddddd-dddd-dddd-dddd-dddddddddddd'
        $firstPath = New-CopilotSessionState -SessionRoot $script:SessionRoot -Id $first -Cwd $script:Workspace -Summary 'Round trip first'
        $secondPath = New-CopilotSessionState -SessionRoot $script:SessionRoot -Id $second -Cwd $script:Workspace -Summary 'Round trip second'
        Set-CopilotTestEvents -SessionPath $firstPath -Lines (New-CopilotTestConversationEvents -Prefix 'round-first' -SessionId $first -Count 2 -Start ([datetimeoffset]'2026-08-20T19:00:00Z'))
        Set-CopilotTestEvents -SessionPath $secondPath -Lines (New-CopilotTestConversationEvents -Prefix 'round-second' -SessionId $second -Count 2 -Start ([datetimeoffset]'2026-08-20T19:10:00Z'))

        $merged = Merge-CopilotSession -Id $first, $second -Confirm:$false
        Compress-CopilotSession -InputObject $merged -Keep 2 -NoBackup -Confirm:$false
        Repair-CopilotSessionEvents -InputObject $merged -NoBackup -Confirm:$false

        $lines = @(Get-Content (Join-Path $merged.Path 'events.jsonl') | Where-Object { $_.Trim() })
        $lines | Should -Not -BeNullOrEmpty
        foreach ($line in $lines) {
            { $line | ConvertFrom-Json } | Should -Not -Throw
        }
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

Describe 'Copilot workspace.yaml helpers' {
    It 'reads quoted and plain flow scalars with varied indentation and line endings' -ForEach @(
        @{ Content = 'name: "quoted value"'; Field = 'name'; Expected = 'quoted value' }
        @{ Content = "name: 'It''s fine'"; Field = 'name'; Expected = "It's fine" }
        @{ Content = '   branch: user/test-workspace-yaml-parser'; Field = 'branch'; Expected = 'user/test-workspace-yaml-parser' }
        @{ Content = "cwd: C:\Work\Repo`r`nsummary: Plain summary"; Field = 'summary'; Expected = 'Plain summary' }
        @{ Content = "cwd: /work/repo`nsummary: LF summary"; Field = 'summary'; Expected = 'LF summary' }
    ) {
        InModuleScope Shmuelie.Copilot -Parameters @{ Content = $Content; Field = $Field } {
            Get-CopilotWorkspaceField -Content $Content -Field $Field
        } | Should -Be $Expected
    }

    It 'reads literal and folded block scalars' -ForEach @(
        @{ Content = "name: |`n  first line`n  second line`nsummary: next"; Expected = "first line`nsecond line`n" }
        @{ Content = "name: |-`n  first line`n  second line`nsummary: next"; Expected = "first line`nsecond line" }
        @{ Content = "name: >`n  first line`n  second line`nsummary: next"; Expected = "first line second line`n" }
        @{ Content = "name: >-`n  first line`n  second line`nsummary: next"; Expected = 'first line second line' }
        @{ Content = "  name: |-`n     odd indent`n  summary: next"; Expected = 'odd indent' }
        @{ Content = "name: |-`r`n  crlf one`r`n  crlf two`r`nsummary: next"; Expected = "crlf one`ncrlf two" }
    ) {
        InModuleScope Shmuelie.Copilot -Parameters @{ Content = $Content } {
            Get-CopilotWorkspaceField -Content $Content -Field 'name'
        } | Should -Be $Expected
    }

    It 'rewrites fields so read-after-write round trips simple, block, and special-character values' -ForEach @(
        @{ Value = 'Merged session'; Original = "name: old`nsummary: keep" }
        @{ Value = "Line one`nLine two"; Original = "name: |-`n  old line`n  removed line`nsummary: keep" }
        @{ Value = 'Needs: quoting # and "quotes"'; Original = "name: old`nsummary: keep" }
    ) {
        $updated = InModuleScope Shmuelie.Copilot -Parameters @{ Original = $Original; Value = $Value } {
            Set-CopilotWorkspaceField -Content $Original -Field 'name' -Value $Value
        }

        InModuleScope Shmuelie.Copilot -Parameters @{ Updated = $updated } {
            Get-CopilotWorkspaceField -Content $Updated -Field 'name'
        } | Should -Be $Value
        $updated | Should -Match 'summary: keep'
        $updated | Should -Not -Match 'removed line'
    }

    It 'preserves CRLF when rewriting content and supports path-based reads and writes' {
        $workspaceYaml = Join-Path $TestDrive 'workspace.yaml'
        Set-Content -Path $workspaceYaml -Value "name: old`r`nsummary: keep`r`n" -NoNewline

        $updated = InModuleScope Shmuelie.Copilot -Parameters @{ Path = $workspaceYaml } {
            Set-CopilotWorkspaceField -Path $Path -Field 'name' -Value 'new value'
        }

        $updated | Should -Match "new value`r`nsummary"
        InModuleScope Shmuelie.Copilot -Parameters @{ Path = $workspaceYaml } {
            Get-CopilotWorkspaceField -Path $Path -Field 'name'
        } | Should -Be 'new value'
    }
}

Describe 'Copilot maintenance-session auto-resume exclusion' {
    BeforeEach {
        $testHome = Join-Path $TestDrive 'home'
        $env:USERPROFILE = Join-Path $TestDrive 'legacy-userprofile'
        New-Item -ItemType Directory -Path $testHome -Force | Out-Null
        Mock -ModuleName Shmuelie.Copilot -CommandName Get-CopilotHome -MockWith { $testHome }
        Add-FakeCopilot -Path (Join-Path $TestDrive 'bin')
    }

    It 'keeps known generated maintenance sessions out of ResumeLatest candidates' -ForEach @(
        @{
            MaintenanceName = 'Apply context_board add/prune updates for this session. End the turn with a 2-3 sentence summary of the changes you made to the context_board.'
            AsBlock = $false
        }
        @{
            MaintenanceName = 'Analyze the session file and write the session insights result to the specified output file as described in the instructions.'
            AsBlock = $false
        }
        @{
            MaintenanceName = "Session File Path:`nC:\Users\example\.copilot\session-state\session\events.jsonl"
            AsBlock = $true
        }
    ) {
        $cwd = Join-Path $TestDrive 'workspace'
        New-Item -ItemType Directory -Path $cwd -Force | Out-Null
        $sessionRoot = Join-Path $testHome '.copilot' 'session-state'
        $regularSessionId = '11111111-1111-1111-1111-111111111111'
        $maintenanceSessionId = '22222222-2222-2222-2222-222222222222'
        New-CopilotSessionState -SessionRoot $sessionRoot -Id $regularSessionId -Cwd $cwd -Summary 'Real work' -UpdatedAt '2026-08-20T10:00:00.000Z' | Out-Null
        $maintenancePath = New-CopilotSessionState -SessionRoot $sessionRoot -Id $maintenanceSessionId -Cwd $cwd -Summary 'generated maintenance' -UpdatedAt '2026-08-20T11:00:00.000Z'

        $workspaceYaml = Join-Path $maintenancePath 'workspace.yaml'
        $content = Get-Content $workspaceYaml -Raw
        if ($AsBlock) {
            $blockLines = $MaintenanceName -split '\r?\n'
            $replacement = "name: |-$([Environment]::NewLine)  $($blockLines -join "$([Environment]::NewLine)  ")"
            $content = $content -replace '(?m)^name:\s*.+$', $replacement
        } else {
            $content = InModuleScope Shmuelie.Copilot -Parameters @{ Content = $content; MaintenanceName = $MaintenanceName } {
                Set-CopilotWorkspaceField -Content $Content -Field 'name' -Value $MaintenanceName
            }
        }
        Set-Content -Path $workspaceYaml -Value $content -Encoding UTF8 -NoNewline

        Push-Location $cwd
        try {
            $plan = Get-CopilotLaunchPlan -ResumeLatest
        } finally {
            Pop-Location
        }

        $resumeArg = [array]::IndexOf($plan.Args, '--resume')
        $resumeArg | Should -BeGreaterOrEqual 0
        $plan.Args[$resumeArg + 1] | Should -Be $regularSessionId -Because 'the auto-resume exclusion still relies on these generated maintenance prompt names; update the exclusion and this regression test together if Copilot CLI changes that shape'
    }
}

Describe 'Get-CopilotSession' {
    BeforeEach {
        $testHome = Join-Path $TestDrive 'home'
        Remove-Item -LiteralPath $testHome -Recurse -Force -ErrorAction SilentlyContinue
        $script:SessionRoot = Join-Path $testHome '.copilot' 'session-state'
        $script:Workspace = Join-Path $TestDrive 'workspace'
        $script:OtherWorkspace = Join-Path $TestDrive 'other-workspace'
        New-Item -ItemType Directory -Path $script:SessionRoot, $script:Workspace, $script:OtherWorkspace -Force | Out-Null
        Mock -ModuleName Shmuelie.Copilot -CommandName Get-CopilotHome -MockWith { $testHome }
    }

    It 'parses workspace metadata and counts optional events when present' {
        $sessionId = '11111111-2222-3333-4444-555555555555'
        $sessionPath = New-CopilotSessionState -SessionRoot $script:SessionRoot -Id $sessionId -Cwd $script:Workspace -Summary 'Investigate CLI helpers' -UpdatedAt '2026-08-20T18:00:00.000Z'
        Add-Content -Path (Join-Path $sessionPath 'workspace.yaml') -Value @(
            'branch: user/test-session'
            'repository: shmuelie/powershell-modules'
        )
        Set-CopilotTestEvents -SessionPath $sessionPath -Lines @(
            (New-CopilotTestEventLine -Type 'session.start' -Id 'start' -Timestamp '2026-08-20T18:00:00Z' -Data @{ sessionId = $sessionId })
            (New-CopilotTestEventLine -Type 'user.message' -Id 'user' -Timestamp '2026-08-20T18:01:00Z' -Data @{ content = 'hello' })
        )

        Push-Location $script:Workspace
        try {
            $sessions = @(Get-CopilotSession)
        } finally {
            Pop-Location
        }

        $sessions | Should -HaveCount 1
        $sessions[0].Id | Should -Be $sessionId
        $sessions[0].Name | Should -Be 'Investigate CLI helpers'
        $sessions[0].Summary | Should -Be 'Investigate CLI helpers'
        $sessions[0].Cwd | Should -Be $script:Workspace
        $sessions[0].Branch | Should -Be 'user/test-session'
        $sessions[0].Repository | Should -Be 'shmuelie/powershell-modules'
        $sessions[0].UpdatedAt | Should -Be ([DateTimeOffset]::Parse('2026-08-20T18:00:00.000Z'))
        $sessions[0].EventCount | Should -Be 2
        $sessions[0].EventSize | Should -BeGreaterThan 0
        $sessions[0].Path | Should -Be $sessionPath
    }

    It 'tolerates missing optional files and filters by cwd, All, and Id' {
        $matchingId = 'aaaaaaaa-0000-0000-0000-000000000000'
        $otherId = 'bbbbbbbb-0000-0000-0000-000000000000'
        New-CopilotSessionState -SessionRoot $script:SessionRoot -Id $matchingId -Cwd $script:Workspace -Summary 'Current workspace' | Out-Null
        $otherPath = New-CopilotSessionState -SessionRoot $script:SessionRoot -Id $otherId -Cwd $script:OtherWorkspace -Summary 'Other workspace'
        Remove-Item -LiteralPath (Join-Path $otherPath 'events.jsonl') -Force -ErrorAction SilentlyContinue

        Push-Location $script:Workspace
        try {
            $currentSessions = @(Get-CopilotSession)
            $allSessions = @(Get-CopilotSession -All)
            $specificSession = Get-CopilotSession -Id $otherId
        } finally {
            Pop-Location
        }

        $currentSessions.Id | Should -Be @($matchingId)
        @($allSessions.Id | Sort-Object) | Should -Be @($matchingId, $otherId)
        $specificSession.Id | Should -Be $otherId
        $specificSession.EventCount | Should -Be 0
        $specificSession.EventSize | Should -Be 0
    }
}

Describe 'Remove-CopilotSession' {
    BeforeEach {
        $testHome = Join-Path $TestDrive 'home'
        Remove-Item -LiteralPath $testHome -Recurse -Force -ErrorAction SilentlyContinue
        $script:SessionRoot = Join-Path $testHome '.copilot' 'session-state'
        $script:Workspace = Join-Path $TestDrive 'workspace'
        New-Item -ItemType Directory -Path $script:SessionRoot, $script:Workspace -Force | Out-Null
        Mock -ModuleName Shmuelie.Copilot -CommandName Get-CopilotHome -MockWith { $testHome }
    }

    It 'honors WhatIf without deleting the target session' {
        $sessionId = 'cccccccc-0000-0000-0000-000000000000'
        $sessionPath = New-CopilotSessionState -SessionRoot $script:SessionRoot -Id $sessionId -Cwd $script:Workspace -Summary 'Keep me'

        Remove-CopilotSession -Id $sessionId -WhatIf

        Test-Path $sessionPath | Should -BeTrue
    }

    It 'removes exactly the requested session directory' {
        $removeId = 'dddddddd-0000-0000-0000-000000000000'
        $keepId = 'eeeeeeee-0000-0000-0000-000000000000'
        $removePath = New-CopilotSessionState -SessionRoot $script:SessionRoot -Id $removeId -Cwd $script:Workspace -Summary 'Remove me'
        $keepPath = New-CopilotSessionState -SessionRoot $script:SessionRoot -Id $keepId -Cwd $script:Workspace -Summary 'Keep me'

        Remove-CopilotSession -Id $removeId -Confirm:$false

        Test-Path $removePath | Should -BeFalse
        Test-Path $keepPath | Should -BeTrue
        @(Get-ChildItem -Path $script:SessionRoot -Directory | Select-Object -ExpandProperty Name) | Should -Be @($keepId)
    }
}

Describe 'Rename-CopilotSession' {
    BeforeEach {
        $testHome = Join-Path $TestDrive 'home'
        Remove-Item -LiteralPath $testHome -Recurse -Force -ErrorAction SilentlyContinue
        $script:SessionRoot = Join-Path $testHome '.copilot' 'session-state'
        $script:Workspace = Join-Path $TestDrive 'workspace'
        New-Item -ItemType Directory -Path $script:SessionRoot, $script:Workspace -Force | Out-Null
        Mock -ModuleName Shmuelie.Copilot -CommandName Get-CopilotHome -MockWith { $testHome }
    }

    It 'honors WhatIf without changing workspace.yaml' {
        $sessionId = 'ffffffff-0000-0000-0000-000000000000'
        $sessionPath = New-CopilotSessionState -SessionRoot $script:SessionRoot -Id $sessionId -Cwd $script:Workspace -Summary 'Original name'
        $workspaceFile = Join-Path $sessionPath 'workspace.yaml'
        $before = Get-Content $workspaceFile -Raw

        Rename-CopilotSession -Id $sessionId -Summary 'New name' -WhatIf

        Get-Content $workspaceFile -Raw | Should -Be $before
    }

    It 'updates the workspace name and summary fields' {
        $sessionId = '99999999-0000-0000-0000-000000000000'
        $sessionPath = New-CopilotSessionState -SessionRoot $script:SessionRoot -Id $sessionId -Cwd $script:Workspace -Summary 'Original name'
        $workspaceFile = Join-Path $sessionPath 'workspace.yaml'

        $renamed = Rename-CopilotSession -Id $sessionId -Summary 'Renamed session' -Confirm:$false

        $renamed.Summary | Should -Be 'Renamed session'
        $content = Get-Content $workspaceFile -Raw
        $content | Should -Match '(?m)^name: Renamed session\r?$'
        $content | Should -Match '(?m)^summary: Renamed session\r?$'
    }
}

Describe 'Resume-CopilotSession' {
    BeforeEach {
        $testHome = Join-Path $TestDrive 'home'
        Remove-Item -LiteralPath $testHome -Recurse -Force -ErrorAction SilentlyContinue
        $script:SessionRoot = Join-Path $testHome '.copilot' 'session-state'
        $script:Workspace = Join-Path $TestDrive 'workspace'
        New-Item -ItemType Directory -Path $script:SessionRoot, $script:Workspace -Force | Out-Null
        Mock -ModuleName Shmuelie.Copilot -CommandName Get-CopilotHome -MockWith { $testHome }
        $script:CopilotTestLog = Join-Path $TestDrive 'copilot.log'
        Remove-Item $script:CopilotTestLog -Force -ErrorAction SilentlyContinue
        $env:COPILOT_TEST_LOG = $script:CopilotTestLog
        Add-FakeCopilot -Path (Join-Path $TestDrive 'bin')
    }

    AfterEach {
        Remove-Item Env:\COPILOT_TEST_LOG -ErrorAction SilentlyContinue
    }

    It 'invokes copilot with the expected resume arguments without deleting session state' {
        $sessionId = '12121212-3434-5656-7878-909090909090'
        $sessionPath = New-CopilotSessionState -SessionRoot $script:SessionRoot -Id $sessionId -Cwd $script:Workspace -Summary 'Resume me'

        Resume-CopilotSession -Id $sessionId

        Get-Content $script:CopilotTestLog -Raw | Should -Be "--allow-all --experimental --resume $sessionId$([Environment]::NewLine)"
        Test-Path $sessionPath | Should -BeTrue
    }
}

Describe 'Copilot plugin, marketplace, and MCP removal cmdlets' {
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

    It 'honors WhatIf without invoking copilot' {
        Uninstall-CopilotPlugin -Name 'dotnet@test-market' -WhatIf
        Unregister-CopilotMarketplace -Name 'test-marketplace' -WhatIf
        Unregister-CopilotMcpServer -Name 'test-server' -WhatIf

        Test-Path $script:CopilotTestLog | Should -BeFalse
    }

    It 'passes the expected uninstall and unregister arguments to copilot' {
        Uninstall-CopilotPlugin -Name 'dotnet@test-market' -Confirm:$false
        Unregister-CopilotMarketplace -Name 'test-marketplace' -Confirm:$false
        Unregister-CopilotMcpServer -Name 'test-server' -Confirm:$false

        $lines = @(Get-Content $script:CopilotTestLog)
        $lines | Should -Contain 'plugin uninstall dotnet@test-market'
        $lines | Should -Contain 'plugin marketplace remove test-marketplace'
        $lines | Should -Contain 'mcp remove test-server'
    }

    It 'rejects unsafe removal arguments before invoking copilot' {
        { Uninstall-CopilotPlugin -Name 'bad&plugin' -Confirm:$false } | Should -Throw '*Unsafe Name value*'
        { Unregister-CopilotMarketplace -Name 'bad&marketplace' -Confirm:$false } | Should -Throw '*Unsafe Name value*'
        { Unregister-CopilotMcpServer -Name 'bad&server' -Confirm:$false } | Should -Throw '*Unsafe Name value*'
        Test-Path $script:CopilotTestLog | Should -BeFalse
    }
}

Describe 'Update-CopilotPlugin' {
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
        Remove-Item Env:\COPILOT_TEST_STDOUT -ErrorAction SilentlyContinue
        Remove-Item Env:\COPILOT_TEST_RETRY_COUNT -ErrorAction SilentlyContinue
    }

    It 'accepts pipeline input from Get-CopilotPlugin' {
        $env:COPILOT_TEST_STDOUT = "  • dotnet@test-market (v1.2.3)$([Environment]::NewLine)"

        $results = @(Get-CopilotPlugin | Update-CopilotPlugin -Confirm:$false)

        $results | Should -HaveCount 1
        $results[0].Name | Should -Be 'dotnet@test-market'
        $results[0].Success | Should -BeTrue
        $results[0].Error | Should -BeNullOrEmpty
        $lines = @(Get-Content $script:CopilotTestLog)
        $lines | Should -Contain 'plugin list'
        $lines | Should -Contain 'plugin update dotnet@test-market'
    }

    It 'retries once when a plugin update initially fails with EBUSY' {
        $retryBin = Join-Path $TestDrive 'retry-bin'
        New-Item -ItemType Directory -Path $retryBin -Force | Out-Null
        $handler = Join-Path $retryBin 'copilot-retry.ps1'
        Set-Content -Path $handler -Value @(
            'if ($env:COPILOT_TEST_LOG) {'
            "    Add-Content -LiteralPath `$env:COPILOT_TEST_LOG -Value (`$args -join ' ')"
            '}'
            "if (`$args.Count -ge 3 -and `$args[0] -eq 'plugin' -and `$args[1] -eq 'update' -and `$args[2] -eq 'locked-plugin') {"
            '    $countPath = $env:COPILOT_TEST_RETRY_COUNT'
            '    $count = if ($countPath -and (Test-Path -LiteralPath $countPath)) { [int](Get-Content -LiteralPath $countPath -Raw) } else { 0 }'
            '    $count++'
            '    if ($countPath) { Set-Content -LiteralPath $countPath -Value $count }'
            '    if ($count -eq 1) {'
            "        [Console]::Error.WriteLine('Error: EBUSY: resource busy or locked')"
            '        exit 1'
            '    }'
            '}'
            'exit 0'
        )
        $pwsh = (Get-Process -Id $PID).Path
        if ($IsWindows) {
            Set-Content -Path (Join-Path $retryBin 'copilot.cmd') -Value @(
                '@echo off'
                "`"$($pwsh -replace '"', '""')`" -NoLogo -NoProfile -NonInteractive -File `"$($handler -replace '"', '""')`" %*"
                'exit /b %ERRORLEVEL%'
            )
        } else {
            $copilot = Join-Path $retryBin 'copilot'
            Set-Content -Path $copilot -Value @(
                '#!/usr/bin/env sh'
                "'$($pwsh -replace '''', '''\''''')' -NoLogo -NoProfile -NonInteractive -File '$($handler -replace '''', '''\''''')' `"`$@`""
            )
            & chmod +x $copilot
        }
        $env:PATH = "$retryBin$([IO.Path]::PathSeparator)$script:OriginalPath"
        $env:COPILOT_TEST_RETRY_COUNT = Join-Path $TestDrive 'retry-count.txt'
        Mock -ModuleName Shmuelie.Copilot -CommandName Start-Sleep -MockWith { }

        $result = Update-CopilotPlugin -Name 'locked-plugin' -Confirm:$false

        $result.Success | Should -BeTrue
        $result.Error | Should -BeNullOrEmpty
        @((Get-Content $script:CopilotTestLog) | Where-Object { $_ -eq 'plugin update locked-plugin' }) | Should -HaveCount 2
        Get-Content $env:COPILOT_TEST_RETRY_COUNT -Raw | Should -Match '^2\s*$'
        Should -Invoke -ModuleName Shmuelie.Copilot -CommandName Start-Sleep -Exactly -Times 1
    }
}

Describe 'Get-CopilotMcpServer' {
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
        Remove-Item Env:\COPILOT_TEST_STDOUT -ErrorAction SilentlyContinue
    }

    It 'parses copilot MCP list JSON output into typed server objects' {
        $env:COPILOT_TEST_STDOUT = [ordered]@{
            mcpServers = [ordered]@{
                local = [ordered]@{
                    type = 'stdio'
                    command = 'pwsh'
                    args = @('-File', 'server.ps1')
                    source = 'user'
                }
                remote = [ordered]@{
                    type = 'http'
                    url = 'https://example.test/mcp'
                    source = 'plugin'
                }
            }
        } | ConvertTo-Json -Depth 5 -Compress

        $servers = @(Get-CopilotMcpServer)
        $filtered = @(Get-CopilotMcpServer -Name 'local*' -Source user)

        $servers | Should -HaveCount 2
        $servers[0].PSTypeNames[0] | Should -Be 'CopilotMcpServer'
        $servers[0].Name | Should -Be 'local'
        $servers[0].Type | Should -Be 'stdio'
        $servers[0].Command | Should -Be 'pwsh'
        $servers[0].Args | Should -Be '-File server.ps1'
        $servers[0].Url | Should -Be ''
        $servers[0].Source | Should -Be 'user'
        $servers[1].Name | Should -Be 'remote'
        $servers[1].Command | Should -Be ''
        $servers[1].Url | Should -Be 'https://example.test/mcp'
        $filtered | Should -HaveCount 1
        $filtered[0].Name | Should -Be 'local'
        @(Get-Content $script:CopilotTestLog | Where-Object { $_ -eq 'mcp list --json' }) | Should -HaveCount 2
    }
}
