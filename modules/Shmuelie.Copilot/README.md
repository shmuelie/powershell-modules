# Shmuelie.Copilot

PowerShell helpers for GitHub Copilot CLI sessions, plugins, marketplaces, MCP
servers, and optional Agency integration.

```powershell
Install-PSResource Shmuelie.Copilot
Import-Module Shmuelie.Copilot
Start-Copilot
```

`Start-Copilot` provides session resume, model and permission options, and direct
CLI argument mapping. Agency profiles can be supplied explicitly or selected with
the `SHMUELIE_AGENCY_PROFILE` environment variable.
