# Private helpers backing the GitHub-account-aware fetch in Sync-GitRemote.
# None of these are exported; they are dot-sourced with the rest of Public/.
#
# The mechanism keeps the globally-active `gh` account unchanged: a per-account
# token is acquired with `gh auth token` and injected into the git child
# process environment only. This is safe when several fetches run concurrently
# in the same process (a shared $env:GH_TOKEN would race). It supports any host
# `gh` manages, i.e. github.com and GitHub Enterprise (GHE) hosts alike.

# Values derived from a repository (remote-URL host/owner segments) and from
# `gh auth status` are passed to the `gh` executable. Validate them first so a
# hostile segment can't smuggle cmd.exe metacharacters into a launched process
# (CVE-2024-1874 / "BatBadBut" class), and so a bad value degrades to a graceful
# no-op rather than an error.
function Test-GitHubHostName {
    param([string]$HostName)
    # DNS host label set only; no scheme, port, path, or shell metacharacters.
    return [bool]($HostName -and $HostName -match '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$')
}

function Test-GitHubAccountName {
    param([string]$Account)
    # GitHub login rules: alphanumerics and single hyphens, no leading hyphen.
    return [bool]($Account -and $Account -match '^[A-Za-z0-9](?:-?[A-Za-z0-9])*$')
}

function Test-GhAvailable {
    return [bool](Get-Command gh -CommandType Application -ErrorAction SilentlyContinue)
}

function Get-GitHubSignedInAccount {
    <#
    .SYNOPSIS
    Enumerate the accounts signed in to `gh`, grouped by host.
    .DESCRIPTION
    Parses `gh auth status` and returns one object per signed-in account with
    its host, account name, and whether it is the active account for that host.
    Covers github.com and any GitHub Enterprise host `gh` is configured for.
    Returns nothing when `gh` is unavailable or no accounts are signed in.
    #>
    [OutputType('GitHubAccount')]
    [CmdletBinding()]
    param()

    if (-not (Test-GhAvailable)) { return }

    # `gh auth status` has no JSON/machine-readable form, so this parses its
    # English output ("Logged in to <host> account <user>" / "Active account:
    # true"). It is therefore coupled to that wording; if a future `gh` changes
    # it, the Active flag only affects candidate ordering, so a parse miss
    # degrades gracefully to "try all accounts" rather than failing.
    $output = & gh auth status 2>&1
    if (-not $output) { return }

    $records = [System.Collections.Generic.List[psobject]]::new()
    $current = $null
    foreach ($line in $output) {
        $text = "$line"
        # "✓ Logged in to <host> account <user> (<source>)"
        if ($text -match 'Logged in to\s+(?<host>\S+)\s+account\s+(?<account>\S+)') {
            $current = [PSCustomObject]@{
                PSTypeName = 'GitHubAccount'
                Host       = $Matches.host.ToLowerInvariant()
                Account    = $Matches.account
                Active     = $false
            }
            $records.Add($current)
        }
        elseif ($current -and $text -match 'Active account:\s*(?<active>true|false)') {
            $current.Active = ($Matches.active -eq 'true')
        }
    }

    $records
}

function Get-GitHubRemoteInfo {
    <#
    .SYNOPSIS
    Extract the host and owner from a git remote URL.
    .DESCRIPTION
    Understands HTTPS/SSH URL form (scheme://[user@]host[:port]/owner/repo) and
    the scp-like form (user@host:owner/repo). Returns an object with a
    lower-cased Host and the Owner, or nothing when the URL is unrecognized.
    #>
    [OutputType('GitHubRemoteInfo')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Url)

    $gitHost = $null
    $owner = $null
    if ($Url -match '^[A-Za-z][A-Za-z0-9+.-]*://(?:[^@/]+@)?(?<host>[^/:]+)(?::\d+)?/(?<owner>[^/]+)/') {
        $gitHost = $Matches.host
        $owner = $Matches.owner
    }
    elseif ($Url -match '^(?:[^@]+@)?(?<host>[^:/]+):(?<owner>[^/]+)/') {
        $gitHost = $Matches.host
        $owner = $Matches.owner
    }

    if (-not $gitHost -or -not $owner) { return }

    [PSCustomObject]@{
        PSTypeName = 'GitHubRemoteInfo'
        Host       = $gitHost.ToLowerInvariant()
        Owner      = $owner
    }
}

function Get-GitHubAccountToken {
    <#
    .SYNOPSIS
    Acquire a host+account token without switching the active account.
    .DESCRIPTION
    Wraps `gh auth token --hostname <host> --user <account>`. Returns the token
    string on success, or nothing on any failure (so callers can fall back).
    The globally-active `gh` account is never changed.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][string]$Account
    )

    if (-not (Test-GitHubHostName $HostName) -or -not (Test-GitHubAccountName $Account)) {
        Write-Verbose "Refusing to request token for unsafe host/account '$HostName'/'$Account'."
        return
    }

    $token = & gh auth token --hostname $HostName --user $Account 2>$null
    if ($LASTEXITCODE -ne 0) { return }

    $token = "$token".Trim()
    if ($token) { $token }
}

function Get-GitHubAccountMapValue {
    <#
    .SYNOPSIS
    Look up an account for a host+owner in a user-supplied map (case-insensitive).
    .DESCRIPTION
    Accepts keys as "host/owner" or bare "owner" (owner-only entries apply on any
    host). Returns the mapped account name, or nothing when no entry matches.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [hashtable]$Map,
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][string]$Owner
    )

    if (-not $Map -or $Map.Count -eq 0) { return }

    $candidates = @("$HostName/$Owner", $Owner)
    foreach ($key in $Map.Keys) {
        foreach ($candidate in $candidates) {
            if ([string]::Equals("$key", $candidate, [System.StringComparison]::OrdinalIgnoreCase)) {
                $value = "$($Map[$key])".Trim()
                if ($value) { return $value }
            }
        }
    }
}

function Invoke-GitWithEnvironment {
    <#
    .SYNOPSIS
    Run git with extra environment variables set on the child process only.
    .DESCRIPTION
    Uses a redirected .NET process so GH_TOKEN/GH_HOST are visible to the git
    child (and the `gh` credential helper it invokes) without touching the
    caller's $env: — safe under same-process parallel callers. Captures both
    stdout and stderr (git fetch writes ref updates to stderr) and returns an
    object with ExitCode and the merged Output lines.
    #>
    [OutputType('GitInvocationResult')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [hashtable]$Environment
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'git'
    foreach ($arg in $Arguments) { $psi.ArgumentList.Add($arg) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    if ($Environment) {
        foreach ($key in $Environment.Keys) {
            $psi.EnvironmentVariables[$key] = [string]$Environment[$key]
        }
    }

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    $null = $proc.Start()
    # Read stdout async while draining stderr synchronously to avoid a
    # full-pipe deadlock when either stream fills its buffer.
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrText = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    $stdoutText = $stdoutTask.GetAwaiter().GetResult()
    $exitCode = $proc.ExitCode
    $proc.Dispose()

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($block in @($stdoutText, $stderrText)) {
        if ($block) {
            foreach ($l in ($block -split "\r?\n")) { $lines.Add($l) }
        }
    }

    [PSCustomObject]@{
        PSTypeName = 'GitInvocationResult'
        ExitCode   = $exitCode
        Output     = $lines.ToArray()
    }
}

function Test-GitHubAuthFailure {
    <#
    .SYNOPSIS
    Heuristically decide whether git fetch output indicates an auth/access
    failure worth retrying with a different account (vs a real error).
    #>
    [OutputType([bool])]
    [CmdletBinding()]
    param([string[]]$Output)

    $joined = ($Output -join "`n")
    return [bool]($joined -match 'Authentication failed|could not read Username|terminal prompts disabled|403 Forbidden|Repository not found|Permission (?:to .*)?denied|access denied|401 Unauthorized')
}
