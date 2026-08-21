function Test-IsWindowsPlatform {
    [CmdletBinding()]
    param()

    return $IsWindows
}

function Assert-WindowsOnly {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CommandName
    )

    if (-not (Test-IsWindowsPlatform)) {
        throw "$CommandName is only supported on Windows."
    }
}
