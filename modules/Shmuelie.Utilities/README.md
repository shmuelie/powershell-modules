# Shmuelie.Utilities

General developer utilities for PowerShell, .NET tools, Python packages, VS
Code, terminal recovery, and general developer workflows.

**Version:** 0.5.0

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
| .NET tools (compatibility wrappers until 1.0) | `Get-DotNetTool`, `Install-DotNetTool`, `Update-DotNetTool`, `Uninstall-DotNetTool` |
| Python | `Get-PipPackages`, `Update-PipPackage`, `Get-UvPackages`, `Update-UvPackage` |
| PowerShell resources | `Update-InstalledPSResource` |
| VS Code | `Start-VsCode`, `Start-VsCodeChat`, `Get-VsCodeExtension`, `Install-VsCodeExtension`, `Uninstall-VsCodeExtension`, `Update-VsCodeExtension` (bulk update, optional `-Profile`) |

## Highlights

The four .NET tool commands now have their canonical home in
[Shmuelie.DotNet](../Shmuelie.DotNet/README.md). Utilities retains thin forwarding
wrappers until Utilities 1.0, preserving parameter sets, streaming pipeline input,
output types, errors, and `-WhatIf`/`-Confirm`. Only the canonical command performs
confirmation; the wrappers do not prompt again.

Install the dependency explicitly before using these four wrappers:

```powershell
Install-PSResource Shmuelie.DotNet
Shmuelie.Utilities\Get-DotNetTool | Shmuelie.Utilities\Update-DotNetTool
```

Importing Utilities does not load DotNet. On first use, a wrapper uses the sibling
DotNet source manifest when working from a source checkout; otherwise it uses an
already loaded DotNet module or discovers it on `$env:PSModulePath`. Dependencies
are imported in a private scope without replacing the caller's unqualified
commands. Missing dependencies produce installation guidance, never an automatic
download or fallback implementation. Other Utilities commands need no DotNet module.

New scripts should use `Shmuelie.DotNet\Get-DotNetTool` and the other
module-qualified DotNet commands directly. Deprecation guidance is in each
wrapper's help, not repeated warnings or success-stream output.

- `Reset-TerminalModes` recovers a terminal left in a bad state (mouse tracking,
  alternate screen, bracketed paste, kitty keyboard flags) by a crashed TUI.
- `Invoke-InLocation` runs a script block in a location and always returns, even
  on Ctrl+C.
- Tool helpers list and update .NET global tools, Python packages, uv tools, VS
  Code extensions, and PowerShell resources deployed with `Save-PSResource` to
  caller-supplied module paths (`Update-InstalledPSResource`). The PowerShell
  resource updater honors recorded repository provenance, supports explicit
  repository override, and can include/exclude module names with wildcards.
  If recorded source provenance cannot be matched to a configured repository,
  the module is skipped rather than silently falling back to PSGallery.
  Prerelease installations retain their full version from `PSGetModuleInfo.xml`
  and include prereleases when checking for updates; stable installations query
  stable releases only. Version comparison respects numeric prerelease identifiers
  (`beta.10` is newer than `beta.2`) and promotion to a stable release with the same
  numeric version. The exact selected version is saved to the supplied path.
  A metadata-less newer version can inherit older repository provenance, but
  never the older version's prerelease state.

## Examples

```powershell
if (Test-IsElevated) { 'admin' }
Get-DotNetTool | Update-DotNetTool
Update-InstalledPSResource -Path (Join-Path $HOME 'PowerShellModules')
Update-InstalledPSResource -Path (($env:PSModulePath -split [IO.Path]::PathSeparator)[0]) -Name 'Shmuelie.*' -Exclude '*.Local'
Reset-TerminalModes
Update-VsCodeExtension -Profile 'Backend' -WhatIf
```

## Requirements

- PowerShell 7.4 or later.
- `Shmuelie.DotNet` and a .NET SDK on `PATH` when using the four .NET tool wrappers.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).
