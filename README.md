# Shmuelie PowerShell Modules

Independently versioned PowerShell modules for developer workflows across Git,
GitHub Copilot CLI, Node.js, and general tooling.

Each module has its own manifest, README, changelog, package artifact, semantic
version, and release tag. Versions are **not** kept in lockstep.

## Modules

| Module | Description | Version |
|---|---|---|
| [Shmuelie.Git](modules/Shmuelie.Git/README.md) | Git worktrees, repository layout, status, completion, and a PSReadLine predictor | 0.1.0 |
| [Shmuelie.Copilot](modules/Shmuelie.Copilot/README.md) | GitHub Copilot CLI sessions, plugins, marketplaces, MCP, and the `Start-Copilot` launcher | 0.2.0 |
| [Shmuelie.Node](modules/Shmuelie.Node/README.md) | Node.js, nvm-windows, npm, and Azure DevOps npm credentials | 0.1.0 |
| [Shmuelie.Utilities](modules/Shmuelie.Utilities/README.md) | .NET tools, Python packages, VS Code, Windows Terminal, services, and WPR | 0.1.0 |

## Installation

PowerShell Gallery publication is prepared but remains disabled while this
repository is in private preview.

```powershell
Install-PSResource Shmuelie.Git
Install-PSResource Shmuelie.Copilot
Install-PSResource Shmuelie.Node
Install-PSResource Shmuelie.Utilities
```

Install only the modules you need — they have no cross-dependencies.

## Requirements

- PowerShell 7.4 or later.
- Windows for the Windows-specific commands (services, Windows Terminal, WPR,
  the worktree predictor build). Cross-platform commands run anywhere PowerShell 7 does.
- The relevant external tool on `PATH` for a given command (`git`, `copilot`,
  `node`/`nvm`, `dotnet`, and so on).

## Build

```powershell
# Build, validate, import every module, and run the public-content scan
.\build\Test-Modules.ps1

# Build a single module into artifacts/
.\build\Build-Module.ps1 -Module Shmuelie.Git
```

`Shmuelie.Git` compiles its bundled `WorktreePredictor` during the build, so a
.NET SDK is required to build that module.

## Public-content policy

These modules are intended for public distribution. They must not reference or
depend on internal-only tooling, private endpoints, organization-specific
systems, or credentials. `build/Test-Modules.ps1` scans module sources,
documentation, and READMEs for forbidden markers and fails the build if any are
found.

## Versioning and releases

- Each module follows semantic versioning independently.
- A module's `.psd1` `ModuleVersion` is the source of truth; the root README and
  documentation site mirror it.
- Releases are tagged per module as `<Module>-v<version>` (for example
  `Shmuelie.Git-v0.1.0`).
- Notable changes are recorded in each module's `CHANGELOG.md`.

## Documentation

The documentation site source is under [`docs/`](docs/) and is authored in
Markdown. Its Pages workflow builds the site with Jekyll and remains manual
while the repository is private.

## Repository structure

```text
powershell-modules/
├── README.md
├── docs/
│   ├── _config.yml
│   ├── index.md
│   ├── modules.md
│   ├── installation.md
│   └── contributing.md
├── build/
│   ├── Build-Module.ps1
│   ├── Publish-Module.ps1
│   └── Test-Modules.ps1
└── modules/
    └── Shmuelie.*/
        ├── Shmuelie.*.psd1
        ├── Shmuelie.*.psm1
        ├── README.md
        ├── CHANGELOG.md
        └── Public/*.ps1
```
