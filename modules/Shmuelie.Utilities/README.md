# Shmuelie.Utilities

General developer utilities for PowerShell, .NET tools, Python packages, VS
Code, Windows Terminal, Windows services, installed applications, and WPR
tracing.

**Version:** 0.2.2

## Install

```powershell
Install-PSResource Shmuelie.Utilities
Import-Module Shmuelie.Utilities
```

## Commands

| Area | Commands |
|---|---|
| Core | `Test-IsElevated`, `New-GlobalConstant`, `New-PathVariable`, `Get-SessionTitle`, `Invoke-InLocation`, `Import-ModuleSafe`, `Repair-GlobalJson`, `Format-Duration` |
| Terminal | `Reset-TerminalModes` |
| Services | `Get-ServiceProcess` |
| .NET tools | `Get-DotNetTool`, `Install-DotNetTool`, `Update-DotNetTool`, `Uninstall-DotNetTool` |
| Python | `Get-PipPackages`, `Update-PipPackage`, `Get-UvPackages`, `Update-UvPackage` |
| VS Code | `Start-VsCode`, `Start-VsCodeChat`, `Get-VsCodeExtension`, `Install-VsCodeExtension`, `Uninstall-VsCodeExtension`, `Update-VsCodeExtension` |
| Windows Terminal | `Get-WindowsTerminalSettings`, `Get-WindowsTerminalProfile` |
| Diagnostics | `Start-WindowsPerformanceRecorder`, `Stop-WindowsPerformanceRecorder` |
| Inventory | `Get-InstalledApplications` |

## Highlights

- `Reset-TerminalModes` recovers a terminal left in a bad state (mouse tracking,
  alternate screen, bracketed paste, kitty keyboard flags) by a crashed TUI.
- `Get-ServiceProcess` resolves a Windows service to its hosting process, so it
  composes with `Stop-Process` and friends.
- `Get-InstalledApplications -Scope AllUsers` honors `-WhatIf` for offline user
  hive load/unload operations and reports registry mount failures.
- `Invoke-InLocation` runs a script block in a location and always returns, even
  on Ctrl+C.

## Examples

```powershell
if (Test-IsElevated) { 'admin' }
Get-DotNetTool | Update-DotNetTool
Get-Service Spooler | Get-ServiceProcess | Stop-Process
Reset-TerminalModes
```

## Requirements

- PowerShell 7.4 or later.
- Windows for the Windows-specific commands (services, Windows Terminal, WPR);
  these report their platform requirements in command help.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).
