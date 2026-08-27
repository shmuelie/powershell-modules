function Test-IsWindowsPlatform {
    [CmdletBinding()]
    param()

    return $IsWindows
}

function Assert-WindowsOnly {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandName
    )

    if (-not (Test-IsWindowsPlatform)) {
        throw "$CommandName is only supported on Windows (nvm-windows)."
    }
}
