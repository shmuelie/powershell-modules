function Test-VsEnvironmentIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Installation,
        [Parameter(Mandatory)]
        [string]$Architecture,
        [Parameter(Mandatory)]
        [string]$HostArchitecture,
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Environment
    )

    $markers = @('VSCMD_VER', 'VSINSTALLDIR', 'VSCMD_ARG_TGT_ARCH', 'VSCMD_ARG_HOST_ARCH')
    $present = @($markers | Where-Object { $Environment[$_] })
    if ($present.Count -eq 0) { return $false }

    $activeVersion = $null
    $matches = $present.Count -eq $markers.Count -and
        [version]::TryParse([string]$Environment['VSCMD_VER'], [ref]$activeVersion) -and
        $activeVersion.Major -eq ([version]$Installation.Version).Major -and
        [IO.Path]::IsPathFullyQualified([string]$Environment['VSINSTALLDIR'])
    if ($matches) {
        $activePath = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath([string]$Environment['VSINSTALLDIR']))
        $requestedPath = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath([string]$Installation.InstallationPath))
        $matches = $activePath -ieq $requestedPath -and
            ($Environment['VSCMD_ARG_TGT_ARCH'] -ireplace '^x64$', 'amd64') -ieq $Architecture -and
            ($Environment['VSCMD_ARG_HOST_ARCH'] -ireplace '^x64$', 'amd64') -ieq $HostArchitecture
    }
    if (-not $matches) {
        throw 'A different or incomplete Visual Studio environment is already active. Start a fresh Start-DevShell session; switching or stacking toolsets is not supported.'
    }
    $true
}

function Get-VsEnvironmentSnapshot {
    [CmdletBinding()]
    param()

    $snapshot = @{}
    foreach ($entry in [Environment]::GetEnvironmentVariables('Process').GetEnumerator()) {
        $snapshot[[string]$entry.Key] = [string]$entry.Value
    }
    $snapshot
}

function Invoke-VsEnvironmentCapture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Installation,
        [Parameter(Mandatory)]
        [ValidateSet('x86', 'amd64', 'arm', 'arm64')]
        [string]$Architecture,
        [Parameter(Mandatory)]
        [ValidateSet('x86', 'amd64', 'arm64')]
        [string]$HostArchitecture
    )

    $pwsh = Join-Path $PSHOME 'pwsh.exe'
    foreach ($path in @($Installation.ScriptPath, $pwsh)) {
        if (-not [IO.Path]::IsPathFullyQualified($path) -or $path -match '[%!^&|<>"\r\n]' -or
            -not (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction Stop)) {
            throw "Cannot safely initialize Visual Studio using path '$path'. A fully qualified existing path without cmd.exe expansion or control characters is required."
        }
    }
    $capture = @'
$ErrorActionPreference = 'Stop'
$values = @{}
foreach ($entry in [Environment]::GetEnvironmentVariables('Process').GetEnumerator()) {
    if ($entry.Key -ne 'SHMUELIE_VS_CAPTURE') { $values[[string]$entry.Key] = [string]$entry.Value }
}
[IO.File]::WriteAllText($env:SHMUELIE_VS_CAPTURE, ($values | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
'@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($capture))
    $resultFile = [IO.Path]::GetTempFileName()
    $process = [Diagnostics.Process]::new()
    try {
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = Join-Path ([Environment]::SystemDirectory) 'cmd.exe'
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.Environment['SHMUELIE_VS_CAPTURE'] = $resultFile
        $start.Arguments = '/d /s /c ""{0}" -no_logo -arch={1} -host_arch={2} && "{3}" -NoLogo -NoProfile -NonInteractive -EncodedCommand {4}"' -f
            $Installation.ScriptPath, $Architecture, $HostArchitecture, $pwsh, $encoded
        $process.StartInfo = $start
        if (-not $process.Start()) { throw 'Could not start the Visual Studio environment initializer.' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw 'Visual Studio environment initialization timed out after 60 seconds.'
        }
        $output = $stdout.GetAwaiter().GetResult()
        $errors = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "Visual Studio environment initialization exited with code $($process.ExitCode). $errors $output"
        }
        $json = [IO.File]::ReadAllText($resultFile)
        if (-not $json) { throw 'Visual Studio environment initialization returned no environment.' }
        $environment = ConvertFrom-Json -InputObject $json -AsHashtable -ErrorAction Stop
        if ($environment -isnot [System.Collections.IDictionary] -or $environment.Count -eq 0) {
            throw 'Visual Studio environment initialization returned an invalid environment.'
        }
        foreach ($key in $environment.Keys) {
            if (-not $key -or $key -match '[=\x00]' -or $environment[$key] -isnot [string] -or $environment[$key].Contains([char]0)) {
                throw 'Visual Studio environment initialization returned an invalid environment entry.'
            }
        }
        $environment
    } finally {
        $process.Dispose()
        [IO.File]::Delete($resultFile)
    }
}

function Initialize-VsDeveloperEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Installation,
        [Parameter(Mandatory)]
        [ValidateSet('x86', 'amd64', 'arm', 'arm64')]
        [string]$Architecture,
        [Parameter(Mandatory)]
        [ValidateSet('x86', 'amd64', 'arm64')]
        [string]$HostArchitecture
    )

    $before = Get-VsEnvironmentSnapshot
    if (Test-VsEnvironmentIdentity -Installation $Installation -Architecture $Architecture -HostArchitecture $HostArchitecture -Environment $before) { return }
    $after = Invoke-VsEnvironmentCapture -Installation $Installation -Architecture $Architecture -HostArchitecture $HostArchitecture
    if (-not (Test-VsEnvironmentIdentity -Installation $Installation -Architecture $Architecture -HostArchitecture $HostArchitecture -Environment $after)) {
        throw 'Visual Studio initialization did not establish the requested environment.'
    }

    $originals = @{}
    try {
        foreach ($key in @($before.Keys) + @($after.Keys) | Sort-Object -Unique) {
            if ($key -in @('PSModulePath', 'SHMUELIE_VS_CAPTURE') -or $before[$key] -ceq $after[$key]) { continue }
            $originals[$key] = $before[$key]
            [Environment]::SetEnvironmentVariable($key, $after[$key], 'Process')
        }
    } catch {
        $applicationError = $_
        foreach ($key in $originals.Keys) {
            [Environment]::SetEnvironmentVariable($key, $originals[$key], 'Process')
        }
        throw $applicationError
    }
    $script:VsEnvironmentOriginals = $originals
}

function Set-VsYearEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$Year,
        [Parameter(Mandatory)]
        [string]$Architecture,
        [Parameter(Mandatory)]
        [string]$HostArchitecture,
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCmdlet]$Caller
    )

    Assert-WindowsOnly -CommandName "Set-VS$Year"
    $installation = Get-VsDeveloperInstallation -Year $Year | Select-Object -First 1
    if (-not $installation) {
        throw "No complete, launchable Visual Studio $Year release installation with VsDevCmd.bat was found."
    }
    if ($Caller.ShouldProcess("$($installation.InstallationPath) ($Architecture, host $HostArchitecture)", 'Initialize current Visual Studio developer environment')) {
        Initialize-VsDeveloperEnvironment -Installation $installation -Architecture $Architecture -HostArchitecture $HostArchitecture
    }
}
