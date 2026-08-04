# Shmuelie.Node

Node.js, nvm-windows, npm package, and Azure DevOps npm credential helpers.

**Version:** 0.1.0

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
| nvm control | `Enable-Nvm`, `Disable-Nvm`, `Get-NvmRoot`, `Get-NvmVersion`, `Test-NvmInstalled` |
| nvm configuration | `Set-NvmProxy`, `Set-NvmNodeMirror`, `Set-NvmNpmMirror` |
| npm packages | `Get-NpmPackage`, `Update-NpmPackage` |
| ADO credentials | `Update-AdoNpmToken` |

## Azure DevOps npm credentials

`Update-AdoNpmToken` runs the `@microsoft/artifacts-npm-credprovider` against a
temporary `.npmrc` to obtain a fresh token. It requires an **explicit** Azure
DevOps feed URL and stores the token in `ADO_NPM_TOKEN` unless `-Name` supplies
a different environment variable name. It hardcodes no feed.

## Examples

```powershell
Install-NodeVersion -Version 22.11.0
Set-NodeVersion -Latest
Get-NpmPackage -Global -Outdated | Update-NpmPackage -Global
Update-AdoNpmToken -Feed 'https://pkgs.dev.azure.com/org/_packaging/feed/npm/registry/'
```

## Requirements

- PowerShell 7.4 or later.
- Node.js and nvm-windows for the version-management commands.
- `@microsoft/artifacts-npm-credprovider` for `Update-AdoNpmToken`.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).
