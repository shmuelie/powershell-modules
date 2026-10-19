# Shmuelie.VisualStudio

Visual Studio discovery, current-session initialization, MSBuild resolution, and
nested developer shells for PowerShell. Uses Visual Studio's own discovery and
initialization tools; **PSVSEnv and third-party provider commands are not required**.

**Version:** 0.2.0

## Install

```powershell
Install-PSResource Shmuelie.VisualStudio
```

## Commands

| Command | Purpose |
|---|---|
| `Get-InstalledVsVersion` | List eligible installed Visual Studio years without a provider dependency. |
| `Resolve-MSBuild` | Resolve the newest compatible Visual Studio `MSBuild.exe`, optionally by year/version and executable architecture. |
| `Set-VS2017` | Initialize Visual Studio 2017 in the current PowerShell session. |
| `Set-VS2019` | Initialize Visual Studio 2019 in the current PowerShell session. |
| `Set-VS2022` | Initialize Visual Studio 2022 in the current PowerShell session. |
| `Set-VS2026` | Initialize Visual Studio 2026 in the current PowerShell session. |
| `Start-DevShell` | Start and initialize a nested developer `pwsh` inline, after its normal profiles run. |

## Initialize the current session

```powershell
Import-Module Shmuelie.VisualStudio
Shmuelie.VisualStudio\Set-VS2022 -Architecture amd64 -HostArchitecture amd64

# The short parameter names also work:
Set-VS2026 -Arch arm64 -HostArch amd64
Set-VS2019 -WhatIf
```

The year commands select the newest complete, launchable release installation
for that year, including standalone Build Tools, with `Common7\Tools\VsDevCmd.bat`.
Preview installations are excluded. Numeric installation versions sort newest
first, with installation path ascending as the tie-breaker. Discovery does not
require a particular workload; initialization fails if the selected installation
does not support the requested tools or architecture. No architecture fallback
occurs.

`-Architecture` (`-Arch`) accepts `x86`, `amd64`, `arm`, or `arm64`;
`-HostArchitecture` (`-HostArch`) accepts `x86`, `amd64`, or `arm64`.
The year commands retain PSVSEnv's **x86 target and host defaults**.
`Start-DevShell` retains its **amd64 target and host defaults**.
Each selected Visual Studio version must support the requested combination.

Initialization uses an isolated, bounded helper process and applies its validated
environment only after success. Values containing equals signs, newlines, or
Unicode are preserved. Working directory and unrelated environment variables are
preserved. Repeating an exactly matching installation and architecture is a no-op.
If a different or incomplete environment is active, initialization fails: use
`Start-DevShell` for a fresh session rather than switching or stacking toolsets.
The commands support `-WhatIf` and `-Confirm`.

Installation and PowerShell executable paths must be fully qualified and cannot
contain cmd.exe expansion/control characters such as `%`, `!`, `^`, `&`, `|`,
`<`, `>`, or a quote. Unsupported paths fail explicitly instead of being passed
unsafely to the batch initializer. Normal spaces and parentheses are supported.

## Nested developer shells and profile migration

```powershell
Start-DevShell 2022
Start-DevShell -Version 2026 -Arch arm64 -HostArch amd64
```

`Start-DevShell` starts `pwsh` in the current window and waits for it to exit.
The child receives a clean login PATH and restored or cleared inherited toolset
variables; the parent environment is not modified. Normal PowerShell profiles run
first. A post-profile bootstrap imports this module from the same installation,
restores the caller's filesystem directory, and initializes the exact selected
Visual Studio installation before interactive use.

Custom profile initialization is optional. To migrate a profile that previously
imported PSVSEnv, remove that import and call the replacement commands instead.
Use module-qualified calls if another module exports the same command names.
A standalone profile can simply call:

```powershell
Import-Module Shmuelie.VisualStudio
Shmuelie.VisualStudio\Set-VS2026 -Arch amd64 -HostArch amd64
```

If the profile is also used by `Start-DevShell`, honor the child's requested year
and architectures rather than hardcoding a conflicting toolset:

```powershell
Import-Module Shmuelie.VisualStudio
$year = if ($env:VSDEV_VERSION) { $env:VSDEV_VERSION } else { '2026' }
if ($year -notin @('2017', '2019', '2022', '2026')) {
    throw "Unsupported requested Visual Studio year: $year"
}
$arch = if ($env:VSDEV_ARCH) { $env:VSDEV_ARCH } else { 'amd64' }
$hostArch = if ($env:VSDEV_HOSTARCH) { $env:VSDEV_HOSTARCH } else { 'amd64' }
& "Shmuelie.VisualStudio\Set-VS$year" -Arch $arch -HostArch $hostArch
```

The bootstrap recognizes an exactly matching profile-initialized environment
using installation path, version, and target/host architectures, and does not
initialize it again. Conflicting profile initialization fails clearly rather
than selecting another toolset. Arbitrary legacy profile code cannot be prevented
from reinitializing tools: migrate unconditional PSVSEnv calls explicitly.
Bootstrap failures exit unsuccessfully instead of opening an uninitialized
interactive shell.

Visual Studio 2010-2015, WAIK, and PSVSEnv's command aliases are not provided.
This module exports functions, not command aliases. It does not install providers
or change execution policies.

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
- `Get-InstalledVsVersion` maps `vswhere.exe` installation versions to sorted,
  unique years: 2017, 2019, 2022, and 2026. Missing tooling, failed discovery, and
  malformed metadata produce terminating errors; no eligible installations
  produce no years.
- Initialization uses the supported
  [Visual Studio Developer Command Prompt](https://learn.microsoft.com/visualstudio/ide/reference/command-prompt-powershell)
  entry point for all supported years, including VS 2017. `Resolve-MSBuild`
  remains independent and does not initialize an environment.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).
