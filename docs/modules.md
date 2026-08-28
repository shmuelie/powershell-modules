---
title: Modules
---

**[Home](index.md) · [Modules](modules.md) · [Installation](installation.md) · [Contributing](contributing.md) · [GitHub](https://github.com/shmuelie/powershell-modules)**

# Modules

Each module is self-contained and independently versioned.

## Import startup cost

The modules use a root-level script loader so newly added command and helper
`.ps1` files are dot-sourced automatically. On a Windows PowerShell 7.4+
host, measured from built artifacts with a fresh `pwsh -NoProfile` process per
module and a stopwatch around `Import-Module`, the expected cold import medians
are:

| Module | Median import time |
|---|---:|
| Shmuelie.Utilities | 488.7 ms |
| Shmuelie.Git | 612.0 ms |
| Shmuelie.Copilot | 536.0 ms |
| Shmuelie.Node | 344.3 ms |
| Shmuelie.VisualStudio | Not yet measured |
| **Combined** | **1981.0 ms** |

`Shmuelie.Git` still performs predictor registration during import when the
bundled `WorktreePredictor.dll` is present in the built module artifact, but it
no longer eagerly imports PSReadLine before registering the predictor.

## Shmuelie.Git

Git repository, worktree, status, completion, and PSReadLine prediction helpers.
**Version 0.8.1.**
[README](https://github.com/shmuelie/powershell-modules/blob/main/modules/Shmuelie.Git/README.md)

Highlights:

- `New-Repository` clones into a standard `<root>/<org>/<repo>/<branch>` layout.
- Worktree lifecycle: `New-Worktree`, `Add-Worktree`, `Set-Worktree`,
  `Remove-Worktree`, `Update-Worktrees`.
- `Get-GitStatusSummary` returns a typed status object.
- A bundled `WorktreePredictor.dll` suggests branch names for worktree commands.

## Shmuelie.Copilot

GitHub Copilot CLI sessions, plugins, marketplaces, MCP servers, and the
`Start-Copilot` launcher. **Version 0.3.1.**
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
**Version 0.1.4.**
[README](https://github.com/shmuelie/powershell-modules/blob/main/modules/Shmuelie.Node/README.md)

Highlights:

- Node version management via nvm-windows.
- `Get-NpmPackage` / `Update-NpmPackage` for global packages.
- `Update-AdoNpmToken` refreshes a token for an explicit Azure DevOps feed URL.

## Shmuelie.Utilities

General developer utilities for PowerShell, .NET tools, Python packages, VS
Code, terminal recovery, and general developer workflows. **Version 0.3.1.**
[README](https://github.com/shmuelie/powershell-modules/blob/main/modules/Shmuelie.Utilities/README.md)

Highlights:

- Core helpers: `Test-IsElevated`, `Invoke-InLocation`, `Reset-TerminalModes`.
- Tool management for `dotnet`, `pip`, `uv`, and VS Code extensions.

## Shmuelie.Windows

Windows-only developer utilities for installed applications, Windows Terminal,
Windows Performance Recorder, and service host processes. **Version 0.1.2.**
[README](https://github.com/shmuelie/powershell-modules/blob/main/modules/Shmuelie.Windows/README.md)

Highlights:

- `Get-InstalledApplications` queries Windows uninstall registry state.
- `Get-ServiceProcess` resolves a Windows service to its hosting process.
- `Get-WindowsTerminalSettings` and `Get-WindowsTerminalProfile` inspect Windows Terminal configuration.
- `Start-WindowsPerformanceRecorder` and `Stop-WindowsPerformanceRecorder` wrap WPR tracing.

## Shmuelie.Dsc

Class-based [DSC v3](https://learn.microsoft.com/powershell/dsc/overview)
resources for developer machine setup. **Version 0.1.0.**
[README](https://github.com/shmuelie/powershell-modules/blob/main/modules/Shmuelie.Dsc/README.md)

Highlights:

- `SavePSResource` saves a PowerShell module to a local path; `SymbolicLink`
  creates and verifies symbolic links.
- `CopilotPlugin` and `CopilotMarketplace` install GitHub Copilot CLI plugins
  and register marketplaces.
- `UvTool` installs a Python tool via `uv tool install`.

## Shmuelie.VisualStudio

Visual Studio developer shell helpers for PowerShell. **Version 0.1.1.**
[README](https://github.com/shmuelie/powershell-modules/blob/main/modules/Shmuelie.VisualStudio/README.md)

Highlights:

- `Get-InstalledVsVersion` lists installed Visual Studio years that have a
  matching `Set-VS<year>` command available.
- `Start-DevShell` launches a nested `pwsh` inline with `VSDEV_VERSION`,
  `VSDEV_ARCH`, `VSDEV_HOSTARCH`, and a clean login `PATH` for profile-driven
  Visual Studio environment loading.
