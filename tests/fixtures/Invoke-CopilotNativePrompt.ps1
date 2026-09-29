param(
    [Parameter(Mandatory)]
    [string]$CasePath,

    [Parameter(Mandatory)]
    [string]$ResultPath
)

$ErrorActionPreference = 'Stop'
Import-Module Microsoft.PowerShell.Management, Microsoft.PowerShell.Utility
$PSModuleAutoLoadingPreference = 'None'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repoRoot 'modules' 'Shmuelie.Copilot' 'SessionSelection.ps1')

$env:PATH = ''
function Get-CopilotHome { throw 'Unexpected session access.' }
function Get-CopilotResumeCandidate { throw 'Unexpected candidate discovery.' }
function copilot { throw 'Unexpected Copilot launch.' }
function git { throw 'Unexpected git execution.' }
function Read-Host { throw 'Unexpected custom input.' }

$case = Get-Content -LiteralPath $CasePath -Raw | ConvertFrom-Json
if ($case.Count -lt 1 -or $case.ExitLabel -cnotin @('&Cancel', '&New session')) {
    throw 'Invalid synthetic prompt case.'
}
$sessions = @(
    foreach ($i in 1..$case.Count) {
        [pscustomobject]@{
            PSTypeName = 'CopilotSession'
            Id = "id-$i"
            Summary = if ($case.Summary) { $case.Summary } else { "Session $i" }
            Branch = 'synthetic&branch'
            Repository = 'owner/repo'
            Cwd = $PSScriptRoot
            UpdatedAt = [datetimeoffset]'2026-09-01T12:00:00Z'
            EventCount = $i
        }
    }
)

# Only the shared picker is invoked: no Copilot module import, discovery, or CLI launch.
$selected = Invoke-CopilotSessionChoice -Sessions $sessions -Caption 'Synthetic session selection' `
    -Message 'Choose synthetic data only.' -ExitLabel $case.ExitLabel -ExitHelp 'End this synthetic selection.'
$selectedIndex = -1
for ($i = 0; $i -lt $sessions.Count; $i++) {
    if ([object]::ReferenceEquals($selected, $sessions[$i])) {
        $selectedIndex = $i
        break
    }
}
if ($null -ne $selected -and $selectedIndex -eq -1) {
    throw 'The picker did not return an original candidate.'
}
[pscustomobject]@{
    SelectedId = $selected.Id
    SelectedIndex = $selectedIndex
    ProcessId = $PID
    PowerShellVersion = $PSVersionTable.PSVersion.ToString()
} | ConvertTo-Json | Set-Content -LiteralPath $ResultPath -Encoding utf8
