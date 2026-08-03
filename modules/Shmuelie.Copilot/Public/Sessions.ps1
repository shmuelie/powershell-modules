function Get-CopilotSession {
    <#
    .SYNOPSIS
        Lists GitHub Copilot CLI sessions, optionally filtered to the current directory.

    .DESCRIPTION
        Enumerates session-state directories under ~/.copilot/session-state/ and
        parses each workspace.yaml to extract session metadata. Includes
        EventCount and EventSize for diagnosing oversized sessions.

        By default only sessions matching the current working directory are returned.
        Use -All to return every session regardless of directory.

    .PARAMETER All
        Return sessions for all directories, not just the current one.

    .PARAMETER Id
        Return only the session with the specified ID.

    .EXAMPLE
        Get-CopilotSession
        # Lists sessions for the current directory.

    .EXAMPLE
        Get-CopilotSession -All
        # Lists all sessions across every directory.

    .EXAMPLE
        Get-CopilotSession -Id "abc-123"
        # Returns the session with the given ID.
    #>
    [OutputType('CopilotSession')]
    [CmdletBinding(DefaultParameterSetName = 'Filter')]
    param(
        [Parameter(ParameterSetName = 'Filter')]
        [switch]$All,

        [Parameter(ParameterSetName = 'ById', Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Id
    )

    $sessionStateDir = Join-Path $env:USERPROFILE '.copilot' 'session-state'
    if (-not (Test-Path $sessionStateDir)) {
        return
    }

    $cwd = (Get-Location).Path

    $dirs = if ($Id) {
        $target = Join-Path $sessionStateDir $Id
        if (Test-Path $target) { Get-Item $target } else { return }
    } else {
        Get-ChildItem $sessionStateDir -Directory
    }

    $dirs | ForEach-Object {
        $wsFile = Join-Path $_.FullName 'workspace.yaml'
        if (Test-Path $wsFile) {
            $content = Get-Content $wsFile -Raw
            $sessionCwd = if ($content -match '(?m)^cwd:\s*(.+)$') { $Matches[1].Trim() }
            $updatedAt  = if ($content -match '(?m)^updated_at:\s*(.+)$') { $Matches[1].Trim() }
            $summary    = if ($content -match '(?m)^summary:\s*(.+)$') { $Matches[1].Trim() } else { $null }
            $branch     = if ($content -match '(?m)^branch:\s*(.+)$') { $Matches[1].Trim() }
            $repository = if ($content -match '(?m)^repository:\s*(.+)$') { $Matches[1].Trim() }
            $createdAt  = if ($content -match '(?m)^created_at:\s*(.+)$') { $Matches[1].Trim() }

            # Parse name field, handling YAML block scalars (|- or >-)
            $name = if ($content -match '(?m)^name:\s*[\|>]-?\s*$') {
                if ($content -match '(?m)^name:\s*[\|>]-?\s*\r?\n(\s{2,}.+)') { $Matches[1].Trim() }
            } elseif ($content -match '(?m)^name:\s+(.+)$') {
                $Matches[1].Trim()
            }

            if ($All -or $Id -or $sessionCwd -eq $cwd) {
                $eventsFile = Join-Path $_.FullName 'events.jsonl'
                $eventCount = 0
                $eventSize  = [long]0
                if (Test-Path $eventsFile) {
                    $fi = [System.IO.FileInfo]::new($eventsFile)
                    $eventSize = $fi.Length
                    # Stream-count lines without allocating the full string array
                    $reader = [System.IO.StreamReader]::new($fi.FullName)
                    try {
                        while ($null -ne $reader.ReadLine()) { $eventCount++ }
                    } finally {
                        $reader.Dispose()
                    }
                }
                [PSCustomObject]@{
                    PSTypeName = 'CopilotSession'
                    Id         = $_.Name
                    Name       = $name ?? $summary ?? '(no summary)'
                    Summary    = $name ?? $summary ?? '(no summary)'
                    Cwd        = $sessionCwd
                    Branch     = $branch
                    Repository = $repository
                    CreatedAt  = if ($createdAt) { [DateTimeOffset]::Parse($createdAt) } else { $null }
                    UpdatedAt  = if ($updatedAt) { [DateTimeOffset]::Parse($updatedAt) } else { $null }
                    EventCount = $eventCount
                    EventSize  = $eventSize
                    Path       = $_.FullName
                }
            }
        }
    } | Sort-Object UpdatedAt -Descending
}

function Remove-CopilotSession {
    <#
    .SYNOPSIS
        Removes one or more GitHub Copilot CLI sessions.

    .DESCRIPTION
        Deletes session-state directories by ID or by pipeline input from
        Get-CopilotSession. Supports -WhatIf and -Confirm via ShouldProcess.

    .PARAMETER Id
        One or more session IDs to remove.

    .PARAMETER InputObject
        Session objects piped from Get-CopilotSession.

    .EXAMPLE
        Remove-CopilotSession -Id "abc-123"
        # Removes a single session by ID.

    .EXAMPLE
        Get-CopilotSession -All | Remove-CopilotSession
        # Removes all sessions.

    .EXAMPLE
        Get-CopilotSession | Remove-CopilotSession -WhatIf
        # Shows which sessions would be removed for the current directory.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'ById')]
    param(
        [Parameter(ParameterSetName = 'ById', Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Id,

        [Parameter(ParameterSetName = 'ByObject', Mandatory, ValueFromPipeline)]
        [PSObject]$InputObject
    )

    process {
        $sessions = if ($PSCmdlet.ParameterSetName -eq 'ById') {
            $Id | ForEach-Object { Get-CopilotSession -Id $_ }
        } else {
            $InputObject
        }

        foreach ($s in $sessions) {
            if ($null -eq $s) { continue }
            if ($PSCmdlet.ShouldProcess("$($s.Summary) ($($s.Id))", 'Remove session')) {
                Remove-Item -LiteralPath $s.Path -Recurse -Force
            }
        }
    }
}

function Rename-CopilotSession {
    <#
    .SYNOPSIS
        Changes the display name of a Copilot CLI session.

    .DESCRIPTION
        Updates the name and/or summary field in workspace.yaml for the specified
        session. Handles both the newer 'name' field (including YAML block scalars)
        and the legacy 'summary' field. If both exist, both are updated.

    .PARAMETER Id
        The session ID to rename.

    .PARAMETER InputObject
        A session object piped from Get-CopilotSession.

    .PARAMETER Summary
        The new display name for the session.

    .EXAMPLE
        Rename-CopilotSession -Id "abc-123" -Name "Auth module refactor"
        # Sets the session name to "Auth module refactor".

    .EXAMPLE
        Get-CopilotSession | Where-Object Summary -eq '(no summary)' | Rename-CopilotSession -Name "Untitled session"
        # Renames all sessions with no name.
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'ById')]
    param(
        [Parameter(ParameterSetName = 'ById', Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Id,

        [Parameter(ParameterSetName = 'ByObject', Mandatory, ValueFromPipeline)]
        [PSObject]$InputObject,

        [Parameter(Mandatory, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [Alias('Name')]
        [string]$Summary
    )

    process {
        $session = if ($PSCmdlet.ParameterSetName -eq 'ById') {
            Get-CopilotSession -Id $Id
        } else {
            $InputObject
        }

        if ($null -eq $session) {
            Write-Error 'Session not found.'
            return
        }

        $wsFile = Join-Path $session.Path 'workspace.yaml'
        if (-not (Test-Path $wsFile)) {
            Write-Error "workspace.yaml not found for session $($session.Id)."
            return
        }

        if (-not $PSCmdlet.ShouldProcess("$($session.Summary) ($($session.Id.Substring(0,8)))", "Rename to '$Summary'")) {
            return
        }

        $content = Get-Content $wsFile -Raw

        # Replace name field (handles block scalars like |- or >-)
        $hasName = $content -match '(?m)^name:'
        if ($hasName) {
            $yamlLines = $content -split '\r?\n'
            $newLines = [System.Collections.Generic.List[string]]::new()
            $skipBlock = $false
            foreach ($line in $yamlLines) {
                if ($line -match '^name:') {
                    $newLines.Add("name: $Summary")
                    $skipBlock = ($line -match ':\s*[\|>]')
                    continue
                }
                if ($skipBlock -and ($line -match '^\s' -or $line -eq '')) { continue }
                $skipBlock = $false
                $newLines.Add($line)
            }
            $content = $newLines -join "`n"
        }

        # Also update summary field if present
        if ($content -match '(?m)^summary:') {
            $content = $content -replace '(?m)^summary:\s*.+$', "summary: $Summary"
        }

        [System.IO.File]::WriteAllText($wsFile, $content, [System.Text.UTF8Encoding]::new($false))
        Write-Verbose "Renamed session $($session.Id.Substring(0,8)) to '$Summary'"

        Get-CopilotSession -Id $session.Id
    }
}

function Resume-CopilotSession {
    <#
    .SYNOPSIS
        Resumes a specific GitHub Copilot CLI session by ID or pipeline input.

    .DESCRIPTION
        Launches the Copilot CLI with --resume targeting the specified session.
        Accepts a session ID directly or a session object piped from Get-CopilotSession.

    .PARAMETER Id
        The session ID to resume.

    .PARAMETER InputObject
        A session object piped from Get-CopilotSession.

    .PARAMETER Prompt
        Optional prompt to execute in autopilot mode within the resumed session.

    .PARAMETER RemainingArgs
        Any additional arguments passed through to the copilot executable.

    .EXAMPLE
        Resume-CopilotSession -Id "abc-123"
        # Resumes the session interactively.

    .EXAMPLE
        Get-CopilotSession | Select-Object -First 1 | Resume-CopilotSession
        # Resumes the most recent session for the current directory.

    .EXAMPLE
        Resume-CopilotSession -Id "abc-123" -Prompt "Continue refactoring"
        # Resumes the session in autopilot mode with the given prompt.
    #>
    [CmdletBinding(DefaultParameterSetName = 'ById')]
    param(
        [Parameter(ParameterSetName = 'ById', Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Id,

        [Parameter(ParameterSetName = 'ByObject', Mandatory, ValueFromPipeline)]
        [PSObject]$InputObject,

        [Parameter(Position = 1)]
        [string]$Prompt,

        [Parameter(ValueFromRemainingArguments)]
        [string[]]$RemainingArgs
    )

    process {
        $sessionId = if ($PSCmdlet.ParameterSetName -eq 'ById') { $Id } else { $InputObject.Id }
        $session = Get-CopilotSession -Id $sessionId
        if ($null -eq $session) {
            Write-Error "Session '$sessionId' not found."
            return
        }

        $copilotExe = (Get-Command copilot -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        $copilotArgs = @('--allow-all', '--experimental', '--resume', $session.Id)

        Write-Verbose "Resuming session: $($session.Summary)"
        Write-Verbose "  Last updated $($session.UpdatedAt.LocalDateTime)"

        if ($Prompt) {
            $copilotArgs += '--autopilot', '-p', $Prompt
        }

        if ($RemainingArgs) {
            $copilotArgs += $RemainingArgs
        }

        & $copilotExe @copilotArgs
    }
}
