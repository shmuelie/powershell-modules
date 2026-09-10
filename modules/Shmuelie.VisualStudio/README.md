# Shmuelie.VisualStudio

Visual Studio discovery, MSBuild resolution, and developer shell helpers for PowerShell. The module discovers
installed Visual Studio years that have matching `Set-VS<year>` provider
commands and can launch a nested PowerShell session configured for one of those
environments. It also resolves standalone Visual Studio MSBuild without a provider.

**Version:** 0.2.0

## Install

```powershell
Install-PSResource Shmuelie.VisualStudio
```

## Commands

| Command | Purpose |
|---|---|
| `Get-InstalledVsVersion` | List installed Visual Studio years that can be loaded by a `Set-VS<year>` command. |
| `Resolve-MSBuild` | Resolve the newest compatible Visual Studio `MSBuild.exe`, optionally by year/version and executable architecture. |
| `Start-DevShell` | Start a nested `pwsh` in the current window with the selected Visual Studio developer environment requested. |

## Resolve MSBuild

```powershell
$msbuild = Resolve-MSBuild -Version 2022 -Architecture x64
$msbuild.Path
& $msbuild.Path .\App.sln -restore

# A numeric Visual Studio version prefix and a path-only result:
& (Resolve-MSBuild -Version 18 -PathOnly) .\App.sln -t:Build
```

This resolves **Visual Studio's MSBuild.exe**, not `dotnet msbuild`. The latter
cannot load every Visual Studio workload or packaging target. Resolution does
not prove that a project's workloads or SDKs are installed and does not run
MSBuild, launch a developer shell, install anything, or change `PATH`.

The default is the newest complete, launchable release installation containing
the MSBuild component and an executable for the native **OS** architecture.
Standalone Build Tools are included; preview installations are excluded.
Installations are sorted by numeric `installationVersion` descending, then
installation path ascending to break ties. An installation missing the requested
executable is skipped. No fallback to another architecture occurs.

- `-Version` accepts 2017, 2019, 2022, or 2026, or a numeric Visual Studio
  installation version prefix such as `17`, `17.10`, or `18.0` (not ranges).
- `-Architecture` (parameter alias `-Arch`) accepts `x86`, `x64`, `amd64`
  (normalized to `x64`), or `arm64`. This selects the MSBuild process, not
  the project's target architecture.
- The default `MSBuildInstallation` typed object contains `Path`,
  `VisualStudioVersion` (`System.Version`), `VisualStudioYear` (integer, or
  null for an unrecognized future major), `InstallationPath`, and `Architecture`.
  `-PathOnly` returns a single path string.

Discovery uses the Visual Studio Installer's `vswhere.exe` and supports Visual
Studio 2017 and later. Missing discovery tooling, invalid discovery output, and
no compatible installation produce terminating errors. No `Set-VS<year>` provider
is required. See Microsoft's [discovery documentation](https://learn.microsoft.com/visualstudio/install/tools-for-managing-visual-studio-instances)
and [MSBuild setup action](https://github.com/microsoft/setup-msbuild).

## Notes

- These commands are Windows-only, but the module imports on any PowerShell 7.4+
  platform.
- `Get-InstalledVsVersion` uses `vswhere.exe` and maps the `installationVersion`
  major number to a Visual Studio year.
- `Start-DevShell` passes `VSDEV_VERSION`, `VSDEV_ARCH`, and `VSDEV_HOSTARCH` to
  the child session. A profile or provider module in that child session should
  load the matching `Set-VS<year>` command. It supports `-WhatIf` and `-Confirm`
  so the nested process launch can be previewed or confirmed.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).
