---
title: Contributing
---

**[Home](index.md) · [Modules](modules.md) · [Installation](installation.md) · [Contributing](contributing.md) · [GitHub](https://github.com/shmuelie/powershell-modules)**

# Contributing

## Where code lives

Each module is a self-contained directory under `modules/`:

```text
modules/<Module>/
├── <Module>.psd1     # manifest and exported members
├── <Module>.psm1     # loader, aliases, and Export-ModuleMember
├── README.md
├── CHANGELOG.md
└── Public/*.ps1      # one file per topic; functions are dot-sourced
```

## Adding or changing a command

1. Add or edit a function under the owning module's `Public/`.
2. Export it from both the `.psm1` `Export-ModuleMember` list and the `.psd1`
   `FunctionsToExport` list.
3. Include comment-based help and use `SupportsShouldProcess` for destructive or
   state-changing operations.
4. Update the module README command table and its `CHANGELOG.md`.
5. Bump the module's `.psd1` `ModuleVersion` and mirror it in the root README
   and documentation site.

## Public-content policy

Public modules must not reference internal-only tooling, private endpoints,
organization-specific systems, or credentials. Prefer parameters and
environment variables over hardcoded hosts or feeds.

## Validate

```powershell
.\build\Test-Modules.ps1
```

This builds every module, validates the manifest, imports and removes it, and
scans module sources, documentation, and READMEs for forbidden markers. Fix any
reported issue before opening a pull request.
