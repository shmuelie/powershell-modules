# Shmuelie.Copilot

GitHub Copilot CLI session, plugin, marketplace, and MCP helpers, plus the
`Start-Copilot` launcher (alias `copilot`). Depends only on the public `copilot`
executable.

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
| Launcher | `Start-Copilot` (alias `copilot`) |
| Sessions | `Get-CopilotSession`, `Resume-CopilotSession`, `Rename-CopilotSession`, `Remove-CopilotSession` |
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
  `-NoAllowAll` / `-NoExperimental`.
- **Default deny rules** for destructive git operations (force push, hard reset,
  rebase, amend, `git pull`, and similar).
- **Full flag mapping** — model, reasoning effort, MCP enable/disable, plan mode,
  attachments, remote control, and the rest of the Copilot CLI surface.
- **Autopilot mode** when a prompt is provided; interactive otherwise.
- **Terminal recovery** after a non-zero exit (via `Reset-TerminalModes` when
  available).
- **`update` / `help` passthrough** straight to the executable.

```powershell
Start-Copilot "Add unit tests for the auth module"
Start-Copilot -Model claude-opus-4.7 -ReasoningEffort high
Start-Copilot -ResumeLatest
Start-Copilot -NoResume -WhatIf   # preview the command line without launching
```

## Requirements

- PowerShell 7.4 or later.
- GitHub Copilot CLI (`copilot`) on `PATH`.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).
