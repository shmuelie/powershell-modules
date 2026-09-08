# Extracted from Utilities so tool discovery does not import an unrelated module.
function Invoke-InLocation {
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
