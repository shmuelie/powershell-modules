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
| App Installer | `Get-AppInstallerApp`, `Update-AppInstallerApp` (compiled binary cmdlets, Windows-only) |
| Inventory | `Get-InstalledApplications` (compiled binary cmdlet) |
| Services | `Get-ServiceProcess` (compiled binary cmdlet) |
| Virtual drives | `Get-SubstDrive`, `New-SubstDrive`, `Remove-SubstDrive` (compiled binary cmdlets) |
| Windows Terminal | `Get-WindowsTerminalSettings`, `Get-WindowsTerminalProfile` |
| Diagnostics | `Start-WindowsPerformanceRecorder`, `Stop-WindowsPerformanceRecorder` |

## Requirements

- PowerShell 7.4 or later.
- Windows. These commands report their platform requirements in command help.

The `Get-AppInstallerApp` and `Update-AppInstallerApp` cmdlets are compiled into
a separate Windows-targeted assembly (`Shmuelie.Windows.AppInstaller.dll`, built
for `net8.0-windows10.0.19041.0`) because they call the WinRT
`Windows.Management.Deployment.PackageManager` API in-process. That assembly is
loaded only on Windows, so those two cmdlets are unavailable on other platforms;
the rest of the module still imports everywhere PowerShell 7 runs.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).
