# Changelog

All notable changes to this module are documented here.
Versions change only when a release is cut; pending work lives under [Unreleased].

## [Unreleased]

### Added

- `Install-DotNetSdk` installs exact or channel-selected SDKs side by side using
  Microsoft's canonical installer, detects existing SDKs, validates available
  signatures, and cleans staging content on success and failure.
- Explicit process PATH integration on every platform and persistent user PATH
  integration on Windows, with independent `ShouldProcess` decisions and typed
  installation results reporting actual PATH changes. Neither is on by default.
- Preserve existing non-versioned hosts across SDK feature bands and runtime-only
  installs; verify the exact SDK's host/runtime compatibility before reporting
  success. Environment failures stop the command even under `Continue`.

## [0.1.0] - 2026-09-08

### Added

- Establish `Shmuelie.DotNet` as the canonical home for `Get-DotNetTool`,
  `Install-DotNetTool`, `Update-DotNetTool`, and `Uninstall-DotNetTool`, preserving
  existing parameters, pipeline binding, output types, and `ShouldProcess`.
- Extract the private location helper so discovery works without loading
  `Shmuelie.Utilities`; importing the module runs no external tools.
- Utilities forwards its four compatibility commands to this module lazily;
  removal of those entry points remains deferred until Utilities 1.0.
