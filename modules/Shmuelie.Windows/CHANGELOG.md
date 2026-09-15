# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/).
Versions change only when a release is cut; unreleased work stays under
`[Unreleased]`.

## [Unreleased]

### Added
- Experimental compiled `Wait-AppInstallItem` for one exact retained caller item,
  using only payload-free manager-event invalidation, an explicit context and a
  mandatory 1-30 second local budget. Captures are execution-thread-only, bounded
  to 64 observations and returned after cleanup; local cancellation never cancels
  installation. Observation leases preserve exact identities without altering
  inventory pruning/search merging and defer disposed-context manager release
  until unsubscribe completes. Primary and cleanup failures remain explicit;
  group completion, individual-item events, broader scope and release remain
  gated. The private-capability restriction and #233 support hold remain in force.
- Experimental compiled `Request-AppInstallUpdateSearch` for only caller-scoped
  all-app searches through an explicit context and caller-provided correlation
  inputs. Both automatic download/install and forced restart are fixed false;
  discovered updates can still be queued paused, so high-impact `ShouldProcess`
  protects every submission and `-WhatIf` performs no native calls. Immutable
  request/item identities distinguish acceptance, search completion and install
  status; failures preserve original errors and stopping only ends local waiting.
  Default request display omits native correlation strings and raw payloads;
  explicit property inspection and JSON retain the original values.
  Search identities merge without pruning unrelated inventory. Per-app, ForUser,
  custom catalog and automatic-action variants remain gated; empirical access
  is not an official third-party support guarantee.
- Experimental compiled `Get-AppInstallItem` for caller-scoped queue/current
  status snapshots through an explicit AppInstall context, with exact filters,
  optional grouped children, bounded local identity tracking, explicit member
  availability and preserved native errors. No search, install, settings,
  entitlement, queue-control or ForUser operation is performed.
- Experimental compiled `Get-AppInstallSettings` for the three approved
  caller-context getters, using an explicit lazy context. The default reads
  only device auto-update and calling-process all-user privilege observations;
  acquisition identity requires an exact opt-in property selector. Immutable
  snapshots retain scope, requested/read properties, raw enum codes and
  unknown/unavailable/false distinctions. Failures preserve original errors
  without rendering raw native diagnostics or returning a partial snapshot.
  No settings mutation, identity change or installation action is provided.
- Experimental compiled `New-AppInstallContext` factory with explicit lazy
  manager ownership, caller scope, runspace-bound lifetime and deterministic
  disposal. Creating a context performs no native activation or search. The
  documented private-capability restriction remains applicable; observed
  runtime access is not an official third-party support guarantee.
- Immutable AppInstall identity/group, status, request, entitlement and error
  contracts with explicit unknown/unavailable observations. Native HRESULTs,
  original exceptions, local/native cancellation and secondary cleanup errors
  remain distinct; no install completion is inferred from request completion.
- A complete AppInstallManager API/options matrix documenting the deferred,
  gated and retired families without exporting their commands.

## [0.2.0] - 2026-09-11

### Added
- Opt-in `Update-AppInstallerApp -PassThru` typed per-package update-check
  request completion. Default calls remain void, and unmatched, skipped, or
  failed requests never emit completion. Results do not claim installation
  success or version changes.

## [0.1.2] - 2026-08-27

### Fixed
- `Get-InstalledApplications -AllUsers`: after a successful `RegLoadKey`, the
  `RegUnLoadKey` cleanup in `finally` was gated behind a second `ShouldProcess`
  call, allowing a user to decline the unload and leave `HKU\temp` mounted.
  Unload is now unconditional once the load succeeds. `-WhatIf` is unaffected
  because the initial load is declined and `finally` is never entered.
  Closes #149.

## [0.1.1] - 2026-08-26

### Changed
- Converted `Get-InstalledApplications` from a script function into a compiled
  C# binary cmdlet (`Shmuelie.Windows.Cmdlets.dll`). It now enumerates the
  uninstall registry keys through `Microsoft.Win32.RegistryKey` and mounts
  offline user hives with the Win32 `RegLoadKey` / `RegUnLoadKey` APIs (instead
  of shelling out to `reg.exe`), guaranteeing each hive is unmounted even when a
  read fails. Public behavior — the `-Scope` values, emitted object shape, and
  `-WhatIf` preview of the mount/unmount operations — is unchanged.
- Converted `Get-ServiceProcess` from a script function into a compiled C#
  binary cmdlet (`Shmuelie.Windows.Cmdlets.dll`). The hosting process id and
  status are now resolved through the Win32 Service Control Manager APIs
  (`OpenSCManager` / `OpenService` / `QueryServiceStatusEx`), the binary command
  line through `QueryServiceConfig`, and `-PerService` reconfigures a service to
  its own process through `ChangeServiceConfig` instead of shelling out to
  `sc.exe`. Public behavior and output shape are unchanged.
- Converted `Get-SubstDrive`, `New-SubstDrive`, and `Remove-SubstDrive` from
  script functions into compiled C# binary cmdlets
  (`Shmuelie.Windows.Cmdlets.dll`) backed by the Win32 `DefineDosDevice` /
  `QueryDosDevice` APIs instead of shelling out to `subst.exe`. Public behavior
  is unchanged.
- Converted `Get-AppInstallerApp` and `Update-AppInstallerApp` from script
  functions into compiled C# binary cmdlets. They now read App Installer
  metadata and trigger updates through the in-process WinRT
  `Windows.Management.Deployment.PackageManager` API
  (`FindPackagesForUser` / `GetAppInstallerInfo` /
  `AddPackageByAppInstallerFileAsync`), removing the shell-out to Windows
  PowerShell 5.1. Because that API requires a Windows-targeted assembly
  (`Shmuelie.Windows.AppInstaller.dll`, `net8.0-windows10.0.19041.0`) that
  cannot load on Linux/macOS, these two cmdlets are now available only on
  Windows; the rest of the module still imports on any platform. The emitted
  object shape (`Shmuelie.Windows.AppInstallerApplication`) and the update
  matching / update-all / `-WhatIf` behavior are unchanged.

## [0.1.0] - 2026-08-25

### Added
- Added `Get-AppInstallerApp` and `Update-AppInstallerApp` for enumerating and triggering updates for apps installed from `.appinstaller` files.
- Added `Get-SubstDrive`, `New-SubstDrive`, and `Remove-SubstDrive` for
  managing Windows subst virtual drive mappings.
- Initial `Shmuelie.Windows` module containing the Windows-only
  `Get-InstalledApplications`, `Get-ServiceProcess`,
  `Get-WindowsTerminalSettings`, `Get-WindowsTerminalProfile`,
  `Start-WindowsPerformanceRecorder`, and `Stop-WindowsPerformanceRecorder`
  cmdlets moved from `Shmuelie.Utilities` with behavior unchanged.
