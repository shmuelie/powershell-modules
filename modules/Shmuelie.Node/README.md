# Shmuelie.Node

Node.js, nvm-windows, npm package, and Azure DevOps npm credential helpers.

```powershell
Install-PSResource Shmuelie.Node
Import-Module Shmuelie.Node
```

`Update-AdoNpmToken` requires an explicit public Azure DevOps feed URL and stores
the refreshed token in `ADO_NPM_TOKEN` unless `-Name` is provided.
