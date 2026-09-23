# Shmuelie.Dsc

Class-based [DSC v3](https://learn.microsoft.com/powershell/dsc/overview)
resources for developer machine setup. Each resource is a PowerShell class
implementing `Get()`, `Test()`, and `Set()`, exported via
`DscResourcesToExport`. The Copilot and uv resources depend only on the public
`copilot` and `uv` CLIs; the others use built-in PowerShell only.

**Version:** 0.1.2

## Install

```powershell
Install-PSResource Shmuelie.Dsc
```

## Resources

| Resource | Key | Purpose |
|---|---|---|
| `SavePSResource` | `Name` | Check a saved module's manifest/layout and save missing content via `Save-PSResource` (defaults to `PSGallery`). |
| `SymbolicLink` | `Path` | Create/verify a symbolic link to a target path. |
| `CopilotPlugin` | `Source` | Install a GitHub Copilot CLI plugin (`owner/repo`, `plugin@marketplace`, or URL). |
| `CopilotMarketplace` | `Name` | Register a GitHub Copilot CLI plugin marketplace from `Repository` (`owner/repo`, URL, or local path), using its manifest name as the identity. |
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
    Name: team-tools # The name declared in the source's marketplace.json
    Repository: example-org/plugin-catalog

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
  List output is parsed only after a confirmed zero exit code. A failed list
  command or unknown completion raises a terminating error from both `Test()`
  and `Get()` instead of reporting installed or absent, even if error text
  contains the requested name. The underlying exception retains the CLI output
  and exit status in `Data['Output']` and `Data['ExitCode']`; an unknown exit is
  not success.
  Native exit tracking is reset per invocation and the caller's previous value
  and color environment are restored. These checks do not install anything.
- **`CopilotMarketplace` source and identity.** `Set()` passes `Repository`
  unchanged as the single source in `copilot plugin marketplace add <source>`.
  `Name` must match the actual name declared by that source's `marketplace.json`
  and shown in the CLI's marketplace list, even when it differs from the
  repository or directory name. The CLI does not accept a custom local name;
  `Name` is the key for `Test()` and `Get()`, not an argument to registration.
  For the example above, the manifest must declare `"name": "team-tools"`.
  With that identity configured, registration makes the presence check pass.
  A different `Name` leaves `Test()` and `Get().Installed` false after
  registration: correct the configured identity rather than reapplying to
  rename it. Presence does not verify repository provenance or replace the
  source of an existing same-named registration. See the public
  [CLI plugin reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-plugin-reference#cli-commands).
- **`CopilotPlugin` URL sources.** The installed plugin name is derived from
  `Source` for `owner/repo`, `plugin@marketplace`, and `market:plugin@marketplace`
  forms. For a URL source the name cannot be derived reliably — set the optional
  `Name` property so the presence check matches, otherwise the plugin is
  re-installed on every apply.
- **`SavePSResource` presence.** Empty directories do not count as saved modules.
  `Test()` and `Get().Installed` require a readable `<Name>.psd1` with a valid
  `ModuleVersion`, plus any declared root module and local startup files
  (`ScriptsToProcess`, `TypesToProcess`, `FormatsToProcess`). Root modules may be
  script or binary files; a data-only manifest need not declare a root module.
  Explicit local file references in `NestedModules` and `RequiredAssemblies`
  must also exist; bare dependency names are not resolved.
  Files are checked literally and must be inside the candidate module directory.
  Without `Version`, either a flat `<Path>/<Name>` layout or at least one
  version subfolder whose manifest version matches its directory is accepted.
- **`SavePSResource` version.** The optional `Version` selects only that exact
  subfolder and requires its manifest version to match; it does not resolve
  version ranges. The value is passed unchanged to `Save-PSResource`.
  Numeric comparison treats omitted build/revision components as zero, so
  `1.0`, `1.0.0`, and `1.0.0.0` are equivalent metadata without changing which
  directory is selected. Use a string for `ModuleVersion`; version casts are
  not permitted by PowerShell's restricted manifest language.
- **`SavePSResource` check limits.** Presence checks never import candidate module
  code, resolve dependencies, contact repositories, or verify runtime/OS
  compatibility or binary contents. Repository provenance is not a presence
  requirement. These are direct file-presence checks, not recursive validation
  of nested manifests or their dependencies. `Set()` retains
  `-SkipDependencyCheck` and the configured `Path` and `Repository`; this is
  saved-content evidence, not a full import test.
- **Shell-safe arguments.** Values passed to the `copilot`/`uv` CLIs are
  validated to reject characters that Windows would re-parse when the CLI
  resolves to a `.cmd`/`.bat` shim.
- **`SymbolicLink` target comparison.** `Test()` compares immediate target
  pathnames, with relative targets anchored to the link's parent directory.
  Exact normalized matches are compliant even for dangling links. Case-only
  differences require directory-entry enumeration and successful literal
  lookups: distinct stored names are noncompliant, while one unambiguous stored
  name accepted under both spellings is equivalent. This uses observed
  filesystem behavior, not an operating-system case assumption.
  If missing or inaccessible components, ambiguous entries, or differing root
  spellings prevent proving case equivalence, `Test()` raises
  `DscSymbolicLinkComparisonUnknown` rather than reporting absence and requesting
  replacement. Drive-letter case is normalized as path syntax.
  Checks do not create probe files or resolve final file identity; different
  hard-link names or symlink chains are not made equivalent by sharing a final
  target. `Get()` retains the observed target spelling; `Set()` is unchanged.

## Requirements

- PowerShell 7.4 or later.
- `SavePSResource` requires `Microsoft.PowerShell.PSResourceGet` (`Save-PSResource`).
- `CopilotPlugin` / `CopilotMarketplace` require the GitHub Copilot CLI (`copilot`) on `PATH`.
- `UvTool` requires the `uv` CLI on `PATH`.
- `SymbolicLink` on Windows requires Developer Mode or an elevated session.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).
