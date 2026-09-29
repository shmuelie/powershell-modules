function Get-CopilotResumeCandidate {
    [CmdletBinding()]
    [OutputType('CopilotSession')]
    param()

    $sessionStateDir = Join-Path (Get-CopilotHome) '.copilot' 'session-state'
    $ignoredSessionNames = @(
        'Apply context_board add/prune updates for this session. End the turn with a 2-3 sentence summary of the changes you made to the context_board.'
        'Analyze the session file and write the session insights result to the specified output file as described in the instructions.'
        'Session File Path:'
    )
    if (-not (Test-Path $sessionStateDir)) {
        return
    }

    $cwd = (Get-Location).Path
    $currentBranch = try { git symbolic-ref --short HEAD 2>$null } catch { $null }
    $sessions = @(Get-ChildItem $sessionStateDir -Directory |
        ForEach-Object {
            $sessionPath = Resolve-CopilotSessionPath -Id $_.Name -ErrorAction Stop
            if (-not $sessionPath) {
                throw "Copilot session candidate '$($_.Name)' no longer exists."
            }
            $wsFile = Join-Path $sessionPath 'workspace.yaml'
            if (Test-Path $wsFile) {
                $content = Get-Content $wsFile -Raw
                $sessionCwd = Get-CopilotWorkspaceField -Content $content -Field 'cwd'
                $updatedAt = Get-CopilotWorkspaceField -Content $content -Field 'updated_at'
                $summary = Get-CopilotWorkspaceField -Content $content -Field 'summary'
                $sessionBranch = Get-CopilotWorkspaceField -Content $content -Field 'branch'
                $sessionName = Get-CopilotWorkspaceField -Content $content -Field 'name'
                if ($sessionName) { $sessionName = ($sessionName -split '\r?\n', 2)[0].Trim() }
                $displayName = $sessionName ?? $summary ?? '(no summary)'
                if ($sessionCwd -eq $cwd -and $updatedAt -and $sessionName -notin $ignoredSessionNames) {
                    [PSCustomObject]@{
                        PSTypeName = 'CopilotSession'
                        Id         = $_.Name
                        Name       = $displayName
                        Summary    = $displayName
                        Branch     = $sessionBranch
                        UpdatedAt  = [DateTimeOffset]::Parse($updatedAt)
                        Cwd        = $sessionCwd
                    }
                }
            }
        } |
        Sort-Object UpdatedAt -Descending)

    # Prefer the current branch only when it has matches; otherwise retain all.
    if ($currentBranch -and $sessions.Count -gt 0) {
        $branchMatches = @($sessions | Where-Object { $_.Branch -and $_.Branch -eq $currentBranch })
        if ($branchMatches.Count -gt 0) {
            $sessions = $branchMatches
        }
    }
    return $sessions
}

function ConvertTo-CopilotSessionDisplayText {
    param([string]$Text)

    # Keep Unicode graphemes (including joiners) intact, but prevent terminal
    # controls and line separators from acting as UI rather than session data.
    $Text -replace '[\p{Cc}\p{Zl}\p{Zp}]', ' '
}

function Invoke-CopilotSessionChoice {
    [CmdletBinding()]
    [OutputType('CopilotSession')]
    param(
        [Parameter(Mandatory)]
        [object[]]$Sessions,

        [Parameter(Mandatory)]
        [string]$Caption,

        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter(Mandatory)]
        [string]$ExitLabel,

        [Parameter(Mandatory)]
        [string]$ExitHelp
    )

    $nameCounts = [System.Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
    $displaySessions = @(
        foreach ($session in $Sessions) {
            $name = ConvertTo-CopilotSessionDisplayText $session.Summary
            $elements = [System.Globalization.StringInfo]::new($name)
            $displayName = if ($elements.LengthInTextElements -gt 80) {
                $elements.SubstringByTextElements(0, 77) + '...'
            } else {
                $name
            }
            if (-not $nameCounts.ContainsKey($displayName)) { $nameCounts[$displayName] = 0 }
            $nameCounts[$displayName]++
            [pscustomobject]@{
                Name = $name
                DisplayName = $displayName
                Branch = ConvertTo-CopilotSessionDisplayText $session.Branch
            }
        }
    )
    # C/M/N/P are reserved for Cancel, Next page, New session, and Previous page.
    $sessionKeys = 'ABDEFGHIJKLOQRSTUVWXYZ'
    $pageSize = $sessionKeys.Length
    $pageStart = 0
    $pageCount = [int][Math]::Ceiling($Sessions.Count / [double]$pageSize)
    # A method failure must terminate even when the caller uses Continue.
    $ErrorActionPreference = 'Stop'
    while ($true) {
        $choices = [System.Collections.ObjectModel.Collection[System.Management.Automation.Host.ChoiceDescription]]::new()
        $sessionCount = [Math]::Min($pageSize, $Sessions.Count - $pageStart)
        $pageEnd = $pageStart + $sessionCount
        for ($i = $pageStart; $i -lt $pageEnd; $i++) {
            $session = $Sessions[$i]
            $display = $displaySessions[$i]
            $branchSuffix = if ($nameCounts[$display.DisplayName] -gt 1 -and -not [string]::IsNullOrWhiteSpace($display.Branch)) {
                " ($($display.Branch))"
            } else {
                ''
            }
            $updatedAt = if ($session.UpdatedAt) { $session.UpdatedAt.ToString('o') } else { '(unknown)' }
            $help = "Id: $($session.Id)`nName: $($display.Name)`nRepository: $($session.Repository)`nBranch: $($display.Branch)`nCwd: $($session.Cwd)`nUpdated: $updatedAt`nEvents: $($session.EventCount)"
            # The host consumes the first '&'; later ampersands stay session data.
            $label = "&$($sessionKeys[$i - $pageStart]) - $($display.DisplayName)$branchSuffix"
            $choices.Add([System.Management.Automation.Host.ChoiceDescription]::new($label, $help))
        }
        $previousChoice = -1
        $nextChoice = -1
        if ($pageStart -gt 0) {
            $previousChoice = $choices.Count
            $choices.Add([System.Management.Automation.Host.ChoiceDescription]::new(
                '&P - Previous page', 'Show the previous sessions without selecting one.'))
        }
        if ($pageEnd -lt $Sessions.Count) {
            $nextChoice = $choices.Count
            $choices.Add([System.Management.Automation.Host.ChoiceDescription]::new(
                '&M - Next page', 'Show the next sessions without selecting one.'))
        }
        $choices.Add([System.Management.Automation.Host.ChoiceDescription]::new($ExitLabel, $ExitHelp))
        $pageNumber = [int]($pageStart / $pageSize) + 1
        $promptMessage = "$Message`n`nSessions $($pageStart + 1)-$pageEnd of $($Sessions.Count) (page $pageNumber of $pageCount).`nChoose a session key or an action. Use choice help for full names, IDs, and workspace details."

        try {
            if ($null -eq $Host.UI) {
                throw [System.NotSupportedException]::new('The active host has no user interface.')
            }
            $selected = $Host.UI.PromptForChoice($Caption, $promptMessage, $choices, -1)
        } catch {
            throw [System.InvalidOperationException]::new(
                "Session selection requires a host with working PromptForChoice input. Supply -SessionSelector or choose a session explicitly. Host error: $($_.Exception.Message)",
                $_.Exception)
        }
        if ($selected -isnot [int] -or $selected -lt 0 -or $selected -ge $choices.Count) {
            throw "The host returned an invalid session choice '$selected'. Supply -SessionSelector or choose a session explicitly."
        }
        if ($selected -lt $sessionCount) { return $Sessions[$pageStart + $selected] }
        if ($selected -eq $previousChoice) {
            $pageStart -= $pageSize
        } elseif ($selected -eq $nextChoice) {
            $pageStart = $pageEnd
        } else {
            return $null
        }
    }
}

function Invoke-CopilotLaunchSessionPicker {
    [CmdletBinding()]
    [OutputType('CopilotSession')]
    param(
        [Parameter(Mandatory)]
        [object[]]$Sessions,

        [scriptblock]$SessionSelector
    )

    if ($SessionSelector) {
        return Invoke-CopilotSessionSelector -Sessions $Sessions -SessionSelector $SessionSelector
    }
    $picked = Invoke-CopilotSessionChoice -Sessions $Sessions -Caption 'Choose Copilot session' `
        -Message 'Choose a session for the current folder, or New session to start without resuming.' `
        -ExitLabel '&New session' -ExitHelp 'Start a new session instead of resuming an existing one.'
    if ($picked) {
        Write-Host "Resuming session: $(ConvertTo-CopilotSessionDisplayText $picked.Summary)" -ForegroundColor Cyan
    }
    return $picked
}

function Invoke-CopilotSessionSelector {
    [CmdletBinding()]
    [OutputType('CopilotSession')]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Sessions,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [scriptblock]$SessionSelector
    )

    if ($Sessions.Count -eq 0) {
        return $null
    }

    # Keep canonical metadata separate from the objects given to caller code.
    $candidates = @($Sessions | ForEach-Object {
        if ($_.PSObject.TypeNames -notcontains 'CopilotSession') {
            throw 'Session candidates must be CopilotSession objects.'
        }
        if (-not (Resolve-CopilotSessionPath -Id $_.Id -ErrorAction Stop)) {
            throw "Copilot session candidate '$($_.Id)' no longer exists."
        }
        $_.PSObject.Copy()
    })
    $selectorSessions = @($candidates | ForEach-Object { $_.PSObject.Copy() })
    $output = @(& $SessionSelector $selectorSessions 2>&1)
    foreach ($item in $output) {
        if ($item -is [System.Management.Automation.ErrorRecord]) {
            $PSCmdlet.ThrowTerminatingError($item)
        }
    }

    if ($output.Count -eq 0 -or ($output.Count -eq 1 -and $null -eq $output[0])) {
        return $null
    }
    if ($output.Count -ne 1 -or
        $output[0].PSObject.TypeNames -notcontains 'CopilotSession' -or
        $output[0].Id -isnot [string] -or
        [string]::IsNullOrWhiteSpace($output[0].Id)) {
        throw 'SessionSelector must return exactly one CopilotSession candidate or $null (no output).'
    }

    $selectedId = $output[0].Id
    $selected = @($candidates | Where-Object { $_.Id -ceq $selectedId })
    if ($selected.Count -ne 1) {
        throw "SessionSelector returned a session that is not a candidate: '$selectedId'."
    }
    if (-not (Resolve-CopilotSessionPath -Id $selectedId -ErrorAction Stop)) {
        throw "Selected Copilot session '$selectedId' no longer exists."
    }
    return $selected[0]
}
