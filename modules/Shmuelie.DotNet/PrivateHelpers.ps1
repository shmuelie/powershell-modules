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

function Invoke-DotNetToolCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Arguments
    )

    $PSNativeCommandUseErrorActionPreference = $false
    # Leave fresh completion evidence available to callers, including adapters.
    $global:LASTEXITCODE = $null
    $output = @(& dotnet @Arguments 2>&1)
    $exitCode = $global:LASTEXITCODE
    $result = [pscustomobject]@{
        Arguments = $Arguments
        ExitCode = $exitCode
        Output = $output
    }
    if ($exitCode -isnot [int] -or $exitCode -ne 0) {
        $detail = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
        $message = if ($exitCode -is [int]) {
            "dotnet $($Arguments -join ' ') failed (exit code $exitCode)."
        } else {
            "dotnet $($Arguments -join ' ') did not report a numeric exit code; the outcome is unknown."
        }
        if ($detail) { $message += [Environment]::NewLine + $detail }
        $errorRecord = [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new($message),
            'DotNetToolCommandFailed', [System.Management.Automation.ErrorCategory]::InvalidOperation, $result)
        $PSCmdlet.WriteError($errorRecord)
        return
    }
    $result
}
