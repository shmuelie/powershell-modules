function Invoke-GitProcess {
    <#
    .SYNOPSIS
    Capture a non-interactive git process without changing the parent environment.
    .DESCRIPTION
    Low-level runner for repository discovery and callers that own exit handling.
    Arguments are individual tokens, passed directly to the native git executable.
    StandardOutput and StandardError preserve the decoded text, including newlines.
    Output preserves the legacy stdout-then-stderr line array (not chronological
    interleaving), including a trailing empty line for each newline-ended stream.
    Non-zero exits are returned, not written as errors. Launch failures terminate.
    .PARAMETER Environment
    Child-only environment overrides. A null value removes an inherited variable.
    Credential prompts, pagers and interactive editors are disabled.
    #>
    [OutputType('GitInvocationResult')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [ValidateCount(1, 2147483647)]
        [AllowEmptyString()]
        [ValidateScript({ -not $_.Contains([char]0) }, ErrorMessage = 'Git arguments must not contain NUL characters.')]
        [string[]]$Arguments,

        [hashtable]$Environment
    )

    # Resolve an application explicitly; never dispatch a function, alias or
    # cmd/bat shim, whose shell would reinterpret otherwise literal arguments.
    $executableName = if ($IsWindows) { 'git.exe' } else { 'git' }
    $executable = Get-Command $executableName -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $executable) {
        $PSCmdlet.ThrowTerminatingError([System.Management.Automation.ErrorRecord]::new(
            [System.IO.FileNotFoundException]::new('The native git executable was not found on PATH.'),
            'GitExecutableNotFound', [System.Management.Automation.ErrorCategory]::ObjectNotFound, $executableName))
    }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $executable.Source
    $psi.WorkingDirectory = $ExecutionContext.SessionState.Path.CurrentFileSystemLocation.ProviderPath
    foreach ($argument in $Arguments) { $psi.ArgumentList.Add($argument) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    if ($Environment) {
        foreach ($key in $Environment.Keys) {
            if ($null -eq $Environment[$key]) {
                $null = $psi.Environment.Remove($key)
            } else {
                $psi.Environment[$key] = [string]$Environment[$key]
            }
        }
    }
    $psi.Environment['GIT_TERMINAL_PROMPT'] = '0'
    $psi.Environment['GCM_INTERACTIVE'] = 'never'
    $psi.Environment['GIT_ASKPASS'] = 'false'
    $psi.Environment['SSH_ASKPASS'] = 'false'
    $psi.Environment['GIT_PAGER'] = 'cat'
    $psi.Environment['GIT_EDITOR'] = 'false'
    $psi.Environment['GIT_SEQUENCE_EDITOR'] = 'false'

    $proc = [System.Diagnostics.Process]::new()
    try {
        $proc.StartInfo = $psi
        $null = $proc.Start()
        $proc.StandardInput.Close()
        # Both reads must be in flight before waiting: either pipe can fill.
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        $proc.WaitForExit()
        $stdoutText = $stdoutTask.GetAwaiter().GetResult()
        $stderrText = $stderrTask.GetAwaiter().GetResult()
        $exitCode = $proc.ExitCode
    } catch [System.ComponentModel.Win32Exception], [System.InvalidOperationException] {
        $PSCmdlet.ThrowTerminatingError([System.Management.Automation.ErrorRecord]::new(
            $_.Exception, 'GitProcessFailed', [System.Management.Automation.ErrorCategory]::ResourceUnavailable, $executable.Source))
    } finally {
        $proc.Dispose()
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($block in @($stdoutText, $stderrText)) {
        if ($block) {
            foreach ($line in ($block -split "\r?\n")) { $lines.Add($line) }
        }
    }

    [PSCustomObject]@{
        PSTypeName     = 'GitInvocationResult'
        ExitCode       = $exitCode
        StandardOutput = $stdoutText
        StandardError  = $stderrText
        Output         = $lines.ToArray()
    }
}

function Invoke-Git {
    <#
    .SYNOPSIS
    Run git in a resolved repository and report native failures as PowerShell errors.
    .DESCRIPTION
    Private entry point for module commands. Does not change location or
    LASTEXITCODE. The caller owns ShouldProcess for mutations and command-specific
    validation of refs/options; use -- where git accepts it before operand values.
    Arguments must not be a pre-quoted command string.
    .PARAMETER Path
    Literal directory inside a working tree. Defaults to the current location.
    Resolved by Resolve-GitRepositoryPath and passed as a separate -C argument.
    .PARAMETER AllowBare
    Allow targeting a bare repository.
    .PARAMETER AllowNonRepository
    Require only an existing FileSystem directory, not a repository. Intended for
    commands such as global/system configuration that do not need a repository.
    .PARAMETER AllowNonZeroExit
    Return the result without an error when git exits non-zero, for commands whose
    exit codes carry domain meaning. Otherwise emit GitCommandFailed and no result;
    -ErrorAction Stop promotes that error to terminating. The error's TargetObject
    contains the result, including both streams, ExitCode and RepositoryPath.
    .PARAMETER Environment
    Child-only environment overrides, as in Invoke-GitProcess.
    #>
    [OutputType('GitInvocationResult')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [ValidateCount(1, 2147483647)]
        [AllowEmptyString()]
        [ValidateScript({ -not $_.Contains([char]0) }, ErrorMessage = 'Git arguments must not contain NUL characters.')]
        [string[]]$Arguments,

        [Alias('RepositoryPath', 'RepoPath')]
        [string]$Path,

        [hashtable]$Environment,

        [switch]$AllowBare,

        [switch]$AllowNonRepository,

        [switch]$AllowNonZeroExit
    )

    $repositoryPath = Resolve-GitRepositoryPath -Path $Path -AllowBare:$AllowBare -AllowNonRepository:$AllowNonRepository -Environment $Environment
    if (-not $repositoryPath) { return }

    $result = Invoke-GitProcess -Arguments (@('-C', $repositoryPath) + $Arguments) -Environment $Environment
    $result | Add-Member -NotePropertyName RepositoryPath -NotePropertyValue $repositoryPath
    if ($result.ExitCode -ne 0 -and -not $AllowNonZeroExit) {
        $detail = if ($result.StandardError) { $result.StandardError.TrimEnd() }
            elseif ($result.StandardOutput) { $result.StandardOutput.TrimEnd() }
            else { 'No output.' }
        $errorRecord = [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new("git failed in '$repositoryPath' (exit $($result.ExitCode)): $detail"),
            'GitCommandFailed', [System.Management.Automation.ErrorCategory]::InvalidOperation, $result)
        $PSCmdlet.WriteError($errorRecord)
        return
    }

    $result
}
