function Start-WindowsPerformanceRecorder {
    <#
    .SYNOPSIS
    Starts WPR recording
    .PARAMETER PerformanceProfile
    A built-in WPR profile name or path to a user-defined profile.
    .PARAMETER FileMode
    Specifies that recording is done in file mode. (The default mode is memory.) By using this option, the data is recorded to an unbounded file, which can grow in size until it fills the disk.
    .EXAMPLE
    Start-WindowsPerformanceRecorder -PerformanceProfile C:\my.wprp -FileMode
    Starts a WPR recording with a custom profile in file mode.
    .NOTES
    Windows only.
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
            & sudo @arguments
        }
    }
}

function Stop-WindowsPerformanceRecorder {
    <#
    .SYNOPSIS
    Stops WPR recording and merges all the recording into the given file
    .DESCRIPTION
    Stops the active WPR recording session and merges all captured data into the specified ETL file.
    .PARAMETER File
    Specifies the event trace log (ETL) file to which WPR saves the recording. 
    .EXAMPLE
    Stop-WindowsPerformanceRecorder -File C:\trace.etl
    Stops the recording and saves the trace to C:\trace.etl.
    .NOTES
    Windows only.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [ValidateNotNullOrEmpty()]
        [string]$File
    )
    process {
        Assert-WindowsOnly -CommandName $MyInvocation.MyCommand.Name

        if ($PSCmdlet.ShouldProcess($File, 'Stop WPR recording')) {
            & sudo wpr -stop $File
        }
    }
}