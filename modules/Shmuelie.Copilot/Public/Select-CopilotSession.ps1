function Invoke-CopilotSessionPicker {
    param(
        [Parameter(Mandatory)]
        [object[]]$Sessions
    )

    $choices = @($Sessions | ForEach-Object {
        [PSCustomObject]@{
            Id         = $_.Id
            Name       = $_.Name
            Summary    = $_.Summary
            Repository = $_.Repository
            Branch     = $_.Branch
            Cwd        = $_.Cwd
            UpdatedAt  = $_.UpdatedAt
            EventCount = $_.EventCount
            Session    = $_
        }
    })

    if (Get-Command Out-ConsoleGridView -ErrorAction SilentlyContinue) {
        $selected = $choices | Out-ConsoleGridView -OutputMode Single
        return $selected.Session
    }

    if (Get-Command Out-GridView -ErrorAction SilentlyContinue) {
        $selected = $choices | Out-GridView -Title 'Select Copilot session to resume' -PassThru
        return $selected.Session
    }

    Write-Host 'Select a Copilot session to resume:' -ForegroundColor Yellow
    Write-Host ''
    for ($i = 0; $i -lt $choices.Count; $i++) {
        $choice = $choices[$i]
        $updatedAt = if ($choice.UpdatedAt) { $choice.UpdatedAt.LocalDateTime } else { '(unknown)' }
        Write-Host ("  [{0}] {1}" -f ($i + 1), $choice.Summary) -ForegroundColor ($(if ($i -eq 0) { 'Cyan' } else { 'Gray' }))
        Write-Host ("      Repo: {0}  Branch: {1}" -f ($choice.Repository ?? '(unknown)'), ($choice.Branch ?? '(unknown)')) -ForegroundColor DarkGray
        Write-Host ("      Cwd: {0}" -f ($choice.Cwd ?? '(unknown)')) -ForegroundColor DarkGray
        Write-Host ("      Updated: {0}  Events: {1}" -f $updatedAt, $choice.EventCount) -ForegroundColor DarkGray
    }
    Write-Host '  [Q] Cancel' -ForegroundColor Green
    Write-Host ''

    do {
        Write-Host "Select session [1-$($choices.Count)/Q]: " -NoNewline -ForegroundColor Yellow
        $selection = Read-Host
        if ($selection -in @('Q', 'q')) { return $null }
        $number = $selection -as [int]
    } while ($null -eq $number -or $number -lt 1 -or $number -gt $choices.Count)

    return $choices[$number - 1].Session
}

function Select-CopilotSession {
    <#
    .SYNOPSIS
        Selects and resumes a Copilot CLI session from all sessions on the machine.

    .DESCRIPTION
        Lists sessions from Get-CopilotSession -All, optionally filters them by
        ID, repository, or branch, and resumes the selected session by delegating
        to Resume-CopilotSession. When filters and -First resolve to exactly one
        session, the picker is skipped. Otherwise, the command prefers
        Out-ConsoleGridView, then Out-GridView, then a numbered console prompt.

        By default the resume runs from the session's recorded Cwd so sessions
        from other directories restore their original workspace context. Use
        -StayInDirectory to resume from the current directory instead.

    .PARAMETER Id
        Select a session by ID. Wildcards are supported.

    .PARAMETER Repository
        Filter sessions by repository. Wildcards are supported.

    .PARAMETER Branch
        Filter sessions by branch. Wildcards are supported.

    .PARAMETER First
        Take the first N matching sessions after sorting by UpdatedAt descending.
        Use -First 1 to resume the most recent matching session without a picker.

    .PARAMETER StayInDirectory
        Resume the chosen session from the current directory instead of changing
        to the session's recorded Cwd.

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

        [ValidateRange(1, [int]::MaxValue)]
        [int]$First,

        [switch]$StayInDirectory,

        [string]$Prompt,

        [Parameter(ValueFromRemainingArguments)]
        [string[]]$RemainingArgs
    )

    $sessions = @(Get-CopilotSession -All | Sort-Object UpdatedAt -Descending)

    if ($Id) {
        $sessions = @($sessions | Where-Object { $_.Id -like $Id })
    }

    if ($Repository) {
        $sessions = @($sessions | Where-Object { $_.Repository -like $Repository })
    }

    if ($Branch) {
        $sessions = @($sessions | Where-Object { $_.Branch -like $Branch })
    }

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

        Invoke-CopilotSessionPicker -Sessions $sessions
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
