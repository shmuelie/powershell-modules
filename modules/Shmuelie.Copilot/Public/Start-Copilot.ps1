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
        default; pass -NoDefaultDenyTools to opt out of those deny rules.

        When a Prompt is provided, runs in non-interactive autopilot mode (-p --autopilot).
        When no Prompt is provided, starts interactively.

        If exactly one previous session exists for the current directory it is
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
        When multiple sessions exist for the current folder, automatically resume
        the most recently updated session instead of showing the interactive picker.

    .PARAMETER ResumeSession
        Resume a specific session directly, by session id, id-prefix, or name
        (passed to the CLI's --resume). Bypasses the auto-resume heuristics and the
        picker. Tab-completes the current folder's sessions. Mutually exclusive with
        -NoResume, -ResumeLatest, and -NoAutoResume.

    .PARAMETER NoAutoResume
        Disable auto-resume and always show the interactive session picker for the
        current folder, even when a session would otherwise be auto-resumed
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
        The AI model to use for the session.

    .PARAMETER Version
        Run a specific Copilot CLI engine version for this session, e.g. '1.0.55'.
        Maps to the engine's --prefer-version flag. When set, --no-auto-update is
        also added so an auto-update can't replace the pinned version mid-session.

    .PARAMETER Agent
        Specify a custom agent to use.

    .PARAMETER ReasoningEffort
        Set the reasoning effort level.

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

    .PARAMETER DisableMcpServer
        One or more MCP server names to disable at startup, in addition to
        any servers disabled by path-based autoConnect policy in the config.

    .PARAMETER EnableMcpServer
        One or more MCP server names to force-enable at startup, overriding
        path-based autoConnect policy in the config.

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
        Change the working directory before doing anything else (maps to -C).
        Aliased as -C.

    .PARAMETER PassThru
        Do not launch. Compute the full launch plan — including the resolved
        executable and the complete argument vector (with the session-resume
        decision already applied) — and return it as a CopilotLaunchPlan object
        with Exe, Args, and Passthrough properties. Interactive session selection
        still runs so the returned plan reflects the real decision (pair with
        -DeferResume to skip it). Use this to build on top of Start-Copilot (for
        example, to wrap the launch with a different engine) without duplicating
        the argument or resume logic.

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
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Copilot')]
    [OutputType('CopilotLaunchPlan')]
    param(
        [Parameter(Position = 0)]
        [string]$Prompt,

        [string]$Interactive,

        [Parameter(ParameterSetName = 'CopilotNoResume', Mandatory)]
        [switch]$NoResume,

        [switch]$NoAllowAll,

        [switch]$NoDefaultDenyTools,

        [Parameter(ParameterSetName = 'CopilotResumeLatest', Mandatory)]
        [switch]$ResumeLatest,

        [Parameter(ParameterSetName = 'CopilotResumeSession', Mandatory)]
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete)
            $sessionStateDir = Join-Path $env:USERPROFILE '.copilot' 'session-state'
            if (-not (Test-Path $sessionStateDir)) { return }
            $cwd = (Get-Location).Path
            Get-ChildItem $sessionStateDir -Directory | ForEach-Object {
                if ($_.Name -notlike "$wordToComplete*") { return }
                $wsFile = Join-Path $_.FullName 'workspace.yaml'
                if (-not (Test-Path $wsFile)) { return }
                $content = Get-Content $wsFile -Raw
                $sessionCwd = if ($content -match '(?m)^cwd:\s*(.+)$') { $Matches[1].Trim() }
                if ($sessionCwd -ne $cwd) { return }
                $summary = if ($content -match '(?m)^summary:\s*(.+)$') { $Matches[1].Trim() }
                $name = if ($content -match '(?m)^name:\s+(.+)$') { $Matches[1].Trim() }
                $display = $name ?? $summary ?? '(no summary)'
                [System.Management.Automation.CompletionResult]::new($_.Name, $_.Name, 'ParameterValue', $display)
            }
        })]
        [string]$ResumeSession,

        [Parameter(ParameterSetName = 'CopilotShowPicker', Mandatory)]
        [Alias('ShowPicker')]
        [switch]$NoAutoResume,

        [Alias('ShowUnnamed')]
        [switch]$IncludeUnnamed,

        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete)
            @(
                'claude-sonnet-4.6', 'claude-sonnet-4.5', 'claude-haiku-4.5',
                'claude-opus-4.7', 'claude-opus-4.7-1m', 'claude-opus-4.6', 'claude-opus-4.5', 'claude-sonnet-4',
                'gpt-5.5', 'gpt-5.4', 'gpt-5.3-codex', 'gpt-5.2-codex', 'gpt-5.2',
                'gpt-5.4-mini', 'gpt-5-mini', 'gpt-4.1'
            ) | Where-Object { $_ -like "$wordToComplete*" }
        })]
        [string]$Model,

        [string]$Version,

        [string]$Agent,

        [ValidateSet('none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max')]
        [string]$ReasoningEffort,

        [string[]]$AddDir,

        [ValidateRange(1, [int]::MaxValue)]
        [int]$MaxAutopilotContinues,

        [switch]$Silent,

        [string]$Share,

        [switch]$ShareGist,

        [switch]$NoCustomInstructions,

        [string[]]$AdditionalMcpConfig,

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

        [int]$MaxAiCredits,

        [switch]$AllowAllMcpServerInstructions,

        [ValidateSet('on', 'off')]
        [string]$BashEnv,

        [switch]$NoBashEnv,

        [switch]$RemoteExport,

        [switch]$NoRemoteExport,

        [string]$ExtensionSdkPath,

        [switch]$Acp,

        [switch]$NoExperimental,

        [Alias('C')]
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
    $launchPlan = Get-CopilotLaunchPlan @planParams

    # -PassThru: return the resolved launch plan without executing.
    if ($PassThru) {
        return $launchPlan
    }

    $exitCode = $null
    if ($PSCmdlet.ShouldProcess("$($launchPlan.Exe) $($launchPlan.Args -join ' ')", 'Execute')) {
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
