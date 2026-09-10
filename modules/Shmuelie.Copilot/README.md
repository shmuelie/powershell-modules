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
| Launcher | `Start-Copilot`, `Get-CopilotLaunchPlan` |
| Sessions | `Get-CopilotSession` / `Select-CopilotSession` (composable metadata and age filters), `Resume-CopilotSession`, `Rename-CopilotSession`, `Remove-CopilotSession` |
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

## Session discovery and cleanup

`Get-CopilotSession` without arguments still returns sessions for the current
directory. `-Repository`, `-Branch`, and `-Summary` narrow that scope; use `-All`
to search globally. Explicit `-Cwd` replaces the implicit current-directory
restriction, with or without `-All`.

The four string filters accept case-insensitive PowerShell wildcard patterns
and combine with **AND**. They match recorded strings, not resolved filesystem
paths: separators and trailing separators are not normalized, and wildcard
characters in literal paths must be escaped with a PowerShell backtick.
Missing or empty Repository, Branch, or Cwd does not match even `'*'`.
Summary matches the displayed value: `name`, then legacy `summary`, then
`'(no summary)'` for unnamed sessions.

| Date filter | Meaning |
|---|---|
| `-UpdatedBefore <DateTimeOffset>` | `UpdatedAt` is strictly before the given instant. Prefer ISO 8601 with `Z` or an explicit offset. Offset-less input means local time; date-only input means local midnight, not the end of the day. |
| `-OlderThan <TimeSpan>` | `UpdatedAt` is strictly more than the positive elapsed duration ago. The UTC clock is sampled once for the invocation. Use `New-TimeSpan -Days 30`, not a bare number; days are 24-hour periods, not calendar days. |

Both date filters can be combined; the earlier cutoff wins. Sessions with missing
UpdatedAt are excluded when either is supplied, without falling back to CreatedAt
or filesystem timestamps. Sessions without workspace metadata are still skipped.
Output remains sorted by UpdatedAt descending.

`-Id` remains an exact, directory-independent lookup, cannot be combined with
filters or `-All`, and retains the session-root guard. `Select-CopilotSession`
uses the same matching logic but still searches **all** directories by default,
supports wildcard IDs, and applies `-First` after filtering and sorting.

```powershell
Get-CopilotSession -All -Repository 'owner/*' -Branch 'feature/*' -Summary '*cleanup*'
Get-CopilotSession -Cwd (Join-Path $HOME 'projects' '*')
Select-CopilotSession -Repository 'owner/repo' -Summary '*investigate*' -First 1

# Capture and inspect the exact batch before deletion.
$stale = Get-CopilotSession -All -Repository 'owner/repo' `
    -UpdatedBefore '2026-08-01T00:00:00Z' -OlderThan (New-TimeSpan -Days 30)
$stale | Remove-CopilotSession -WhatIf
$stale | Remove-CopilotSession -Confirm
```

Cleanup remains an explicit pipeline into `Remove-CopilotSession`: discovery
never deletes anything, and removal re-resolves each ID rather than trusting
the pipeline object's Path.

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
