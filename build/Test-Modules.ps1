[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$modules = @('Shmuelie.Git', 'Shmuelie.Copilot', 'Shmuelie.Node', 'Shmuelie.Utilities')

foreach ($module in $modules) {
    Write-Information "Building $module" -InformationAction Continue
    & (Join-Path $PSScriptRoot 'Build-Module.ps1') -Module $module | Out-Null
}

$forbidden = 'dev\.azure\.com/microsoft|msazure\.pkgs\.visualstudio\.com|OS\.Developer|WindowsHiveMind|SFC\.|SFS\.|SFU\.|os\.2020|OSClient|IXPTools|StoreFundementals|user/senglard|SEnglard|\\\\redmond\\|D:\\wsd\\'
$matches = Get-ChildItem (Join-Path $repoRoot 'modules') -Recurse -File |
    Where-Object { $_.FullName -notmatch '\\(?:bin|obj)\\' } |
    Select-String -Pattern $forbidden
if ($matches) {
    $matches | Format-Table Path, LineNumber, Line -AutoSize
    throw 'Internal-only markers were found in public module sources.'
}
