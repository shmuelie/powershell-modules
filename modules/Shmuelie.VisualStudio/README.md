# Shmuelie.VisualStudio

Visual Studio developer shell helpers for PowerShell. The module discovers
installed Visual Studio years that have matching `Set-VS<year>` provider
commands and can launch a nested PowerShell session configured for one of those
environments.

**Version:** 0.1.0

## Install

```powershell
Install-PSResource Shmuelie.VisualStudio
```

## Commands

| Command | Purpose |
|---|---|
| `Get-InstalledVsVersion` | List installed Visual Studio years that can be loaded by a `Set-VS<year>` command. |
| `Start-DevShell` | Start a nested `pwsh` in the current window with the selected Visual Studio developer environment requested. |

## Notes

- These commands are Windows-only, but the module imports on any PowerShell 7.4+
  platform.
- `Get-InstalledVsVersion` uses `vswhere.exe` and maps the `installationVersion`
  major number to a Visual Studio year.
- `Start-DevShell` passes `VSDEV_VERSION`, `VSDEV_ARCH`, and `VSDEV_HOSTARCH` to
  the child session. A profile or provider module in that child session should
  load the matching `Set-VS<year>` command.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).
