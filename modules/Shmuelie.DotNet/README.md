# Shmuelie.DotNet

User-local .NET SDK installation and canonical tool management for PowerShell on
Windows, Linux, and macOS.

**Version:** 0.1.0

## Install

```powershell
Install-PSResource Shmuelie.DotNet
Import-Module Shmuelie.DotNet
```

## Commands

| Command | Purpose |
|---|---|
| `Install-DotNetSdk` | Install an exact SDK or latest channel version side by side; optionally integrate with process or Windows user PATH |
| `Get-DotNetTool` | List global tools by default, or local manifest tools with `-Local`; filter package IDs with `-Name` wildcards |
| `Install-DotNetTool` | Install a global tool by name, skipping tools already installed |
| `Update-DotNetTool` | Update global/local tools by name or pipeline object |
| `Uninstall-DotNetTool` | Uninstall global tools by name or pipeline object |

`Get-DotNetTool` returns `DotNetTool` objects with `PackageId`, `Version`,
`Commands`, and `Global`. `Update-DotNetTool` returns `DotNetToolUpdateResult`
objects with `PackageId`, `Version`, and `Updated`. Tool install and uninstall emit
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

Utilities forwards to this module without duplicating tool logic. Install
`Shmuelie.DotNet` explicitly with `Install-PSResource Shmuelie.DotNet` before
using the Utilities wrappers. They load this dependency only when called and
do not change the caller's unqualified command resolution. Source checkouts
use the sibling DotNet manifest; installed Utilities discovers an already loaded
DotNet module or an installation on `$env:PSModulePath`. Missing dependencies
produce actionable errors rather than automatic installation. Neither module
eagerly imports the other. Wrapper help provides deprecation guidance; removal
is deferred until Utilities 1.0.

## SDK installation

```powershell
Install-DotNetSdk -Version 8.0.412
Install-DotNetSdk -Channel 10.0 -Quality GA -AddToProcessPath
Install-DotNetSdk -Channel 10.0.1xx -Quality preview -InstallDir ./preview-sdk
Install-DotNetSdk -Channel LTS -AddToUserPath -WhatIf # Windows only
```

`-Version` is an exact three-part SDK version, including prereleases; it cannot
be combined with `-Channel` or `-Quality`. `-Channel` defaults to `LTS`, and
accepts `STS`, `major.minor`, or a .NET 5+ `major.minor.Nxx` feature band.
`-Quality daily|preview|GA` requires a numeric .NET 5+ channel.
`-Architecture` defaults to the OS architecture (`auto`); supported selections
are `amd64`/`x64`, `x86`, `arm64`, `arm`, `s390x`, `ppc64le`, and `riscv64`,
subject to operating-system and SDK availability.

The default directory is `%LOCALAPPDATA%\Microsoft\dotnet` on Windows or
`$HOME/.dotnet` on Linux/macOS. `-InstallDir` overrides it (including relative
filesystem paths); `DOTNET_INSTALL_DIR` does not override this default.
Architectures must use separate directories: an existing host with a different
architecture is rejected. Exact-version detection is offline and scoped to the
selected host and SDK files. Channels resolve the latest version through the
installer's supported dry run each time, then skip installation if that exact
SDK is already present. Other installed SDK version directories are preserved.
An existing non-versioned host is always preserved with the installer's supported
skip option, including runtime-only installations. SDK feature-band version order
does **not** indicate the version of its bundled runtime or host.

The [.NET muxer loads the highest versioned hostfxr](https://github.com/dotnet/runtime/blob/main/docs/design/features/host-components.md);
new runtime and hostfxr directories can therefore be added without downgrading
the existing muxer. Before reporting success (including `AlreadyInstalled`), the
cmdlet runs the exact selected SDK via `dotnet exec <sdk>/dotnet.dll --version`
with the selected host, isolated CLI state, and telemetry disabled. This verifies
actual host/runtime compatibility rather than inferring it from SDK numbers.
`-WhatIf` does not execute this probe.

Preserving an existing muxer deliberately does not service that executable.
If it cannot launch the SDK, installation fails without PATH updates or a success
result; use a separate `-InstallDir` or explicitly service the existing host.
The SDK files already installed remain on disk, but a subsequent call repeats
the compatibility probe rather than claiming they are usable. Cross-architecture
installation also requires the requested host to be executable on the machine
(for example, appropriate OS emulation).

No PATH or `DOTNET_ROOT` changes occur by default. `-AddToProcessPath` prepends
only to the current process. `-AddToUserPath` independently updates Windows
persistent user PATH and the current process, preserving existing entries.
PATH comparison is case-insensitive on Windows and case-sensitive on Unix;
an existing matching entry is not added again. `-AddToUserPath` on Linux/macOS
throws **before any mutation**, even when combined with `-WhatIf`.

Downloads, SDK installation, user PATH, and process PATH each have their own
`ShouldProcess` decision. `-WhatIf` does not download or execute an installer.
Without resolution, its result has no resolved channel/version; an exact
requested version is already resolved. Declined installation does not add an
unavailable SDK to PATH. Existing SDKs can opt into PATH without reinstallation.

The result's type name is `DotNetSdkInstallResult`:

| Property | Meaning |
|---|---|
| `RequestedVersion`, `RequestedChannel`, `Quality` | Original selection; unused selection fields are empty |
| `ResolvedVersion`, `ResolvedChannel` | Exact SDK version and its numeric major.minor release, when resolved |
| `Architecture`, `InstallDir` | Normalized architecture and absolute installation directory |
| `Status` | `Installed`, `AlreadyInstalled`, or `Skipped` |
| `ProcessPathChanged`, `UserPathChanged` | Actual changes, not merely requested switches |

Uses Microsoft's [supported dotnet-install mechanism](https://learn.microsoft.com/dotnet/core/tools/dotnet-install-script).
Only canonical `https://dot.net/v1/dotnet-install.*` script/signature/key URLs
and their `builds.dotnet.microsoft.com/dotnet/scripts/v1/` redirects are allowed.
Windows validates Authenticode when a signature is present (unsigned canonical
scripts rely on HTTPS). Linux/macOS require `bash` and `gpg`, and verify Microsoft's
documented detached signature using a disposable isolated keyring. No GPG keys
are imported into the user's keyring and no prerequisite is auto-installed.

The current filesystem directory must be writable for disposable
`.dotnet-install-*` staging. Staged scripts, archives, extraction scratch, and
the keyring are cleaned on success or failure. Child processes receive discrete
arguments, never constructed shell commands, and are terminated on timeout
(30 minutes) or interruption. Download, signature, installer, post-install
validation, and environment read/write failures terminate locally without a
success result, even with the caller's error preference set to `Continue`. No
subsequent PATH target is changed after a failure. A failed
installation can leave partial files in `InstallDir`; PATH failures do not
roll back an already completed install or an earlier independently approved
PATH change.

As documented by Microsoft, the script does not install operating-system
dependencies, update Windows registry installation records, or configure
system-wide settings. Microsoft primarily recommends it for CI/non-admin
automation; normal development-machine setup may be better served by native
installers.

## Requirements

- PowerShell 7.4 or later.
- A .NET SDK providing `dotnet` on `PATH` when a tool command is used.
  Importing the module does not invoke `dotnet` or require Utilities.

- SDK installation requires HTTPS access to Microsoft's installer/SDK services.
  Linux/macOS also require native `bash` and `gpg` executables.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).
