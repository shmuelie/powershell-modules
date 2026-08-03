function Get-AgencyPluginName {
    <#
    .SYNOPSIS
        Extract the plugin name from an Agency plugin spec.
    .DESCRIPTION
        Handles 'market:<name>@<url>', 'local:<path>', 'github:owner/repo:path',
        a bare name, or a spec object with a .plugin property. Returns the lowercased
        name, or $null when it can't be determined.
    #>
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)] $Spec)
    process {
        if ($null -eq $Spec) { return }
        $s = if ($Spec -is [string]) { $Spec } elseif ($Spec.PSObject.Properties['plugin']) { $Spec.plugin } else { "$Spec" }
        $s = $s.Trim()
        if ($s -match '^market:([^@]+)@') { return $Matches[1].Trim().ToLowerInvariant() }
        if ($s -match '^local:(.+)$') { return (Split-Path $Matches[1].Trim() -Leaf).ToLowerInvariant() }
        if ($s -match '^github:[^:]+/([^:/]+)') { return $Matches[1].Trim().ToLowerInvariant() }
        return $s.ToLowerInvariant()
    }
}

function Get-RepoLocalPlugin {
    <#
    .SYNOPSIS
        Map the plugin names a repo defines locally to their 'local:<abs path>' specs.
    .DESCRIPTION
        A repo is a plugin-dev source when its root agency.toml declares `local:`
        plugin paths, or it contains plugin manifests (plugins/*/*/plugin.json,
        .github/plugin/plugin.json, or .github/plugin/*/plugin.json for a
        multi-plugin marketplace). Returns a hashtable of lowercased plugin name ->
        'local:<absolute dir>' spec. Empty when the repo defines no local plugins.
    .PARAMETER RepoRoot
        The repository root to inspect.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$RepoRoot)

    $result = @{}

    # Resolve a plugin directory to its manifest name (matches the CLI's manifest
    # search order: plugin.json, .github/plugin/plugin.json, .claude-plugin/plugin.json).
    $readName = {
        param($dir)
        foreach ($rel in @('plugin.json', '.github\plugin\plugin.json', '.claude-plugin\plugin.json')) {
            $mf = Join-Path $dir $rel
            if (Test-Path $mf) {
                try { $n = (Get-Content $mf -Raw | ConvertFrom-Json).name; if ($n) { return $n } } catch { }
            }
        }
        return $null
    }

    # 1) Prefer the root agency.toml `local:` entries (the author's declared dev set).
    $agencyToml = Join-Path $RepoRoot 'agency.toml'
    if (Test-Path $agencyToml) {
        $toml = Get-Content $agencyToml -Raw
        foreach ($m in [regex]::Matches($toml, 'local:([^"'',\s\]]+)')) {
            $rel = $m.Groups[1].Value.Trim()
            $dir = if ([System.IO.Path]::IsPathRooted($rel)) { $rel } else { Join-Path $RepoRoot $rel }
            if (Test-Path $dir) {
                $name = & $readName $dir
                if ($name) { $result[$name.ToLowerInvariant()] = "local:$((Resolve-Path $dir).Path)" }
            }
        }
    }

    # 2) Fallback: discover plugin manifests under the repo.
    if ($result.Count -eq 0) {
        $manifests = @()
        $pluginsDir = Join-Path $RepoRoot 'plugins'
        if (Test-Path $pluginsDir) { $manifests += Get-ChildItem $pluginsDir -Recurse -Filter plugin.json -File -ErrorAction SilentlyContinue }
        $ghPluginDir = Join-Path $RepoRoot '.github\plugin'
        if (Test-Path $ghPluginDir) {
            # legacy single-plugin manifest at .github/plugin/plugin.json
            $legacy = Join-Path $ghPluginDir 'plugin.json'
            if (Test-Path $legacy) { $manifests += Get-Item $legacy }
            # multi-plugin marketplace: .github/plugin/<name>/plugin.json
            foreach ($sub in (Get-ChildItem $ghPluginDir -Directory -ErrorAction SilentlyContinue)) {
                $mf = Join-Path $sub.FullName 'plugin.json'
                if (Test-Path $mf) { $manifests += Get-Item $mf }
            }
        }
        foreach ($mf in $manifests) {
            try { $name = (Get-Content $mf.FullName -Raw | ConvertFrom-Json).name } catch { $name = $null }
            if ($name) { $result[$name.ToLowerInvariant()] = "local:$($mf.Directory.FullName)" }
        }
    }

    return $result
}

function Get-AgencyEffectivePluginSpec {
    <#
    .SYNOPSIS
        Resolve the effective plugins.default specs Agency would load for a directory.
    .DESCRIPTION
        Runs `agency config get plugins.default` (from -WorkingDirectory) and returns
        the plugin spec strings. Used to determine which marketplace plugins are active
        when no profile is selected.
    .PARAMETER WorkingDirectory
        The directory to resolve config from (a plugin-dev repo root).
    #>
    [CmdletBinding()]
    param([string]$WorkingDirectory)
    $exe = Resolve-CliExe -Name agency
    if (-not $exe) { return @() }
    Push-Location $WorkingDirectory -ErrorAction SilentlyContinue
    try {
        $out = & $exe config get plugins.default 2>$null | ForEach-Object { $_.ToString() }
    } finally { Pop-Location -ErrorAction SilentlyContinue }
    $out | ForEach-Object { if ($_ -match 'plugin:\s*(.+?)\s*$') { $Matches[1].Trim() } }
}

function Start-Copilot {
    <#
    .SYNOPSIS
        Starts GitHub Copilot CLI with all permissions, optionally in autopilot
        mode, resuming the most recent session for the current folder if one exists.

    .DESCRIPTION
        Wraps the GitHub Copilot CLI executable with automatic session resume
        and sensible defaults (--allow-all --experimental), each of which can be
        turned off with -NoAllowAll / -NoExperimental.

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
        session without prompting. Auto-generated context_board maintenance
        sessions are ignored when choosing a session to resume.

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
        Maps to the engine's (currently undocumented) --prefer-version flag and is
        forwarded on both the bare-copilot and Agency launch paths. When set,
        --no-auto-update is also added so an auto-update can't replace the pinned
        version mid-session.

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
        Servers with autoConnect: false use native CLI lazy loading.

    .PARAMETER EnableMcpServer
        One or more MCP server names to force-enable at startup, overriding
        path-based autoConnect policy in the config. Under -Agency, this also
        keeps the mcp-config.json version of an overlapping server instead of
        swapping to the Agency built-in.

    .PARAMETER Agency
        Force use of Agency regardless of the git remote URL. Under Agency,
        overlapping MCP servers (EngHub, MicrosoftLearn, MicrosoftFabricRTI,
        AzureDevops, and the Microsoft 365 suite) are swapped for Agency's
        built-in MCPs (--mcp); bare copilot keeps the mcp-config.json servers.

    .PARAMETER DetectAgency
        Auto-detect whether to use Agency based on the git remote URL
        (matches Azure DevOps remotes).

    .PARAMETER AgencyAgent
        (Agency only) Load a named agent. Supports plugin:agent syntax (e.g., my-plugin:my-agent).

    .PARAMETER AgencyProfile
        (Agency only) Activate a named plugin profile (see Get-AgencyProfile).
        Default semantics are profile-only (lean: the profile's
        plugins replace the base set). 'full' loads every installed plugin. When omitted,
        a profile is auto-selected from the current repo/cwd unless -NoAutoProfile is set.

    .PARAMETER MergeProfile
        (Agency only) Activate the profile with --profile (deep-merge over the base
        plugin set) instead of the default --profile-only (replace).

    .PARAMETER NoAutoProfile
        (Agency only) Disable auto-selecting a plugin profile from the current repo/cwd.

    .PARAMETER NoLocalPluginSwap
        (Agency only) Disable the automatic local-plugin swap. By default, when the
        current repo is a plugin-dev source (its root agency.toml declares local:
        plugins, or it has plugins/*/*/plugin.json manifests), any active plugin whose
        name matches a local plugin is loaded from the working tree instead of its
        marketplace copy — so your local edits are used. This switch keeps the plain
        profile/config behavior (marketplace copies).

    .PARAMETER IncludeLocalOnlyPlugins
        (Agency only) When the local-plugin swap runs, also load the repo's local
        plugins that are NOT already in the active plugin set (local-only plugins),
        not just the ones that shadow a marketplace copy.

    .PARAMETER AgencyMcp
        (Agency only) Add built-in Agency MCP servers (e.g., ado, bluebird, icm, watson).
        Can be specified multiple times.

    .PARAMETER NoDefaultMcps
        (Agency only) Skip loading default Agency MCP servers (bluebird, workiq).

    .PARAMETER NoInstalledPlugins
        (Agency only) Skip auto-loading installed plugins from the registry
        (emits Agency's --no-config-plugins; env AGENCY_NO_INSTALLED_PLUGINS).

    .PARAMETER NoInputProcessing
        (Agency only) Skip input-variable processing when loading an agent, keeping
        the agent instructions unchanged.

    .PARAMETER CopilotSessionFile
        (Agency only) Custom name for the Copilot session file (include the .jsonl
        extension). Defaults to '{session_id}.jsonl'.

    .PARAMETER CopilotLogName
        (Agency only) Custom name for the Copilot CLI log file (include the .log
        extension). Advanced; defaults to 'session-{session_id}.log'.

    .PARAMETER GenerateResult
        (Agency only) Generate a result classification after execution. Combine with
        -ResultPath for a custom output path and -ResultType to choose the type.

    .PARAMETER ResultPath
        (Agency only) Custom output path for -GenerateResult (must end in .json;
        relative paths resolve against the session log directory).

    .PARAMETER ResultType
        (Agency only) Result classification type for -GenerateResult: standard or pr.

    .PARAMETER NoOrgConfig
        (Agency only) Skip org-hierarchy config loading for this invocation (bypasses
        the Graph API call, index download, and org config merge).

    .PARAMETER Organization
        (Agency only) ADO organization name (required for -AgencySource organization).

    .PARAMETER Project
        (Agency only) ADO project name (for -AgencySource organization).

    .PARAMETER Repository
        (Agency only) ADO repository name (for -AgencySource organization).

    .PARAMETER Branch
        (Agency only) ADO branch name (optional; defaults to the repo's default branch).

    .PARAMETER AgencyPlugin
        (Agency only) Load specific plugin specs (e.g., local:./path, github:owner/repo, cat:catalog).

    .PARAMETER AgencySource
        (Agency only) Override agent resolution source: personal, repo, organization, company, playground, spec.

    .PARAMETER AgencyInput
        (Agency only) Input variable assignments in VAR=VALUE format for agent templates.

    .PARAMETER NoAgencyConfigCache
        (Agency only) Bypass the on-disk cache for remote config fetches.

    .PARAMETER AgencyVerbosity
        (Agency only) Override the Agency log verbosity level. Default is 'warn'
        to suppress startup noise. Set to 'info' or 'debug' for troubleshooting.

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
        More granular than -NoAllowAll (which enables all permissions).

    .PARAMETER AllowAllUrls
        Allow access to all URLs without confirmation.
        More granular than -NoAllowAll (which enables all permissions).

    .PARAMETER EnableMemory
        Enable the memory tools in prompt (-Prompt) mode. Memory is disabled by
        default in non-interactive mode.

    .PARAMETER NoExperimental
        Do not pass --experimental. By default Start-Copilot opts into
        experimental features; use this switch to run with them off.

    .PARAMETER ChangeDir
        Change the working directory before doing anything else (maps to -C).
        Aliased as -C.

    .PARAMETER RemainingArgs
        Any additional arguments are passed through to the copilot executable.

    .EXAMPLE
        Start-Copilot
        # Starts an interactive Copilot session, auto-resuming if a session exists.

    .EXAMPLE
        Start-Copilot "Add unit tests for the auth module"
        # Runs the prompt in autopilot mode and exits on completion.

    .EXAMPLE
        Start-Copilot -Model claude-opus-4.6 -ReasoningEffort high
        # Starts with a specific model and high reasoning effort.

    .EXAMPLE
        Start-Copilot -Version 1.0.55
        # Pins the Copilot CLI engine to version 1.0.55 for this session (via --prefer-version).

    .EXAMPLE
        Start-Copilot -Interactive "Fix the bug in main.js"
        # Starts interactive mode, runs the prompt, then stays interactive.

    .EXAMPLE
        Start-Copilot -ResumeLatest
        # Resumes the most recent session for this folder, even if multiple exist.

    .EXAMPLE
        Start-Copilot -ResumeSession my-feature
        # Resumes the session named (or id-prefixed) 'my-feature' directly, skipping the picker.

    .EXAMPLE
        Start-Copilot -NoAutoResume
        # Disables auto-resume and always shows the session picker for this folder,
        # even if only one session exists. (-ShowPicker is a back-compat alias.)

    .EXAMPLE
        Start-Copilot -NoAutoResume -IncludeUnnamed
        # Shows the picker listing every session, including unnamed '(no summary)' stubs.

    .EXAMPLE
        Start-Copilot -NoResume
        # Starts a fresh interactive session, ignoring any previous sessions.

    .EXAMPLE
        Start-Copilot -NoResume "Refactor the database layer"
        # Runs the prompt in autopilot mode without resuming a prior session.

    .EXAMPLE
        Start-Copilot -DisableMcpServer EngHub
        # Starts with EngHub disabled in addition to autoConnect: false servers.

    .EXAMPLE
        Start-Copilot -EnableMcpServer Playwright, NuGet
        # Starts with Playwright and NuGet enabled despite autoConnect: false.

    .EXAMPLE
        Start-Copilot -Silent -Prompt "Explain this repo" -Share
        # Runs silently and exports the session to markdown.

    .EXAMPLE
        Start-Copilot -AddDir ~/other-project -AllowTool 'shell(git:*)'
        # Grants access to another directory and allows all git commands.

    .EXAMPLE
        Start-Copilot update
        # Passes "update" directly to the copilot executable (copilot update).

    .EXAMPLE
        Start-Copilot help
        # Passes "help" directly to the copilot executable (copilot help).

    .EXAMPLE
        Start-Copilot help update
        # Passes "help update" directly to the copilot executable.

    .EXAMPLE
        Start-Copilot -NoResume -Name "Auth refactor"
        # Starts a fresh named session.

    .EXAMPLE
        Start-Copilot -Plan
        # Starts in plan mode (backward compat — equivalent to -Mode plan).

    .EXAMPLE
        Start-Copilot -Mode autopilot
        # Starts in autopilot mode.

    .EXAMPLE
        Start-Copilot -Connect
        # Connects to a remote session (shows session picker).

    .EXAMPLE
        Start-Copilot -PlainDiff
        # Starts with rich diff rendering disabled.

    .EXAMPLE
        Start-Copilot -Remote
        # Starts with remote control enabled from GitHub web and mobile.

    .EXAMPLE
        Start-Copilot -Prompt "Add tests" -Attachment screenshot.png
        # Runs a non-interactive prompt with an attached image.

    .EXAMPLE
        Start-Copilot -Prompt "Refactor the parser" -EnableMemory
        # Runs a non-interactive prompt with memory tools enabled.

    .EXAMPLE
        Start-Copilot -NoExperimental
        # Starts without opting into experimental features.

    .EXAMPLE
        Start-Copilot -MaxAiCredits 50 -BashEnv off
        # Caps AI credit usage and disables BASH_ENV support for this session.

    .EXAMPLE
        Start-Copilot -Agency -GenerateResult -ResultType pr
        # Runs under Agency and produces a PR-style result classification afterward.
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Copilot')]
    param(
        [Parameter(Position = 0)]
        [string]$Prompt,

        [string]$Interactive,

        [Parameter(ParameterSetName = 'CopilotNoResume', Mandatory)]
        [Parameter(ParameterSetName = 'AgencyNoResume', Mandatory)]
        [switch]$NoResume,

        [switch]$NoAllowAll,

        [Parameter(ParameterSetName = 'CopilotResumeLatest', Mandatory)]
        [Parameter(ParameterSetName = 'AgencyResumeLatest', Mandatory)]
        [switch]$ResumeLatest,

        [Parameter(ParameterSetName = 'CopilotResumeSession', Mandatory)]
        [Parameter(ParameterSetName = 'AgencyResumeSession', Mandatory)]
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
        [Parameter(ParameterSetName = 'AgencyShowPicker', Mandatory)]
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

        [Parameter(ParameterSetName = 'Agency', Mandatory)]
        [Parameter(ParameterSetName = 'AgencyNoResume', Mandatory)]
        [Parameter(ParameterSetName = 'AgencyResumeLatest', Mandatory)]
        [Parameter(ParameterSetName = 'AgencyResumeSession', Mandatory)]
        [Parameter(ParameterSetName = 'AgencyShowPicker', Mandatory)]
        [switch]$Agency,

        [switch]$DetectAgency,

        # --- Agency-specific parameters (only valid with -Agency) ---

        [Parameter(ParameterSetName = 'Agency')]
        [Parameter(ParameterSetName = 'AgencyNoResume')]
        [Parameter(ParameterSetName = 'AgencyResumeLatest')]
        [Parameter(ParameterSetName = 'AgencyResumeSession')]
        [Parameter(ParameterSetName = 'AgencyShowPicker')]
        [string]$AgencyAgent,

        [Parameter(ParameterSetName = 'Agency')]
        [Parameter(ParameterSetName = 'AgencyNoResume')]
        [Parameter(ParameterSetName = 'AgencyResumeLatest')]
        [Parameter(ParameterSetName = 'AgencyResumeSession')]
        [Parameter(ParameterSetName = 'AgencyShowPicker')]
        [string]$AgencyProfile,

        [Parameter(ParameterSetName = 'Agency')]
        [Parameter(ParameterSetName = 'AgencyNoResume')]
        [Parameter(ParameterSetName = 'AgencyResumeLatest')]
        [Parameter(ParameterSetName = 'AgencyResumeSession')]
        [Parameter(ParameterSetName = 'AgencyShowPicker')]
        [switch]$MergeProfile,

        [Parameter(ParameterSetName = 'Agency')]
        [Parameter(ParameterSetName = 'AgencyNoResume')]
        [Parameter(ParameterSetName = 'AgencyResumeLatest')]
        [Parameter(ParameterSetName = 'AgencyResumeSession')]
        [Parameter(ParameterSetName = 'AgencyShowPicker')]
        [switch]$NoAutoProfile,

        [Parameter(ParameterSetName = 'Agency')]
        [Parameter(ParameterSetName = 'AgencyNoResume')]
        [Parameter(ParameterSetName = 'AgencyResumeLatest')]
        [Parameter(ParameterSetName = 'AgencyResumeSession')]
        [Parameter(ParameterSetName = 'AgencyShowPicker')]
        [switch]$NoLocalPluginSwap,

        [Parameter(ParameterSetName = 'Agency')]
        [Parameter(ParameterSetName = 'AgencyNoResume')]
        [Parameter(ParameterSetName = 'AgencyResumeLatest')]
        [Parameter(ParameterSetName = 'AgencyResumeSession')]
        [Parameter(ParameterSetName = 'AgencyShowPicker')]
        [switch]$IncludeLocalOnlyPlugins,

        [Parameter(ParameterSetName = 'Agency')]
        [Parameter(ParameterSetName = 'AgencyNoResume')]
        [Parameter(ParameterSetName = 'AgencyResumeLatest')]
        [Parameter(ParameterSetName = 'AgencyResumeSession')]
        [Parameter(ParameterSetName = 'AgencyShowPicker')]
        [string[]]$AgencyMcp,

        [Parameter(ParameterSetName = 'Agency')]
        [Parameter(ParameterSetName = 'AgencyNoResume')]
        [Parameter(ParameterSetName = 'AgencyResumeLatest')]
        [Parameter(ParameterSetName = 'AgencyResumeSession')]
        [Parameter(ParameterSetName = 'AgencyShowPicker')]
        [switch]$NoDefaultMcps,

        [Parameter(ParameterSetName = 'Agency')]
        [Parameter(ParameterSetName = 'AgencyNoResume')]
        [Parameter(ParameterSetName = 'AgencyResumeLatest')]
        [Parameter(ParameterSetName = 'AgencyResumeSession')]
        [Parameter(ParameterSetName = 'AgencyShowPicker')]
        [switch]$NoInstalledPlugins,

        [Parameter(ParameterSetName = 'Agency')]
        [Parameter(ParameterSetName = 'AgencyNoResume')]
        [Parameter(ParameterSetName = 'AgencyResumeLatest')]
        [Parameter(ParameterSetName = 'AgencyResumeSession')]
        [Parameter(ParameterSetName = 'AgencyShowPicker')]
        [string[]]$AgencyPlugin,

        [Parameter(ParameterSetName = 'Agency')]
        [Parameter(ParameterSetName = 'AgencyNoResume')]
        [Parameter(ParameterSetName = 'AgencyResumeLatest')]
        [Parameter(ParameterSetName = 'AgencyResumeSession')]
        [Parameter(ParameterSetName = 'AgencyShowPicker')]
        [ValidateSet('personal', 'repo', 'organization', 'company', 'playground', 'spec')]
        [string]$AgencySource,

        [Parameter(ParameterSetName = 'Agency')]
        [Parameter(ParameterSetName = 'AgencyNoResume')]
        [Parameter(ParameterSetName = 'AgencyResumeLatest')]
        [Parameter(ParameterSetName = 'AgencyResumeSession')]
        [Parameter(ParameterSetName = 'AgencyShowPicker')]
        [string[]]$AgencyInput,

        [Parameter(ParameterSetName = 'Agency')]
        [Parameter(ParameterSetName = 'AgencyNoResume')]
        [Parameter(ParameterSetName = 'AgencyResumeLatest')]
        [Parameter(ParameterSetName = 'AgencyResumeSession')]
        [Parameter(ParameterSetName = 'AgencyShowPicker')]
        [switch]$NoInputProcessing,

        [Parameter(ParameterSetName = 'Agency')]
        [Parameter(ParameterSetName = 'AgencyNoResume')]
        [Parameter(ParameterSetName = 'AgencyResumeLatest')]
        [Parameter(ParameterSetName = 'AgencyResumeSession')]
        [Parameter(ParameterSetName = 'AgencyShowPicker')]
        [string]$CopilotSessionFile,

        [Parameter(ParameterSetName = 'Agency')]
        [Parameter(ParameterSetName = 'AgencyNoResume')]
        [Parameter(ParameterSetName = 'AgencyResumeLatest')]
        [Parameter(ParameterSetName = 'AgencyResumeSession')]
        [Parameter(ParameterSetName = 'AgencyShowPicker')]
        [string]$CopilotLogName,

        [Parameter(ParameterSetName = 'Agency')]
        [Parameter(ParameterSetName = 'AgencyNoResume')]
        [Parameter(ParameterSetName = 'AgencyResumeLatest')]
        [Parameter(ParameterSetName = 'AgencyResumeSession')]
        [Parameter(ParameterSetName = 'AgencyShowPicker')]
        [switch]$GenerateResult,

        [Parameter(ParameterSetName = 'Agency')]
        [Parameter(ParameterSetName = 'AgencyNoResume')]
        [Parameter(ParameterSetName = 'AgencyResumeLatest')]
        [Parameter(ParameterSetName = 'AgencyResumeSession')]
        [Parameter(ParameterSetName = 'AgencyShowPicker')]
        [string]$ResultPath,

        [Parameter(ParameterSetName = 'Agency')]
        [Parameter(ParameterSetName = 'AgencyNoResume')]
        [Parameter(ParameterSetName = 'AgencyResumeLatest')]
        [Parameter(ParameterSetName = 'AgencyResumeSession')]
        [Parameter(ParameterSetName = 'AgencyShowPicker')]
        [ValidateSet('standard', 'pr')]
        [string]$ResultType,

        [Parameter(ParameterSetName = 'Agency')]
        [Parameter(ParameterSetName = 'AgencyNoResume')]
        [Parameter(ParameterSetName = 'AgencyResumeLatest')]
        [Parameter(ParameterSetName = 'AgencyResumeSession')]
        [Parameter(ParameterSetName = 'AgencyShowPicker')]
        [switch]$NoOrgConfig,

        [Parameter(ParameterSetName = 'Agency')]
        [Parameter(ParameterSetName = 'AgencyNoResume')]
        [Parameter(ParameterSetName = 'AgencyResumeLatest')]
        [Parameter(ParameterSetName = 'AgencyResumeSession')]
        [Parameter(ParameterSetName = 'AgencyShowPicker')]
        [string]$Organization,

        [Parameter(ParameterSetName = 'Agency')]
        [Parameter(ParameterSetName = 'AgencyNoResume')]
        [Parameter(ParameterSetName = 'AgencyResumeLatest')]
        [Parameter(ParameterSetName = 'AgencyResumeSession')]
        [Parameter(ParameterSetName = 'AgencyShowPicker')]
        [string]$Project,

        [Parameter(ParameterSetName = 'Agency')]
        [Parameter(ParameterSetName = 'AgencyNoResume')]
        [Parameter(ParameterSetName = 'AgencyResumeLatest')]
        [Parameter(ParameterSetName = 'AgencyResumeSession')]
        [Parameter(ParameterSetName = 'AgencyShowPicker')]
        [string]$Repository,

        [Parameter(ParameterSetName = 'Agency')]
        [Parameter(ParameterSetName = 'AgencyNoResume')]
        [Parameter(ParameterSetName = 'AgencyResumeLatest')]
        [Parameter(ParameterSetName = 'AgencyResumeSession')]
        [Parameter(ParameterSetName = 'AgencyShowPicker')]
        [string]$Branch,

        [Parameter(ParameterSetName = 'Agency')]
        [Parameter(ParameterSetName = 'AgencyNoResume')]
        [Parameter(ParameterSetName = 'AgencyResumeLatest')]
        [Parameter(ParameterSetName = 'AgencyResumeSession')]
        [Parameter(ParameterSetName = 'AgencyShowPicker')]
        [switch]$NoAgencyConfigCache,

        [Parameter(ParameterSetName = 'Agency')]
        [Parameter(ParameterSetName = 'AgencyNoResume')]
        [Parameter(ParameterSetName = 'AgencyResumeLatest')]
        [Parameter(ParameterSetName = 'AgencyResumeSession')]
        [Parameter(ParameterSetName = 'AgencyShowPicker')]
        [ValidateSet('off', 'trace', 'debug', 'info', 'warn', 'error')]
        [string]$AgencyVerbosity,

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

        [Parameter(ValueFromRemainingArguments)]
        [string[]]$RemainingArgs
    )

    # Use plain copilot by default.
    # -Agency forces agency on; -DetectAgency auto-detects from git remote URL.
    $useAgency = $false
    if ($Agency) {
        $agencyExe = (Get-Command agency -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        $useAgency = $true
    } elseif ($DetectAgency) {
        $remoteUrl = git remote get-url origin 2>$null
        if ($remoteUrl -and ($remoteUrl -match 'dev\.azure\.com|ssh\.dev\.azure\.com|visualstudio\.com')) {
            $agencyExe = (Get-Command agency -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
            if ($agencyExe) { $useAgency = $true }
        }
    }
    if (-not $useAgency) {
        $copilotExe = (Get-Command copilot -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    }

    # Build Agency-specific args (root-level and copilot-level)
    $agencyVerbosityLevel = if ($AgencyVerbosity) { $AgencyVerbosity } else { 'warn' }
    $agencyRootArgs = @('--verbosity', $agencyVerbosityLevel)
    $agencyCopilotArgs = @()
    if ($useAgency) {
        if ($NoAgencyConfigCache) { $agencyRootArgs += '--no-config-cache' }
        if ($AgencyAgent) { $agencyCopilotArgs += '--agent', $AgencyAgent }
        # Plugin profile selection: explicit -AgencyProfile wins; otherwise
        # auto-select from the current repo/cwd (unless -NoAutoProfile or an
        # explicit plugin override is given). Default semantics are profile-only
        # (lean: the profile's plugins replace the base set); -MergeProfile uses
        # --profile (the profile adds on top of the base set). The virtual 'full'
        # profile maps to no flag (= the base plugins.default, i.e. every plugin).
        $activeProfile = $null
        if ($AgencyProfile) {
            $activeProfile = $AgencyProfile
        } elseif (-not $NoAutoProfile -and -not $NoInstalledPlugins -and -not $AgencyPlugin) {
            $activeProfile = $env:SHMUELIE_AGENCY_PROFILE
            if ($activeProfile) { Write-Verbose "Selected agency profile '$activeProfile' from SHMUELIE_AGENCY_PROFILE." }
        }
        # Local-plugin swap: in a plugin-dev repo, prefer working-tree plugins over
        # their marketplace copies so local edits are used. For each active-set plugin
        # whose name matches a plugin the repo defines locally, drop the marketplace
        # copy and load local:<path> instead. Agency has no per-plugin exclude, so this
        # reconstructs the plugin set (--no-config-plugins + explicit --plugin), which
        # replaces the --profile-only/--profile flag for this launch.
        $localSwapApplied = $false
        if (-not $NoLocalPluginSwap -and -not $NoInstalledPlugins -and -not $AgencyPlugin) {
            $swapRepoRoot = (git rev-parse --show-toplevel 2>$null)
            if ($swapRepoRoot) {
                $localPlugins = Get-RepoLocalPlugin -RepoRoot $swapRepoRoot
                if ($localPlugins.Count -gt 0) {
                    $activeSpecs = if ($activeProfile -and $activeProfile -ne 'full') {
                        @((Get-AgencyProfile $activeProfile -ErrorAction SilentlyContinue).Plugins)
                    } else {
                        @(Get-AgencyEffectivePluginSpec -WorkingDirectory $swapRepoRoot)
                    }
                    # Agency stages local: plugins by their folder LEAF name, so two
                    # working-tree plugins with the same leaf (e.g. plugins/os/dev and
                    # plugins/shared/dev, both leaf 'dev') can't both be swapped. Used to
                    # de-collide the reconstructed set below. (Only guards local:-vs-local:
                    # collisions — a local: leaf clashing with a *kept* marketplace plugin's
                    # own staging folder is out of scope; Agency's market folder names aren't
                    # reliably predictable from the spec.)
                    $leafOf = { param($localSpec) (Split-Path ($localSpec -replace '^local:') -Leaf).ToLowerInvariant() }

                    $swapNames = [System.Collections.Generic.List[string]]::new()
                    $keptSpecs = [System.Collections.Generic.List[string]]::new()
                    $swapOriginal = @{}
                    foreach ($spec in $activeSpecs) {
                        if (-not $spec) { continue }
                        $nm = Get-AgencyPluginName $spec
                        if ($nm -and $localPlugins.ContainsKey($nm)) {
                            if ($swapNames -notcontains $nm) { $swapNames.Add($nm); $swapOriginal[$nm] = $spec }
                        }
                        else { $keptSpecs.Add($spec) }
                    }

                    # De-collide swap targets by folder leaf name. For any leaf shared by
                    # >=2 plugins, keep the marketplace/config copy for all of them (revert
                    # out of the swap) — Agency stages market plugins by full name, so their
                    # staging folders stay distinct. Non-colliding plugins still swap to the
                    # working-tree copy. Lossless: every plugin still loads.
                    $swapLeaf = @{}
                    foreach ($nm in $swapNames) { $swapLeaf[$nm] = & $leafOf $localPlugins[$nm] }
                    $revertedColliders = [System.Collections.Generic.List[string]]::new()
                    foreach ($g in ($swapNames | Group-Object { $swapLeaf[$_] })) {
                        if ($g.Count -gt 1) {
                            foreach ($nm in $g.Group) {
                                $keptSpecs.Add($swapOriginal[$nm])
                                $revertedColliders.Add($nm)
                            }
                        }
                    }
                    foreach ($nm in $revertedColliders) { [void]$swapNames.Remove($nm) }

                    if ($swapNames.Count -gt 0) {
                        $localSwapApplied = $true
                        $agencyCopilotArgs += '--no-config-plugins'
                        foreach ($spec in $keptSpecs) { $agencyCopilotArgs += '--plugin', $spec }
                        $usedLeaves = [System.Collections.Generic.HashSet[string]]::new()
                        foreach ($nm in $swapNames) {
                            $agencyCopilotArgs += '--plugin', $localPlugins[$nm]
                            [void]$usedLeaves.Add((& $leafOf $localPlugins[$nm]))
                        }
                        if ($IncludeLocalOnlyPlugins) {
                            # Add repo-local plugins not already in the active set, keeping
                            # folder-leaf uniqueness (local-only plugins have no marketplace
                            # fallback, so first-wins; skip and warn on a leaf clash).
                            $skippedLocalOnly = [System.Collections.Generic.List[string]]::new()
                            foreach ($nm in $localPlugins.Keys) {
                                if (($swapNames -contains $nm) -or ($revertedColliders -contains $nm)) { continue }
                                if ($usedLeaves.Add((& $leafOf $localPlugins[$nm]))) {
                                    $agencyCopilotArgs += '--plugin', $localPlugins[$nm]
                                } else {
                                    $skippedLocalOnly.Add($nm)
                                }
                            }
                            if ($skippedLocalOnly.Count -gt 0) {
                                Write-Warning "Local-plugin swap: skipped local-only plugin(s) with a duplicate folder leaf name: [$(($skippedLocalOnly | Sort-Object) -join ', ')] (Agency stages local plugins by folder leaf name)."
                            }
                        }
                        if ($revertedColliders.Count -gt 0) {
                            Write-Warning "Local-plugin swap: kept marketplace copies for folder-name-colliding plugin(s) [$(($revertedColliders | Sort-Object) -join ', ')] (Agency stages local plugins by folder leaf name); working-tree edits for these won't be used."
                        }
                        Write-Verbose "Local-plugin swap: using working-tree copies for [$($swapNames -join ', ')] from $swapRepoRoot (marketplace copies excluded)"
                    }
                }
            }
        }
        if (-not $localSwapApplied -and $activeProfile -and $activeProfile -ne 'full') {
            $profileFlag = if ($MergeProfile) { '--profile' } else { '--profile-only' }
            $agencyCopilotArgs += $profileFlag, $activeProfile
        }
        if ($AgencyMcp) { foreach ($m in $AgencyMcp) { $agencyCopilotArgs += '--mcp', $m } }
        if ($NoDefaultMcps) { $agencyCopilotArgs += '--no-default-mcps' }
        if ($NoInstalledPlugins) { $agencyCopilotArgs += '--no-config-plugins' }
        if ($AgencyPlugin) { foreach ($p in $AgencyPlugin) { $agencyCopilotArgs += '--plugin', $p } }
        if ($AgencySource) { $agencyCopilotArgs += '--source', $AgencySource }
        if ($AgencyInput) { foreach ($i in $AgencyInput) { $agencyCopilotArgs += '--input', $i } }
        if ($NoInputProcessing) { $agencyCopilotArgs += '--no-input-processing' }
        if ($CopilotSessionFile) { $agencyCopilotArgs += '--copilot-session-file', $CopilotSessionFile }
        if ($CopilotLogName) { $agencyCopilotArgs += '--copilot-log-name', $CopilotLogName }
        if ($GenerateResult) {
            if ($ResultPath) { $agencyCopilotArgs += '--generate-result', $ResultPath } else { $agencyCopilotArgs += '--generate-result' }
        }
        if ($ResultType) { $agencyCopilotArgs += '--result-type', $ResultType }
        if ($NoOrgConfig) { $agencyCopilotArgs += '--no-org-config' }
        if ($Organization) { $agencyCopilotArgs += '--organization', $Organization }
        if ($Project) { $agencyCopilotArgs += '--project', $Project }
        if ($Repository) { $agencyCopilotArgs += '--repository', $Repository }
        if ($Branch) { $agencyCopilotArgs += '--branch', $Branch }
    }

    $copilotArgs = @()
    if (-not $NoExperimental) { $copilotArgs += '--experimental' }
    if (-not $NoAllowAll) { $copilotArgs += '--allow-all' }

    # Block destructive git force operations (--deny-tool takes precedence over --allow-all)
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

    # Disable MCP servers based on autoConnect policy:
    #   false        → handled natively by the CLI (lazy/dormant)
    #   true/absent  → always enabled
    #   [path globs] → enabled only when CWD matches a pattern (custom extension)
    # Manual overrides from -DisableMcpServer and -EnableMcpServer apply after.
    $enableSet = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    if ($EnableMcpServer) { foreach ($s in $EnableMcpServer) { [void]$enableSet.Add($s) } }

    $mcpConfigPath = Join-Path $env:USERPROFILE '.copilot' 'mcp-config.json'
    $configServerNames = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    if (Test-Path $mcpConfigPath) {
        $mcpConfig = Get-Content $mcpConfigPath -Raw | ConvertFrom-Json
        $cwd = (Get-Location).Path
        foreach ($server in $mcpConfig.mcpServers.PSObject.Properties) {
            [void]$configServerNames.Add($server.Name)
            if ($enableSet.Contains($server.Name)) { continue }
            $autoConnect = $server.Value.autoConnect
            # Only handle path-glob arrays — boolean false is native lazy loading
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

    # Under Agency, prefer Agency's built-in MCP servers over the equivalent ones
    # from mcp-config.json: disable the JSON version (engine passthrough) and add
    # the Agency built-in via --mcp. Bare copilot sessions are unaffected.
    # The map is a union over the work and consumer MCP configs; the --mcp add is
    # unconditional (always use Agency's version), while --disable-mcp-server is
    # only emitted for servers actually present in the active mcp-config.json so we
    # don't pass disable flags for names the config doesn't contain.
    $agencyMcpEquivalents = [ordered]@{
        EngHub                  = 'enghub'
        MicrosoftLearn          = 'msft-learn'
        MicrosoftFabricRTI      = 'kusto'
        AzureDevops             = 'ado'
        Microsoft365Calendar    = 'calendar'
        Microsoft365Mail        = 'mail'
        Microsoft365CopilotChat = 'm365-copilot'
        Microsoft365User        = 'm365-user'
        MicrosoftTeams          = 'teams'
        MicrosoftWord           = 'word'
        OneDriveAndSharePoint   = 'onedrive'
        SharePointLists         = 'sharepoint'
    }
    if ($useAgency) {
        foreach ($jsonName in $agencyMcpEquivalents.Keys) {
            if ($enableSet.Contains($jsonName)) { continue }   # respect -EnableMcpServer override
            if ($configServerNames.Contains($jsonName)) {
                $copilotArgs += '--disable-mcp-server', $jsonName
            }
            $agencyCopilotArgs += '--mcp', $agencyMcpEquivalents[$jsonName]
        }
    }

    # Named parameters mapped to CLI flags
    if ($Model) { $copilotArgs += '--model', $Model }
    if ($Version) { $copilotArgs += '--prefer-version', $Version; if ($copilotArgs -notcontains '--no-auto-update') { $copilotArgs += '--no-auto-update' } }
    if ($Agent) { $copilotArgs += '--agent', $Agent }
    if ($ReasoningEffort) { $copilotArgs += '--reasoning-effort', $ReasoningEffort }
    if ($AddDir) { foreach ($d in $AddDir) { $copilotArgs += '--add-dir', $d } }
    if ($MaxAutopilotContinues) { $copilotArgs += '--max-autopilot-continues', $MaxAutopilotContinues }
    if ($Silent) { $copilotArgs += '--silent' }
    if ($PSBoundParameters.ContainsKey('Share')) {
        if ($Share) { $copilotArgs += '--share', $Share } else { $copilotArgs += '--share' }
    }
    if ($ShareGist) { $copilotArgs += '--share-gist' }
    if ($NoCustomInstructions) { $copilotArgs += '--no-custom-instructions' }
    if ($AdditionalMcpConfig) { foreach ($c in $AdditionalMcpConfig) { $copilotArgs += '--additional-mcp-config', $c } }
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
    if ($PSBoundParameters.ContainsKey('Remote')) { $copilotArgs += '--remote' }
    if ($NoRemote) { $copilotArgs += '--no-remote' }
    if ($Mouse) { $copilotArgs += '--mouse', $Mouse }
    if ($PSBoundParameters.ContainsKey('Connect')) {
        if ($Connect) { $copilotArgs += '--connect', $Connect } else { $copilotArgs += '--connect' }
    }
    if ($MaxAiCredits) { $copilotArgs += '--max-ai-credits', $MaxAiCredits }
    if ($AllowAllMcpServerInstructions) { $copilotArgs += '--allow-all-mcp-server-instructions' }
    if ($BashEnv) { $copilotArgs += '--bash-env', $BashEnv }
    if ($NoBashEnv) { $copilotArgs += '--no-bash-env' }
    if ($RemoteExport) { $copilotArgs += '--remote-export' }
    if ($NoRemoteExport) { $copilotArgs += '--no-remote-export' }
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
            # Defer — only apply if we don't end up resuming
            $applyName = $true
        }
    }

    $isPassthrough = $Prompt -in @('update', 'help')
    if ($isPassthrough) {
        $passthroughArgs = @($Prompt) + @($RemainingArgs | Where-Object { $_ })
        $Prompt = $null
    }

    # Resume-mode flags derived from the active parameter set (engine×resume matrix).
    $isNoResume     = $PSCmdlet.ParameterSetName -like '*NoResume'
    $isResumeLatest = $PSCmdlet.ParameterSetName -like '*ResumeLatest'
    # User-facing switch is -NoAutoResume (back-compat alias -ShowPicker); the internal
    # parameter-set names are kept as *ShowPicker, so this match covers both.
    $isShowPicker   = $PSCmdlet.ParameterSetName -like '*ShowPicker'

    # Renders the interactive session picker and returns the chosen session object
    # (or $null if the user chose a new session).
    function Invoke-SessionPicker {
        param([object[]]$Sessions)
        Write-Host "Multiple sessions found for this folder:" -ForegroundColor Yellow
        Write-Host ""
        for ($i = 0; $i -lt $Sessions.Count; $i++) {
            $s = $Sessions[$i]
            $branchSuffix = if ($s.Branch) { " ($($s.Branch))" } else { '' }
            $label = "  [$($i + 1)] $($s.Summary)$branchSuffix"
            $time  = "      $($s.UpdatedAt.LocalDateTime)"
            if ($i -eq 0) {
                Write-Host $label -ForegroundColor Cyan
                Write-Host $time -ForegroundColor DarkGray
            } else {
                Write-Host $label
                Write-Host $time -ForegroundColor DarkGray
            }
        }
        Write-Host "  [N] New session" -ForegroundColor Green
        Write-Host ""
        do {
            Write-Host "Select session [1-$($Sessions.Count)/N]: " -NoNewline -ForegroundColor Yellow
            $choice = Read-Host
            if ($choice -eq 'N' -or $choice -eq 'n') { return $null }
            $num = $choice -as [int]
        } while ($null -eq $num -or $num -lt 1 -or $num -gt $Sessions.Count)
        $picked = $Sessions[$num - 1]
        Write-Host "Resuming session: $($picked.Summary)" -ForegroundColor Cyan
        return $picked
    }

    if ($ResumeSession) {
        # Resume a specific session directly (id / id-prefix / name).
        Write-Verbose "Resuming session: $ResumeSession"
        $copilotArgs += '--resume', $ResumeSession
    }
    elseif (-not $isNoResume -and -not $isPassthrough) {
        $sessionStateDir = Join-Path $env:USERPROFILE '.copilot' 'session-state'
        # Auto-generated maintenance sessions to skip when auto-resuming
        $ignoredSessionNames = @(
            'Apply context_board add/prune updates for this session. End the turn with a 2-3 sentence summary of the changes you made to the context_board.'
            'Analyze the session file and write the session insights result to the specified output file as described in the instructions.'
            # Session-summary worker: its block-scalar name's first line (all the parser captures)
            'Session File Path:'
        )
        if (Test-Path $sessionStateDir) {
            $cwd = (Get-Location).Path
            $currentBranch = try { git symbolic-ref --short HEAD 2>$null } catch { $null }

            $sessions = @(Get-ChildItem $sessionStateDir -Directory |
                ForEach-Object {
                    $wsFile = Join-Path $_.FullName 'workspace.yaml'
                    if (Test-Path $wsFile) {
                        $content = Get-Content $wsFile -Raw
                        $sessionCwd = if ($content -match '(?m)^cwd:\s*(.+)$') { $Matches[1].Trim() }
                        $updatedAt = if ($content -match '(?m)^updated_at:\s*(.+)$') { $Matches[1].Trim() }
                        $summary = if ($content -match '(?m)^summary:\s*(.+)$') { $Matches[1].Trim() }
                        $sessionBranch = if ($content -match '(?m)^branch:\s*(.+)$') { $Matches[1].Trim() }
                        $sessionName = if ($content -match '(?m)^name:\s*[\|>]-?\s*$') {
                            if ($content -match '(?m)^name:\s*[\|>]-?\s*\r?\n(\s{2,}.+)') { $Matches[1].Trim() }
                        } elseif ($content -match '(?m)^name:\s+(.+)$') {
                            $Matches[1].Trim()
                        }
                        $displayName = $sessionName ?? $summary ?? '(no summary)'
                        if ($sessionCwd -eq $cwd -and $updatedAt -and $sessionName -notin $ignoredSessionNames) {
                            [PSCustomObject]@{
                                Id        = $_.Name
                                Summary   = $displayName
                                Branch    = $sessionBranch
                                UpdatedAt = [DateTimeOffset]::Parse($updatedAt)
                            }
                        }
                    }
                } |
                Sort-Object UpdatedAt -Descending)

            # Prefer sessions matching the current git branch
            if ($currentBranch -and $sessions.Count -gt 0) {
                $branchMatches = @($sessions | Where-Object { $_.Branch -and $_.Branch -eq $currentBranch })
                if ($branchMatches.Count -gt 0) {
                    $sessions = $branchMatches
                }
            }

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
                $chosen = Invoke-SessionPicker $pickerSessions
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
                $chosen = Invoke-SessionPicker $pickerSessions
            }

            if ($chosen) { $copilotArgs += '--resume', $chosen.Id }
        }
    }

    # Apply deferred -Name if we didn't end up resuming a session
    if ($applyName -and $copilotArgs -notcontains '--resume') {
        $copilotArgs += '--name', $Name
    }

    $exitCode = $null
    if ($isPassthrough) {
        $exe = if ($useAgency) { $agencyExe } else { $copilotExe }
        if ($PSCmdlet.ShouldProcess("$exe copilot $($passthroughArgs -join ' ')", 'Execute')) {
            if ($useAgency) {
                & $agencyExe @agencyRootArgs copilot @agencyCopilotArgs @passthroughArgs
            } else {
                & $copilotExe @passthroughArgs
            }
            $exitCode = $LASTEXITCODE
        }
    } else {
        if ($Prompt) {
            $copilotArgs += '--autopilot', '-p', $Prompt
        } elseif ($Interactive) {
            $copilotArgs += '--interactive', $Interactive
        }

        if ($RemainingArgs) {
            $copilotArgs += $RemainingArgs
        }

        $exe = if ($useAgency) { $agencyExe } else { $copilotExe }
        $displayArgs = if ($useAgency) { "copilot $($agencyCopilotArgs -join ' ') $($copilotArgs -join ' ')" } else { $copilotArgs -join ' ' }
        if ($PSCmdlet.ShouldProcess("$exe $displayArgs", 'Execute')) {
            if ($useAgency) {
                & $agencyExe @agencyRootArgs copilot @agencyCopilotArgs @copilotArgs
            } else {
                & $copilotExe @copilotArgs
            }
            $exitCode = $LASTEXITCODE
        }
    }

    # If the engine exited non-zero it may have crashed out of its TUI and left the
    # terminal in a bad state. Reset it via the shared helper (guarded so the built
    # Shmuelie.Copilot doesn't require Shmuelie.Utilities;
    # the prompt also resets on every render as the primary safety net).
    if ($null -ne $exitCode -and $exitCode -ne 0 -and (Get-Command Reset-TerminalModes -ErrorAction SilentlyContinue)) {
        Reset-TerminalModes
    }
}