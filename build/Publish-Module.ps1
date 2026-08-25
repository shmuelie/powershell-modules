[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Shmuelie.Git', 'Shmuelie.Copilot', 'Shmuelie.Node', 'Shmuelie.Utilities', 'Shmuelie.Dsc', 'Shmuelie.Windows')]
    [string]$Module,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ApiKey,

    [string]$Repository = 'PSGallery'
)

$artifact = & (Join-Path $PSScriptRoot 'Build-Module.ps1') -Module $Module
if ($PSCmdlet.ShouldProcess("$Module -> $Repository", 'Publish PowerShell module')) {
    Publish-PSResource -Path $artifact.FullName -Repository $Repository -ApiKey $ApiKey
}
