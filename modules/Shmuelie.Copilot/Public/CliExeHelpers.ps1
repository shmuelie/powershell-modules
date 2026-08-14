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
