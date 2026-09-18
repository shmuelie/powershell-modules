[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Module,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ApiKey,

    [string]$Repository = 'PSGallery'
)

$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'Assert-ModulePublishable.ps1') -Module $Module
$artifact = & (Join-Path $PSScriptRoot 'Build-Module.ps1') -Module $Module
& (Join-Path $PSScriptRoot 'Assert-ModulePublishable.ps1') -Module $Module -Path $artifact.FullName
if ($PSCmdlet.ShouldProcess("$Module -> $Repository", 'Publish PowerShell module')) {
    Publish-PSResource -Path $artifact.FullName -Repository $Repository -ApiKey $ApiKey
}
