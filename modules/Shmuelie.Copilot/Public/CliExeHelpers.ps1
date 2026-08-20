# Shared helper for the Copilot CLI cmdlets.
#
# Resolve-CliExe is the single place that resolves the copilot executable. The
# Copilot cmdlets own their `copilot plugin ...` / `copilot plugin marketplace
# ...` calls inline in Plugins.ps1 / Marketplaces.ps1.

function Resolve-CliExe {
    <#
    .SYNOPSIS
        Resolve the path to the copilot executable.
    .PARAMETER Name
        Which executable to resolve. Currently only 'copilot' is supported.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('copilot')]
        [string]$Name
    )
    (Get-Command $Name -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
}

function Invoke-WithUtf8Console {
    <#
    .SYNOPSIS
        Run a command while decoding native output as UTF-8.
    .DESCRIPTION
        Temporarily sets [Console]::OutputEncoding to UTF-8 while running the
        supplied script block, then restores the previous encoding in a finally
        block. Hosts that reject OutputEncoding changes are treated as best
        effort so callers still run normally.
    .PARAMETER ScriptBlock
        The script block to invoke while UTF-8 console output decoding is active.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock
    )

    $previousEncoding = $null
    $hasPreviousEncoding = $false

    try {
        try {
            $previousEncoding = [Console]::OutputEncoding
            $hasPreviousEncoding = $true
            [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        } catch {
            # Best effort: some hosts do not allow changing console encoding.
        }

        & $ScriptBlock
    } finally {
        if ($hasPreviousEncoding) {
            try {
                [Console]::OutputEncoding = $previousEncoding
            } catch {
                # Best effort: do not mask the script block result or error.
            }
        }
    }
}

function Test-CopilotShimArgument {
    param(
        [AllowEmptyString()]
        [string]$Value,

        [string]$Pattern = '^[A-Za-z0-9][A-Za-z0-9._@/#:-]*$'
    )

    return [bool]($Value -and
        $Value -notmatch '[<>&|%!^`"()]' -and
        $Value -match $Pattern)
}

function Assert-CopilotShimArgument {
    param(
        [AllowEmptyString()]
        [string]$Value,

        [Parameter(Mandatory)]
        [string]$ParameterName,

        [string]$Pattern = '^[A-Za-z0-9][A-Za-z0-9._@/#:-]*$'
    )

    if (-not (Test-CopilotShimArgument -Value $Value -Pattern $Pattern)) {
        throw [System.ArgumentException]::new(
            "Unsafe $ParameterName value. Values passed to the copilot CLI may only contain allow-listed characters and must not contain cmd.exe metacharacters.",
            $ParameterName)
    }
}

function Assert-CopilotShimTextArgument {
    param(
        [AllowEmptyString()]
        [string]$Value,

        [Parameter(Mandatory)]
        [string]$ParameterName
    )

    if (-not $Value -or $Value -match '[<>&|%!^`"()]') {
        throw [System.ArgumentException]::new(
            "Unsafe $ParameterName value. Values passed to the copilot CLI must not contain cmd.exe metacharacters.",
            $ParameterName)
    }
}
