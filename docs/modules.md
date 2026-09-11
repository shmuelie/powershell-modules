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
| Shmuelie.DotNet | Not yet measured |
| Shmuelie.VisualStudio | Not yet measured |
| **Combined** | **1981.0 ms** |

`Shmuelie.Git` still performs predictor registration during import when the
bundled `WorktreePredictor.dll` is present in the built module artifact, but it
no longer eagerly imports PSReadLine before registering the predictor.

## Shmuelie.Git

Git repository, worktree, status, completion, and PSReadLine prediction helpers.
**Version 0.10.0.**
[README](https://github.com/shmuelie/powershell-modules/blob/main/modules/Shmuelie.Git/README.md)

Highlights:

- `New-Repository` clones into a standard `<root>/<org>/<repo>/<branch>` layout.
- Worktree lifecycle: `New-Worktree`, `Add-Worktree`, `Set-Worktree`,
  `Remove-Worktree`, `Update-Worktrees`.
- `Get-GitStatusSummary` returns a typed status object.
- `Get-Branch` and `Get-GitTag` inspect local refs as typed objects without fetching.
- `Set-Branch` and `Remove-Branch` make branch changes explicit and support confirmation.
- `Save-GitStash` and `Restore-GitStash` save and restore changes using native Git semantics.
- `Restore-Items` preserves staged changes unless `-IncludeIndex` is specified.
- `Set-Config` writes literal local, global or system settings with confirmation.
- `Update-Worktrees -ChangedOnly` limits output to actionable worktree results.
- A bundled `WorktreePredictor.dll` suggests branch names for worktree commands.

**Worktree navigation change:** `New-Worktree` and `Add-Worktree` now enter the
created worktree by default, like `New-Repository`, even with an explicit `-Path`.
Add `-NoSetLocation` to scripts that must stay in the caller's directory.
The temporary compatibility switch `-SetLocation` still works; explicit
`-SetLocation:$false` still stays put and can be replaced with `-NoSetLocation`.
Do not combine the two switches, even when false. Failed creation and `-WhatIf`
never change location.

### Removing worktrees: migration

`Remove-Worktree` now removes the backing local branch after successful worktree
removal by default. This retains its previous `git branch -D` cleanup semantics,
including deletion of unmerged branches. Add `-KeepBranch` to scripts that
previously omitted `-RemoveBranch` in order to preserve unfinished work.
Existing `-RemoveBranch` calls still work, and `-RemoveBranch:$false` still keeps
the branch. Enabling both `-KeepBranch` and `-RemoveBranch` is rejected.

Worktree removal and branch deletion have separate high-impact confirmations;
`-Confirm:$false` is the explicit unattended opt-in. `-WhatIf` previews the planned
operations and changes neither resource. Detached worktrees never delete branches,
failed or declined worktree removal preserves the branch, and no remote branch
is deleted. `-Force` keeps its existing single-`--force` worktree behavior without
bypassing confirmation or escalating after a failure.

## Shmuelie.Copilot

GitHub Copilot CLI sessions, plugins, marketplaces, MCP servers, and the
`Start-Copilot` launcher. **Version 0.4.0.**
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

## Shmuelie.DotNet

User-local .NET SDK installation and canonical tool management for Windows,
Linux, and macOS.
**Version 0.2.0.**
[README](https://github.com/shmuelie/powershell-modules/blob/main/modules/Shmuelie.DotNet/README.md)

Highlights:

- `Install-DotNetSdk` installs exact or channel/quality-selected SDKs side by side,
  skips existing matches, and returns typed results. PATH changes are opt-in:
  process-only everywhere, or persistent user plus process on Windows.
- SDK installers use canonical Microsoft URLs, available signature validation,
  isolated staging cleanup, and separate download/install/PATH confirmations.
- `Get-DotNetTool` returns typed tool records with wildcard package filtering.
- `Install-DotNetTool` and `Uninstall-DotNetTool` manage global tools.
- `Update-DotNetTool` accepts names or pipeline objects and supports local tools.
- Import requires no SDK invocation and does not load Utilities.

The four Utilities entry points forward lazily to DotNet and remain available
until Utilities 1.0. Install the dependency explicitly with
`Install-PSResource Shmuelie.DotNet`; importing Utilities does not load DotNet.
Wrappers use the sibling DotNet manifest in a source checkout, or a loaded module
or installation on `$env:PSModulePath` otherwise, without changing caller command
precedence. Missing dependencies report installation guidance. Use module-qualified
`Shmuelie.DotNet` commands in new scripts. See the module README for preserved
scope behavior.

## Shmuelie.Utilities

General developer utilities for PowerShell, .NET tools, Python packages, VS
Code, terminal recovery, and general developer workflows. **Version 0.6.0.**
[README](https://github.com/shmuelie/powershell-modules/blob/main/modules/Shmuelie.Utilities/README.md)

Highlights:

- Core helpers: `Test-IsElevated`, `Invoke-InLocation`, `Reset-TerminalModes`.
- Tool management for `pip`, `uv`, and VS Code extensions, plus legacy .NET tool
  entry points; `Shmuelie.DotNet` is the canonical owner of .NET tool management.

## Shmuelie.Windows

Windows-only developer utilities for installed applications, Windows Terminal,
Windows Performance Recorder, and service host processes. **Version 0.2.0.**
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

Visual Studio discovery, MSBuild resolution, and developer shell helpers for PowerShell. **Version 0.2.0.**
[README](https://github.com/shmuelie/powershell-modules/blob/main/modules/Shmuelie.VisualStudio/README.md)

Highlights:

- `Get-InstalledVsVersion` lists installed Visual Studio years that have a
  matching `Set-VS<year>` command available.
- `Resolve-MSBuild` resolves Visual Studio's real `MSBuild.exe` (not
  `dotnet msbuild`) using `vswhere`, including standalone Build Tools. Optional
  year/version-prefix and executable-architecture filters select the newest
  compatible release; the default architecture is native to the OS. Returns
  typed installation metadata or a path with `-PathOnly`, without running a
  build or changing `PATH`. Windows-only; module import remains cross-platform.
- `Start-DevShell` launches a nested `pwsh` inline with `VSDEV_VERSION`,
  `VSDEV_ARCH`, `VSDEV_HOSTARCH`, and a clean login `PATH` for profile-driven
  Visual Studio environment loading.

## Shmuelie.PackageManagement

Provider-neutral package update orchestration. **Version 0.3.0.**
[README](https://github.com/shmuelie/powershell-modules/blob/main/modules/Shmuelie.PackageManagement/README.md)

`Update-AllPackages` provides provider selection/exclusion, provider-specific
option tables, lazy dependency discovery, per-target `ShouldProcess`, typed
results, and optional fail-fast behavior.

See the module README for provider availability and supported options.
The Windows-only WinGet provider uses optional Microsoft.WinGet.Client and
winget.exe 1.8.1911+ dependencies. It accepts source agreements by default,
including preview discovery; package agreements require explicit Boolean opt-in.
All eight providers are implemented; unavailable integrations report `Skipped` with a reason.
Importing the core is portable and does not import optional provider modules.
The Windows-only AppInstaller adapter lazily uses compiled Shmuelie.Windows
commands with opt-in request results. Its operation-scoped outcomes report
completed update-check requests, never inferred application version changes.
