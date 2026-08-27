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
function Test-IsElevated {
    [CmdletBinding()]
    param()

    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
