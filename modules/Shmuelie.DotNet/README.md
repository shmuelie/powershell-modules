# Shmuelie.DotNet

Canonical .NET tool management for PowerShell on Windows, Linux, and macOS.

**Version:** 0.1.0

## Install

```powershell
Install-PSResource Shmuelie.DotNet
Import-Module Shmuelie.DotNet
```

## Commands

| Command | Purpose |
|---|---|
| `Get-DotNetTool` | List global tools by default, or local manifest tools with `-Local`; filter package IDs with `-Name` wildcards |
| `Install-DotNetTool` | Install a global tool by name, skipping tools already installed |
| `Update-DotNetTool` | Update global/local tools by name or pipeline object |
| `Uninstall-DotNetTool` | Uninstall global tools by name or pipeline object |

`Get-DotNetTool` returns `DotNetTool` objects with `PackageId`, `Version`,
`Commands`, and `Global`. `Update-DotNetTool` returns `DotNetToolUpdateResult`
objects with `PackageId`, `Version`, and `Updated`. Install and uninstall emit
no success-stream objects. Mutating commands support `-WhatIf` and `-Confirm`.

## Examples

```powershell
Get-DotNetTool -Name 'dotnet-e*'
Install-DotNetTool dotnet-ef -WhatIf
Get-DotNetTool | Update-DotNetTool
Update-DotNetTool -Name dotnet-ef -Local
Get-DotNetTool old-tool | Uninstall-DotNetTool -WhatIf
```

Discovery retains the existing Utilities working-directory behavior: both
global and local lists run from the home directory, then restore the caller's
location. Updates run from the caller's location; pipeline input selects scope
using `Global`. Install and uninstall remain global-only. This migration does
not change native output parsing or failure reporting.

## Utilities compatibility

`Shmuelie.DotNet` owns the four tool commands. Existing
`Shmuelie.Utilities` exports remain available until Utilities 1.0.
Use module-qualified names when both modules are imported:

```powershell
Shmuelie.DotNet\Get-DotNetTool | Shmuelie.DotNet\Update-DotNetTool
```

The migration is staged across separate pull requests:
[#186](https://github.com/shmuelie/powershell-modules/issues/186) adds the
canonical module while temporarily retaining the Utilities implementations so
intermediate main-branch checkouts remain functional.
[#187](https://github.com/shmuelie/powershell-modules/issues/187) replaces those
implementations with thin, lazy, module-qualified compatibility wrappers.
Complete #187 before the M2 release; duplicated tool implementations must not
ship in that release. Neither module needs to eagerly import the other.

## Requirements

- PowerShell 7.4 or later.
- A .NET SDK providing `dotnet` on `PATH` when a tool command is used.
  Importing the module does not invoke `dotnet` or require Utilities.

SDK installation is tracked separately in
[#188](https://github.com/shmuelie/powershell-modules/issues/188); this module
currently exports only the four tool commands.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).
