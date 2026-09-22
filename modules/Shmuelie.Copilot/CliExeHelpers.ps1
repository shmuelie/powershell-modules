# Shared helper for the Copilot CLI cmdlets.
#
# Resolve-CliExe is the single place that resolves the copilot executable.
# Discovery uses Invoke-CopilotDiscovery to check native status before parsing.
# Mutating commands own their calls in Plugins.ps1 / Marketplaces.ps1.

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

function Invoke-CopilotDiscovery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $exe = Resolve-CliExe -Name copilot
    $previousExitCode = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction Ignore
    $previousExitCodeValue = if ($previousExitCode) { $previousExitCode.Value }
    try {
        $global:LASTEXITCODE = $null
        $result = Invoke-WithUtf8Console {
            # Report one error with the complete diagnostics, regardless of the native preference.
            $PSNativeCommandUseErrorActionPreference = $false
            $ErrorActionPreference = 'Stop'
            $output = @(& $exe @Arguments 2>&1)
            $exitCode = $global:LASTEXITCODE
            [pscustomobject]@{
                ExitCode = $exitCode
                Output   = $output
            }
        }
    } finally {
        if ($previousExitCode) {
            $global:LASTEXITCODE = $previousExitCodeValue
        } else {
            Remove-Variable -Name LASTEXITCODE -Scope Global -WhatIf:$false -Confirm:$false
        }
    }

    if ($result.ExitCode -isnot [int] -or $result.ExitCode -ne 0) {
        $diagnostics = ($result.Output | ForEach-Object { "$_" }) -join [Environment]::NewLine
        $status = if ($result.ExitCode -is [int]) { "exit code $($result.ExitCode)" } else { 'an unknown native exit status' }
        $message = "copilot $($Arguments -join ' ') failed with $status."
        if ($diagnostics) {
            $message += [Environment]::NewLine + $diagnostics
        }
        Write-Error -Message $message -ErrorId CopilotDiscoveryFailed -Category InvalidOperation -TargetObject $result
        return
    }

    $result.Output
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
