# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/).
Versions change only when a release is cut; unreleased work stays under
`[Unreleased]`.

## [Unreleased]

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
