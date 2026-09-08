# Changelog

All notable changes to this module are documented here.
Versions change only when a release is cut; pending work lives under [Unreleased].

## [Unreleased]

### Added

- Establish `Shmuelie.DotNet` as the canonical home for `Get-DotNetTool`,
  `Install-DotNetTool`, `Update-DotNetTool`, and `Uninstall-DotNetTool`, preserving
  existing parameters, pipeline binding, output types, and `ShouldProcess`.
- Extract the private location helper so discovery works without loading
  `Shmuelie.Utilities`; importing the module runs no external tools.
- Retain Utilities implementations temporarily for the additive #186/#187
  migration. Replace them with compatibility wrappers before the M2 release;
  removal of Utilities exports remains deferred until Utilities 1.0.
