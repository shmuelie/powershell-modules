---
title: Installation
---

**[Home](index.md) · [Modules](modules.md) · [Installation](installation.md) · [Contributing](contributing.md) · [GitHub](https://github.com/shmuelie/powershell-modules)**

# Installation

## PowerShell Gallery

Gallery publication is prepared but disabled while the repository is in private
preview. Once published, install each module independently:

```powershell
Install-PSResource Shmuelie.Git
Install-PSResource Shmuelie.Copilot
Install-PSResource Shmuelie.Node
Install-PSResource Shmuelie.Utilities
Install-PSResource Shmuelie.Windows
```

Import a module before use:

```powershell
Import-Module Shmuelie.Git
```

## Update and remove

```powershell
Update-PSResource Shmuelie.Git
Uninstall-PSResource Shmuelie.Git
```

## Build from source

Clone the repository and build with the included scripts:

```powershell
# Build, validate, import every module, and run the public-content scan
.\build\Test-Modules.ps1

# Run the Pester unit test suite
.\build\Invoke-Tests.ps1

# Build one module into artifacts/
.\build\Build-Module.ps1 -Module Shmuelie.Git
```

Import a built module directly from its artifact directory:

```powershell
Import-Module .\artifacts\Shmuelie.Git\0.1.0\Shmuelie.Git.psd1
```

## Requirements

- PowerShell 7.4 or later.
- A .NET SDK to build `Shmuelie.Git` (it compiles the bundled worktree predictor).
- The external tool a given command wraps (`git`, `copilot`, `node`/`nvm`,
  `dotnet`, and so on) on `PATH`.
- Windows for the Windows-specific commands; cross-platform commands run
  anywhere PowerShell 7 does.
