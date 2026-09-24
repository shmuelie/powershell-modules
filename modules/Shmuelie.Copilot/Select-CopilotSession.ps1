function Invoke-CopilotSessionPicker {
    param(
        [Parameter(Mandatory)]
        [object[]]$Sessions
    )

    Invoke-CopilotSessionChoice -Sessions $Sessions -Caption 'Select Copilot session to resume' `
        -Message 'Choose a session from all matching sessions, or Cancel to return without resuming.' `
        -ExitLabel '&Cancel' -ExitHelp 'Return without resuming or launching a session.'
}

function Select-CopilotSession {
    <#
    .SYNOPSIS
        Selects and resumes a Copilot CLI session from all sessions on the machine.

    .DESCRIPTION
        Lists sessions from Get-CopilotSession -All, optionally filters them by
        ID, repository, branch, cwd, summary, or age using the same matching logic
        as Get-CopilotSession. Discovery remains global, unlike Get-CopilotSession's
        default current-directory scope. All supplied filters must match.
        Resumes the selected session by delegating to Resume-CopilotSession.
        When filters and -First resolve to exactly one session, the picker is
        skipped. Otherwise, the active PowerShell host presents PromptForChoice
        with descriptive session labels, 22 sessions per page, and an explicit
        Cancel option on every page. M selects Next page and P selects Previous
        page when available; C cancels. Session keys are unique within each page.
        Names are capped at 80 Unicode text elements (including '...' when
        truncated); branches appear only for displayed names duplicated anywhere
        in the candidate set.
        Full names and context remain in choice help. Names/branches have terminal
        controls sanitized; assigned keys preserve exact selection even for
        duplicate names and literal ampersands. All matching sessions remain
        reachable, with no default choice or grid-view dependency.

        By default the resume runs from the session's recorded Cwd so sessions
        from other directories restore their original workspace context. Use
        -StayInDirectory to resume from the current directory instead.

    .PARAMETER Id
        Select a session by ID. Wildcards are supported.

    .PARAMETER Repository
        Filter sessions by repository. Case-insensitive wildcards are supported.
        Missing or empty Repository does not match even '*'.

    .PARAMETER Branch
        Filter sessions by branch. Case-insensitive wildcards are supported.
        Missing or empty Branch does not match even '*'.

    .PARAMETER Cwd
        Filter recorded working directories using case-insensitive wildcards.
        Paths are not normalized or resolved. Missing Cwd does not match '*'.

    .PARAMETER Summary
        Filter displayed Summary using case-insensitive wildcards (name, then
        legacy summary, then '(no summary)').

    .PARAMETER UpdatedBefore
        Match UpdatedAt strictly before this DateTimeOffset instant. Use ISO 8601
        with Z or an explicit offset. Input without an offset uses local time;
        a date-only input means local midnight. Missing UpdatedAt is excluded.

    .PARAMETER OlderThan
        Match UpdatedAt strictly more than this positive TimeSpan ago, measured
        against one UTC clock sample per invocation. Use New-TimeSpan -Days 30;
        a day means 24 elapsed hours. With UpdatedBefore, both limits must match.
        Missing UpdatedAt is excluded; there is no timestamp fallback.

    .PARAMETER First
        Take the first N matching sessions after sorting by UpdatedAt descending.
        Use -First 1 to resume the most recent matching session without a picker.

    .PARAMETER StayInDirectory
        Resume the chosen session from the current directory instead of changing
        to the session's recorded Cwd.

    .PARAMETER SessionSelector
        Optional scriptblock replacing the picker when multiple sessions match.
        Receives one object[] of CopilotSession candidates with Id, Name, Summary,
        Branch, UpdatedAt, and Cwd. Return one candidate or $null/no output to
        cancel without launching. Only a candidate's exact Id is accepted;
        returned metadata changes are ignored. Multiple objects, other output,
        errors, and noncandidate results terminate without launching or opening
        a fallback picker. Use Write-Host or Write-Verbose for diagnostics.
        A single match still skips selection. No matches retain the existing
        error, and -WhatIf never invokes a selector. Custom selectors work without
        an interactive console and are responsible for their own UI requirements.
        The default picker requires a host that supports PromptForChoice.
        Unavailable input, host errors, or invalid responses terminate without
        choosing a session or falling back to another UI. Confirmation remains
        managed by PowerShell's standard -Confirm and -WhatIf support.

    .PARAMETER Prompt
        Optional prompt to execute in autopilot mode within the resumed session.

    .PARAMETER RemainingArgs
        Any additional arguments passed through to Resume-CopilotSession.

    .EXAMPLE
        Select-CopilotSession
        # Shows a picker over all Copilot sessions and resumes the selected one.

    .EXAMPLE
        Select-CopilotSession -Repository 'shmuelie/powershell-modules' -Branch 'main' -First 1
        # Resumes the most recent matching session without opening the picker.

    .EXAMPLE
        Select-CopilotSession -Id 'abc-*' -WhatIf
        # Shows which matching session would be resumed without launching Copilot.

    .EXAMPLE
        Select-CopilotSession -SessionSelector {
            param([object[]]$Sessions)
            $Sessions | Sort-Object UpdatedAt -Descending | Select-Object -First 1
        }
        # A portable selector; returning $null instead cancels the resume.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [SupportsWildcards()]
        [ValidateNotNullOrEmpty()]
        [string]$Id,

        [SupportsWildcards()]
        [ValidateNotNullOrEmpty()]
        [string]$Repository,

        [SupportsWildcards()]
        [ValidateNotNullOrEmpty()]
        [string]$Branch,

        [SupportsWildcards()]
        [ValidateNotNullOrEmpty()]
        [string]$Cwd,

        [SupportsWildcards()]
        [ValidateNotNullOrEmpty()]
        [string]$Summary,

        [datetimeoffset]$UpdatedBefore,

        [ValidateScript({ $_ -gt [timespan]::Zero }, ErrorMessage = 'OlderThan must be a positive TimeSpan.')]
        [timespan]$OlderThan,

        [ValidateRange(1, [int]::MaxValue)]
        [int]$First,

        [switch]$StayInDirectory,

        [ValidateNotNull()]
        [scriptblock]$SessionSelector,

        [string]$Prompt,

        [Parameter(ValueFromRemainingArguments)]
        [string[]]$RemainingArgs
    )

    $filters = @{}
    foreach ($filter in 'Id', 'Repository', 'Branch', 'Cwd', 'Summary', 'UpdatedBefore', 'OlderThan') {
        if ($PSBoundParameters.ContainsKey($filter)) {
            $filters[$filter] = $PSBoundParameters[$filter]
        }
    }
    $sessions = @(Get-CopilotSession -All | Select-CopilotSessionMatch @filters | Sort-Object UpdatedAt -Descending)

    if ($First) {
        $sessions = @($sessions | Select-Object -First $First)
    }

    if ($sessions.Count -eq 0) {
        Write-Error 'No Copilot sessions matched the specified criteria.'
        return
    }

    $session = if ($sessions.Count -eq 1) {
        $sessions[0]
    } else {
        if ($WhatIfPreference) {
            Write-Error 'Multiple Copilot sessions matched. Refine the filters or use -First 1 to preview without opening the picker.'
            return
        }

        if ($SessionSelector) {
            Invoke-CopilotSessionSelector -Sessions $sessions -SessionSelector $SessionSelector
        } else {
            Invoke-CopilotSessionPicker -Sessions $sessions
        }
    }

    if ($null -eq $session) {
        return
    }

    $target = "$($session.Summary) ($($session.Id))"
    $action = if ($StayInDirectory) {
        'Resume Copilot session from current directory'
    } else {
        "Resume Copilot session from $($session.Cwd)"
    }

    if (-not $PSCmdlet.ShouldProcess($target, $action)) {
        return
    }

    $resumeParams = @{ Id = $session.Id }
    if ($Prompt) {
        $resumeParams['Prompt'] = $Prompt
    }

    if ($StayInDirectory) {
        if ($RemainingArgs) {
            Resume-CopilotSession @resumeParams -RemainingArgs $RemainingArgs
        } else {
            Resume-CopilotSession @resumeParams
        }
        return
    }

    if (-not $session.Cwd -or -not (Test-Path -LiteralPath $session.Cwd -PathType Container)) {
        Write-Error "Session '$($session.Id)' has no existing Cwd to resume from: $($session.Cwd)"
        return
    }

    Push-Location -LiteralPath $session.Cwd
    try {
        if ($RemainingArgs) {
            Resume-CopilotSession @resumeParams -RemainingArgs $RemainingArgs
        } else {
            Resume-CopilotSession @resumeParams
        }
    } finally {
        Pop-Location
    }
}
