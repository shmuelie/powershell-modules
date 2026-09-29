function Invoke-WprNative {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,
        [Parameter(Mandatory)]
        [string]$Operation
    )

    # Convert native failures ourselves, without changing caller preferences or exit state.
    $PSNativeCommandUseErrorActionPreference = $false
    $ErrorActionPreference = 'Stop'
    $previousExitCode = Get-Variable LASTEXITCODE -Scope Global -ErrorAction Ignore
    $previousValue = if ($previousExitCode) { $previousExitCode.Value } else { $null }
    try {
        $global:LASTEXITCODE = $null
        try {
            $output = @(& sudo @Arguments 2>&1)
            $exitCode = $global:LASTEXITCODE
        }
        catch {
            $PSCmdlet.ThrowTerminatingError([System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new("WPR $Operation could not be invoked through sudo: $($_.Exception.Message)", $_.Exception),
                'WprInvocationFailed', [System.Management.Automation.ErrorCategory]::ResourceUnavailable, $Arguments))
        }
    }
    finally {
        if ($previousExitCode) { $global:LASTEXITCODE = $previousValue }
        else { Remove-Variable LASTEXITCODE -Scope Global -ErrorAction Stop -WhatIf:$false -Confirm:$false }
    }

    if ($exitCode -isnot [int]) {
        $PSCmdlet.ThrowTerminatingError([System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new("WPR $Operation did not report a native exit code; the outcome is unknown."),
            'WprExitCodeUnavailable', [System.Management.Automation.ErrorCategory]::InvalidResult, $Arguments))
    }
    if ($exitCode -ne 0) {
        $PSCmdlet.ThrowTerminatingError([System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new("WPR $Operation failed with sudo exit code $exitCode. $($output -join [Environment]::NewLine)"),
            'WprCommandFailed', [System.Management.Automation.ErrorCategory]::InvalidOperation, $Arguments))
    }

    $output
}

function Start-WindowsPerformanceRecorder {
    <#
    .SYNOPSIS
    Starts WPR recording
    .DESCRIPTION
    Starts WPR through sudo. Invocation failures and nonzero exit codes produce
    PowerShell errors independently of the native-error preference. Use
    -ErrorAction Stop to catch them. Native output is returned only on success.
    .PARAMETER PerformanceProfile
    A built-in WPR profile name or path to a user-defined profile.
    .PARAMETER FileMode
    Specifies that recording is done in file mode. (The default mode is memory.) By using this option, the data is recorded to an unbounded file, which can grow in size until it fills the disk.
    .EXAMPLE
    Start-WindowsPerformanceRecorder -PerformanceProfile C:\my.wprp -FileMode
    Starts a WPR recording with a custom profile in file mode.
    .NOTES
    Windows only. Preserves the caller's preferences and LASTEXITCODE.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [Alias('Profile')]
        [ValidateNotNullOrEmpty()]
        [string]$PerformanceProfile,
        [switch]$FileMode
    )
    process {
        Assert-WindowsOnly -CommandName $MyInvocation.MyCommand.Name

        $arguments = @('wpr', '-start', $PerformanceProfile)

        if ($FileMode) {
            $arguments += '-filemode'
        }

        if ($PSCmdlet.ShouldProcess($PerformanceProfile, 'Start WPR recording')) {
            try {
                Invoke-WprNative -Arguments $arguments -Operation 'start'
            }
            catch {
                $PSCmdlet.WriteError($_)
            }
        }
    }
}

function Stop-WindowsPerformanceRecorder {
    <#
    .SYNOPSIS
    Stops WPR recording and merges all the recording into the given file
    .DESCRIPTION
    Stops the active WPR recording session and merges all captured data into the specified ETL file.
    Invocation failures and nonzero exit codes produce PowerShell errors
    independently of the native-error preference. Use -ErrorAction Stop to
    catch them. Native output is returned only on success.
    .PARAMETER File
    Required nonblank event trace log (ETL) output filename.
    .EXAMPLE
    Stop-WindowsPerformanceRecorder -File C:\trace.etl
    Stops the recording and saves the trace to C:\trace.etl.
    .NOTES
    Windows only. Preserves the caller's preferences and LASTEXITCODE.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrWhiteSpace()]
        [string]$File
    )
    process {
        Assert-WindowsOnly -CommandName $MyInvocation.MyCommand.Name

        if ($PSCmdlet.ShouldProcess($File, 'Stop WPR recording')) {
            try {
                Invoke-WprNative -Arguments @('wpr', '-stop', $File) -Operation 'stop'
            }
            catch {
                $PSCmdlet.WriteError($_)
            }
        }
    }
}
