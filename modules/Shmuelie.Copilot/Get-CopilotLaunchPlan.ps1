function Assert-CopilotMcpGitHubAuth {
    param(
        [string[]]$McpGitHubAuth,
        [string[]]$AdditionalMcpConfig
    )

    if (-not $AdditionalMcpConfig) {
        throw '-McpGitHubAuth requires -AdditionalMcpConfig with the named remote server.'
    }

    $servers = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($source in $AdditionalMcpConfig) {
        try {
            if ($source.StartsWith('@', [StringComparison]::Ordinal)) {
                $path = $source.Substring(1)
                if ($path.StartsWith('~/', [StringComparison]::Ordinal)) {
                    $path = Join-Path (Get-CopilotHome) $path.Substring(2)
                }
                $json = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
            } else {
                $json = $source
            }
            $config = ConvertFrom-Json -InputObject $json -ErrorAction Stop
        } catch {
            throw 'Cannot read or parse -AdditionalMcpConfig for -McpGitHubAuth. No authentication was enabled.'
        }
        if ($null -eq $config -or $null -eq $config.mcpServers) {
            throw '-AdditionalMcpConfig must contain mcpServers for -McpGitHubAuth.'
        }
        foreach ($server in $config.mcpServers.PSObject.Properties) {
            if ($servers.ContainsKey($server.Name)) {
                throw 'Duplicate explicit MCP server name in -AdditionalMcpConfig for -McpGitHubAuth.'
            }
            $servers.Add($server.Name, $server.Value)
        }
    }

    $scopedNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in $McpGitHubAuth) {
        if ($entry -cnotmatch '\A([A-Za-z0-9][A-Za-z0-9._-]*)=(https?://(?:[A-Za-z0-9.-]+|\[::1\])(?::[0-9]{1,5})?)/?\z') {
            throw 'Invalid -McpGitHubAuth entry. Use server=https://host[:port] (or literal loopback HTTP); never include a token, path, or credentials.'
        }
        $name = $Matches[1]
        $originText = $Matches[2]
        if (-not $scopedNames.Add($name)) {
            throw "MCP server '$name' has more than one -McpGitHubAuth origin."
        }
        $origin = $null
        if (-not [uri]::TryCreate($originText, [UriKind]::Absolute, [ref]$origin) -or
            $origin.UserInfo -or
            ($origin.Scheme -eq 'http' -and $origin.Host -notin @('127.0.0.1', '[::1]'))) {
            throw 'Invalid -McpGitHubAuth origin. Use HTTPS or literal loopback HTTP without credentials, path, query, or fragment.'
        }
        if (-not $servers.ContainsKey($name)) {
            throw "MCP server '$name' must be defined in -AdditionalMcpConfig for -McpGitHubAuth."
        }
        $server = $servers[$name]
        $url = $null
        if (($server.type -and $server.type -notin @('http', 'sse')) -or
            $server.url -isnot [string] -or
            -not [uri]::TryCreate($server.url, [UriKind]::Absolute, [ref]$url) -or
            $url.UserInfo -or
            $url.Scheme -ne $origin.Scheme -or
            $url.IdnHost -ine $origin.IdnHost -or
            $url.Port -ne $origin.Port) {
            throw "MCP server '$name' must have a remote URL at the approved -McpGitHubAuth origin."
        }
    }
}

function Get-CopilotModelCompletion {
    param([string]$WordToComplete)

    # Native help documents auto but offers no non-interactive model inventory.
    @(
        'auto',
        'claude-sonnet-4.6', 'claude-sonnet-4.5', 'claude-haiku-4.5',
        'claude-opus-4.7', 'claude-opus-4.7-1m', 'claude-opus-4.6', 'claude-opus-4.5', 'claude-sonnet-4',
        'gpt-5.5', 'gpt-5.4', 'gpt-5.3-codex', 'gpt-5.2-codex', 'gpt-5.2',
        'gpt-5.4-mini', 'gpt-5-mini', 'gpt-4.1'
    ) | Where-Object { $_ -like "$WordToComplete*" }
}

function Get-CopilotLaunchPlan {
    <#
    .SYNOPSIS
        Compute the GitHub Copilot CLI launch plan (executable, argument vector,
        and passthrough flag) without launching anything.

    .DESCRIPTION
        Builds the full copilot argument vector — sensible defaults
        (--allow-all --experimental), the destructive-git deny rules, MCP
        autoConnect handling, every mapped flag, and the session-resume decision —
        and returns it as a CopilotLaunchPlan object with Exe, Args, and
        Passthrough properties. It never launches a process.

        This is the shared core used by Start-Copilot and by any tool that builds
        on top of it (for example, an overlay that launches a different engine):
        both compute identical arguments through this one function instead of
        duplicating the logic. Destructive git operations (force push, hard reset,
        rebase, amend, and similar) are denied by default; pass -NoDefaultDenyTools
        to opt out of those deny rules. Typed mappings track the current printed
        CLI surface, while compatibility switches such as -Version
        (--prefer-version) and -EnableReasoningSummaries
        (--enable-reasoning-summaries) remain available even though the current
        native help text omits them.

        When a Prompt is provided, the plan runs in non-interactive autopilot mode
        (-p --autopilot). When no Prompt is provided, it is interactive.

        When the effective directory belongs to a GitHub worktree with an origin
        and checked-out branch, sessions are scoped by recorded repository and
        branch, even after a worktree moves. Incomplete session metadata falls
        back only at the current directory when known fields do not conflict;
        non-Git or ambiguous origins use the current directory. If exactly one
        eligible session exists it is
        resumed automatically. If multiple sessions exist, an interactive picker
        is shown -- except when only one of them is a *named* session (the rest
        being unnamed '(no summary)' stubs), in which case that lone named
        session is resumed automatically. When the picker is shown, unnamed
        '(no summary)' sessions are hidden if any named session exists; pass
        -IncludeUnnamed to list them too. Use -NoResume to skip session resume
        entirely, or -ResumeLatest to automatically resume the most recent
        session without prompting. Auto-generated maintenance sessions are
        ignored when choosing a session to resume.

        The prompt values "update" and "help" are treated as passthrough
        commands, forwarding all arguments directly to the copilot executable
        (e.g., copilot update, copilot help).

    .PARAMETER Prompt
        Prompt to execute. When provided, copilot runs non-interactively in autopilot
        mode and exits on completion.

    .PARAMETER Interactive
        Start interactive mode and automatically execute this prompt. Unlike -Prompt,
        the session remains interactive after the initial prompt completes.

    .PARAMETER Fleet
        Run the initial prompt in fleet mode (parallel subagent orchestration).
        When using this wrapper, combine it with -Prompt or -Interactive.

    .PARAMETER NoResume
        Skip session resume even if a matching session exists.

    .PARAMETER NoAllowAll
        Do not pass --allow-all. By default Start-Copilot enables all permissions;
        use this switch to start with normal permission prompting.

    .PARAMETER NoDefaultDenyTools
        Do not add the built-in deny rules for destructive git operations (force
        push, hard reset, rebase, amend, git pull, and similar). Use this if your
        workflow relies on those commands; you can still add your own via
        -DenyTool.

    .PARAMETER ResumeLatest
        When multiple eligible sessions exist, automatically resume
        the most recently updated session instead of showing the interactive picker.

    .PARAMETER ResumeSession
        Resume a specific session directly, by session id, id-prefix, or name
        (passed to the CLI's --resume). Bypasses the auto-resume heuristics and the
        picker. Tab-completes eligible sessions in the effective launch directory
        (including -ChangeDir). Mutually exclusive with
        -NoResume, -ResumeLatest, and -NoAutoResume. If combined with -SessionId,
        this parameter drives the --resume value while -SessionId is still forwarded
        as --session-id.

    .PARAMETER NoAutoResume
        Disable auto-resume and always show the interactive session picker for the
        current scope, even when a session would otherwise be auto-resumed
        (including when only one session exists). Mutually exclusive with -NoResume,
        -ResumeLatest, and -ResumeSession. The former name -ShowPicker is retained
        as an alias for back-compat.

    .PARAMETER IncludeUnnamed
        Include unnamed '(no summary)' sessions in the interactive picker. By
        default the picker hides these stubs whenever at least one named session
        exists for the folder (if there are no named sessions, unnamed ones are
        always shown so the picker is never empty). Combine with -NoAutoResume to
        force the picker and list every session. Has no effect when no picker is
        shown (e.g. with -NoResume, -ResumeLatest, or -ResumeSession).

    .PARAMETER Model
        The AI model to use for the session. Use 'auto' for native model routing.
        Tab completion suggests common models but does not limit accepted values.

    .PARAMETER SessionSelector
        Optional scriptblock replacing only the native host session picker. Receives
        one object[] argument containing CopilotSession objects with Id, Name,
        Summary, Branch, UpdatedAt (DateTimeOffset), and Cwd. Return exactly one
        CopilotSession whose Id exactly matches a candidate, or $null/no output
        to start a new session. Other success-stream output is invalid; use
        Write-Host or Write-Verbose for UI/diagnostics. Returned metadata changes
        are ignored. Errors and invalid results terminate without launching or
        falling back to another picker.

        Automatic single-session/lone-named-session resume still takes precedence;
        use -NoAutoResume to force selection. -NoResume, -ResumeLatest,
        -ResumeSession, -SessionId, -DeferResume, and help/update passthrough bypass
        the selector. It is never called for zero candidates. Custom selectors work
        in noninteractive hosts without console access; they own any UI they use.
        The default picker uses the active host's PromptForChoice with descriptive
        labels and 22 sessions per page. M selects Next page and P selects Previous
        page when available; N starts a New session from any page. All candidates
        remain reachable, with unique session keys per page and no default choice.
        Names are capped at 80 Unicode text elements including '...'; branches
        appear only for displayed names duplicated anywhere in the candidate set.
        Full details remain in choice help. Names/branches have terminal controls
        sanitized; literal ampersands do not assign keys. Unavailable input, host errors,
        and invalid responses terminate without choosing a session or falling
        back to another UI.

    .PARAMETER Version
        Run a specific Copilot CLI engine version for this session, e.g. '1.0.55'.
        Maps to the engine's --prefer-version flag. When set, --no-auto-update is
        also added so an auto-update can't replace the pinned version mid-session.

    .PARAMETER Agent
        Specify a custom agent to use.

    .PARAMETER ReasoningEffort
        Set the reasoning effort level.

    .PARAMETER AutoTier
        Set the Auto routing preference: efficiency, balance, or intelligence.
        If combined with -Model, the model must be 'auto'.

    .PARAMETER AddDir
        One or more directories to grant file access to.

    .PARAMETER MaxAutopilotContinues
        Maximum number of continuation messages in autopilot mode.

    .PARAMETER Silent
        Output only the agent response (no stats), useful for scripting with -Prompt.

    .PARAMETER Share
        Export session to a markdown file after completion in non-interactive mode.
        Optionally specify a file path; defaults to ./copilot-session-<id>.md.

    .PARAMETER ShareGist
        Export session to a secret GitHub gist after completion in non-interactive mode.

    .PARAMETER NoCustomInstructions
        Disable loading of custom instructions from AGENTS.md and related files.

    .PARAMETER AdditionalMcpConfig
        Additional MCP servers configuration as JSON string or file path (prefix with @).

    .PARAMETER McpGitHubAuth
        One or more server=origin entries for native --mcp-github-auth (Copilot CLI
        1.0.90-3 or later). Sends the signed-in GitHub account credential only to
        the named server in explicit -AdditionalMcpConfig at that exact origin.
        Origins must be HTTPS, except literal 127.0.0.1 or [::1] HTTP. Never put
        a token in this argument. Plans retain any inline -AdditionalMcpConfig
        verbatim, so do not embed secrets there or share a plan publicly.

    .PARAMETER AllowTool
        One or more tools to allow without confirmation.

    .PARAMETER DenyTool
        One or more tools to deny permission to use.

    .PARAMETER AllowUrl
        One or more URLs or domains to allow access to.

    .PARAMETER DenyUrl
        One or more URLs or domains to deny access to.

    .PARAMETER OutputFormat
        Output format for non-interactive mode.

    .PARAMETER LogLevel
        Set the log level.

    .PARAMETER NoAskUser
        Disable the ask_user tool so the agent works fully autonomously.

    .PARAMETER PluginDir
        One or more local plugin directories to load.

    .PARAMETER SecretEnvVars
        Environment variable names whose values are stripped and redacted.

    .PARAMETER ScreenReader
        Enable screen reader accessibility optimizations.

    .PARAMETER AssistedApproval
        Review tool-permission requests with the assisted-approval safety judge
        instead of approving them outright. Takes precedence over allowing all
        tools when the judge engages; requires experimental mode (on by default
        unless -NoExperimental is set).

    .PARAMETER AllowAllTools
        Allow all tools to run automatically without confirmation while keeping
        file-path and URL verification (unlike --allow-all, which also disables
        path/URL checks). Implies not passing --allow-all. For fully
        non-interactive use (-Prompt) where the agent may access paths outside
        the working directory or external URLs, also pass -AllowAllPaths /
        -AllowAllUrls so it does not stall on permission prompts.

    .PARAMETER UsageOutputFile
        Write final usage statistics as JSON to the specified file. Most useful
        with -Prompt (non-interactive mode).

    .PARAMETER DisableMcpServer
        One or more MCP server names to disable at startup, in addition to
        any servers disabled by path-based autoConnect policy in the config.

    .PARAMETER EnableMcpServer
        One or more MCP server names to enable at startup. Overrides the
        path-based autoConnect policy in the config and also passes the CLI's
        native --enable-mcp-server so a server disabled in the Copilot settings
        is enabled for this run only (nothing is persisted). Passing a name whose
        server is already enabled is a no-op.

    .PARAMETER Name
        Set a name for the new session. Cannot be combined with session resume.

    .PARAMETER Mode
        Set the initial agent mode: interactive, plan, or autopilot.
        Supersedes the -Plan switch (which maps to -Mode plan for backward compat).

    .PARAMETER Plan
        Start in plan mode instead of interactive mode.
        Backward-compatibility alias for -Mode plan.

    .PARAMETER Connect
        Connect to a remote session. Optionally specify a session ID or task ID.

    .PARAMETER Attachment
        One or more file paths (images or documents) to attach to the initial prompt.
        Only valid with -Prompt (non-interactive mode).

    .PARAMETER Remote
        Enable remote control of the session from GitHub web and mobile.

    .PARAMETER NoRemote
        Disable remote control of the session from GitHub web and mobile.

    .PARAMETER Mouse
        Enable or disable mouse support in alt screen mode ('on' or 'off').

    .PARAMETER NoMouse
        Disable mouse support in alt screen mode. Native compatibility switch
        alongside -Mouse on|off; cannot be combined with -Mouse.

    .PARAMETER PlainDiff
        Disable rich diff rendering (syntax highlighting via git's diff tool).

    .PARAMETER Stream
        Enable or disable streaming mode ('on' or 'off').

    .PARAMETER AvailableTool
        Restrict the tools available to the model to only these tools.

    .PARAMETER ExcludedTool
        Exclude specific tools from being available to the model.

    .PARAMETER LogDir
        Override the log file directory (default: ~/.copilot/logs/).

    .PARAMETER AddGitHubMcpTool
        Add individual tools to enable for the GitHub MCP server
        (can be used multiple times). Use "*" for all tools.

    .PARAMETER AddGitHubMcpToolset
        Add toolsets to enable for the GitHub MCP server
        (can be used multiple times). Use "all" for all toolsets.

    .PARAMETER EnableAllGitHubMcpTools
        Enable all GitHub MCP server tools instead of the default CLI subset.

    .PARAMETER DisableBuiltinMcps
        Disable all built-in MCP servers (currently: github-mcp-server).

    .PARAMETER EnableReasoningSummaries
        Request reasoning summaries for OpenAI models.

    .PARAMETER SessionId
        Set the session UUID for the CLI invocation (maps to --session-id), such
        as when assigning an id to a new session or task. This does not resume a
        session by itself; use -ResumeSession to resume by id, id-prefix, or
        name via --resume. If combined with -ResumeSession, the plan emits both
        --resume (from -ResumeSession) and --session-id (from -SessionId).

    .PARAMETER NoColor
        Disable all color output (useful for piping or scripting).

    .PARAMETER Banner
        Show the startup banner.

    .PARAMETER NoAutoUpdate
        Disable automatic CLI update during the session.

    .PARAMETER DisallowTempDir
        Prevent automatic access to the system temporary directory.

    .PARAMETER Context
        Set the context window tier: 'default' or 'long_context'.
        Use 'long_context' for large codebases that need more context.

    .PARAMETER AllowAllPaths
        Disable file path verification and allow access to any path.

    .PARAMETER AllowAllUrls
        Allow access to all URLs without confirmation.

    .PARAMETER EnableMemory
        Enable the memory tools in prompt (-Prompt) mode. Memory is disabled by
        default in non-interactive mode.

    .PARAMETER DynamicRetrieval
        Persistently enable or disable embeddings-based dynamic retrieval per
        category, using values such as 'skills=off'. Unlike ordinary session
        flags, this updates Copilot's saved setting when the CLI actually starts.
        Get-CopilotLaunchPlan, Start-Copilot -PassThru, and -WhatIf only preview
        the native arguments and do not persist anything.

    .PARAMETER MaxAiCredits
        Set the maximum AI credits to spend in this session.

    .PARAMETER AllowAllMcpServerInstructions
        Include initialization instructions from all MCP servers in the system
        prompt, instead of only allowlisted servers.

    .PARAMETER BashEnv
        Enable or disable BASH_ENV support for bash shells ('on' or 'off').

    .PARAMETER NoBashEnv
        Disable BASH_ENV support for bash shells.

    .PARAMETER RemoteExport
        Export the session to GitHub web and mobile (read-only; does not enable
        remote control).

    .PARAMETER NoRemoteExport
        Disable exporting the session to GitHub web and mobile (also disables
        remote control).

    .PARAMETER NoEagerPowerShellResolution
        On Windows, disable background PowerShell prompt resolution. This native
        switch is Windows-only; passing it on another platform is an error.

    .PARAMETER ExtensionSdkPath
        Override the bundled @github/copilot-sdk injected into extension
        subprocesses with a local copilot-sdk/ folder (advanced; invalid paths
        fall back to the bundled SDK).

    .PARAMETER Acp
        Start as an Agent Client Protocol (ACP) server.

    .PARAMETER NoExperimental
        Do not pass --experimental. By default Start-Copilot opts into
        experimental features; use this switch to run with them off.

    .PARAMETER ChangeDir
        Use this directory for session/branch selection and MCP path policy.
        Aliased as -C. Relative paths resolve from the caller's location; the
        directory must exist in the filesystem. Planning temporarily uses that
        location and restores the caller's location on success or error.
        Normal launch arguments include -C with the absolute filesystem path,
        so the native CLI does not apply a relative directory change twice.
        Help/update passthrough arguments remain unchanged.

    .PARAMETER DeferResume
        Skip the automatic session-resume decision entirely: no interactive
        picker runs and no --resume argument is added, leaving session selection
        to the caller. Intended for overlays that own their own multi-session
        orchestration. An explicit -ResumeSession still takes effect; -NoResume
        and the resume-mode switches are unaffected.

    .PARAMETER RemainingArgs
        Any additional arguments are included in the plan's Args verbatim.

    .EXAMPLE
        $plan = Get-CopilotLaunchPlan
        # Returns @{ Exe; Args; Passthrough } for an interactive session,
        # auto-resuming if a session exists.

    .EXAMPLE
        $plan = Get-CopilotLaunchPlan -Model claude-opus-4.7
        # Returns the plan without launching, so a caller can reuse the built
        # arguments (e.g. to launch a different engine).

    .EXAMPLE
        $plan = Get-CopilotLaunchPlan -DeferResume
        # Returns the plan with no --resume and no picker, so an overlay can make
        # the session-resume decision itself.

    .EXAMPLE
        $plan = Get-CopilotLaunchPlan -NoAutoResume -SessionSelector {
            param([object[]]$Sessions)
            $Sessions | Sort-Object UpdatedAt -Descending | Select-Object -First 1
        } -Model gpt-5.4
        # Portable selection without console input; all other launch flags remain intact.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Copilot')]
    [OutputType('CopilotLaunchPlan')]
    param(
        [Parameter(Position = 0)]
        [string]$Prompt,

        [string]$Interactive,

        [switch]$Fleet,

        [Parameter(ParameterSetName = 'CopilotNoResume', Mandatory)]
        [switch]$NoResume,

        [switch]$NoAllowAll,

        [switch]$NoDefaultDenyTools,

        [Parameter(ParameterSetName = 'CopilotResumeLatest', Mandatory)]
        [switch]$ResumeLatest,

        [Parameter(ParameterSetName = 'CopilotResumeSession', Mandatory)]
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
            & (Get-Module Shmuelie.Copilot -ErrorAction Stop) {
                param($word, $bound)
                Complete-CopilotResumeSession -WordToComplete $word -BoundParameters $bound
            } $wordToComplete $fakeBoundParameters
        })]
        [string]$ResumeSession,

        [Parameter(ParameterSetName = 'CopilotShowPicker', Mandatory)]
        [Alias('ShowPicker')]
        [switch]$NoAutoResume,

        [Alias('ShowUnnamed')]
        [switch]$IncludeUnnamed,

        [ValidateNotNull()]
        [scriptblock]$SessionSelector,

        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete)
            & (Get-Module Shmuelie.Copilot) {
                param($word)
                Get-CopilotModelCompletion -WordToComplete $word
            } $wordToComplete
        })]
        [string]$Model,

        [string]$Version,

        [string]$Agent,

        [ValidateSet('none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max')]
        [string]$ReasoningEffort,

        [ValidateSet('efficiency', 'balance', 'intelligence')]
        [string]$AutoTier,

        [string[]]$AddDir,

        [ValidateRange(1, [int]::MaxValue)]
        [int]$MaxAutopilotContinues,

        [switch]$Silent,

        [string]$Share,

        [switch]$ShareGist,

        [switch]$NoCustomInstructions,

        [string[]]$AdditionalMcpConfig,

        [string[]]$McpGitHubAuth,

        [string[]]$AllowTool,

        [string[]]$DenyTool,

        [string[]]$AllowUrl,

        [string[]]$DenyUrl,

        [ValidateSet('text', 'json')]
        [string]$OutputFormat,

        [ValidateSet('none', 'error', 'warning', 'info', 'debug', 'all', 'default')]
        [string]$LogLevel,

        [switch]$NoAskUser,

        [string[]]$PluginDir,

        [string[]]$SecretEnvVars,

        [switch]$ScreenReader,

        [switch]$AssistedApproval,

        [switch]$AllowAllTools,

        [string]$UsageOutputFile,

        [string[]]$DisableMcpServer,

        [string[]]$EnableMcpServer,

        [string]$Name,

        [ValidateSet('interactive', 'plan', 'autopilot')]
        [string]$Mode,

        [switch]$Plan,

        [string]$Connect,

        [string[]]$Attachment,

        [switch]$Remote,

        [switch]$NoRemote,

        [ValidateSet('on', 'off')]
        [string]$Mouse,

        [switch]$NoMouse,

        [switch]$PlainDiff,

        [ValidateSet('on', 'off')]
        [string]$Stream,

        [string[]]$AvailableTool,

        [string[]]$ExcludedTool,

        [string]$LogDir,

        [string[]]$AddGitHubMcpTool,

        [string[]]$AddGitHubMcpToolset,

        [switch]$EnableAllGitHubMcpTools,

        [switch]$DisableBuiltinMcps,

        [switch]$EnableReasoningSummaries,

        [string]$SessionId,

        [switch]$NoColor,

        [switch]$Banner,

        [switch]$NoAutoUpdate,

        [switch]$DisallowTempDir,

        [ValidateSet('default', 'long_context')]
        [string]$Context,

        [switch]$AllowAllPaths,

        [switch]$AllowAllUrls,

        [switch]$EnableMemory,

        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete)
            @('skills=on', 'skills=off') | Where-Object { $_ -like "$wordToComplete*" }
        })]
        [ValidateScript({
            if ($_ -isnot [string] -or $_ -notmatch '^skills=(on|off)$') {
                throw "DynamicRetrieval values must match the current native help, e.g. 'skills=on' or 'skills=off'."
            }
            $true
        })]
        [string[]]$DynamicRetrieval,

        [int]$MaxAiCredits,

        [switch]$AllowAllMcpServerInstructions,

        [ValidateSet('on', 'off')]
        [string]$BashEnv,

        [switch]$NoBashEnv,

        [switch]$RemoteExport,

        [switch]$NoRemoteExport,

        [switch]$NoEagerPowerShellResolution,

        [string]$ExtensionSdkPath,

        [switch]$Acp,

        [switch]$NoExperimental,

        [Alias('C')]
        [ValidateNotNullOrEmpty()]
        [string]$ChangeDir,

        [switch]$DeferResume,

        [Parameter(ValueFromRemainingArguments)]
        [string[]]$RemainingArgs
    )

    $originalLocation = $null
    if ($PSBoundParameters.ContainsKey('ChangeDir')) {
        $directory = Get-Item -LiteralPath $ChangeDir -Force -ErrorAction Stop
        if ($directory.PSProvider.Name -ne 'FileSystem' -or -not $directory.PSIsContainer) {
            throw "ChangeDir must be an existing filesystem directory: '$ChangeDir'."
        }
        $ChangeDir = $directory.FullName
        $originalLocation = Get-Location
    }

    try {
        if ($null -ne $originalLocation) {
            Set-Location -LiteralPath $ChangeDir -ErrorAction Stop
        }

        if ($McpGitHubAuth) {
            Assert-CopilotMcpGitHubAuth -McpGitHubAuth $McpGitHubAuth -AdditionalMcpConfig $AdditionalMcpConfig
        }

        $copilotExe = (Get-Command copilot -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source

        $copilotArgs = @()
        if (-not $NoExperimental) { $copilotArgs += '--experimental' }
        if (-not $NoAllowAll -and -not $AllowAllTools) { $copilotArgs += '--allow-all' }
        if ($AllowAllTools) { $copilotArgs += '--allow-all-tools' }

        # Block destructive git force operations (--deny-tool takes precedence over --allow-all)
        if (-not $NoDefaultDenyTools) {
            $copilotArgs += @(
                '--deny-tool', 'shell(git push --force)',
                '--deny-tool', 'shell(git push -f)',
                '--deny-tool', 'shell(git push --force-with-lease)',
                '--deny-tool', 'shell(git checkout --force)',
                '--deny-tool', 'shell(git checkout -f)',
                '--deny-tool', 'shell(git clean --force)',
                '--deny-tool', 'shell(git clean -f)',
                '--deny-tool', 'shell(git reset --hard)',
                '--deny-tool', 'shell(git commit --amend)',
                '--deny-tool', 'shell(git commit -a --amend)',
                '--deny-tool', 'shell(git rebase)',
                '--deny-tool', 'shell(git rebase -i)',
                '--deny-tool', 'shell(git rebase --interactive)',
                '--deny-tool', 'shell(git pull)'
            )
        }

        # Disable MCP servers based on autoConnect policy:
        #   false        -> handled natively by the CLI (lazy/dormant)
        #   true/absent  -> always enabled
        #   [path globs] -> enabled only when CWD matches a pattern (custom extension)
        # Manual overrides from -DisableMcpServer and -EnableMcpServer apply after.
        $enableSet = [System.Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase)
        if ($EnableMcpServer) { foreach ($s in $EnableMcpServer) { [void]$enableSet.Add($s) } }

        $mcpConfigPath = Join-Path (Get-CopilotHome) '.copilot' 'mcp-config.json'
        if (Test-Path $mcpConfigPath) {
            $mcpConfig = Get-Content $mcpConfigPath -Raw | ConvertFrom-Json
            $cwd = (Get-Location).Path
            foreach ($server in $mcpConfig.mcpServers.PSObject.Properties) {
                if ($enableSet.Contains($server.Name)) { continue }
                $autoConnect = $server.Value.autoConnect
                # Only handle path-glob arrays -- boolean false is native lazy loading
                if ($autoConnect -is [array]) {
                    if (-not ($autoConnect | Where-Object { $cwd -like $_ })) {
                        $copilotArgs += '--disable-mcp-server', $server.Name
                    }
                }
            }
        }

        if ($DisableMcpServer) {
            foreach ($s in $DisableMcpServer) {
                $copilotArgs += '--disable-mcp-server', $s
            }
        }

        # Re-enable servers disabled in the CLI's own settings for this run only.
        if ($EnableMcpServer) {
            foreach ($s in $EnableMcpServer) {
                $copilotArgs += '--enable-mcp-server', $s
            }
        }

        # Named parameters mapped to CLI flags
        if ($Fleet) { $copilotArgs += '--fleet' }
        if ($Model) { $copilotArgs += '--model', $Model }
        if ($Version) { $copilotArgs += '--prefer-version', $Version; if ($copilotArgs -notcontains '--no-auto-update') { $copilotArgs += '--no-auto-update' } }
        if ($Agent) { $copilotArgs += '--agent', $Agent }
        if ($ReasoningEffort) { $copilotArgs += '--reasoning-effort', $ReasoningEffort }
        if ($AutoTier) { $copilotArgs += '--auto-tier', $AutoTier }
        if ($AddDir) { foreach ($d in $AddDir) { $copilotArgs += '--add-dir', $d } }
        if ($MaxAutopilotContinues) { $copilotArgs += '--max-autopilot-continues', $MaxAutopilotContinues }
        if ($Silent) { $copilotArgs += '--silent' }
        if ($PSBoundParameters.ContainsKey('Share')) {
            if ($Share) { $copilotArgs += '--share', $Share } else { $copilotArgs += '--share' }
        }
        if ($ShareGist) { $copilotArgs += '--share-gist' }
        if ($NoCustomInstructions) { $copilotArgs += '--no-custom-instructions' }
        if ($AdditionalMcpConfig) { foreach ($c in $AdditionalMcpConfig) { $copilotArgs += '--additional-mcp-config', $c } }
        if ($McpGitHubAuth) { foreach ($entry in $McpGitHubAuth) { $copilotArgs += '--mcp-github-auth', $entry } }
        if ($AllowTool) { foreach ($t in $AllowTool) { $copilotArgs += '--allow-tool', $t } }
        if ($DenyTool) { foreach ($t in $DenyTool) { $copilotArgs += '--deny-tool', $t } }
        if ($AllowUrl) { foreach ($u in $AllowUrl) { $copilotArgs += '--allow-url', $u } }
        if ($DenyUrl) { foreach ($u in $DenyUrl) { $copilotArgs += '--deny-url', $u } }
        if ($OutputFormat) { $copilotArgs += '--output-format', $OutputFormat }
        if ($LogLevel) { $copilotArgs += '--log-level', $LogLevel }
        if ($NoAskUser) { $copilotArgs += '--no-ask-user' }
        if ($PluginDir) { foreach ($p in $PluginDir) { $copilotArgs += '--plugin-dir', $p } }
        if ($SecretEnvVars) { $copilotArgs += '--secret-env-vars', ($SecretEnvVars -join ',') }
        if ($ScreenReader) { $copilotArgs += '--screen-reader' }
        if ($AssistedApproval) {
            if ($NoExperimental) {
                Write-Warning '-AssistedApproval requires experimental mode; -NoExperimental will likely prevent the assisted-approval judge from engaging.'
            }
            $copilotArgs += '--assisted-approval'
        }
        if ($UsageOutputFile) { $copilotArgs += '--usage-output-file', $UsageOutputFile }
        if ($PlainDiff) { $copilotArgs += '--plain-diff' }
        if ($Stream) { $copilotArgs += '--stream', $Stream }
        if ($AvailableTool) { foreach ($t in $AvailableTool) { $copilotArgs += '--available-tools', $t } }
        if ($ExcludedTool) { foreach ($t in $ExcludedTool) { $copilotArgs += '--excluded-tools', $t } }
        if ($LogDir) { $copilotArgs += '--log-dir', $LogDir }
        if ($AddGitHubMcpTool) { foreach ($t in $AddGitHubMcpTool) { $copilotArgs += '--add-github-mcp-tool', $t } }
        if ($AddGitHubMcpToolset) { foreach ($t in $AddGitHubMcpToolset) { $copilotArgs += '--add-github-mcp-toolset', $t } }
        if ($EnableAllGitHubMcpTools) { $copilotArgs += '--enable-all-github-mcp-tools' }
        if ($DisableBuiltinMcps) { $copilotArgs += '--disable-builtin-mcps' }
        if ($EnableReasoningSummaries) { $copilotArgs += '--enable-reasoning-summaries' }
        if ($SessionId) { $copilotArgs += '--session-id', $SessionId }
        if ($NoColor) { $copilotArgs += '--no-color' }
        if ($Banner) { $copilotArgs += '--banner' }
        if ($NoAutoUpdate) { $copilotArgs += '--no-auto-update' }
        if ($DisallowTempDir) { $copilotArgs += '--disallow-temp-dir' }
        if ($Context) { $copilotArgs += '--context', $Context }
        if ($AllowAllPaths) { $copilotArgs += '--allow-all-paths' }
        if ($AllowAllUrls) { $copilotArgs += '--allow-all-urls' }
        if ($EnableMemory) { $copilotArgs += '--enable-memory' }
        if ($ChangeDir) { $copilotArgs += '-C', $ChangeDir }
        if ($Attachment) { foreach ($a in $Attachment) { $copilotArgs += '--attachment', $a } }
        if ($Remote) { $copilotArgs += '--remote' }
        if ($NoRemote) { $copilotArgs += '--no-remote' }
        if ($Mouse) { $copilotArgs += '--mouse', $Mouse }
        if ($NoMouse) { $copilotArgs += '--no-mouse' }
        if ($PSBoundParameters.ContainsKey('Connect')) {
            if ($Connect) { $copilotArgs += '--connect', $Connect } else { $copilotArgs += '--connect' }
        }
        if ($MaxAiCredits) { $copilotArgs += '--max-ai-credits', $MaxAiCredits }
        if ($AllowAllMcpServerInstructions) { $copilotArgs += '--allow-all-mcp-server-instructions' }
        if ($BashEnv) { $copilotArgs += '--bash-env', $BashEnv }
        if ($NoBashEnv) { $copilotArgs += '--no-bash-env' }
        if ($RemoteExport) { $copilotArgs += '--remote-export' }
        if ($NoRemoteExport) { $copilotArgs += '--no-remote-export' }
        if ($DynamicRetrieval) { foreach ($entry in $DynamicRetrieval) { $copilotArgs += '--dynamic-retrieval', $entry } }
        if ($NoEagerPowerShellResolution) { $copilotArgs += '--no-eager-powershell-resolution' }
        if ($ExtensionSdkPath) { $copilotArgs += '--extension-sdk-path', $ExtensionSdkPath }
        if ($Acp) { $copilotArgs += '--acp' }

        # -Mode supersedes -Plan (backward compat: -Plan maps to -Mode plan)
        if ($Mode) {
            $copilotArgs += '--mode', $Mode
        } elseif ($Plan) {
            $copilotArgs += '--plan'
        }

        # -Name only applies to new sessions, not resumed ones
        $applyName = $false
        if ($Name) {
            if ($NoResume) {
                $copilotArgs += '--name', $Name
            } else {
                # Defer -- only apply if we don't end up resuming
                $applyName = $true
            }
        }

        $isPassthrough = $Prompt -in @('update', 'help')
        if ($isPassthrough) {
            $passthroughArgs = @($Prompt) + @($RemainingArgs | Where-Object { $_ })
            $Prompt = $null
        }

        if (-not $isPassthrough) {
            if ($Fleet -and -not ($PSBoundParameters.ContainsKey('Prompt') -or $PSBoundParameters.ContainsKey('Interactive'))) {
                throw '-Fleet requires -Prompt or -Interactive when using Start-Copilot/Get-CopilotLaunchPlan.'
            }
            if ($AutoTier -and $PSBoundParameters.ContainsKey('Model') -and $Model -ne 'auto') {
                throw '-AutoTier can only be combined with -Model auto.'
            }
            if ($NoMouse -and $PSBoundParameters.ContainsKey('Mouse')) {
                throw '-NoMouse cannot be combined with -Mouse.'
            }
            if ($NoEagerPowerShellResolution -and -not $IsWindows) {
                throw '-NoEagerPowerShellResolution is only supported on Windows.'
            }
        }

        # Resume-mode flags derived from the active parameter set.
        $isNoResume     = $PSCmdlet.ParameterSetName -like '*NoResume'
        $isResumeLatest = $PSCmdlet.ParameterSetName -like '*ResumeLatest'
        # User-facing switch is -NoAutoResume (back-compat alias -ShowPicker); the internal
        # parameter-set name is kept as *ShowPicker, so this match covers both.
        $isShowPicker   = $PSCmdlet.ParameterSetName -like '*ShowPicker'

        if ($ResumeSession) {
            # Resume a specific session directly (id / id-prefix / name).
            Write-Verbose "Resuming session: $ResumeSession"
            $copilotArgs += '--resume', $ResumeSession
        }
        elseif (-not $isNoResume -and -not $isPassthrough -and -not $DeferResume -and -not $SessionId) {
            $sessions = @(Get-CopilotResumeCandidate)
            if ($sessions.Count -gt 0) {
                # Named sessions are those with a real display name (not the
                # '(no summary)' placeholder, and not blank). When a lone named
                # session is the only real candidate, auto-resume it instead of
                # dropping into the picker.
                $namedSessions = @($sessions | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Summary) -and $_.Summary -ne '(no summary)' })

                # Sessions to list in the picker. Hide unnamed '(no summary)' stubs when
                # named sessions exist, unless -IncludeUnnamed is set. Never empty: with
                # no named sessions, fall back to the full list.
                $pickerSessions = if (-not $IncludeUnnamed -and $namedSessions.Count -gt 0) { $namedSessions } else { $sessions }

                $chosen = $null
                if ($isShowPicker -and $sessions.Count -ge 1) {
                    # -NoAutoResume (alias -ShowPicker) forces the picker whenever any session exists.
                    $chosen = Invoke-CopilotLaunchSessionPicker -Sessions $pickerSessions -SessionSelector $SessionSelector
                }
                elseif ($sessions.Count -eq 1) {
                    $chosen = $sessions[0]
                    Write-Verbose "Resuming session: $($chosen.Summary) (last updated $($chosen.UpdatedAt.LocalDateTime))"
                }
                elseif ($sessions.Count -gt 1 -and $isResumeLatest) {
                    $chosen = $sessions[0]
                    Write-Verbose "Resuming latest session: $($chosen.Summary) (last updated $($chosen.UpdatedAt.LocalDateTime))"
                }
                elseif ($sessions.Count -gt 1 -and $namedSessions.Count -eq 1) {
                    $chosen = $namedSessions[0]
                    Write-Verbose "Resuming the only named session: $($chosen.Summary) (last updated $($chosen.UpdatedAt.LocalDateTime))"
                }
                elseif ($sessions.Count -gt 1) {
                    $chosen = Invoke-CopilotLaunchSessionPicker -Sessions $pickerSessions -SessionSelector $SessionSelector
                }

                if ($chosen) { $copilotArgs += '--resume', $chosen.Id }
            }
        }

        # Apply deferred -Name if we didn't end up resuming a session
        if ($applyName -and $copilotArgs -notcontains '--resume') {
            $copilotArgs += '--name', $Name
        }

        # Compute the final argument vector for both the passthrough (update/help) and
        # normal launch paths, so -PassThru and the launcher share one code path.
        if ($isPassthrough) {
            $finalArgs = $passthroughArgs
        } else {
            if ($Prompt) {
                $copilotArgs += '--autopilot', '-p', $Prompt
            } elseif ($Interactive) {
                $copilotArgs += '--interactive', $Interactive
            }

            if ($RemainingArgs) {
                $copilotArgs += $RemainingArgs
            }

            $finalArgs = $copilotArgs
        }

        # Always return the resolved launch plan; this helper never launches.
        return [pscustomobject]@{
            PSTypeName  = 'CopilotLaunchPlan'
            Exe         = $copilotExe
            Args        = $finalArgs
            Passthrough = [bool]$isPassthrough
        }
    } finally {
        if ($null -ne $originalLocation) {
            Set-Location -LiteralPath $originalLocation.Path -ErrorAction Stop
        }
    }
}
