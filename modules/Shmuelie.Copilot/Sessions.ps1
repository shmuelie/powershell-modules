function Get-CopilotSession {
    <#
    .SYNOPSIS
        Lists GitHub Copilot CLI sessions with directory, metadata, and age filters.

    .DESCRIPTION
        Enumerates session-state directories under ~/.copilot/session-state/ and
        parses each workspace.yaml to extract session metadata. Includes
        EventCount and EventSize for diagnosing oversized sessions.

        By default only sessions matching the current working directory are returned.
        Use -All to search every directory, or -Cwd to replace the implicit current
        directory scope. Repository, Branch, and Summary do not broaden that scope.
        All supplied filters must match. String filters use case-insensitive
        PowerShell wildcards against recorded metadata, without resolving paths.
        Results remain sorted by UpdatedAt descending.

        Missing repository, branch, or cwd metadata does not match even '*'.
        Summary matches the displayed Summary (name, then legacy summary, then
        '(no summary)'). Missing UpdatedAt never matches a date filter; no
        creation time or filesystem timestamp is substituted.

    .PARAMETER All
        Search sessions for all directories, still applying any supplied filters.

    .PARAMETER Id
        Return only the session with the specified ID. The ID must be a single
        session directory name (a GUID for CLI-created sessions); values with path
        separators, drive qualifiers, or relative segments are rejected so they
        cannot escape the session-state root. This is an exact lookup, independent
        of the current directory, and cannot be combined with All or filters.

    .PARAMETER Repository
        Match recorded Repository using a case-insensitive wildcard pattern.

    .PARAMETER Branch
        Match recorded Branch using a case-insensitive wildcard pattern.

    .PARAMETER Cwd
        Match recorded Cwd using a case-insensitive wildcard pattern instead of
        the implicit current-directory restriction. Paths are not normalized or
        resolved; escape literal wildcard characters with a PowerShell backtick.

    .PARAMETER Summary
        Match the displayed Summary using a case-insensitive wildcard pattern.
        Unnamed sessions have the displayed value '(no summary)'.

    .PARAMETER UpdatedBefore
        Return sessions whose UpdatedAt is strictly earlier than this DateTimeOffset
        instant. Use ISO 8601 with Z or an explicit offset for portable results.
        Input without an offset is interpreted in the local timezone. A date-only
        input means local midnight, not the end of that day.

    .PARAMETER OlderThan
        Return sessions last updated strictly more than this positive TimeSpan ago.
        Use New-TimeSpan -Days 30 or [timespan]::FromDays(30), not a bare number.
        The UTC clock is sampled once per invocation; days are elapsed 24-hour
        periods, not calendar days. With UpdatedBefore, both limits must match.

    .EXAMPLE
        Get-CopilotSession
        # Lists sessions for the current directory.

    .EXAMPLE
        Get-CopilotSession -All
        # Lists all sessions across every directory.

    .EXAMPLE
        Get-CopilotSession -Id "abc-123"
        # Returns the session with the given ID.

    .EXAMPLE
        Get-CopilotSession -All -Repository 'owner/*' -Branch 'feature/*' -Summary '*cleanup*'
        # Combines filters across every directory.

    .EXAMPLE
        Get-CopilotSession -All -UpdatedBefore '2026-08-01T00:00:00Z' -OlderThan (New-TimeSpan -Days 30) |
            Remove-CopilotSession -WhatIf
        # Previews cleanup of sessions matching both exclusive age cutoffs.
    #>
    [OutputType('CopilotSession')]
    [CmdletBinding(DefaultParameterSetName = 'Filter')]
    param(
        [Parameter(ParameterSetName = 'Filter')]
        [switch]$All,

        [Parameter(ParameterSetName = 'ById', Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Id,

        [Parameter(ParameterSetName = 'Filter')]
        [SupportsWildcards()]
        [ValidateNotNullOrEmpty()]
        [string]$Repository,

        [Parameter(ParameterSetName = 'Filter')]
        [SupportsWildcards()]
        [ValidateNotNullOrEmpty()]
        [string]$Branch,

        [Parameter(ParameterSetName = 'Filter')]
        [SupportsWildcards()]
        [ValidateNotNullOrEmpty()]
        [string]$Cwd,

        [Parameter(ParameterSetName = 'Filter')]
        [SupportsWildcards()]
        [ValidateNotNullOrEmpty()]
        [string]$Summary,

        [Parameter(ParameterSetName = 'Filter')]
        [datetimeoffset]$UpdatedBefore,

        [Parameter(ParameterSetName = 'Filter')]
        [ValidateScript({ $_ -gt [timespan]::Zero }, ErrorMessage = 'OlderThan must be a positive TimeSpan.')]
        [timespan]$OlderThan
    )

    $filters = @{}
    foreach ($filter in 'Repository', 'Branch', 'Cwd', 'Summary', 'UpdatedBefore', 'OlderThan') {
        if ($PSBoundParameters.ContainsKey($filter)) {
            $filters[$filter] = $PSBoundParameters[$filter]
        }
    }
    $sessionStateDir = Join-Path (Get-CopilotHome) '.copilot' 'session-state'
    if (-not (Test-Path $sessionStateDir)) {
        return
    }

    $currentDirectory = (Get-Location).Path

    $dirs = if ($Id) {
        $target = Resolve-CopilotSessionPath -Id $Id
        if ($target) { Get-Item -LiteralPath $target } else { return }
    } else {
        Get-ChildItem $sessionStateDir -Directory
    }

    $dirs | ForEach-Object {
        $wsFile = Join-Path $_.FullName 'workspace.yaml'
        if (Test-Path $wsFile) {
            $content = Get-Content $wsFile -Raw
            $sessionCwd        = Get-CopilotWorkspaceField -Content $content -Field 'cwd'
            $updatedAt         = Get-CopilotWorkspaceField -Content $content -Field 'updated_at'
            $sessionSummary    = Get-CopilotWorkspaceField -Content $content -Field 'summary'
            $sessionBranch     = Get-CopilotWorkspaceField -Content $content -Field 'branch'
            $sessionRepository = Get-CopilotWorkspaceField -Content $content -Field 'repository'
            $createdAt         = Get-CopilotWorkspaceField -Content $content -Field 'created_at'
            $name              = Get-CopilotWorkspaceField -Content $content -Field 'name'
            if ($name) { $name = ($name -split '\r?\n', 2)[0].Trim() }

            if ($All -or $Id -or $filters.ContainsKey('Cwd') -or $sessionCwd -eq $currentDirectory) {
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
                    Name       = $name ?? $sessionSummary ?? '(no summary)'
                    Summary    = $name ?? $sessionSummary ?? '(no summary)'
                    Cwd        = $sessionCwd
                    Branch     = $sessionBranch
                    Repository = $sessionRepository
                    CreatedAt  = if ($createdAt) { [DateTimeOffset]::Parse($createdAt) } else { $null }
                    UpdatedAt  = if ($updatedAt) { [DateTimeOffset]::Parse($updatedAt) } else { $null }
                    EventCount = $eventCount
                    EventSize  = $eventSize
                    Path       = $_.FullName
                }
            }
        }
    } | Select-CopilotSessionMatch @filters | Sort-Object UpdatedAt -Descending
}

function Remove-CopilotSession {
    <#
    .SYNOPSIS
        Removes one or more GitHub Copilot CLI sessions.

    .DESCRIPTION
        Deletes session-state directories by ID or by pipeline input from
        Get-CopilotSession. Supports -WhatIf and -Confirm via ShouldProcess.

        Each target is re-resolved by its ID through the session-state root guard
        before deletion, so an untrusted pipeline object's Path is never used and
        an ID that escapes the session-state root is rejected.

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
        $ids = if ($PSCmdlet.ParameterSetName -eq 'ById') {
            $Id
        } elseif ($null -ne $InputObject) {
            @($InputObject.Id)
        } else {
            @()
        }

        foreach ($sid in $ids) {
            if ([string]::IsNullOrWhiteSpace($sid)) {
                Write-Error 'The pipeline input does not contain a session Id.'
                continue
            }
            # Re-resolve by ID so the deletion target is the guard-validated
            # canonical path, never a caller-supplied InputObject.Path.
            $s = Get-CopilotSession -Id $sid
            if ($null -eq $s) {
                Write-Error "Session '$sid' not found."
                continue
            }
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

        The session is re-resolved by its ID through the session-state root guard
        before workspace.yaml is rewritten, so an untrusted pipeline object's Path
        is never used and an ID that escapes the session-state root is rejected.

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
        $sessionId = if ($PSCmdlet.ParameterSetName -eq 'ById') { $Id } else { $InputObject.Id }
        if ([string]::IsNullOrWhiteSpace($sessionId)) {
            Write-Error 'The pipeline input does not contain a session Id.'
            return
        }

        # Re-resolve by ID so the rewrite target is the guard-validated canonical
        # path, never a caller-supplied InputObject.Path.
        $session = Get-CopilotSession -Id $sessionId
        if ($null -eq $session) {
            Write-Error "Session '$sessionId' not found."
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

        $content = Set-CopilotWorkspaceField -Content $content -Field 'name' -Value $Summary
        $content = Set-CopilotWorkspaceField -Content $content -Field 'summary' -Value $Summary

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
