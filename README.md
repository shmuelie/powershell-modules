# Shmuelie PowerShell Modules

Independently versioned PowerShell modules for developer workflows.

| Module | Description | Version |
|---|---|---|
| [Shmuelie.Git](modules/Shmuelie.Git/README.md) | Git worktrees, repository management, completion, and prediction | 0.1.0 |
| [Shmuelie.Copilot](modules/Shmuelie.Copilot/README.md) | GitHub Copilot CLI sessions, plugins, marketplaces, and MCP management | 0.1.0 |
| [Shmuelie.Node](modules/Shmuelie.Node/README.md) | Node.js, nvm-windows, npm, and ADO npm credentials | 0.1.0 |
| [Shmuelie.Utilities](modules/Shmuelie.Utilities/README.md) | General .NET, Python, VS Code, Terminal, service, and WPR utilities | 0.1.0 |

Each module has its own manifest, README, changelog, package artifact, semantic
version, and release tag. Versions are not kept in lockstep.

## Installation

PowerShell Gallery publication is prepared but remains disabled while this
repository is in private preview.

```powershell
Install-PSResource Shmuelie.Git
Install-PSResource Shmuelie.Copilot
Install-PSResource Shmuelie.Node
Install-PSResource Shmuelie.Utilities
```

## Build

```powershell
.\build\Test-Modules.ps1
.\build\Build-Module.ps1 -Module Shmuelie.Git
```

The documentation site source is under [`docs/`](docs/).
