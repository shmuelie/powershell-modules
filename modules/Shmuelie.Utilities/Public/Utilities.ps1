function Test-IsElevated {
    <#
    .SYNOPSIS
    Check if current session is elevated.
    .DESCRIPTION
    Returns $true if the session is running with administrator privileges on Windows
    or as root on non-Windows platforms.
    .EXAMPLE
    Test-IsElevated
    Returns $true if the current session is elevated.
    #>
    [CmdletBinding()]
    param()

	if ($PSVersionTable.PSVersion.Major -gt 5 -and -not $IsWindows) {
		return ((id -u) -eq 0)
	}
	return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function New-GlobalConstant {
    <#
    .SYNOPSIS
    Create a global constant variable.
    .DESCRIPTION
    Creates a variable with Constant and AllScope options in the Global scope.
    .PARAMETER Name
    The name of the variable to create.
    .PARAMETER Value
    The value to assign to the variable.
    .EXAMPLE
    New-GlobalConstant 'MyConst' 42
    Creates a global constant variable named MyConst with value 42.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        $Value
    )
	New-Variable -Name $Name -Value $Value -Option Constant,AllScope -Scope Global
}

function New-PathVariable {
    <#
    .SYNOPSIS
    Create a global constant variable if the given path exists.
    .DESCRIPTION
    Validates that the path exists before creating the variable via New-GlobalConstant.
    .PARAMETER Name
    The name of the variable to create.
    .PARAMETER Path
    The filesystem path to validate and assign. Variable is only created if the path exists.
    .EXAMPLE
    New-PathVariable 'RepoRoot' 'D:\source\repos'
    Creates a global constant RepoRoot if the path exists.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [string]$Path
    )
	if ($null -ne $Path -and (Test-Path -Path $Path) -eq $true) {
		New-GlobalConstant $Name $Path
	}
}

function Get-SessionTitle {
    <#
    .SYNOPSIS
    Build a descriptive title for the current PowerShell session.
    .DESCRIPTION
    Returns a string like 'PowerShell 7.4.0 (X64)' with prefixes for Windows PowerShell and elevated sessions.
    .EXAMPLE
    Get-SessionTitle
    Returns 'Elevated: PowerShell 7.4.0 (X64)' when running as administrator.
    #>
    [CmdletBinding()]
    param()
    $title = "PowerShell $($PSVersionTable.PSVersion) ($([System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture))"
    if ($PSVersionTable.PSVersion.Major -le 5) {
        $title = "Windows $title"
    }
    if (Test-IsElevated) {
        $profileIsElevated = $global:WTProfile -and $global:WTProfile.name -match 'Elevated'
        if (-not $profileIsElevated) {
            $title = "🛡️ $title"
        }
    }
    return $title
}

function Reset-TerminalModes {
    <#
    .SYNOPSIS
    Reset the terminal's DEC private modes and kitty keyboard flags after a crashed TUI.
    .DESCRIPTION
    A TUI program (e.g. the Copilot engine) that crashes can leave the terminal
    with mouse tracking, focus reporting, the alternate screen buffer, bracketed paste,
    synchronized output, and the kitty keyboard protocol still enabled — making the
    shell unusable. This emits a DECRST sequence that disables all of them so the shell
    recovers.

    The modes reset (via `CSI ? Pm l` — the '?' is REQUIRED; the ANSI-RM form `CSI Pm l`
    without it is a silent no-op for these DEC private modes): 2026 synchronized output,
    2004 bracketed paste, 1049 alternate screen, 1006/1003/1000 SGR/any-event/normal
    mouse, and 1004 focus reporting. It then force-resets the kitty keyboard flags with
    `CSI = 0 u` (more robust for crash recovery than `CSI < u`, which only pops one entry
    off the kitty stack).

    All modes are already off in a healthy terminal, so this is idempotent and harmless
    to call repeatedly (e.g. from the prompt). No-ops when stdout is redirected so the
    escape bytes can't corrupt captured output.
    .EXAMPLE
    Reset-TerminalModes
    Restores normal terminal input/output after an engine crash.
    #>
    [CmdletBinding()]
    param()
    if ([Console]::IsOutputRedirected) { return }
    [Console]::Write("`e[?2026;2004;1049;1006;1004;1003;1000l`e[=0u")
}

function Import-ModuleSafe {
    <#
    .SYNOPSIS
    Import a PowerShell module if its path exists.
    .DESCRIPTION
    Checks whether the specified path exists before attempting to import the module.
    Silently does nothing if the path is not found.
    .PARAMETER Path
    The path to the module file or directory. The module is only imported if the path exists.
    .EXAMPLE
    Import-ModuleSafe 'D:\PowerShell\Modules\MyModule\MyModule.psd1'
    Imports the module if the file exists.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )
    if ((Test-Path -Path $Path) -eq $true) {
        Import-Module $Path
    }
}

function Invoke-InLocation {
    <#
    .SYNOPSIS
    Invoke a script with a given current location
    .DESCRIPTION
    The script is run with the chosen location and will return to the current location after, even if the script is interrupted.
    .PARAMETER Location
    The location to change to before running the script.
    .PARAMETER ScriptBlock
    The script to run in the location
    .EXAMPLE
    Invoke-InLocation -Location $HOME -ScriptBlock { ls }
    #>
    [CmdletBinding()]
    param(
        [Alias('Path')]
        [ValidateScript({ Test-Path $_ })]
        [string]$Location,
        [Alias('Process')]
        [scriptblock]$ScriptBlock
    )
    begin {
        Push-Location -Path $Location
    }
    process {
        & $ScriptBlock
    }
    clean {
        Pop-Location
    }
}

function ConvertFrom-ToolJsonOutput {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline)]
        [AllowNull()]
        [object]$InputObject
    )

    begin {
        $lines = [System.Collections.Generic.List[string]]::new()
    }
    process {
        if ($null -ne $InputObject) {
            $lines.Add([string]$InputObject)
        }
    }
    end {
        $text = ($lines -join [Environment]::NewLine).Trim()
        if (-not $text) { return }

        try {
            return $text | ConvertFrom-Json
        } catch {
            $originalError = $_
        }

        for ($startIndex = 0; $startIndex -lt $lines.Count; $startIndex++) {
            $trimmedStart = $lines[$startIndex].TrimStart()
            if (-not ($trimmedStart.StartsWith('[') -or $trimmedStart.StartsWith('{'))) { continue }

            $close = if ($trimmedStart.StartsWith('[')) { ']' } else { '}' }
            for ($endIndex = $lines.Count - 1; $endIndex -ge $startIndex; $endIndex--) {
                if (-not $lines[$endIndex].TrimEnd().EndsWith($close)) { continue }

                $candidate = ($lines[$startIndex..$endIndex] -join [Environment]::NewLine).Trim()
                try {
                    return $candidate | ConvertFrom-Json
                } catch {
                    continue
                }
            }
        }

        throw $originalError
    }
}

function Repair-GlobalJson {
    <#
    .SYNOPSIS
    Reset global.json SDK rollForward policy to 'disable'.
    .DESCRIPTION
    Reads the global.json in the current directory, sets sdk.rollForward to 'disable', and writes it back.
    .EXAMPLE
    Repair-GlobalJson
    Resets the rollForward policy in the current directory's global.json.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if ($PSCmdlet.ShouldProcess('global.json', "Set sdk.rollForward to 'disable'")) {
        $a = Get-Content .\global.json | ConvertFrom-Json
        $a.sdk.rollForward = 'disable'
        $a | ConvertTo-Json | Set-Content .\global.json
    }
}

function Format-Duration {
    <#
    .SYNOPSIS
    Format a TimeSpan as a compact human-readable duration string.
    .DESCRIPTION
    Returns a duration string whose shape scales with length:

    - one hour or more  -> 'H:MM:SS.mmm' (hours can exceed 24; days are folded in)
    - one minute or more -> 'M:SS.mmm'
    - under a minute      -> '<seconds> seconds' (fractional TotalSeconds)

    The string carries no trailing punctuation or label, so a caller can embed it
    in a sentence (e.g. a prompt's "Command Time: ..." line).
    .PARAMETER TimeSpan
    The duration to format. Accepts pipeline input.
    .EXAMPLE
    Format-Duration ([TimeSpan]::FromSeconds(5.3))
    Returns '5.3 seconds'.
    .EXAMPLE
    (Get-History -Count 1 | ForEach-Object { $_.EndExecutionTime - $_.StartExecutionTime }) | Format-Duration
    Formats the elapsed time of the last command.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline, Position = 0)]
        [TimeSpan]$TimeSpan
    )

    process {
        if ($TimeSpan.TotalSeconds -ge 3600) {
            '{0:#0}:{1:00}:{2:00}.{3:000}' -f (($TimeSpan.Days * 24) + $TimeSpan.Hours), $TimeSpan.Minutes, $TimeSpan.Seconds, $TimeSpan.Milliseconds
        }
        elseif ($TimeSpan.TotalSeconds -ge 60) {
            '{0:#0}:{1:00}.{2:000}' -f $TimeSpan.Minutes, $TimeSpan.Seconds, $TimeSpan.Milliseconds
        }
        else {
            '{0:0.###} seconds' -f $TimeSpan.TotalSeconds
        }
    }
}
