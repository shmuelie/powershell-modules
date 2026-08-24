# Shmuelie.Dsc

Class-based [DSC v3](https://learn.microsoft.com/powershell/dsc/overview)
resources for developer machine setup. Each resource is a PowerShell class
implementing `Get()`, `Test()`, and `Set()`, exported via
`DscResourcesToExport`. The Copilot and uv resources depend only on the public
`copilot` and `uv` CLIs; the others use built-in PowerShell only.

**Version:** 0.1.0

## Install

```powershell
Install-PSResource Shmuelie.Dsc
```

## Resources

| Resource | Key | Purpose |
|---|---|---|
| `SavePSResource` | `Name` | Save a PowerShell module to a local path via `Save-PSResource` (defaults to `PSGallery`). |
| `SymbolicLink` | `Path` | Create/verify a symbolic link to a target path. |
| `CopilotPlugin` | `Source` | Install a GitHub Copilot CLI plugin (`owner/repo`, `plugin@marketplace`, or URL). |
| `CopilotMarketplace` | `Name` | Register a GitHub Copilot CLI plugin marketplace (`owner/repo`). |
| `UvTool` | `Name` | Install a Python tool via `uv tool install`. |

## Usage

These are DSC v3 resources, addressed as `Shmuelie.Dsc/<ResourceName>`:

```yaml
- name: Save Pester
  type: Shmuelie.Dsc/SavePSResource
  properties:
    Name: Pester
    Path: C:\Modules

- name: Symlink .gitconfig
  type: Shmuelie.Dsc/SymbolicLink
  properties:
    Path: C:\Users\me\.gitconfig
    Target: C:\dotfiles\.gitconfig

- name: Install a Copilot plugin
  type: Shmuelie.Dsc/CopilotPlugin
  properties:
    Source: owner/repo

- name: Register a Copilot marketplace
  type: Shmuelie.Dsc/CopilotMarketplace
  properties:
    Name: dotnet-skills
    Repository: dotnet/skills

- name: Install a uv tool
  type: Shmuelie.Dsc/UvTool
  properties:
    Name: fast-agent-mcp
```

## Notes

- **Idempotency / presence checks.** `CopilotPlugin`, `CopilotMarketplace`, and
  `UvTool` determine "already installed" by a whole-token match against the
  relevant CLI list output (color/ANSI is stripped first), so a desired name
  that is a substring of another entry does not produce a false positive.
- **`CopilotPlugin` URL sources.** The installed plugin name is derived from
  `Source` for `owner/repo`, `plugin@marketplace`, and `market:plugin@marketplace`
  forms. For a URL source the name cannot be derived reliably — set the optional
  `Name` property so the presence check matches, otherwise the plugin is
  re-installed on every apply.
- **`SavePSResource` version.** Set the optional `Version` property to make the
  presence check (and the save) version-specific.
- **Shell-safe arguments.** Values passed to the `copilot`/`uv` CLIs are
  validated to reject characters that Windows would re-parse when the CLI
  resolves to a `.cmd`/`.bat` shim.

## Requirements

- PowerShell 7.4 or later.
- `SavePSResource` requires `Microsoft.PowerShell.PSResourceGet` (`Save-PSResource`).
- `CopilotPlugin` / `CopilotMarketplace` require the GitHub Copilot CLI (`copilot`) on `PATH`.
- `UvTool` requires the `uv` CLI on `PATH`.
- `SymbolicLink` on Windows requires Developer Mode or an elevated session.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).
