function Invoke-DevTunnelProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$Stream,
        [switch]$Sensitive,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 60
    )
    end {
        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $process.StartInfo.FileName = $FilePath
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.RedirectStandardOutput = $true
        $process.StartInfo.RedirectStandardError = $true
        $process.StartInfo.RedirectStandardInput = $true
        foreach ($argument in $Arguments) {
            if ($null -eq $argument -or $argument.Contains([char]0)) {
                throw 'devtunnel arguments cannot contain null characters.'
            }
            $process.StartInfo.ArgumentList.Add($argument)
        }
        $stdout = [System.Text.StringBuilder]::new()
        $stderr = [System.Text.StringBuilder]::new()
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        $started = $process.Start()
        if (-not $started) { throw 'Could not start devtunnel.' }
        $process.StandardInput.Close()
        $outRead = $process.StandardOutput.ReadLineAsync()
        $errRead = $process.StandardError.ReadLineAsync()
        while ($null -ne $outRead -or $null -ne $errRead -or -not $process.HasExited) {
            if (-not $Stream -and $timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                throw "devtunnel timed out after $TimeoutSeconds seconds."
            }
            if ($null -ne $outRead -and $outRead.IsCompleted) {
                $line = $outRead.GetAwaiter().GetResult()
                if ($null -eq $line) {
                    $outRead = $null
                } else {
                    if ($Stream) { $line } else { $null = $stdout.AppendLine($line) }
                    $outRead = $process.StandardOutput.ReadLineAsync()
                }
            }
            if ($null -ne $errRead -and $errRead.IsCompleted) {
                $line = $errRead.GetAwaiter().GetResult()
                if ($null -eq $line) {
                    $errRead = $null
                } else {
                    if ($Stream) {
                        Write-Information $line -InformationAction Continue
                    } else {
                        $null = $stderr.AppendLine($line)
                    }
                    $errRead = $process.StandardError.ReadLineAsync()
                }
            }
            Start-Sleep -Milliseconds 10
        }
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            $message = "devtunnel failed (exit code $($process.ExitCode))."
            # Authentication and token failures must not echo credential-bearing output.
            if (-not $Sensitive -and $stderr.Length) { $message += [Environment]::NewLine + $stderr.ToString().TrimEnd() }
            $PSCmdlet.ThrowTerminatingError([System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new($message), 'DevTunnelCommandFailed',
                [System.Management.Automation.ErrorCategory]::InvalidOperation, $FilePath))
        }
        if (-not $Stream) {
            if (-not $Sensitive -and $stderr.Length) { Write-Warning $stderr.ToString().TrimEnd() }
            $stdout.ToString()
        }
    }
    clean {
        if ($process) {
            try {
                if ($started -and -not $process.HasExited) {
                    $process.Kill($true)
                    $process.WaitForExit()
                }
            } finally {
                $process.Dispose()
            }
        }
    }
}

function Resolve-DevTunnelCli {
    [CmdletBinding()]
    param()
    $command = Get-Command devtunnel -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $command) {
        throw 'devtunnel was not found on PATH. Install the Microsoft devtunnel CLI: https://learn.microsoft.com/azure/developer/dev-tunnels/get-started'
    }
    if ($IsWindows -and [System.IO.Path]::GetExtension($command.Source) -ne '.exe') {
        throw 'devtunnel must resolve to a native .exe, not a Windows command shim. Put the devtunnel executable on PATH.'
    }
    $command.Source
}

function Get-DevTunnelCliVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$FilePath)
    $versionText = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($FilePath).ProductVersion
    if (-not $versionText) {
        $versionText = Invoke-DevTunnelProcess -FilePath $FilePath -Arguments '--version'
    }
    if ($versionText -notmatch '(?m)^(?:Tunnel CLI version:\s*)?(?<version>\d+\.\d+\.\d+)(?:[+.\s-]|$)') {
        throw 'Cannot determine the devtunnel CLI version. Install devtunnel 1.0.2115 or a compatible 1.x version.'
    }
    $version = [version]$Matches.version
    if ($version -lt [version]'1.0.2115' -or $version.Major -ne 1) {
        throw "Unsupported devtunnel CLI version $version. Install devtunnel 1.0.2115 or a compatible 1.x version."
    }
    $version
}

function New-DevTunnelArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Command,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Parameters,
        [switch]$Json
    )
    $arguments = [System.Collections.Generic.List[string]]::new()
    $arguments.AddRange($Command)
    if ($Parameters.Keys -contains 'TunnelId') { $arguments.Add([string]$Parameters['TunnelId']) }
    $options = [ordered]@{
        PortNumber = 'port-number'; Protocol = 'protocol'; Description = 'description'
        Label = 'labels'; AllLabel = 'all-labels'; AddLabel = 'add-labels'; RemoveLabel = 'remove-labels'
        Expiration = 'expiration'; Limit = 'limit'; Scope = 'scopes'; Index = 'index'
        Organization = 'organization'; Repository = 'repo'; Interface = 'interface'
        Size = 'size'; Interval = 'interval'
    }
    foreach ($name in $options.Keys) {
        if ($Parameters.Keys -contains $name) {
            foreach ($value in @($Parameters[$name])) {
                $arguments.Add("--$($options[$name])=$value")
            }
        }
    }
    $switches = [ordered]@{
        AllowAnonymous = 'allow-anonymous'; Anonymous = 'anonymous'; Tenant = 'tenant'
        Deny = 'deny'; GitHub = 'github'; DeviceCode = 'use-device-code-auth'; Ping = 'ping'
    }
    foreach ($entry in $switches.GetEnumerator()) {
        if ($Parameters.Keys -contains $entry.Key -and $Parameters[$entry.Key]) { $arguments.Add("--$($entry.Value)") }
    }
    if ($Json) { $arguments.Add('--json') }
    $arguments.ToArray()
}

function Invoke-DevTunnelCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$Stream,
        [switch]$Sensitive
    )
    $filePath = Resolve-DevTunnelCli
    $null = Get-DevTunnelCliVersion -FilePath $filePath
    if ($Stream) {
        Invoke-DevTunnelProcess -FilePath $filePath -Arguments $Arguments -Stream -Sensitive:$Sensitive
        return
    }
    $output = Invoke-DevTunnelProcess -FilePath $filePath -Arguments $Arguments -Sensitive:$Sensitive
    if ([string]::IsNullOrWhiteSpace($output)) { return }
    try {
        $output | ConvertFrom-Json -Depth 100 -ErrorAction Stop
    } catch {
        # Do not include JSON content: token output can contain secrets.
        throw 'devtunnel returned invalid JSON. Verify that the installed CLI version supports this command and --json.'
    }
}

function Write-DevTunnelAnonymousWarning {
    Write-Warning 'Anonymous access allows anyone on the internet who knows the tunnel address to connect to the exposed service.'
}

function Test-DevTunnelExpiration {
    param([string]$Value)
    if ($Value -notmatch '^(?<value>[1-9][0-9]{0,2})(?<unit>[hd])$') {
        throw 'Expiration must be 1h through 720h or 1d through 30d.'
    }
    $maximum = if ($Matches.unit -eq 'h') { 720 } else { 30 }
    if ([int]$Matches.value -gt $maximum) { throw 'Expiration cannot exceed 30 days.' }
    $true
}
