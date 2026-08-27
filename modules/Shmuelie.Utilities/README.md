# Shmuelie.Utilities

General developer utilities for PowerShell, .NET tools, Python packages, VS
Code, terminal recovery, and general developer workflows.

**Version:** 0.3.1

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
| .NET tools | `Get-DotNetTool`, `Install-DotNetTool`, `Update-DotNetTool`, `Uninstall-DotNetTool` |
| Python | `Get-PipPackages`, `Update-PipPackage`, `Get-UvPackages`, `Update-UvPackage` |
| PowerShell resources | `Update-InstalledPSResource` |
| VS Code | `Start-VsCode`, `Start-VsCodeChat`, `Get-VsCodeExtension`, `Install-VsCodeExtension`, `Uninstall-VsCodeExtension`, `Update-VsCodeExtension` |

## Highlights

- `Reset-TerminalModes` recovers a terminal left in a bad state (mouse tracking,
  alternate screen, bracketed paste, kitty keyboard flags) by a crashed TUI.
- `Invoke-InLocation` runs a script block in a location and always returns, even
  on Ctrl+C.
- Tool helpers list and update .NET global tools, Python packages, uv tools, VS
  Code extensions, and PowerShell resources deployed with `Save-PSResource` to
  caller-supplied module paths (`Update-InstalledPSResource`).

## Examples

```powershell
if (Test-IsElevated) { 'admin' }
Get-DotNetTool | Update-DotNetTool
Update-InstalledPSResource -Path (Join-Path $HOME 'PowerShellModules')
Reset-TerminalModes
```

## Requirements

- PowerShell 7.4 or later.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).
