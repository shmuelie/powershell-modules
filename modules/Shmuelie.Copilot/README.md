# Shmuelie.Copilot

PowerShell helpers for GitHub Copilot CLI sessions, plugins, marketplaces, and
MCP servers. The `copilot` alias wraps `Start-Copilot`, which adds session
resume and full command-line mapping over the public `copilot` executable.

**Version:** 0.2.0 · [Changelog](CHANGELOG.md) · Part of [`shmuelie/powershell-modules`](../../README.md)

## Install

```powershell
Install-PSResource Shmuelie.Copilot
Import-Module Shmuelie.Copilot
Start-Copilot
```

## Commands

| Area | Commands |
|---|---|
| Sessions | `Get-CopilotSession`, `Remove-CopilotSession`, `Rename-CopilotSession`, `Resume-CopilotSession` |
| Session maintenance | `Merge-CopilotSession`, `Compress-CopilotSession`, `Repair-CopilotSessionEvents` |
| Plugins | `Get-CopilotPlugin`, `Install-CopilotPlugin`, `Update-CopilotPlugin`, `Uninstall-CopilotPlugin` |
| Marketplaces | `Get-CopilotMarketplace`, `Register-CopilotMarketplace`, `Unregister-CopilotMarketplace`, `Get-CopilotMarketplacePlugin` |
| MCP servers | `Get-CopilotMcpServer`, `Register-CopilotMcpServer`, `Unregister-CopilotMcpServer` |
| Launcher | `Start-Copilot` (alias `copilot`) |

## Start-Copilot

`Start-Copilot` wraps the `copilot` executable with:

- Automatic session resume for the current folder, a picker for multiple
  sessions, and `-NoResume` / `-ResumeLatest` / `-ResumeSession` / `-NoAutoResume`.
- Sensible defaults (`--allow-all --experimental`) that can be disabled with
  `-NoAllowAll` / `-NoExperimental`.
- Default deny rules for destructive git operations.
- Full mapping of Copilot CLI flags to named parameters.
- Terminal-mode recovery after a non-zero exit.

```powershell
Start-Copilot "Add unit tests for the auth module"
Start-Copilot -Model claude-opus-4.7 -ReasoningEffort high
Start-Copilot -NoResume -WhatIf   # preview the command line without launching
```

## Requirements

- PowerShell 7.4 or later
- GitHub Copilot CLI (`copilot`) on `PATH`
