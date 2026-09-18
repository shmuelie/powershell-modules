# Extracted from Utilities so tool discovery does not import an unrelated module.
function Invoke-InLocation {
    [CmdletBinding()]
    param(
        [Alias('Path')]
        [ValidateScript({ Test-Path -Path $_ -PathType Container })]
        [string]$Location,
        [Alias('Process')]
        [scriptblock]$ScriptBlock
    )
    begin {
        $locationPushed = $false
        Push-Location -Path $Location -ErrorAction Stop
        $locationPushed = $true
    }
    process {
        & $ScriptBlock
    }
    clean {
        if ($locationPushed) { Pop-Location }
    }
}
