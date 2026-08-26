# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/).
Versions change only when a release is cut; unreleased work stays under
`[Unreleased]`.

## [Unreleased]

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
