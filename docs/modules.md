---
title: Modules
---

**[Home](index.md) · [Modules](modules.md) · [Installation](installation.md) · [Contributing](contributing.md) · [GitHub](https://github.com/shmuelie/powershell-modules)**

# Modules

Each module is self-contained and independently versioned.

## Shmuelie.Git

Git repository, worktree, status, completion, and PSReadLine prediction helpers.
**Version 0.3.0.**
[README](https://github.com/shmuelie/powershell-modules/blob/main/modules/Shmuelie.Git/README.md)

Highlights:

- `New-Repository` clones into a standard `<root>/<org>/<repo>/<branch>` layout.
- Worktree lifecycle: `New-Worktree`, `Add-Worktree`, `Set-Worktree`,
  `Remove-Worktree`, `Update-Worktrees`.
- `Get-GitStatusSummary` returns a typed status object.
- A bundled `WorktreePredictor.dll` suggests branch names for worktree commands.

## Shmuelie.Copilot

GitHub Copilot CLI sessions, plugins, marketplaces, MCP servers, and the
`Start-Copilot` launcher. **Version 0.1.2.**
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
**Version 0.1.1.**
[README](https://github.com/shmuelie/powershell-modules/blob/main/modules/Shmuelie.Node/README.md)

Highlights:

- Node version management via nvm-windows.
- `Get-NpmPackage` / `Update-NpmPackage` for global packages.
- `Update-AdoNpmToken` refreshes a token for an explicit Azure DevOps feed URL.

## Shmuelie.Utilities

General developer utilities for PowerShell, .NET tools, Python packages, VS
Code, Windows Terminal, services, applications, and WPR. **Version 0.2.1.**
[README](https://github.com/shmuelie/powershell-modules/blob/main/modules/Shmuelie.Utilities/README.md)

Highlights:

- Core helpers: `Test-IsElevated`, `Invoke-InLocation`, `Reset-TerminalModes`.
- Tool management for `dotnet`, `pip`, `uv`, and VS Code extensions.
- `Get-ServiceProcess` resolves a service to its hosting process.
