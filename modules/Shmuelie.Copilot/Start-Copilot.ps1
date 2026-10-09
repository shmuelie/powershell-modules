function Start-Copilot {
    <#
    .SYNOPSIS
        Starts GitHub Copilot CLI with all permissions, optionally in autopilot
        mode, resuming the most recent session for the current folder if one exists.

    .DESCRIPTION
        Wraps the GitHub Copilot CLI executable with automatic session resume
        and sensible defaults (--allow-all --experimental), each of which can be
        turned off with -NoAllowAll / -NoExperimental. Destructive git operations
        (force push, hard reset, rebase, amend, and similar) are denied by
        default; pass -NoDefaultDenyTools to opt out of those deny rules. Typed
        mappings track the current printed CLI surface, while compatibility
        switches such as -Version (--prefer-version) and
        -EnableReasoningSummaries (--enable-reasoning-summaries) remain
        available even though the current native help text omits them.

        When a Prompt is provided, runs in non-interactive autopilot mode (-p --autopilot).
        When no Prompt is provided, starts interactively.

        When the effective directory belongs to a GitHub or Azure DevOps worktree
        with one recognized origin and a checked-out branch, sessions are scoped
        by recorded repository and branch even after a worktree moves. Azure
        DevOps accepts dev.azure.com HTTPS, ssh.dev.azure.com SSH, and legacy
        {organization}.visualstudio.com HTTPS, with optional .git, encoded
        segments, and applicable DefaultCollection prefixes. Incomplete metadata
        falls back to the exact directory when known fields do not conflict; non-Git or
        ambiguous origins use the directory. If exactly one eligible session exists it is
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
        picker. Tab-completes eligible sessions in the effective launch directory,
        including -ChangeDir. Mutually exclusive with
        -NoResume, -ResumeLatest, and -NoAutoResume.

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
        Optional scriptblock replacing the native host picker, forwarded unchanged
        to Get-CopilotLaunchPlan. Receives one object[] of CopilotSession candidates
        (Id, Name, Summary, Branch, UpdatedAt, Cwd). Return one candidate or
        $null/no output to start a new session; errors and invalid/noncandidate
        results terminate without launching. Automatic resume still takes
        precedence; use -NoAutoResume to force selection. -NoResume, -ResumeLatest,
        -ResumeSession, -SessionId, -DeferResume, help/update passthrough, and
        -WhatIf bypass it.
        Zero candidates start a new session without calling the selector.
        Custom selectors need no interactive console and own their UI requirements.
        The default picker uses the active host's PromptForChoice with descriptive
        labels and 22 sessions per page. M selects Next page and P selects Previous
        page when available; N starts a New session from any page. All candidates
        remain reachable, with unique session keys per page and no default choice.
        Names are capped at 80 Unicode text elements including '...'; branches
        appear only for displayed names duplicated anywhere in the candidate set.
        Full details remain in choice help. Names/branches have terminal controls
        sanitized; literal ampersands do not assign keys. Unavailable input, host errors,
        and invalid responses terminate without choosing a session or falling
        back to another UI. Execution
        confirmation remains managed by PowerShell's -Confirm and -WhatIf.

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
        One or more server=origin entries for --mcp-github-auth (Copilot CLI
        1.0.90-3 or later). Only the named server in explicit -AdditionalMcpConfig
        at the approved HTTPS origin (or literal loopback HTTP) receives the
        signed-in GitHub account credential. Never put a token in this argument.
        -PassThru and -WhatIf plan without authenticating. -PassThru retains
        inline -AdditionalMcpConfig verbatim; -WhatIf redacts it in diagnostics.

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
        file-path and URL verification (unlike the default --allow-all, which
        also disables path/URL checks). Implies not passing --allow-all. For
        fully non-interactive use (-Prompt) where the agent may access paths
        outside the working directory or external URLs, also pass -AllowAllPaths
        / -AllowAllUrls so it does not stall on permission prompts.

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
        Resume an existing session or task by UUID, or set the UUID for a new session.

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
        Start-Copilot -PassThru, Get-CopilotLaunchPlan, and -WhatIf only preview
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
        Use this directory for session/branch selection and MCP path policy,
        including -PassThru and -WhatIf. Aliased as -C. Relative paths resolve
        from the caller's location; invalid/non-filesystem directories terminate
        before launch. Planning restores the caller's location before returning,
        confirmation, or execution, including on selection errors.
        Normal launches pass the absolute filesystem path as native -C without
        changing the caller's location. Help/update passthrough arguments remain
        unchanged.

    .PARAMETER PassThru
        Do not launch. Compute the full launch plan — including the resolved
        executable and the complete argument vector (with the session-resume
        decision already applied) — and return it as a CopilotLaunchPlan object
        with Exe, Args, and Passthrough properties. Interactive session selection
        still runs so the returned plan reflects the real decision (pair with
        -DeferResume to skip it). Use this to build on top of Start-Copilot (for
        example, to wrap the launch with a different engine) without duplicating
        the argument or resume logic.

        When -WhatIf is active, Start-Copilot computes this plan with resume
        deferred so previewing the command never opens the interactive session
        picker.

    .PARAMETER DeferResume
        Skip the automatic session-resume decision entirely: no interactive
        picker runs and no --resume argument is added, leaving session selection
        to the caller. Intended for -PassThru overlays that own their own
        multi-session orchestration. An explicit -ResumeSession still takes
        effect; -NoResume and the resume-mode switches are unaffected.

    .PARAMETER RemainingArgs
        Any additional arguments are passed through to the copilot executable.

    .EXAMPLE
        Start-Copilot
        # Starts an interactive Copilot session, auto-resuming if a session exists.

    .EXAMPLE
        Start-Copilot "Add unit tests for the auth module"
        # Runs the prompt in autopilot mode and exits on completion.

    .EXAMPLE
        Start-Copilot -Model claude-opus-4.7 -ReasoningEffort high
        # Starts with a specific model and high reasoning effort.

    .EXAMPLE
        Start-Copilot -ResumeLatest
        # Resumes the most recent session for this folder, even if multiple exist.

    .EXAMPLE
        Start-Copilot -NoResume -WhatIf
        # Renders the full copilot command line without launching a session.

    .EXAMPLE
        $plan = Start-Copilot -PassThru -Model claude-opus-4.7
        # Returns @{ Exe; Args; Passthrough } without launching, so a caller can
        # reuse the built arguments (e.g. to launch a different engine).

    .EXAMPLE
        $plan = Start-Copilot -PassThru -DeferResume
        # Returns the plan with no --resume and no picker, so an overlay can make
        # the session-resume decision itself.

    .EXAMPLE
        Start-Copilot -NoAutoResume -SessionSelector {
            param([object[]]$Sessions)
            $Sessions | Sort-Object UpdatedAt -Descending | Select-Object -First 1
        } -Model gpt-5.4
        # Selects without console input on any supported platform.
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Copilot')]
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

        [switch]$PassThru,

        [switch]$DeferResume,

        [Parameter(ValueFromRemainingArguments)]
        [string[]]$RemainingArgs
    )


    # Delegate all argument building and the session-resume decision to the shared
    # Get-CopilotLaunchPlan core, so this launcher and any overlay that builds on
    # top compute identical command lines from one place. Forward every bound
    # parameter the core accepts (all base parameters plus common ones); -PassThru
    # and -WhatIf/-Confirm stay here because this function owns launching.
    $coreParams = (Get-Command Get-CopilotLaunchPlan).Parameters.Keys
    $planParams = @{}
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Key -ne 'PassThru' -and $coreParams -contains $kv.Key) {
            $planParams[$kv.Key] = $kv.Value
        }
    }

    $originalDeferResume = $planParams.ContainsKey('DeferResume') -and [bool]$planParams['DeferResume']
    $confirmationMayPrompt =
        $ConfirmPreference -ne [System.Management.Automation.ConfirmImpact]::None -and
        [System.Management.Automation.ConfirmImpact]::Medium -ge $ConfirmPreference
    $useNonInteractivePreview = $WhatIfPreference -or (-not $PassThru -and $confirmationMayPrompt)
    $previewPlanDiffers = $useNonInteractivePreview -and -not $originalDeferResume

    $previewPlanParams = $planParams.Clone()
    if ($useNonInteractivePreview) {
        $previewPlanParams['DeferResume'] = $true
    }

    $launchPlan = Get-CopilotLaunchPlan @previewPlanParams

    # -PassThru: return the resolved launch plan without executing.
    if ($PassThru) {
        return $launchPlan
    }

    $displayArgs = @($launchPlan.Args)
    for ($i = 0; $i -lt $displayArgs.Count - 1; $i++) {
        if ($displayArgs[$i] -eq '--additional-mcp-config' -and $displayArgs[$i + 1] -notlike '@*') {
            $displayArgs[$i + 1] = '<redacted inline MCP config>'
            $i++
        }
    }

    $exitCode = $null
    if ($PSCmdlet.ShouldProcess("$($launchPlan.Exe) $($displayArgs -join ' ')", 'Execute')) {
        if ($previewPlanDiffers) {
            $launchPlan = Get-CopilotLaunchPlan @planParams
        }

        & $launchPlan.Exe @($launchPlan.Args)
        $exitCode = $LASTEXITCODE
    }

    # If the engine exited non-zero it may have crashed out of its TUI and left the
    # terminal in a bad state. Reset it via the shared helper (guarded so the built
    # Shmuelie.Copilot doesn't require Shmuelie.Utilities).
    if ($null -ne $exitCode -and $exitCode -ne 0 -and (Get-Command Reset-TerminalModes -ErrorAction SilentlyContinue)) {
        Reset-TerminalModes
    }
}
