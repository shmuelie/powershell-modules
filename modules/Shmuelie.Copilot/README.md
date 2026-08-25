# Shmuelie.Copilot

GitHub Copilot CLI session, plugin, marketplace, and MCP helpers, plus the
`Start-Copilot` launcher. Depends only on the public `copilot` executable.

**Version:** 0.2.0

## Install

```powershell
Install-PSResource Shmuelie.Copilot
Import-Module Shmuelie.Copilot
Start-Copilot
```

## Commands

| Area | Commands |
|---|---|
| Launcher | `Start-Copilot`, `Get-CopilotLaunchPlan` |
| Sessions | `Get-CopilotSession`, `Select-CopilotSession`, `Resume-CopilotSession`, `Rename-CopilotSession`, `Remove-CopilotSession` |
| Session maintenance | `Merge-CopilotSession`, `Compress-CopilotSession`, `Repair-CopilotSessionEvents` |
| Plugins | `Get-CopilotPlugin`, `Install-CopilotPlugin`, `Update-CopilotPlugin`, `Uninstall-CopilotPlugin` |
| Marketplaces | `Get-CopilotMarketplace`, `Register-CopilotMarketplace`, `Unregister-CopilotMarketplace`, `Get-CopilotMarketplacePlugin` |
| MCP servers | `Get-CopilotMcpServer`, `Register-CopilotMcpServer`, `Unregister-CopilotMcpServer` |

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
