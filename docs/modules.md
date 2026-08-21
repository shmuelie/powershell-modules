---
title: Modules
---

**[Home](index.md) · [Modules](modules.md) · [Installation](installation.md) · [Contributing](contributing.md) · [GitHub](https://github.com/shmuelie/powershell-modules)**

# Modules

Each module is self-contained and independently versioned.

## Import startup cost

The modules use a directory-based Public script loader so newly added command
and helper files are dot-sourced automatically. On a Windows PowerShell 7.4+
host, measured from built artifacts with a fresh `pwsh -NoProfile` process per
module and a stopwatch around `Import-Module`, the expected cold import medians
are:

| Module | Median import time |
|---|---:|
| Shmuelie.Utilities | 548.3 ms |
| Shmuelie.Git | 777.6 ms |
| Shmuelie.Copilot | 600.5 ms |
| Shmuelie.Node | 483.8 ms |
| **Combined** | **2410.2 ms** |

`Shmuelie.Git` still performs predictor registration during import when the
bundled `WorktreePredictor.dll` is present in the built module artifact, but it
no longer eagerly imports PSReadLine before registering the predictor.

## Shmuelie.Git

Git repository, worktree, status, completion, and PSReadLine prediction helpers.
**Version 0.5.0.**
[README](https://github.com/shmuelie/powershell-modules/blob/main/modules/Shmuelie.Git/README.md)

Highlights:

- `New-Repository` clones into a standard `<root>/<org>/<repo>/<branch>` layout.
- Worktree lifecycle: `New-Worktree`, `Add-Worktree`, `Set-Worktree`,
  `Remove-Worktree`, `Update-Worktrees`.
- `Get-GitStatusSummary` returns a typed status object.
- A bundled `WorktreePredictor.dll` suggests branch names for worktree commands.

## Shmuelie.Copilot

GitHub Copilot CLI sessions, plugins, marketplaces, MCP servers, and the
`Start-Copilot` launcher. **Version 0.1.3.**
[README](https://github.com/shmuelie/powershell-modules/blob/main/modules/Shmuelie.Copilot/README.md)

Highlights:

- `Start-Copilot` adds session resume, a multi-session picker,
  safe git deny rules, and full Copilot CLI flag mapping.
- `Start-Copilot -PassThru` returns the resolved launch plan without launching,
  so other tools can reuse the built arguments (`-DeferResume` also skips the
  resume picker so an overlay owns session selection).
- Path-aware MCP startup: a server's `autoConnect` value (`true`/absent, `false`,
  or an array of path globs) decides whether `Start-Copilot` enables it for the
  current directory. See the module README.
- Session tools: `Get-CopilotSession`, `Resume-CopilotSession`,
  `Merge-CopilotSession`, `Compress-CopilotSession`, `Repair-CopilotSessionEvents`.
- Plugin, marketplace, and MCP management wrap the public `copilot` CLI.

## Shmuelie.Node

Node.js, nvm-windows, npm package, and Azure DevOps npm credential helpers.
**Version 0.1.2.**
[README](https://github.com/shmuelie/powershell-modules/blob/main/modules/Shmuelie.Node/README.md)

Highlights:

- Node version management via nvm-windows.
- `Get-NpmPackage` / `Update-NpmPackage` for global packages.
- `Update-AdoNpmToken` refreshes a token for an explicit Azure DevOps feed URL.

## Shmuelie.Utilities

General developer utilities for PowerShell, .NET tools, Python packages, VS
Code, Windows Terminal, services, applications, and WPR. **Version 0.2.2.**
[README](https://github.com/shmuelie/powershell-modules/blob/main/modules/Shmuelie.Utilities/README.md)

Highlights:

- Core helpers: `Test-IsElevated`, `Invoke-InLocation`, `Reset-TerminalModes`.
- Tool management for `dotnet`, `pip`, `uv`, and VS Code extensions.
- `Get-ServiceProcess` resolves a service to its hosting process.
