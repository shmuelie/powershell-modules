# Shmuelie.Windows

Windows-only developer utilities for installed applications, Windows Terminal,
Windows Performance Recorder, and Windows service host processes.

**Version:** 0.1.0

## Install

```powershell
Install-PSResource Shmuelie.Windows
Import-Module Shmuelie.Windows
```

## Commands

| Area | Commands |
|---|---|
| Inventory | `Get-InstalledApplications` |
| Services | `Get-ServiceProcess` |
| Windows Terminal | `Get-WindowsTerminalSettings`, `Get-WindowsTerminalProfile` |
| Diagnostics | `Start-WindowsPerformanceRecorder`, `Stop-WindowsPerformanceRecorder` |

## Requirements

- PowerShell 7.4 or later.
- Windows. These commands report their platform requirements in command help.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).
