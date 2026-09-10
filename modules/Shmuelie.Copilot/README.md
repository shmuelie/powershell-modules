# Shmuelie.Copilot

GitHub Copilot CLI session, plugin, marketplace, and MCP helpers, plus the
`Start-Copilot` launcher. Depends only on the public `copilot` executable.

**Version:** 0.3.2

## Install

```powershell
Install-PSResource Shmuelie.Copilot
Import-Module Shmuelie.Copilot
Start-Copilot
```

## Commands

| Area | Commands |
|---|---|
| Launcher | `Start-Copilot`, `Get-CopilotLaunchPlan` (optional `-SessionSelector`) |
| Sessions | `Get-CopilotSession`, `Select-CopilotSession` (optional `-SessionSelector`), `Resume-CopilotSession`, `Rename-CopilotSession`, `Remove-CopilotSession` |
| Session maintenance | `Merge-CopilotSession`, `Compress-CopilotSession`, `Repair-CopilotSessionEvents` |
| Plugins | `Get-CopilotPlugin`, `Install-CopilotPlugin`, `Update-CopilotPlugin`, `Uninstall-CopilotPlugin` |
| Marketplaces | `Get-CopilotMarketplace`, `Register-CopilotMarketplace`, `Unregister-CopilotMarketplace`, `Get-CopilotMarketplacePlugin` |
| MCP servers | `Get-CopilotMcpServer`, `Register-CopilotMcpServer`, `Unregister-CopilotMcpServer` (registration/removal protect symlink-managed configuration) |

## Start-Copilot

`Start-Copilot` wraps the `copilot` executable and adds:

- **Automatic session resume** for the current folder — a single session resumes
  automatically, multiple sessions show a picker, and a lone named session
  auto-resumes. Control it with `-NoResume`, `-ResumeLatest`, `-ResumeSession`,
  `-NoAutoResume`, and `-IncludeUnnamed`.
- **Sensible defaults** (`--allow-all --experimental`), each disablable with
  `-NoAllowAll` / `-NoExperimental`. Use `-AllowAllTools` for a middle ground
  that auto-approves tools while keeping file-path and URL verification.
- **More permission & scripting flags** — `-AssistedApproval`
  (`--assisted-approval` safety judge), `-UsageOutputFile` (write usage JSON to
  a file), and `-EnableMcpServer` (also re-enables a settings-disabled MCP
  server for the run).
- **Default deny rules** for destructive git operations (force push, hard reset,
  rebase, amend, `git pull`, and similar).
- **Full flag mapping** — model, reasoning effort, MCP enable/disable, plan mode,
  attachments, remote control, and the rest of the Copilot CLI surface.
- **Autopilot mode** when a prompt is provided; interactive otherwise.
- **`-PassThru`** returns the resolved launch plan (`Exe`, `Args`,
  `Passthrough`) without launching, so other tools can reuse the built arguments
  and session-resume decision. Add **`-DeferResume`** to skip the resume picker
  and emit no `--resume`, letting an overlay own session selection.
  `Get-CopilotLaunchPlan` exposes the same plan directly — it is the shared core
  `Start-Copilot` delegates to, so an overlay can build identical command lines
  without re-invoking `Start-Copilot`. `-WhatIf` also defers resume while
  rendering the command line, so previews never open the session picker.
- **Terminal recovery** after a non-zero exit (via `Reset-TerminalModes` when
  available).
- **`update` / `help` passthrough** straight to the executable.

```powershell
Start-Copilot "Add unit tests for the auth module"
Start-Copilot -Model claude-opus-4.7 -ReasoningEffort high
Start-Copilot -ResumeLatest
Start-Copilot -NoResume -WhatIf   # preview the command line without launching
```

## Custom session selection

Pass `-SessionSelector` to `Start-Copilot`, `Get-CopilotLaunchPlan`, or
`Select-CopilotSession` to replace only the selection UI. No UI package or
terminal-specific adapter is required:

```powershell
$selector = {
    param([object[]]$Sessions)
    $Sessions | Sort-Object UpdatedAt -Descending | Select-Object -First 1
}
$plan = Start-Copilot -PassThru -NoAutoResume -SessionSelector $selector `
    -Model gpt-5.4 -EnableMcpServer my-server
```

The callback receives **one array argument**, ordered newest first, of
`CopilotSession` objects (PowerShell `PSTypeName`) with `Id`, `Name`, `Summary`,
`Branch`, `UpdatedAt`, and `Cwd`. `UpdatedAt` is a `DateTimeOffset`, or may be
null for sessions discovered by `Select-CopilotSession`. `Get-CopilotSession`
remains available for discovery without rendering or launching; the launcher's
existing folder, maintenance-session, and branch-preference policy is separate
from its renderer and does not change the general discovery command's results.

Return exactly one typed candidate, or a typed copy with the **same exact ID**.
IDs are matched against the original candidate list and resolved under the
session-state root; returned `Path`, `Cwd`, and other metadata changes are ignored.
Candidates are copied before invoking caller code. Like any supplied scriptblock,
the callback is trusted code, not a sandbox, and should not change process state.
Use `Write-Host` or `Write-Verbose` for UI and diagnostics, not the success stream.

| Outcome | `Start-Copilot` / `Get-CopilotLaunchPlan` | `Select-CopilotSession` |
|---|---|---|
| One valid candidate | Add only `--resume <ID>` to the existing plan | Resume from the original candidate's Cwd, unless `-StayInDirectory` |
| `$null` or no output | Start a new session (apply `-Name` if supplied) | Cancel without launching |
| Zero candidates | Start new without invoking the callback | Existing no-matches error; callback not invoked |
| Exception, unsuppressed error, multiple objects, invalid/noncandidate result, or disappeared selected session | Terminate; no launch or fallback picker | Terminate; no launch or fallback picker |

Automatic single-session resume, lone-named-session preference, and unnamed-stub
filtering remain unchanged. `-IncludeUnnamed` controls only the picker list;
`-NoAutoResume` forces selection even for one candidate. `-ResumeLatest`,
`-ResumeSession`, `-NoResume`, `-SessionId`, `-DeferResume`, and `help`/`update`
passthrough bypass the callback. `Select-CopilotSession` retains its global
discovery and single-match shortcut, without adopting the launcher's heuristics.
`-WhatIf` never invokes the callback.

The selected ID changes only the resume decision: model, MCP configuration,
deny-tool rules, passthrough arguments, and all other launch flags remain intact.
Returning null is **not** a request to abort a new launch; throw an exception if
your launch selector must cancel the entire operation.

Without a custom callback, the launcher still uses its numbered `[N] New session`
picker; `Select-CopilotSession` still prefers `Out-ConsoleGridView`, then
`Out-GridView`, then its numbered `[Q] Cancel` picker. Built-in pickers reject
unavailable interactive input (including redirected ConsoleHost input), and host
prompt errors, such as PowerShell `-NonInteractive`, terminate without fallback.
The module does not inspect or read the console before invoking custom callbacks,
so they can select deterministically in noninteractive hosts. Callbacks that
implement a UI own its requirements.

## MCP configuration management

`Register-CopilotMcpServer` and `Unregister-CopilotMcpServer` delegate to the
native CLI for ordinary `~/.copilot/mcp-config.json` files, preserving native
arguments and validation. If that file is a symbolic link, both commands fail
before invoking the native mutation, which would otherwise replace the link.
This also applies to pipeline removal and to relative, chained, or dangling
links; neither the link nor its target is modified.

For symlink-managed configuration, edit the target file directly or use the
tool that manages it. The error identifies the link and its target; relative
targets are relative to the link's containing directory. `-WhatIf` still
previews the operation without invoking the native command, and `-Confirm`
still controls whether an operation proceeds. `Get-CopilotMcpServer` is unchanged.

## MCP autoConnect policy

`Start-Copilot` reads the `autoConnect` field on each server in your Copilot CLI
MCP configuration and decides which servers to disable at startup (passing
`--disable-mcp-server` for the ones that should stay off). This is an extension
`Start-Copilot` layers on top of the base CLI — the `[path globs]` form below is
interpreted by `Start-Copilot`, not by `copilot` itself.

| `autoConnect` value | Behavior |
|---|---|
| `true` or omitted | Server is always enabled. |
| `false` | Left to the CLI's native lazy/dormant handling (not force-disabled). |
| `["glob", ...]` | Enabled **only** when the current directory matches one of the path globs; otherwise disabled for this launch. |

The path-glob form is useful for MCP servers that are only relevant in certain
repositories. For example, a server configured with
`"autoConnect": ["D:\\work\\*"]` connects only when you launch from under
`D:\work`. Use `-EnableMcpServer <name>` to force a server on regardless of its
`autoConnect` policy — this also passes the CLI's native `--enable-mcp-server`,
so a server disabled in your Copilot settings is enabled for the run — or
`-DisableMcpServer <name>` to force one off.

## Requirements

- PowerShell 7.4 or later.
- GitHub Copilot CLI (`copilot`) on `PATH`.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).
