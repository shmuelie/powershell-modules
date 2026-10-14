---
title: Installation
---

**[Home](index.md) · [Modules](modules.md) · [Installation](installation.md) · [Contributing](contributing.md) · [GitHub](https://github.com/shmuelie/powershell-modules)**

# Installation

## PowerShell Gallery

Install each released module independently from the PowerShell Gallery:

```powershell
Install-PSResource Shmuelie.Git
Install-PSResource Shmuelie.Copilot
Install-PSResource Shmuelie.Node
Install-PSResource Shmuelie.DotNet
Install-PSResource Shmuelie.Utilities
Install-PSResource Shmuelie.Windows
Install-PSResource Shmuelie.PackageManagement
Install-PSResource Shmuelie.DevTunnel
```

Import a module before use:

```powershell
Import-Module Shmuelie.Git
```

See the [Shmuelie.PackageManagement README](https://github.com/shmuelie/powershell-modules/blob/main/modules/Shmuelie.PackageManagement/README.md)
for provider availability and optional dependencies. Unavailable integrations
report explicit skipped outcomes; installing the module does not install or
update provider tools.

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
- `Shmuelie.DevTunnel` requires the native Microsoft `devtunnel` CLI 1.0.2115
  or a compatible 1.x build. Install it separately; module import never installs
  the CLI or logs in. See its
  [README](https://github.com/shmuelie/powershell-modules/blob/main/modules/Shmuelie.DevTunnel/README.md).
- Windows for the Windows-specific commands; cross-platform commands run
  anywhere PowerShell 7 does.
