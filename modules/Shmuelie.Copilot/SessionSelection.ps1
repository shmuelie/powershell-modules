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

function Assert-CopilotSessionPickerInteractive {
    [CmdletBinding()]
    param()

    if (-not [Environment]::UserInteractive -or
        ($Host.Name -eq 'ConsoleHost' -and [Console]::IsInputRedirected)) {
        throw 'Session selection requires interactive input. Supply -SessionSelector, or choose a session explicitly instead of opening the default picker.'
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
    Assert-CopilotSessionPickerInteractive
    Write-Host "Multiple sessions found for this folder:" -ForegroundColor Yellow
    Write-Host ""
    for ($i = 0; $i -lt $Sessions.Count; $i++) {
        $s = $Sessions[$i]
        $branchSuffix = if ($s.Branch) { " ($($s.Branch))" } else { '' }
        $label = "  [$($i + 1)] $($s.Summary)$branchSuffix"
        $time  = "      $($s.UpdatedAt.LocalDateTime)"
        if ($i -eq 0) {
            Write-Host $label -ForegroundColor Cyan
            Write-Host $time -ForegroundColor DarkGray
        } else {
            Write-Host $label
            Write-Host $time -ForegroundColor DarkGray
        }
    }
    Write-Host "  [N] New session" -ForegroundColor Green
    Write-Host ""
    do {
        Write-Host "Select session [1-$($Sessions.Count)/N]: " -NoNewline -ForegroundColor Yellow
        $choice = Read-Host -ErrorAction Stop
        if ($choice -eq 'N' -or $choice -eq 'n') { return $null }
        $num = $choice -as [int]
    } while ($null -eq $num -or $num -lt 1 -or $num -gt $Sessions.Count)
    $picked = $Sessions[$num - 1]
    Write-Host "Resuming session: $($picked.Summary)" -ForegroundColor Cyan
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
