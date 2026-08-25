---
title: Shmuelie PowerShell Modules
---

**[Home](index.md) · [Modules](modules.md) · [Installation](installation.md) · [Contributing](contributing.md) · [GitHub](https://github.com/shmuelie/powershell-modules)**

Independently versioned PowerShell modules for developer workflows across Git,
GitHub Copilot CLI, Node.js, Visual Studio, and general tooling.

Each module ships its own manifest, README, changelog, package artifact,
semantic version, and release tag. Versions are not kept in lockstep, so you can
install and upgrade each module on its own.

## Modules

| Module | Description | Version |
|---|---|---|
| [Shmuelie.Git](modules.md#shmuelie-git) | Git worktrees, layout, status, completion, and prediction | 0.6.0 |
| [Shmuelie.Copilot](modules.md#shmuelie-copilot) | Copilot CLI sessions, plugins, marketplaces, MCP, and launcher | 0.2.0 |
| [Shmuelie.Node](modules.md#shmuelie-node) | Node.js, nvm-windows, npm, and ADO npm credentials | 0.1.3 |
| [Shmuelie.Utilities](modules.md#shmuelie-utilities) | .NET, Python, VS Code, Terminal, services, and WPR | 0.2.3 |
| [Shmuelie.Dsc](modules.md#shmuelie-dsc) | DSC v3 resources for setup: modules, symlinks, Copilot plugins/marketplaces, uv tools | 0.1.0 |
| [Shmuelie.VisualStudio](modules.md#shmuelie-visualstudio) | Visual Studio discovery and developer shell launch helpers | 0.1.0 |

## Quick start

```powershell
Install-PSResource Shmuelie.Git
Import-Module Shmuelie.Git
```

See the [installation guide](installation.md) for gallery status, updates, and
building from source.

## Public by design

These modules are for public distribution and exclude internal-only tooling,
private endpoints, organization-specific systems, and credentials. The build
scans sources and documentation for forbidden markers. See the
[contribution guide](contributing.md).
