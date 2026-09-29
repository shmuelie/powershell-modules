# Shmuelie.Node

Node.js, nvm-windows, npm package, and Azure DevOps npm credential helpers.

**Version:** 0.1.5

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

## npm package updates

`Update-NpmPackage -Name` accepts registry identifiers such as `typescript` and
`@scope/tool`, not version/tag specifications, paths, URLs, or command options.
Names are limited to 214 characters and the same ASCII identifier syntax used
by the package-management adapter. Whitespace, control characters, and shell
metacharacters are rejected before invoking npm, including `npm.cmd` on Windows.

Validation applies to direct calls and each property-bound pipeline record in
both local and global scope. Local updates retain `npm update <name>`; global
updates retain `npm install -g <name>@latest`, including scoped names. Results
remain `NpmUpdateResult` objects with `Name`, `Global`, and `Success`.
`-WhatIf` and `-Confirm` still control each valid update.

Pipelines remain streaming: an invalid later record does not roll back earlier
updates. Use `-ErrorAction Stop` to prevent subsequent records after an error.

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
