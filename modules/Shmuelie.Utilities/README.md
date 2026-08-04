# Shmuelie.Utilities

General developer utilities for PowerShell, .NET tools, Python packages, VS
Code, Windows Terminal, Windows services, installed applications, and WPR
tracing.

**Version:** 0.1.0 · [Changelog](CHANGELOG.md) · Part of [`shmuelie/powershell-modules`](../../README.md)

## Install

```powershell
Install-PSResource Shmuelie.Utilities
Import-Module Shmuelie.Utilities
```

## Commands

| Area | Commands |
|---|---|
| Core | `Test-IsElevated`, `New-GlobalConstant`, `New-PathVariable`, `Get-SessionTitle`, `Invoke-InLocation`, `Import-ModuleSafe`, `Repair-GlobalJson` |
| Terminal | `Reset-TerminalModes` |
| Services | `Get-ServiceProcess` |
| .NET tools | `Get-DotNetTool`, `Install-DotNetTool`, `Update-DotNetTool`, `Uninstall-DotNetTool` |
| Python | `Get-PipPackages`, `Update-PipPackage`, `Get-UvPackages`, `Update-UvPackage` |
| VS Code | `Start-VsCode`, `Start-VsCodeChat`, `Get-VsCodeExtension`, `Install-VsCodeExtension`, `Uninstall-VsCodeExtension`, `Update-VsCodeExtension` |
| Windows Terminal | `Get-WindowsTerminalSettings`, `Get-WindowsTerminalProfile` |
| Diagnostics | `Start-WindowsPerformanceRecorder`, `Stop-WindowsPerformanceRecorder` |
| Inventory | `Get-InstalledApplications` |

Aliases: `code` (Start-VsCode), `Get-GlobalDotNetTools` (Get-DotNetTool).

## Examples

```powershell
if (Test-IsElevated) { 'admin' }
Get-DotNetTool | Update-DotNetTool
Get-Service Spooler | Get-ServiceProcess | Stop-Process
Reset-TerminalModes   # recover a terminal left in a bad state by a crashed TUI
```

## Requirements

- PowerShell 7.4 or later
- Windows for Windows-specific commands (services, Terminal, WPR); these report
  their platform requirements in command help.
