# Shmuelie.Node

Node.js, nvm-windows, npm package, and Azure DevOps npm credential helpers.

**Version:** 0.1.2

## Install

```powershell
Install-PSResource Shmuelie.Node
Import-Module Shmuelie.Node
```

## Commands

| Area | Commands |
|---|---|
| Node versions (Windows/nvm-windows) | `Get-NodeVersion`, `Install-NodeVersion`, `Uninstall-NodeVersion`, `Set-NodeVersion` |
| Node aliases (Windows/nvm-windows) | `Set-NodeAlias`, `Remove-NodeAlias` |
| nvm control (Windows/nvm-windows) | `Enable-Nvm`, `Disable-Nvm`, `Get-NvmRoot`, `Get-NvmVersion`, `Test-NvmInstalled` |
| nvm configuration (Windows/nvm-windows) | `Set-NvmProxy`, `Set-NvmNodeMirror`, `Set-NvmNpmMirror` |
| npm packages | `Get-NpmPackage`, `Update-NpmPackage` |
| ADO credentials | `Update-AdoNpmToken` |

## nvm-windows commands

The Node version, Node alias, and nvm commands wrap nvm-windows and are supported only on Windows. On non-Windows platforms, they fail before invoking `nvm` with a clear Windows-only error. The npm package and Azure DevOps credential helpers remain portable.

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
Get-NvmRoot -Path 'C:\nvm' -WhatIf
```

## Requirements

- PowerShell 7.4 or later.
- Node.js and nvm-windows for the version-management commands.
- `@microsoft/artifacts-npm-credprovider` for `Update-AdoNpmToken`.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).
