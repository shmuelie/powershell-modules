# Discovery-only recovery. These helpers never persist an inferred identity.
function Test-CopilotRepositoryCompatibility {
    param([string]$Recorded, [string]$Canonical)

    if (-not $Recorded -or $Recorded -ieq $Canonical) { return $true }
    $parts = $Canonical.Split('/')
    if ($parts.Count -ne 3) { return $false }
    return ($Recorded -ieq "$($parts[1])/$($parts[2])" -or
        $Recorded -ieq "DefaultCollection/$($parts[1])/$($parts[2])")
}

function Get-CopilotEventEnvelopeType {
    param([Parameter(Mandatory)][string]$Line)

    # Inspect top-level headers without deserializing conversation payloads.
    # JSON property order is immaterial, including data preceding type.
    $depth = 0
    $expectType = $false
    foreach ($token in [regex]::Matches($Line, '(?<string>"(?<text>(?:[^"\\]|\\.)*)")(?<property>\s*:)?|(?<open>[\{\[])|(?<close>[\}\]])')) {
        if ($token.Groups['open'].Success) {
            if ($expectType) { throw [FormatException]::new('Event type must be a string.') }
            $depth++
        } elseif ($token.Groups['close'].Success) {
            $depth--
        } elseif ($depth -eq 1) {
            if ($token.Groups['property'].Success) {
                $property = $token.Groups['text'].Value
                if ($property.Contains('\')) {
                    $property = ConvertFrom-Json -InputObject $token.Groups['string'].Value -ErrorAction Stop
                }
                $expectType = $property -ceq 'type'
            } elseif ($expectType) {
                return (ConvertFrom-Json -InputObject $token.Groups['string'].Value -ErrorAction Stop)
            }
        }
    }
}

function Get-CopilotLifecycleContext {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionPath)

    $journal = Join-Path $SessionPath 'events.jsonl'
    if (-not (Test-Path -LiteralPath $journal -PathType Leaf -ErrorAction Stop)) { return }
    # Bound both allocation and scanning. Never trust a partial scan's old context.
    if ((Get-Item -LiteralPath $journal -ErrorAction Stop).Length -gt 8MB) {
        throw [FormatException]::new('Identity recovery journal exceeds the 8 MiB limit.')
    }
    $reader = [IO.StreamReader]::new($journal)
    try {
        $latest = $null
        $lineCount = 0
        while ($null -ne ($line = $reader.ReadLine())) {
            if (++$lineCount -gt 8192 -or $reader.BaseStream.Position -gt 8MB) {
                throw [FormatException]::new('Identity recovery journal exceeds the scan limit.')
            }
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $type = Get-CopilotEventEnvelopeType -Line $line
            if ($type -cnotin @('session.start', 'session.resume', 'session.context_changed')) {
                continue
            }
            $event = ConvertFrom-Json -InputObject $line -AsHashtable -ErrorAction Stop
            if ($event.data -isnot [System.Collections.IDictionary]) {
                throw [FormatException]::new('Lifecycle data must be an object.')
            }
            if ($event.data.sessionId -and $event.data.sessionId -cne (Split-Path $SessionPath -Leaf)) {
                throw [FormatException]::new('Lifecycle sessionId does not match the session directory.')
            }
            # A later lifecycle boundary without context invalidates old evidence.
            $latest = $event.data.context
            if ($null -ne $latest -and $latest -isnot [System.Collections.IDictionary]) {
                throw [FormatException]::new('Lifecycle context must be an object.')
            }
        }
        if ($latest) {
            foreach ($field in 'repository', 'branch', 'cwd', 'gitRoot', 'hostType', 'repositoryHost') {
                if ($null -ne $latest[$field] -and $latest[$field] -isnot [string]) {
                    throw [FormatException]::new("Lifecycle context $field must be a string.")
                }
            }
            return $latest
        }
    } finally {
        $reader.Dispose()
    }
}

function Get-CopilotRecordedOriginIdentity {
    param([Parameter(Mandatory)][string]$Path)

    if (-not [IO.Path]::IsPathFullyQualified($Path) -or
        -not (Test-Path -LiteralPath $Path -PathType Container -ErrorAction Stop)) { return }
    $previousExitCode = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction Ignore
    $previousExitCodeValue = if ($previousExitCode) { $previousExitCode.Value }
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        $global:LASTEXITCODE = $null
        $inside = @(git -C $Path rev-parse --is-inside-work-tree 2>$null)
        if ($LASTEXITCODE -ne 0 -or $inside.Count -ne 1 -or $inside[0] -cne 'true') { return }
        $global:LASTEXITCODE = $null
        $urls = @(git -C $Path config --get-all remote.origin.url 2>$null)
        if ($LASTEXITCODE -ne 0 -or $urls.Count -ne 1) {
            throw [FormatException]::new('Recorded Git path does not have one origin.')
        }
        $identity = ConvertTo-CopilotAdoRepositoryIdentity -Url $urls[0]
        if (-not $identity) { $identity = ConvertTo-CopilotGitHubRepositoryIdentity -Url $urls[0] }
        if (-not $identity) {
            throw [FormatException]::new('Recorded Git origin is not recognized.')
        }
        return $identity
    } finally {
        if ($previousExitCode) { $global:LASTEXITCODE = $previousExitCodeValue }
        else { Remove-Variable -Name LASTEXITCODE -Scope Global -WhatIf:$false -Confirm:$false }
    }
}

function Resolve-CopilotSessionIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SessionPath,
        [string]$Cwd,
        [string]$Repository,
        [string]$Branch,
        $Scope
    )

    $recorded = [pscustomobject]@{ Cwd = $Cwd; Repository = $Repository; Branch = $Branch }
    if (-not $Scope.Repository -or -not $Scope.Branch) { return $recorded }
    $adoScope = $Scope.Repository -like '*/*/*'
    # Current scope may rule evidence out, but never supplies missing identity.
    if (($Branch -and $Branch -cne $Scope.Branch) -or
        ($Repository -and -not (Test-CopilotRepositoryCompatibility -Recorded $Repository -Canonical $Scope.Repository))) {
        return $recorded
    }
    # Complete ordinary identities need no journal or historical worktree reads.
    $legacy = $adoScope -and ($Repository.Split('/').Count -eq 2 -or $Repository -like 'DefaultCollection/*')
    if ($Repository -and $Branch -and -not $legacy) { return $recorded }

    try {
        $context = Get-CopilotLifecycleContext -SessionPath $SessionPath
        $effectiveRepository = $Repository
        $effectiveBranch = $Branch
        $effectiveCwd = $Cwd
        $paths = [System.Collections.Generic.List[string]]::new()
        if ($Cwd) { $paths.Add($Cwd) }
        if ($context) {
            # Never borrow context from a different known directory or branch.
            $contextPaths = @($context.cwd, $context.gitRoot | Where-Object { $_ })
            if (($Cwd -and $contextPaths.Count -gt 0 -and $Cwd -notin $contextPaths) -or
                ($Branch -and $context.branch -and $context.branch -cne $Branch)) {
                return $recorded
            }
            $contextRepository = $context.repository
            $organization = $null
            if ($context.repositoryHost) {
                if ($context.repositoryHost -match '\A([a-z0-9](?:[a-z0-9-]*[a-z0-9])?)\.visualstudio\.com\z') {
                    $organization = $Matches[1].ToLowerInvariant()
                } elseif ($context.repositoryHost -notin @('dev.azure.com', 'ssh.dev.azure.com', 'github.com')) {
                    throw [FormatException]::new('Lifecycle repositoryHost is not a supported ADO hostname.')
                }
                if (($context.repositoryHost -ieq 'github.com' -and $adoScope) -or
                    ($context.repositoryHost -ine 'github.com' -and $context.hostType -and
                        $context.hostType -notin @('ado', 'azure-devops', 'azureDevOps'))) {
                    return $recorded
                }
            }
            if ($context.hostType -and $context.hostType -notin @('ado', 'azure-devops', 'azureDevOps', 'github')) {
                return $recorded
            }
            if ($context.hostType -ieq 'github' -and $adoScope) { return $recorded }
            if ($organization) {
                if ($contextRepository) {
                    $parts = $contextRepository.Split('/')
                    if ($parts.Count -eq 2) { $contextRepository = "$organization/$contextRepository" }
                    elseif ($parts.Count -eq 3 -and $parts[0] -ieq 'DefaultCollection') {
                        $contextRepository = "$organization/$($parts[1])/$($parts[2])"
                    } elseif ($parts.Count -ne 3 -or $parts[0] -ine $organization) {
                        return $recorded
                    }
                } elseif ($legacy) {
                    $parts = $Repository.Split('/')
                    $contextRepository = "$organization/$($parts[-2])/$($parts[-1])"
                }
            }
            if ($contextRepository) {
                # Validate decoded canonical ADO identities with the URL parser.
                $parts = $contextRepository.Split('/')
                $canonical = if ($parts.Count -eq 3 -and $parts[0] -ine 'DefaultCollection') {
                    $urlParts = @($parts | ForEach-Object { [uri]::EscapeDataString($_) })
                    ConvertTo-CopilotAdoRepositoryIdentity -Url "https://dev.azure.com/$($urlParts[0])/$($urlParts[1])/_git/$($urlParts[2])"
                } elseif (-not $adoScope -and $parts.Count -eq 2) {
                    ConvertTo-CopilotGitHubRepositoryIdentity -Url "https://github.com/$contextRepository"
                }
                if ($canonical) {
                    if (-not (Test-CopilotRepositoryCompatibility -Recorded $Repository -Canonical $canonical)) { return $recorded }
                    $effectiveRepository = $canonical
                } elseif ($adoScope -and ($parts.Count -eq 2 -or
                    ($parts.Count -eq 3 -and $parts[0] -ieq 'DefaultCollection'))) {
                    # Keep the unresolved shape pending independent Git evidence.
                    if ($Repository -and $Repository -ine $contextRepository -and
                        -not (Test-CopilotRepositoryCompatibility -Recorded $contextRepository -Canonical $Repository)) { return $recorded }
                    if (-not $Repository) { $effectiveRepository = $contextRepository }
                } else { return $recorded }
            }
            if (-not $Branch) { $effectiveBranch = $context.branch }
            if (-not $Cwd) { $effectiveCwd = $context.cwd }
            foreach ($path in $context.cwd, $context.gitRoot) {
                if ($path -and $path -notin $paths) { $paths.Add($path) }
            }
        }

        # A complete lifecycle recovery needs no Git probe. Otherwise only
        # recorded paths can establish origin; never read today's branch.
        $stillLegacy = $adoScope -and ($effectiveRepository.Split('/').Count -eq 2 -or $effectiveRepository -like 'DefaultCollection/*')
        if (-not $effectiveRepository -or $stillLegacy) {
            $origins = @($paths | ForEach-Object { Get-CopilotRecordedOriginIdentity -Path $_ } | Sort-Object -Unique)
            if ($origins.Count -gt 1) { return $recorded }
            if ($origins.Count -eq 1) {
                if (-not (Test-CopilotRepositoryCompatibility -Recorded $effectiveRepository -Canonical $origins[0])) { return $recorded }
                $effectiveRepository = $origins[0]
            }
        }
        [pscustomobject]@{ Cwd = $effectiveCwd; Repository = $effectiveRepository; Branch = $effectiveBranch }
    } catch {
        $message = "Invalid identity recovery evidence for Copilot session '$(Split-Path $SessionPath -Leaf)' in '$SessionPath': $($_.Exception.Message)"
        $recorded | Add-Member -NotePropertyName RecoveryError -NotePropertyValue ([System.Management.Automation.ErrorRecord]::new(
            [FormatException]::new($message), 'InvalidCopilotSessionIdentity',
            [System.Management.Automation.ErrorCategory]::InvalidData, $SessionPath))
        return $recorded
    }
}
