function Get-ServiceProcess {
    <#
    .SYNOPSIS
    Get the hosting process for one or more Windows services.
    .DESCRIPTION
    Resolves each service name (wildcards supported) to its hosting process via Win32_Service.
    When a single running service is matched, the underlying System.Diagnostics.Process is
    returned so the cmdlet composes naturally with Stop-Process, Wait-Process, etc.
    Otherwise, one ServiceProcess object is emitted per service with metadata including
    the svchost command line for shared-host services.
    .PARAMETER Name
    One or more service names. Supports wildcards. Accepts pipeline input by value (string)
    or by property name (e.g. Get-Service | Get-ServiceProcess).
    .PARAMETER PerService
    Reconfigure each shared-svchost service to run in its own process via
    'sc.exe config <name> type= own'. Requires elevation. The change takes effect on next
    service restart.
    .EXAMPLE
    Get-ServiceProcess Spooler
    Returns the System.Diagnostics.Process hosting the Print Spooler.
    .EXAMPLE
    Get-ServiceProcess Spooler | Stop-Process
    Stops the process hosting the Spooler service.
    .EXAMPLE
    Get-Service W3* | Get-ServiceProcess
    Returns one ServiceProcess object per matching service.
    .EXAMPLE
    Get-ServiceProcess BITS -PerService -WhatIf
    Previews reconfiguring BITS to run in its own process.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([System.Diagnostics.Process], [pscustomobject])]
    param(
        [Parameter(Position = 0, Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Name,

        [switch]$PerService
    )
    begin {
        Assert-WindowsOnly -CommandName $MyInvocation.MyCommand.Name
        if ($PerService -and -not $WhatIfPreference -and -not (Test-IsElevated)) {
            throw '-PerService requires an elevated session.'
        }
        $results = [System.Collections.Generic.List[pscustomobject]]::new()
        # Bulk-fetch all Win32_Service CIM data once, index by name
        $cimIndex = @{}
        foreach ($c in (Get-CimInstance Win32_Service)) {
            $cimIndex[$c.Name] = $c
        }
    }
    process {
        foreach ($pattern in $Name) {
            $services = Get-Service -Name $pattern -ErrorAction SilentlyContinue
            if (-not $services) {
                Write-Error "No service matched '$pattern'."
                continue
            }
            foreach ($svc in $services) {
                if ($PerService) {
                    if ($PSCmdlet.ShouldProcess($svc.Name, "sc.exe config <name> type= own")) {
                        & sc.exe config $svc.Name type= own | Out-Null
                        if ($LASTEXITCODE -ne 0) {
                            Write-Error "sc.exe config $($svc.Name) type= own failed with exit code $LASTEXITCODE."
                            continue
                        }
                        Write-Warning "$($svc.Name): reconfigured to type=own. Restart the service for the change to take effect."
                    }
                }
                $cim = $cimIndex[$svc.Name]
                $procId = if ($cim) { [int]$cim.ProcessId } else { 0 }
                $proc = if ($procId -gt 0) { Get-Process -Id $procId -ErrorAction SilentlyContinue } else { $null }
                $results.Add([pscustomobject]@{
                    PSTypeName  = 'ServiceProcess'
                    Name        = $svc.Name
                    DisplayName = $svc.DisplayName
                    Status      = $svc.Status
                    ProcessId   = $procId
                    ProcessName = if ($proc) { $proc.ProcessName } else { '' }
                    Process     = $proc
                    CommandLine = if ($cim) { $cim.PathName } else { '' }
                })
            }
        }
    }
    end {
        if ($results.Count -eq 1 -and $null -ne $results[0].Process) {
            $results[0].Process
        } else {
            $results
        }
    }
}
