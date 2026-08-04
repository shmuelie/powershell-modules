# Shmuelie.Node

Node.js, nvm-windows, npm package, and Azure DevOps npm credential helpers.

**Version:** 0.1.0 · [Changelog](CHANGELOG.md) · Part of [`shmuelie/powershell-modules`](../../README.md)

## Install

```powershell
Install-PSResource Shmuelie.Node
Import-Module Shmuelie.Node
```

## Commands

| Area | Commands |
|---|---|
| Node versions | `Get-NodeVersion`, `Install-NodeVersion`, `Uninstall-NodeVersion`, `Set-NodeVersion` |
| Node aliases | `Set-NodeAlias`, `Remove-NodeAlias` |
| nvm control | `Enable-Nvm`, `Disable-Nvm`, `Get-NvmRoot`, `Get-NvmVersion`, `Test-NvmInstalled`, `Set-NvmProxy`, `Set-NvmNodeMirror`, `Set-NvmNpmMirror` |
| npm packages | `Get-NpmPackage`, `Update-NpmPackage` |
| ADO credentials | `Update-AdoNpmToken` |

## Examples

```powershell
Install-NodeVersion -Version 22.11.0
Set-NodeVersion -Latest
Get-NpmPackage -Global -Outdated | Update-NpmPackage -Global
Update-AdoNpmToken -Feed 'https://pkgs.dev.azure.com/org/_packaging/feed/npm/registry/'
```

`Update-AdoNpmToken` requires an explicit Azure DevOps feed URL and stores the
refreshed token in `ADO_NPM_TOKEN` unless `-Name` is provided. It does not
hardcode any feed.

## Requirements

- PowerShell 7.4 or later
- Node.js and nvm-windows for version-management commands
- `@microsoft/artifacts-npm-credprovider` for `Update-AdoNpmToken`
