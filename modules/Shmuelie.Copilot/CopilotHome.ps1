function Get-CopilotHome {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if (-not $HOME) {
        throw 'Unable to resolve the user home directory.'
    }

    return $HOME
}

function Resolve-CopilotSessionPath {
    <#
    .SYNOPSIS
        Resolves a Copilot session ID to its directory strictly under the
        canonical session-state root, rejecting path-traversal input.

    .DESCRIPTION
        Central identity/path guard shared by the session cmdlets. A valid session
        ID is a single directory name (Copilot CLI session IDs are GUIDs). The ID
        must not contain directory separators, be a rooted/absolute path, carry a
        drive or stream qualifier, or be a '.'/'..' dot segment. The resolved
        target is then canonicalized and confirmed to be a direct child of the
        session-state root, defeating any residual traversal.

        Throws a terminating error for unsafe input. Returns the canonical
        directory path when the session exists, or $null when a valid ID has no
        matching session directory.

    .PARAMETER Id
        The session ID to validate and resolve.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Id
    )

    if ([string]::IsNullOrWhiteSpace($Id)) {
        throw 'Invalid Copilot session ID: the ID must not be empty.'
    }

    # Reject anything that is not a single, safe path component before it ever
    # reaches Join-Path: no separators, no rooted/absolute paths, no drive or
    # alternate-stream qualifier, and no '.'/'..' dot segments.
    if ($Id -match '[\\/]' -or
        $Id -eq '.' -or $Id -eq '..' -or
        [System.IO.Path]::IsPathRooted($Id) -or
        $Id.IndexOf([System.IO.Path]::VolumeSeparatorChar) -ge 0) {
        throw "Invalid Copilot session ID '$Id': the ID must be a single session directory name without path separators, drive qualifiers, or relative segments."
    }

    $separator = [System.IO.Path]::DirectorySeparatorChar
    $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }

    $root = Join-Path (Get-CopilotHome) '.copilot' 'session-state'
    $rootFull = [System.IO.Path]::GetFullPath($root + $separator)

    # Canonicalize the candidate and confirm it resolves to a direct child of the
    # session-state root.
    $candidateFull = [System.IO.Path]::GetFullPath((Join-Path $root $Id))
    $parentFull = [System.IO.Path]::GetFullPath([System.IO.Path]::GetDirectoryName($candidateFull) + $separator)

    if (-not $parentFull.Equals($rootFull, $comparison)) {
        throw "Invalid Copilot session ID '$Id': the resolved path escapes the session-state root."
    }

    if (-not (Test-Path -LiteralPath $candidateFull -PathType Container)) {
        return $null
    }

    return $candidateFull
}
