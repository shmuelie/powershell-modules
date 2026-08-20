# Copilot session maintenance: merge, compact, and repair operations.
# Split out of Sessions.ps1 to keep that file focused on basic session CRUD.

function Merge-CopilotSession {
    <#
    .SYNOPSIS
        Merges two or more Copilot CLI sessions into one resumable session.

    .DESCRIPTION
        Combines the conversation history (events.jsonl), checkpoints, and
        rewind snapshots from multiple sessions into a single new session.
        Events are interleaved in chronological order. The workspace metadata
        is taken from the most recently updated source session.

        The original sessions are preserved unless -RemoveSource is specified.

    .PARAMETER Id
        Two or more session IDs to merge.

    .PARAMETER InputObject
        Session objects piped from Get-CopilotSession.

    .PARAMETER RemoveSource
        Remove the source sessions after a successful merge.

    .EXAMPLE
        Merge-CopilotSession -Id "abc-123", "def-456"
        Merges two sessions into a new combined session.

    .EXAMPLE
        Get-CopilotSession | Merge-CopilotSession
        Merges all sessions for the current directory.

    .EXAMPLE
        Get-CopilotSession | Merge-CopilotSession -RemoveSource
        Merges all sessions for the current directory and removes the originals.
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'ById')]
    param(
        [Parameter(ParameterSetName = 'ById', Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Id,

        [Parameter(ParameterSetName = 'ByObject', Mandatory, ValueFromPipeline)]
        [PSObject]$InputObject,

        [switch]$RemoveSource
    )

    begin {
        $collectedSessions = [System.Collections.Generic.List[PSObject]]::new()
    }

    process {
        if ($PSCmdlet.ParameterSetName -eq 'ById') {
            foreach ($sid in $Id) {
                $s = Get-CopilotSession -Id $sid
                if ($null -eq $s) {
                    Write-Error "Session '$sid' not found."
                    return
                }
                $collectedSessions.Add($s)
            }
        } else {
            $collectedSessions.Add($InputObject)
        }
    }

    end {
        if ($collectedSessions.Count -lt 2) {
            Write-Error 'At least two sessions are required to merge.'
            return
        }

        # Validate all sessions share the same working directory
        $cwds = @($collectedSessions | Select-Object -ExpandProperty Cwd -Unique)
        if (@($cwds).Count -gt 1) {
            # On non-case-sensitive file systems, paths differing only by case are equivalent
            $normalizedCwds = @($cwds | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique)
            if (@($normalizedCwds).Count -gt 1) {
                Write-Error "Cannot merge sessions from different directories: $($cwds -join ', ')"
                return
            }
        }

        $sessionNames = $collectedSessions | ForEach-Object { "$($_.Summary) ($($_.Id.Substring(0,8)))" }
        if (-not $PSCmdlet.ShouldProcess(($sessionNames -join ' + '), 'Merge sessions')) {
            return
        }

        $activity = "Merging $($collectedSessions.Count) sessions"

        try {

        # Use the most recently updated session for workspace metadata
        $primary = $collectedSessions | Sort-Object UpdatedAt -Descending | Select-Object -First 1

        # Create new session directory
        Write-Progress -Activity $activity -Status 'Creating session directory' -PercentComplete 0 -Id 1
        $newId = [guid]::NewGuid().ToString()
        $sessionStateDir = Join-Path (Get-CopilotHome) '.copilot' 'session-state'
        $newSessionPath = Join-Path $sessionStateDir $newId
        New-Item -ItemType Directory -Path $newSessionPath -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $newSessionPath 'checkpoints') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $newSessionPath 'files') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $newSessionPath 'research') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $newSessionPath 'rewind-snapshots') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $newSessionPath 'rewind-snapshots' 'backups') -Force | Out-Null

        # Merge events.jsonl — concatenate sessions in chronological order,
        # preserving intra-session event ordering to avoid splitting tool_use/tool_result pairs.
        # (Global timestamp sorting breaks tool pairing when events share timestamps.)
        Write-Progress -Activity $activity -Status 'Merging conversation history' -PercentComplete 10 -Id 1

        # Order sessions by their earliest event timestamp
        $orderedSessions = $collectedSessions | Sort-Object { $_.UpdatedAt } | Sort-Object {
            $eventsFile = Join-Path $_.Path 'events.jsonl'
            if (Test-Path $eventsFile) {
                $firstLine = Get-Content $eventsFile -TotalCount 1
                if ($firstLine) {
                    $evt = $firstLine | ConvertFrom-Json
                    [DateTimeOffset]::Parse($evt.timestamp)
                }
            }
        }

        $newEventsFile = Join-Path $newSessionPath 'events.jsonl'
        $totalEvents = 0
        $isFirst = $true
        $sessionIdx = 0

        foreach ($s in $orderedSessions) {
            $eventsFile = Join-Path $s.Path 'events.jsonl'
            if (-not (Test-Path $eventsFile)) { continue }

            $sessionIdx++
            $eventPercent = 10 + [int](40 * $sessionIdx / $orderedSessions.Count)
            Write-Progress -Activity $activity -Status "Processing session $sessionIdx of $($orderedSessions.Count)" -PercentComplete $eventPercent -CurrentOperation $s.Id.Substring(0,8) -Id 1

            # Repair each session's events before merging (fix orphaned tool events, etc.)
            Write-Verbose "  Processing $($s.Id.Substring(0,8))..."
            $sessionLines = Get-Content $eventsFile
            $repairedLines = Repair-CopilotSessionEvents -EventLines $sessionLines

            foreach ($line in $repairedLines) {
                $evt = $line | ConvertFrom-Json

                if ($evt.type -eq 'session.start') {
                    if ($isFirst) {
                        $evt.data.sessionId = $newId
                        $evt.id = [guid]::NewGuid().ToString()
                        $evt | ConvertTo-Json -Depth 10 -Compress | Add-Content -LiteralPath $newEventsFile -Encoding UTF8
                        $totalEvents++
                        $isFirst = $false
                    }
                    continue
                }

                # Skip session lifecycle events from source sessions
                if ($evt.type -in @('session.shutdown', 'session.resume', 'session.error', 'session.warning',
                        'session.compaction_start', 'session.compaction_complete', 'session.truncation',
                        'session.context_changed', 'abort')) {
                    continue
                }

                $line | Add-Content -LiteralPath $newEventsFile -Encoding UTF8
                $totalEvents++
            }
        }

        # Merge checkpoints/index.md
        Write-Progress -Activity $activity -Status 'Merging checkpoints' -PercentComplete 55 -Id 1
        $checkpointHeader = @(
            '# Checkpoint History'
            'Checkpoints are listed in chronological order. Checkpoint 1 is the oldest, higher numbers are more recent.'
            ''
            '| # | Title | File |'
            '|---|-------|------|'
        )
        $checkpointRows = [System.Collections.Generic.List[string]]::new()
        foreach ($s in ($collectedSessions | Sort-Object { $_.UpdatedAt })) {
            $cpFile = Join-Path $s.Path 'checkpoints' 'index.md'
            if (Test-Path $cpFile) {
                Get-Content $cpFile | Where-Object { $_ -match '^\|\s*\d+' } | ForEach-Object {
                    $checkpointRows.Add($_)
                }
            }
        }
        # Renumber checkpoints
        $cpNumber = 1
        $renumbered = $checkpointRows | ForEach-Object {
            $currentNumber = $cpNumber
            $cpNumber++
            $_ -replace '^\|\s*\d+', "| $currentNumber"
        }
        ($checkpointHeader + $renumbered) | Set-Content (Join-Path $newSessionPath 'checkpoints' 'index.md') -Encoding UTF8

        # Merge rewind-snapshots
        Write-Progress -Activity $activity -Status 'Merging rewind snapshots' -PercentComplete 65 -Id 1
        $mergedSnapshots = [System.Collections.Generic.List[PSObject]]::new()
        foreach ($s in $collectedSessions) {
            $indexFile = Join-Path $s.Path 'rewind-snapshots' 'index.json'
            if (Test-Path $indexFile) {
                $index = Get-Content $indexFile -Raw | ConvertFrom-Json
                if ($index.snapshots) {
                    foreach ($snap in $index.snapshots) { $mergedSnapshots.Add($snap) }
                }
            }
            # Copy backup files
            $backupsDir = Join-Path $s.Path 'rewind-snapshots' 'backups'
            if (Test-Path $backupsDir) {
                Get-ChildItem $backupsDir | Copy-Item -Destination (Join-Path $newSessionPath 'rewind-snapshots' 'backups') -Force
            }
        }
        $mergedSnapshots = $mergedSnapshots | Sort-Object { [DateTimeOffset]::Parse($_.timestamp) }
        @{ version = 1; snapshots = @($mergedSnapshots) } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $newSessionPath 'rewind-snapshots' 'index.json') -Encoding UTF8

        # Copy files and research from all sessions
        Write-Progress -Activity $activity -Status 'Copying files and research' -PercentComplete 75 -Id 1
        foreach ($s in $collectedSessions) {
            $filesDir = Join-Path $s.Path 'files'
            if ((Test-Path $filesDir) -and (Get-ChildItem $filesDir)) {
                Get-ChildItem $filesDir | Copy-Item -Destination (Join-Path $newSessionPath 'files') -Recurse -Force
            }
            $researchDir = Join-Path $s.Path 'research'
            if ((Test-Path $researchDir) -and (Get-ChildItem $researchDir)) {
                Get-ChildItem $researchDir | Copy-Item -Destination (Join-Path $newSessionPath 'research') -Recurse -Force
            }
        }

        # Write workspace.yaml with merged summary
        Write-Progress -Activity $activity -Status 'Writing workspace metadata' -PercentComplete 85 -Id 1
        $now = [DateTimeOffset]::UtcNow.ToString('o')
        $primaryContent = Get-Content (Join-Path $primary.Path 'workspace.yaml') -Raw
        $mergedSummary = ($collectedSessions | Sort-Object UpdatedAt | ForEach-Object { $_.Name } |
            Where-Object { $_ -ne '(no summary)' } | Select-Object -Unique) -join ' + '
        if (-not $mergedSummary) { $mergedSummary = 'merged session' }

        # Replace name field in workspace.yaml (handles block scalars like |- or >-)
        $hasName = $primaryContent -match '(?m)^name:'
        if ($hasName) {
            $yamlLines = $primaryContent -split '\r?\n'
            $newLines = [System.Collections.Generic.List[string]]::new()
            $skipBlock = $false
            foreach ($line in $yamlLines) {
                if ($line -match '^name:') {
                    $newLines.Add("name: $mergedSummary")
                    $skipBlock = ($line -match ':\s*[\|>]')
                    continue
                }
                if ($skipBlock -and ($line -match '^\s' -or $line -eq '')) { continue }
                $skipBlock = $false
                $newLines.Add($line)
            }
            $primaryContent = $newLines -join "`n"
        }

        $workspaceYaml = $primaryContent -replace '(?m)^id:\s*.+$', "id: $newId"
        $workspaceYaml = $workspaceYaml -replace '(?m)^summary:\s*.+$', "summary: $mergedSummary"
        $workspaceYaml = $workspaceYaml -replace '(?m)^summary_count:\s*.+$', 'summary_count: 0'
        $workspaceYaml = $workspaceYaml -replace '(?m)^updated_at:\s*.+$', "updated_at: $now"
        $workspaceYaml | Set-Content (Join-Path $newSessionPath 'workspace.yaml') -Encoding UTF8 -NoNewline

        # Write empty vscode metadata
        '{}' | Set-Content (Join-Path $newSessionPath 'vscode.metadata.json') -Encoding UTF8

        # Merge plan.md — concatenate plans from all sessions
        $plans = [System.Collections.Generic.List[string]]::new()
        foreach ($s in ($collectedSessions | Sort-Object { $_.UpdatedAt })) {
            $planFile = Join-Path $s.Path 'plan.md'
            if (Test-Path $planFile) {
                $planContent = Get-Content $planFile -Raw
                if ($planContent.Trim()) {
                    $plans.Add($planContent.Trim())
                }
            }
        }
        if ($plans.Count -gt 0) {
            ($plans -join "`n`n---`n`n") | Set-Content (Join-Path $newSessionPath 'plan.md') -Encoding UTF8
        }

        # Repair the final merged event stream (fix orphaned tool events, etc.)
        Write-Progress -Activity $activity -Status 'Repairing merged session' -PercentComplete 90 -Id 1
        Repair-CopilotSessionEvents -Path $newSessionPath -NoBackup

        Write-Verbose "Merged $($collectedSessions.Count) sessions into $newId"
        Write-Verbose "  Summary: $mergedSummary"
        Write-Verbose "  Events: $totalEvents"

        # Remove source sessions if requested
        if ($RemoveSource) {
            Write-Progress -Activity $activity -Status 'Removing source sessions' -PercentComplete 95 -Id 1
            foreach ($s in $collectedSessions) {
                Write-Verbose "Removing source session: $($s.Id.Substring(0,8))..."
                Remove-Item -LiteralPath $s.Path -Recurse -Force
            }
        }

        Write-Progress -Activity $activity -Id 1 -Completed

        } finally {
            Write-Progress -Activity $activity -Id 1 -Completed
        }

        # Return the new session
        Get-CopilotSession -Id $newId
    }
}

function Compress-CopilotSession {
    <#
    .SYNOPSIS
        Compacts an oversized Copilot CLI session by keeping only recent conversations.

    .DESCRIPTION
        Reduces the size of a session's events.jsonl by keeping only the last N
        user/assistant conversation exchanges. This fixes sessions that have grown
        too large to resume (typically >5 MB or 1000+ events).

        The original events.jsonl is backed up to events.jsonl.bak unless -NoBackup
        is specified. Raw event lines are preserved byte-for-byte to avoid
        re-serialization issues.

        Also cleans up rewind-snapshots that reference deleted events.

    .PARAMETER Id
        Session ID to compact.

    .PARAMETER InputObject
        A session object from Get-CopilotSession.

    .PARAMETER Keep
        Number of recent user/assistant conversation exchanges to keep. Defaults to 5.

    .PARAMETER NoBackup
        Skip creating a .bak backup before overwriting.

    .EXAMPLE
        Compress-CopilotSession -Id "abc-123"
        # Compacts the session to the last 5 conversations.

    .EXAMPLE
        Compress-CopilotSession -Id "abc-123" -Keep 10
        # Keeps the last 10 conversations.

    .EXAMPLE
        Get-CopilotSession | Where-Object EventSize -gt 5MB | Compress-CopilotSession
        # Compacts all oversized sessions for the current directory.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(ParameterSetName = 'ById', Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Id,

        [Parameter(ParameterSetName = 'ByObject', Mandatory, ValueFromPipeline)]
        [PSObject]$InputObject,

        [ValidateRange(1, [int]::MaxValue)]
        [int]$Keep = 5,

        [switch]$NoBackup
    )

    process {
        $session = if ($PSCmdlet.ParameterSetName -eq 'ById') {
            Get-CopilotSession -Id $Id
        } else {
            $InputObject
        }

        if ($null -eq $session) {
            Write-Error "Session not found."
            return
        }

        $eventsFile = Join-Path $session.Path 'events.jsonl'
        if (-not (Test-Path $eventsFile)) {
            Write-Warning "No events.jsonl found for session $($session.Id.Substring(0,8))."
            return
        }

        $lines = Get-Content -LiteralPath $eventsFile
        $originalCount = $lines.Count
        $originalSize = (Get-Item $eventsFile).Length

        if (-not $PSCmdlet.ShouldProcess(
            "$($session.Summary) ($($session.Id.Substring(0,8))) — $originalCount events, $([math]::Round($originalSize / 1MB, 1)) MB",
            "Compact to last $Keep conversations")) {
            return
        }

        # Single-pass: parse each line once, collecting type, id, and user.message indices
        $userIndices = [System.Collections.Generic.List[int]]::new()
        $sessionStartIndex = -1
        $eventIds = New-Object 'string[]' $lines.Count

        for ($i = 0; $i -lt $lines.Count; $i++) {
            $json = $lines[$i] | ConvertFrom-Json
            $eventIds[$i] = $json.id
            switch ($json.type) {
                'user.message'  { $userIndices.Add($i) }
                'session.start' { $sessionStartIndex = $i }
            }
        }

        if ($userIndices.Count -le $Keep) {
            Write-Verbose "Session has only $($userIndices.Count) conversations, no compaction needed."
            return
        }

        # Keep session.start + everything from the Nth-to-last user message onward
        $cutIndex = $userIndices[$userIndices.Count - $Keep]
        $output = [System.Collections.Generic.List[string]]::new()
        $keptEventIds = [System.Collections.Generic.HashSet[string]]::new()

        # Preserve the session.start event
        if ($sessionStartIndex -ge 0) {
            $output.Add($lines[$sessionStartIndex])
            if ($eventIds[$sessionStartIndex]) { [void]$keptEventIds.Add($eventIds[$sessionStartIndex]) }
        }

        # Add all events from the cut point onward (skip duplicate session.start)
        for ($i = $cutIndex; $i -lt $lines.Count; $i++) {
            if ($i -eq $sessionStartIndex) { continue }
            $output.Add($lines[$i])
            if ($eventIds[$i]) { [void]$keptEventIds.Add($eventIds[$i]) }
        }

        # Back up and write
        if (-not $NoBackup) {
            Copy-Item -LiteralPath $eventsFile -Destination "$eventsFile.bak" -Force
        }
        $content = $output -join "`r`n"
        [System.IO.File]::WriteAllText($eventsFile, "$content`r`n", [System.Text.UTF8Encoding]::new($false))

        # Clean up rewind-snapshots referencing deleted events
        $snapshotIndex = Join-Path $session.Path 'rewind-snapshots' 'index.json'
        if (Test-Path $snapshotIndex) {
            $index = Get-Content $snapshotIndex -Raw | ConvertFrom-Json
            if ($index.snapshots) {
                # Keep only snapshots whose eventId is still in the output
                $filtered = @($index.snapshots | Where-Object {
                    -not $_.eventId -or $keptEventIds.Contains($_.eventId)
                })
                @{ version = 1; snapshots = $filtered } |
                    ConvertTo-Json -Depth 5 |
                    Set-Content $snapshotIndex -Encoding UTF8
            }
        }

        # Repair the compacted session to fix any orphaned tool events
        Repair-CopilotSessionEvents -Path $session.Path -NoBackup

        $newSize = (Get-Item $eventsFile).Length
        Write-Verbose "Compacted $($session.Id.Substring(0,8)): $originalCount -> $($output.Count) events, $([math]::Round($originalSize / 1MB, 1)) MB -> $([math]::Round($newSize / 1MB, 1)) MB"
        Write-Information "Session compacted: kept last $Keep conversations ($($output.Count) events)." -InformationAction Continue
    }
}

function Repair-CopilotSessionEvents {
    <#
    .SYNOPSIS
        Sanitizes a Copilot session's events.jsonl to fix tool event ordering issues.

    .DESCRIPTION
        Fixes common corruption patterns in events.jsonl that prevent session resume:

        1. Relocates orphaned tool events (execution_complete/start that appear
           before their assistant.message) to after their corresponding request.
        2. Synthesizes missing tool completion events for tool_use blocks that
           have no matching tool_result anywhere in the file.
        3. Removes session.error and session.warning events that pollute the conversation history.
        4. Removes malformed events from previous bad repairs (empty id fields,
           model set to 'unknown').
        5. Validates the final tool_use/tool_result pairing.

        These issues typically arise from race conditions in the event logger
        where tool completions are recorded before the assistant message that
        requested them, or from context window truncation that splits
        tool_use/tool_result pairs.

    .PARAMETER EventLines
        Raw string array of events.jsonl lines to sanitize. When provided, the
        function operates on this array and returns the sanitized lines instead
        of reading/writing files.

    .PARAMETER Path
        Path to the session directory. If specified, reads and overwrites
        events.jsonl in place (creating a .bak backup first).

    .PARAMETER Id
        Session ID. Resolved to the session directory automatically.

    .PARAMETER InputObject
        A session object from Get-CopilotSession.

    .PARAMETER NoBackup
        Skip creating a .bak backup before overwriting.

    .EXAMPLE
        Repair-CopilotSessionEvents -Id "fb52be08-2f0a-42e1-95cd-bd137f0ad769"
        # Repairs the session's events.jsonl in place.

    .EXAMPLE
        Get-CopilotSession | Repair-CopilotSessionEvents
        # Repairs all sessions for the current directory.

    .EXAMPLE
        $fixed = Repair-CopilotSessionEvents -EventLines (Get-Content events.jsonl)
        # Returns sanitized lines without writing to disk.
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByEventLines', SupportsShouldProcess)]
    param(
        [Parameter(ParameterSetName = 'ByEventLines', Mandatory, Position = 0)]
        [string[]]$EventLines,

        [Parameter(ParameterSetName = 'ByPath', Mandatory)]
        [ValidateScript({ Test-Path $_ -PathType Container })]
        [string]$Path,

        [Parameter(ParameterSetName = 'ById', Mandatory)]
        [string]$Id,

        [Parameter(ParameterSetName = 'ByObject', Mandatory, ValueFromPipeline)]
        [PSObject]$InputObject,

        [switch]$NoBackup
    )

    process {
        # Resolve input to an array of raw event lines
        $eventsFile = $null
        switch ($PSCmdlet.ParameterSetName) {
            'ByEventLines' { $lines = $EventLines }
            'ByPath' {
                $eventsFile = Join-Path $Path 'events.jsonl'
                $lines = Get-Content -LiteralPath $eventsFile
            }
            'ById' {
                $s = Get-CopilotSession -Id $Id
                if ($null -eq $s) { Write-Error "Session '$Id' not found."; return }
                $eventsFile = Join-Path $s.Path 'events.jsonl'
                $lines = Get-Content -LiteralPath $eventsFile
            }
            'ByObject' {
                $eventsFile = Join-Path $InputObject.Path 'events.jsonl'
                $lines = Get-Content -LiteralPath $eventsFile
            }
        }

        if (-not $lines -or $lines.Count -eq 0) {
            Write-Warning 'No events to repair.'
            return $lines
        }

        # Parse all events
        $parsed = for ($i = 0; $i -lt $lines.Count; $i++) {
            $json = $lines[$i] | ConvertFrom-Json
            $toolReqs = if ($json.type -eq 'assistant.message' -and $json.data.toolRequests) {
                @($json.data.toolRequests | ForEach-Object { $_.toolCallId })
            } else { @() }
            [PSCustomObject]@{
                Idx          = $i
                Type         = $json.type
                ToolCallId   = $json.data.toolCallId
                ToolRequests = $toolReqs
                Raw          = $lines[$i]
                Json         = $json
            }
        }

        # Build global map: toolCallId -> index of the assistant.message that requested it
        $requestMap = @{}
        for ($i = 0; $i -lt $parsed.Count; $i++) {
            if ($parsed[$i].Type -eq 'assistant.message') {
                foreach ($tid in $parsed[$i].ToolRequests) {
                    $requestMap[$tid] = $i
                }
            }
        }

        # Build maps of all execution_complete and execution_start indices per toolCallId
        $completeMap = @{} # toolCallId -> List[int]
        $startMap    = @{}
        for ($i = 0; $i -lt $parsed.Count; $i++) {
            $ev = $parsed[$i]
            if ($ev.Type -eq 'tool.execution_complete' -and $ev.ToolCallId) {
                if (-not $completeMap[$ev.ToolCallId]) { $completeMap[$ev.ToolCallId] = [System.Collections.Generic.List[int]]::new() }
                $completeMap[$ev.ToolCallId].Add($i)
            }
            if ($ev.Type -eq 'tool.execution_start' -and $ev.ToolCallId) {
                if (-not $startMap[$ev.ToolCallId]) { $startMap[$ev.ToolCallId] = [System.Collections.Generic.List[int]]::new() }
                $startMap[$ev.ToolCallId].Add($i)
            }
        }

        # Identify tool events that appear BEFORE their assistant.message (orphaned)
        $relocate = [System.Collections.Generic.HashSet[int]]::new()
        foreach ($tid in $requestMap.Keys) {
            $reqIdx = $requestMap[$tid]
            if ($completeMap[$tid]) {
                foreach ($ci in $completeMap[$tid]) {
                    if ($ci -lt $reqIdx) { [void]$relocate.Add($ci) }
                }
            }
            if ($startMap[$tid]) {
                foreach ($si in $startMap[$tid]) {
                    if ($si -lt $reqIdx) { [void]$relocate.Add($si) }
                }
            }
        }

        # Build output: skip relocated/error events, insert relocated ones after their assistant.message
        $output = [System.Collections.Generic.List[string]]::new()
        for ($i = 0; $i -lt $parsed.Count; $i++) {
            $ev = $parsed[$i]

            # Skip orphaned events (will be re-inserted after their request)
            if ($relocate.Contains($i)) { continue }

            # Strip session.error and session.warning events
            if ($ev.Type -in @('session.error', 'session.warning')) { continue }

            # Strip malformed events from previous bad repairs (empty id, unknown model)
            if ($ev.Json.id -eq '' -or
                ($ev.Type -eq 'tool.execution_complete' -and $ev.Json.data.model -eq 'unknown')) {
                continue
            }

            $output.Add($ev.Raw)

            # After an assistant.message, re-insert any relocated tool events for its tools
            if ($ev.Type -eq 'assistant.message' -and $ev.ToolRequests.Count -gt 0) {
                foreach ($tid in $ev.ToolRequests) {
                    if ($startMap[$tid]) {
                        foreach ($si in $startMap[$tid]) {
                            if ($relocate.Contains($si)) { $output.Add($parsed[$si].Raw) }
                        }
                    }
                    if ($completeMap[$tid]) {
                        foreach ($ci in $completeMap[$tid]) {
                            if ($relocate.Contains($ci)) { $output.Add($parsed[$ci].Raw) }
                        }
                    }
                }
            }
        }

        # Synthesize missing tool completions (tool_use with no execution_complete anywhere)
        # Re-parse output to find the assistant.messages and their positions
        $outputParsed = for ($i = 0; $i -lt $output.Count; $i++) {
            $json = $output[$i] | ConvertFrom-Json
            [PSCustomObject]@{ Idx = $i; Type = $json.type; Json = $json }
        }

        $finalRequestMap = @{} # toolCallId -> output index of assistant.message
        $finalCompleteSet = [System.Collections.Generic.HashSet[string]]::new()
        for ($i = 0; $i -lt $outputParsed.Count; $i++) {
            $ev = $outputParsed[$i]
            if ($ev.Type -eq 'assistant.message' -and $ev.Json.data.toolRequests) {
                foreach ($req in $ev.Json.data.toolRequests) {
                    $finalRequestMap[$req.toolCallId] = $i
                }
            }
            if ($ev.Type -eq 'tool.execution_complete' -and $ev.Json.data.toolCallId) {
                [void]$finalCompleteSet.Add($ev.Json.data.toolCallId)
            }
        }

        # Find tool IDs with no completion and synthesize them
        $missingTids = $finalRequestMap.Keys | Where-Object { -not $finalCompleteSet.Contains($_) }
        if ($missingTids) {
            # Group missing TIDs by their assistant.message and find the turn_end after each
            $insertions = [System.Collections.Generic.List[PSObject]]::new()
            foreach ($tid in $missingTids) {
                $assistIdx = $finalRequestMap[$tid]
                $assistJson = $outputParsed[$assistIdx].Json
                $interactionId = $assistJson.data.interactionId
                $model = if ($assistJson.data.model -and $assistJson.data.model -ne 'unknown') { $assistJson.data.model } else { 'claude-sonnet-4' }

                # Find the turn_end after this assistant.message
                for ($j = $assistIdx + 1; $j -lt $output.Count; $j++) {
                    $ej = $output[$j] | ConvertFrom-Json
                    if ($ej.type -eq 'assistant.turn_end') {
                        $synth = @{
                            type = 'tool.execution_complete'
                            id = [guid]::NewGuid().ToString()
                            timestamp = $ej.timestamp
                            data = @{
                                toolCallId    = $tid
                                model         = $model
                                interactionId = $interactionId
                                success       = $true
                                result        = @{ content = '[Session repair: tool execution data unavailable]' }
                            }
                        }
                        $insertions.Add([PSCustomObject]@{
                            InsertBefore = $j
                            Json         = ($synth | ConvertTo-Json -Depth 5 -Compress)
                        })
                        break
                    }
                }
            }

            # Insert in reverse order so indices remain valid
            $insertions | Sort-Object InsertBefore -Descending | ForEach-Object {
                $output.Insert($_.InsertBefore, $_.Json)
            }
        }

        # Report stats
        $removedErrors = ($parsed | Where-Object { $_.Type -in @('session.error', 'session.warning') }).Count
        $removedMalformed = ($parsed | Where-Object {
            $_.Json.id -eq '' -or
            ($_.Type -eq 'tool.execution_complete' -and $_.Json.data.model -eq 'unknown')
        }).Count
        $stats = @{
            Relocated  = $relocate.Count
            Removed    = $removedErrors + $removedMalformed
            Synthesized = @($missingTids).Count
        }
        $total = $stats.Relocated + $stats.Removed + $stats.Synthesized
        if ($total -gt 0) {
            Write-Verbose "Repaired: relocated $($stats.Relocated) orphaned tool events, removed $($stats.Removed) error/malformed events, synthesized $($stats.Synthesized) missing completions"
        }

        # Write back to file or return lines
        if ($eventsFile) {
            if (-not $PSCmdlet.ShouldProcess($eventsFile, "Overwrite with $($output.Count) repaired events")) {
                return
            }
            if (-not $NoBackup) {
                Copy-Item -LiteralPath $eventsFile -Destination "$eventsFile.bak" -Force
            }
            $content = $output -join "`r`n"
            [System.IO.File]::WriteAllText($eventsFile, "$content`r`n", [System.Text.UTF8Encoding]::new($false))
            Write-Verbose "Wrote $($output.Count) events (was $($lines.Count))"
        } else {
            return [string[]]$output
        }
    }
}
