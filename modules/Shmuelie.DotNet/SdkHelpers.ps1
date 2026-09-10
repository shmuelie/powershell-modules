function Get-DotNetSdkPlatform {
    if ($IsWindows) { return 'Windows' }
    if ($IsLinux) { return 'Linux' }
    if ($IsMacOS) { return 'macOS' }
    throw [System.PlatformNotSupportedException]::new('SDK installation supports Windows, Linux, and macOS.')
}

function Get-DotNetSdkEnvironment {
    [CmdletBinding()]
    param([string]$Name, [System.EnvironmentVariableTarget]$Target = 'Process')
    $ErrorActionPreference = 'Stop'
    [System.Environment]::GetEnvironmentVariable($Name, $Target)
}

function Set-DotNetSdkEnvironment {
    [CmdletBinding()]
    param([string]$Name, [string]$Value, [System.EnvironmentVariableTarget]$Target)
    $ErrorActionPreference = 'Stop'
    [System.Environment]::SetEnvironmentVariable($Name, $Value, $Target)
}

function New-DotNetSdkProcess {
    [Diagnostics.Process]::new()
}

function Invoke-DotNetSdkProcess {
    [CmdletBinding()]
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [hashtable]$Environment,
        [int]$TimeoutSeconds = 1800
    )
    if ([IO.Path]::GetExtension($FilePath) -in '.cmd', '.bat') {
        throw 'SDK operations require native executables, not batch shims.'
    }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $FilePath
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.WorkingDirectory = $ExecutionContext.SessionState.Path.CurrentFileSystemLocation.ProviderPath
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    if ($Environment) {
        foreach ($key in $Environment.Keys) { $start.Environment[$key] = $Environment[$key] }
    }
    $process = New-DotNetSdkProcess
    $started = $false
    try {
        $process.StartInfo = $start
        $started = $process.Start()
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            throw [TimeoutException]::new("SDK process '$FilePath' timed out after $TimeoutSeconds seconds.")
        }
        $output = $stdout.GetAwaiter().GetResult()
        $errorOutput = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "SDK process '$FilePath' failed (exit $($process.ExitCode)): $errorOutput`n$output"
        }
        $output
    } finally {
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

function Get-DotNetSdkInstallerFile {
    [CmdletBinding()]
    param(
        [ValidateSet('dotnet-install.ps1', 'dotnet-install.sh', 'dotnet-install.asc', 'dotnet-install.sig')]
        [string]$Name,
        [string]$Directory
    )
    $uri = [uri]"https://dot.net/v1/$Name"
    $destination = Join-Path $Directory $Name
    for ($redirect = 0; $redirect -le 5; $redirect++) {
        # Follow only the canonical redirect, never an arbitrary redirect target.
        if ($uri.AbsoluteUri -cnotin @(
            "https://dot.net/v1/$Name",
            "https://builds.dotnet.microsoft.com/dotnet/scripts/v1/$Name"
        )) { throw "Untrusted installer URL: $uri" }
        # PowerShell emits MaximumRedirectExceeded even for an intentional
        # zero-redirect request. Handle only that record; surface every other error.
        $requestErrors = @()
        $response = Invoke-WebRequest -Uri $uri -OutFile $destination -PassThru `
            -MaximumRedirection 0 -SkipHttpErrorCheck -ErrorAction SilentlyContinue -ErrorVariable requestErrors
        foreach ($requestError in $requestErrors) {
            if ($requestError.FullyQualifiedErrorId -notlike 'MaximumRedirectExceeded,*' -or
                [int]$response.StatusCode -notin 301, 302, 303, 307, 308) {
                $PSCmdlet.ThrowTerminatingError($requestError)
            }
        }
        if ([int]$response.StatusCode -eq 200) { return $destination }
        if ([int]$response.StatusCode -notin 301, 302, 303, 307, 308 -or -not $response.Headers.Location) {
            throw "Installer download failed: HTTP $($response.StatusCode) from $uri"
        }
        $uri = [uri]::new($uri, [string]@($response.Headers.Location)[0])
    }
    throw 'Installer download exceeded the redirect limit.'
}

function Test-DotNetSdkInstaller {
    [CmdletBinding()]
    param([string]$Installer, [string]$Platform, [string]$Directory)
    if ($Platform -eq 'Windows') {
        $signature = Get-AuthenticodeSignature -LiteralPath $Installer -ErrorAction Stop
        if ($signature.Status -eq 'NotSigned') {
            Write-Verbose 'The canonical PowerShell installer is unsigned; authenticity relies on canonical HTTPS delivery.'
        } elseif ($signature.Status -ne 'Valid') {
            throw "Installer Authenticode validation failed: $($signature.Status)"
        }
        return
    }
    $gpg = Get-Command gpg -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $key = Get-DotNetSdkInstallerFile -Name dotnet-install.asc -Directory $Directory
    $signature = Get-DotNetSdkInstallerFile -Name dotnet-install.sig -Directory $Directory
    $keyring = Join-Path $Directory 'keyring'
    $null = New-Item -ItemType Directory -Path $keyring -ErrorAction Stop
    [IO.File]::SetUnixFileMode($keyring, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
    # An isolated keyring avoids trusting unrelated keys or changing the user's GPG state.
    $options = @('--batch', '--no-options', '--homedir', $keyring, '--no-autostart')
    $null = Invoke-DotNetSdkProcess -FilePath $gpg.Source -Arguments ($options + @('--import', $key))
    $null = Invoke-DotNetSdkProcess -FilePath $gpg.Source -Arguments ($options + @('--verify', $signature, $Installer))
}

function Get-DotNetSdkHostArchitecture {
    param([string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        $magic = $reader.ReadUInt32()
        if (($magic -band 0xffff) -eq 0x5a4d) {
            $stream.Position = 0x3c
            $offset = $reader.ReadUInt32()
            $stream.Position = $offset
            if ($reader.ReadUInt32() -ne 0x4550) { throw 'Invalid PE header.' }
            switch ($reader.ReadUInt16()) {
                0x8664 { return 'x64' }
                0x14c { return 'x86' }
                0xaa64 { return 'arm64' }
                0x1c4 { return 'arm' }
            }
        } elseif ($magic -eq 0x464c457f) {
            $stream.Position = 5
            $endian = $reader.ReadByte()
            $stream.Position = 18
            $machine = $reader.ReadBytes(2)
            $value = if ($endian -eq 1) { $machine[0] + 256 * $machine[1] } else { 256 * $machine[0] + $machine[1] }
            switch ($value) {
                62 { return 'x64' }
                3 { return 'x86' }
                183 { return 'arm64' }
                40 { return 'arm' }
                22 { return 's390x' }
                21 { if ($endian -eq 1) { return 'ppc64le' } }
                243 { return 'riscv64' }
            }
        } elseif ($magic -eq 0xfeedfacfu) {
            switch ($reader.ReadUInt32()) {
                0x1000007 { return 'x64' }
                0x100000c { return 'arm64' }
            }
        }
        throw "Unsupported dotnet host architecture in '$Path'. Use a separate installation directory."
    } finally {
        $reader.Dispose()
    }
}

function Test-DotNetSdkInstalled {
    param([string]$InstallDir, [string]$Version)
    Test-Path -LiteralPath (Join-Path $InstallDir 'sdk' $Version 'dotnet.dll') -PathType Leaf -ErrorAction Stop
}

function Assert-DotNetSdkCompatibility {
    [CmdletBinding()]
    param([string]$HostPath, [string]$InstallDir, [string]$Version)
    $ErrorActionPreference = 'Stop'
    $directory = Join-Path $ExecutionContext.SessionState.Path.CurrentFileSystemLocation.ProviderPath ('.dotnet-install-' + [guid]::NewGuid().ToString('N'))
    $created = $false
    try {
        $null = New-Item -ItemType Directory -Path $directory -ErrorAction Stop
        $created = $true
        $environment = @{
            DOTNET_CLI_HOME = $directory
            DOTNET_CLI_TELEMETRY_OPTOUT = '1'
            DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
            DOTNET_NOLOGO = '1'
            DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE = 'true'
            DOTNET_MULTILEVEL_LOOKUP = '0'
            DOTNET_CLI_UI_LANGUAGE = 'en-US'
            TEMP = $directory
            TMP = $directory
            TMPDIR = $directory
        }
        # Execute this SDK directly, without PATH or global.json SDK selection.
        $sdk = Join-Path $InstallDir 'sdk' $Version 'dotnet.dll'
        $output = Invoke-DotNetSdkProcess -FilePath $HostPath -Arguments @('exec', $sdk, '--version') -Environment $environment -TimeoutSeconds 60
        if ($output.Trim() -cne $Version) {
            throw "The selected host did not run SDK '$Version'. Use a separate InstallDir or service the existing host explicitly."
        }
    } finally {
        if ($created) { Remove-Item -LiteralPath $directory -Recurse -Force -Confirm:$false -WhatIf:$false -ErrorAction Stop }
    }
}

function Get-DotNetSdkPathUpdate {
    param([AllowNull()][string]$Path, [string]$InstallDir, [string]$Platform)
    $windows = $Platform -eq 'Windows'
    $separator = if ($windows) { ';' } else { ':' }
    $comparison = if ($windows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $target = $InstallDir.TrimEnd([char[]]@('/', '\'))
    if ($windows) { $target = $target.Replace('/', '\') }
    foreach ($entry in ($Path -split [regex]::Escape($separator))) {
        if ([string]::IsNullOrEmpty($entry)) { continue }
        $candidate = $entry.Trim('"').TrimEnd([char[]]@('/', '\'))
        if ($windows) {
            $candidate = [Environment]::ExpandEnvironmentVariables($candidate).Replace('/', '\')
        }
        if ($candidate.Equals($target, $comparison)) { return $Path }
    }
    if ([string]::IsNullOrEmpty($Path)) { return $InstallDir }
    "$InstallDir$separator$Path"
}

function Install-DotNetSdk {
    <#
    .SYNOPSIS
        Install a user-local .NET SDK using Microsoft's dotnet-install script.
    .DESCRIPTION
        Installs an exact version, or resolves the latest version of a channel.
        Existing matching SDKs in the selected directory are not reinstalled.
        Architectures cannot be mixed in one directory. Downloads, installation,
        persistent user PATH, and current process PATH have separate ShouldProcess
        decisions. Neither PATH nor DOTNET_ROOT is changed by default.
        Windows checks Authenticode when present. Linux/macOS require bash and
        GPG and verify Microsoft's detached signature in an isolated keyring.
        Staging content is created below the current filesystem directory and
        removed even on failure. Installation failures can leave partial SDK files.
        Existing non-versioned hosts are preserved; the highest versioned hostfxr
        supplies runtime resolution. Before success, the exact SDK is launched
        with the selected host to verify compatibility (except under WhatIf).
        An incompatible host requires a separate InstallDir or explicit servicing.
        Environment access failures terminate even under caller preference Continue.
    .PARAMETER Version
        Exact three-part SDK version, optionally with a prerelease suffix.
        Cannot be combined with Channel or Quality.
    .PARAMETER Channel
        LTS (default), STS, a major.minor release, or a major.minor.Nxx feature
        band (.NET 5+). Resolves the latest available version on each invocation.
    .PARAMETER Quality
        daily, preview, or GA. Requires an explicit numeric .NET 5+ channel.
    .PARAMETER Architecture
        auto (the OS architecture), amd64/x64, x86, arm64, arm, s390x, ppc64le,
        or riscv64. Availability depends on the selected SDK and operating system.
    .PARAMETER InstallDir
        Filesystem installation directory. Defaults to LocalAppData/Microsoft/dotnet
        on Windows and HOME/.dotnet on Linux/macOS, independent of DOTNET_INSTALL_DIR.
        Use separate directories for different architectures.
    .PARAMETER AddToProcessPath
        Prepend the installation directory to this process's PATH if absent.
    .PARAMETER AddToUserPath
        Prepend to Windows persistent user PATH and this process's PATH if absent.
        On Linux/macOS, throws before any download, installation, or PATH change.
    .OUTPUTS
        DotNetSdkInstallResult with requested/resolved version and channel, quality,
        architecture, InstallDir, Status (Installed, AlreadyInstalled, or Skipped),
        ProcessPathChanged, and UserPathChanged. Failures terminate without a result.
    .EXAMPLE
        Install-DotNetSdk -Version 8.0.412
        Install exactly this SDK without changing PATH.
    .EXAMPLE
        Install-DotNetSdk -Channel 10.0 -Quality GA -AddToProcessPath
        Install the latest stable SDK on the channel and opt into process PATH.
    .EXAMPLE
        Install-DotNetSdk -Channel LTS -InstallDir ./sdk -WhatIf
        Preview without downloading or invoking an installer or changing PATH.
    .LINK
        https://learn.microsoft.com/dotnet/core/tools/dotnet-install-script
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Channel')]
    [OutputType('DotNetSdkInstallResult')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Version')]
        [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?\z')]
        [string]$Version,

        [Parameter(ParameterSetName = 'Channel')]
        [ValidatePattern('^(?i:LTS|STS|[0-9]+\.[0-9]+(?:\.[0-9]xx)?)\z')]
        [string]$Channel = 'LTS',

        [Parameter(ParameterSetName = 'Channel')]
        [ValidateSet('daily', 'preview', 'GA')]
        [string]$Quality,

        [ValidateSet('auto', 'amd64', 'x64', 'x86', 'arm64', 'arm', 's390x', 'ppc64le', 'riscv64')]
        [string]$Architecture = 'auto',

        [ValidateNotNullOrEmpty()]
        [string]$InstallDir,

        [switch]$AddToProcessPath,
        [switch]$AddToUserPath
    )
    $ErrorActionPreference = 'Stop'
    $platform = Get-DotNetSdkPlatform
    $windows = $platform -eq 'Windows'
    if ($AddToUserPath -and -not $windows) {
        throw [PlatformNotSupportedException]::new('-AddToUserPath is supported only on Windows. Use -AddToProcessPath instead.')
    }
    if ($Quality -and ($Channel -notmatch '^\d+\.' -or [int]($Channel.Split('.')[0]) -lt 5)) {
        throw 'Quality requires a numeric .NET 5+ Channel, not LTS or STS.'
    }
    if ($Channel -match 'xx$' -and [int]($Channel.Split('.')[0]) -lt 5) {
        throw 'SDK feature-band channels require .NET 5 or later.'
    }
    $Architecture = $Architecture.ToLowerInvariant()
    if ($Architecture -eq 'auto') { $Architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant() }
    if ($Architecture -eq 'amd64') { $Architecture = 'x64' }
    $allowedArchitectures = if ($windows) { @('x64', 'x86', 'arm64', 'arm') }
        elseif ($platform -eq 'macOS') { @('x64', 'arm64') }
        else { @('x64', 'x86', 'arm64', 'arm', 's390x', 'ppc64le', 'riscv64') }
    if ($Architecture -notin $allowedArchitectures) { throw "Unsupported architecture '$Architecture' on $platform." }
    if (-not $InstallDir) {
        $homePath = if ($windows) { Get-DotNetSdkEnvironment -Name LOCALAPPDATA } else { $HOME }
        if ([string]::IsNullOrWhiteSpace($homePath)) { throw 'Cannot determine the user-local SDK directory; specify InstallDir.' }
        $InstallDir = if ($windows) { Join-Path $homePath 'Microsoft' 'dotnet' } else { Join-Path $homePath '.dotnet' }
    }
    if ([string]::IsNullOrWhiteSpace($InstallDir) -or $InstallDir -match '[\x00-\x1f\x7f"*?<>|]' -or
        $InstallDir.Contains([string][IO.Path]::PathSeparator)) {
        throw 'InstallDir must be a literal filesystem path without control characters, wildcards, quotes, or PATH separators.'
    }
    $provider = $null
    $drive = $null
    $InstallDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InstallDir, [ref]$provider, [ref]$drive)
    if ($provider.Name -ne 'FileSystem') { throw 'InstallDir must be a filesystem path.' }
    if ($IsWindows -and $InstallDir.Substring([IO.Path]::GetPathRoot($InstallDir).Length).Contains(':')) {
        throw 'InstallDir must not contain alternate data stream syntax.'
    }
    if (Test-Path -LiteralPath $InstallDir -PathType Leaf -ErrorAction Stop) { throw 'InstallDir refers to a file, not a directory.' }
    $hostPath = Join-Path $InstallDir $(if ($windows) { 'dotnet.exe' } else { 'dotnet' })
    $hostExists = Test-Path -LiteralPath $hostPath -PathType Leaf -ErrorAction Stop
    if ($hostExists -and (Get-DotNetSdkHostArchitecture -Path $hostPath) -ne $Architecture) {
        throw 'InstallDir contains a different dotnet architecture. Specify a separate directory.'
    }
    $resolvedVersion = $Version
    $status = 'Skipped'
    $ready = $hostExists -and $Version -and (Test-DotNetSdkInstalled -InstallDir $InstallDir -Version $Version)
    if ($ready) { $status = 'AlreadyInstalled' }
    elseif ($PSCmdlet.ShouldProcess("https://dot.net/v1/dotnet-install.$(if ($windows) { 'ps1' } else { 'sh' })", 'Download and verify Microsoft SDK installer')) {
        $directory = Join-Path $ExecutionContext.SessionState.Path.CurrentFileSystemLocation.ProviderPath ('.dotnet-install-' + [guid]::NewGuid().ToString('N'))
        $created = $false
        try {
            $null = New-Item -ItemType Directory -Path $directory -ErrorAction Stop
            $created = $true
            $name = if ($windows) { 'dotnet-install.ps1' } else { 'dotnet-install.sh' }
            $installer = Get-DotNetSdkInstallerFile -Name $name -Directory $directory
            Test-DotNetSdkInstaller -Installer $installer -Platform $platform -Directory $directory
            $executable = if ($windows) { Join-Path $PSHOME 'pwsh.exe' }
                else { (Get-Command bash -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source }
            $prefix = if ($windows) { @('-NoProfile', '-NonInteractive', '-File', $installer) } else { @($installer) }
            $common = if ($windows) { @('-Architecture', $Architecture, '-InstallDir', $InstallDir, '-NoPath', '-ZipPath', (Join-Path $directory 'sdk.zip')) }
                else { @('--architecture', $Architecture, '--install-dir', $InstallDir, '--no-path', '--zip-path', (Join-Path $directory 'sdk.tar.gz')) }
            $environment = @{ TMPDIR = $directory; TEMP = $directory; TMP = $directory; DOTNET_CLI_UI_LANGUAGE = 'en-US' }
            if (-not $Version) {
                $selection = if ($windows) { @('-Channel', $Channel, '-DryRun') } else { @('--channel', $Channel, '--dry-run') }
                if ($Quality) { $selection += @($(if ($windows) { '-Quality' } else { '--quality' }), $Quality) }
                $output = Invoke-DotNetSdkProcess -FilePath $executable -Arguments ($prefix + $common + $selection) -Environment $environment
                # Parse only the validated version token; never execute the printed command.
                $matchesFound = [regex]::Matches($output, '(?im)^.*Repeatable invocation:.*?--?version\s+"(?<version>[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?)"')
                if ($matchesFound.Count -ne 1) { throw 'Installer did not resolve exactly one valid SDK version.' }
                $resolvedVersion = $matchesFound[0].Groups['version'].Value
            }
            $ready = $hostExists -and (Test-DotNetSdkInstalled -InstallDir $InstallDir -Version $resolvedVersion)
            if ($ready) { $status = 'AlreadyInstalled' }
            elseif ($PSCmdlet.ShouldProcess("$InstallDir ($Architecture, $resolvedVersion)", 'Install .NET SDK')) {
                $selection = @($(if ($windows) { '-Version' } else { '--version' }), $resolvedVersion)
                # The muxer loads the highest versioned hostfxr. SDK feature-band
                # order says nothing about the age of its bundled host/runtime.
                if ($hostExists) {
                    $selection += $(if ($windows) { '-SkipNonVersionedFiles' } else { '--skip-non-versioned-files' })
                }
                $output = Invoke-DotNetSdkProcess -FilePath $executable -Arguments ($prefix + $common + $selection) -Environment $environment
                Write-Verbose $output
                if (-not (Test-Path -LiteralPath $hostPath -PathType Leaf -ErrorAction Stop) -or
                    (Get-DotNetSdkHostArchitecture -Path $hostPath) -ne $Architecture -or
                    -not (Test-DotNetSdkInstalled -InstallDir $InstallDir -Version $resolvedVersion)) {
                    throw "Installer exited successfully but SDK '$resolvedVersion' ($Architecture) was not found in '$InstallDir'."
                }
                $ready = $true
                $status = 'Installed'
            }
        } finally {
            if ($created -and (Test-Path -LiteralPath $directory)) {
                Remove-Item -LiteralPath $directory -Recurse -Force -Confirm:$false -WhatIf:$false -ErrorAction Stop
            }
        }
    } elseif ($WhatIfPreference) {
        $null = $PSCmdlet.ShouldProcess("$InstallDir ($Architecture)", 'Install .NET SDK')
    }
    if ($ready -and -not $WhatIfPreference) {
        Assert-DotNetSdkCompatibility -HostPath $hostPath -InstallDir $InstallDir -Version $resolvedVersion
    }
    $userChanged = $false
    $processChanged = $false
    foreach ($target in @('User', 'Process')) {
        $requested = if ($target -eq 'User') { $AddToUserPath } else { $AddToProcessPath -or $AddToUserPath }
        if (-not $requested) { continue }
        $oldPath = Get-DotNetSdkEnvironment -Name PATH -Target $target
        $newPath = Get-DotNetSdkPathUpdate -Path $oldPath -InstallDir $InstallDir -Platform $platform
        if ($oldPath -cne $newPath -and $PSCmdlet.ShouldProcess("$target PATH", "Add $InstallDir") -and $ready) {
            Set-DotNetSdkEnvironment -Name PATH -Value $newPath -Target $target
            if ($target -eq 'User') { $userChanged = $true } else { $processChanged = $true }
        }
    }
    [pscustomobject]@{
        PSTypeName = 'DotNetSdkInstallResult'
        RequestedVersion = $Version
        RequestedChannel = $(if (-not $Version) { $Channel } else { $null })
        Quality = $Quality
        ResolvedVersion = $resolvedVersion
        ResolvedChannel = $(if ($resolvedVersion) { ($resolvedVersion -split '\.')[0..1] -join '.' } else { $null })
        Architecture = $Architecture
        InstallDir = $InstallDir
        Status = $status
        ProcessPathChanged = $processChanged
        UserPathChanged = $userChanged
    }
}
