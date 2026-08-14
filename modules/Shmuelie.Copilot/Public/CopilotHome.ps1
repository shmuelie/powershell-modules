function Get-CopilotHome {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if (-not $HOME) {
        throw 'Unable to resolve the user home directory.'
    }

    return $HOME
}
