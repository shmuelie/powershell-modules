function Invoke-AppInstallerEnumeration {
    [CmdletBinding()]
    param()

    $scriptBlock = @'
$ErrorActionPreference = 'Stop'

$packageManager = [Windows.Management.Deployment.PackageManager, Windows.Management.Deployment, ContentType = WindowsRuntime]::new()
$packages = @($packageManager.FindPackagesForUser([string]::Empty))

$results = foreach ($package in $packages) {
    $appInstallerInfo = $null

    try {
        $appInstallerInfo = $package.GetAppInstallerInfo()
    } catch {
        $appInstallerInfo = $null
    }

    if ($null -eq $appInstallerInfo) {
        continue
    }

    $appInstallerUri = $null
    foreach ($propertyName in @('AppInstallerUri', 'Uri')) {
        try {
            $value = $appInstallerInfo.$propertyName
        } catch {
            $value = $null
        }

        if ($null -ne $value) {
            if ($value -is [System.Uri]) {
                $appInstallerUri = $value.AbsoluteUri
            } else {
                $appInstallerUri = $value.ToString()
            }
            break
        }
    }

    if ([string]::IsNullOrWhiteSpace($appInstallerUri)) {
        continue
    }

    $identity = $package.Id
    $version = $null
    if ($null -ne $identity.Version) {
        $version = '{0}.{1}.{2}.{3}' -f $identity.Version.Major, $identity.Version.Minor, $identity.Version.Build, $identity.Version.Revision
    }

    [PSCustomObject]@{
        Name              = $identity.Name
        PackageFullName   = $identity.FullName
        PackageFamilyName = $identity.FamilyName
        Publisher         = $identity.Publisher
        Version           = $version
        Architecture      = $identity.Architecture.ToString()
        AppInstallerUri   = $appInstallerUri
    }
}

$results | ConvertTo-Json -Depth 4
'@

    $output = & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $scriptBlock 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "powershell.exe failed to enumerate App Installer applications. Exit code: $LASTEXITCODE. Output: $($output -join [Environment]::NewLine)"
    }

    $json = $output -join [Environment]::NewLine
    if ([string]::IsNullOrWhiteSpace($json)) {
        return
    }

    $json | ConvertFrom-Json
}

function Get-AppInstallerValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string[]]$PropertyName
    )

    foreach ($name in $PropertyName) {
        $property = $InputObject.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value -and -not [string]::IsNullOrWhiteSpace($property.Value.ToString())) {
            return $property.Value
        }
    }

    return $null
}

function ConvertTo-AppInstallerApplication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object]$InputObject
    )

    process {
        $uri = Get-AppInstallerValue -InputObject $InputObject -PropertyName @('AppInstallerUri', 'Uri', 'UpdateUri')
        if ($uri -is [System.Uri]) {
            $uri = $uri.AbsoluteUri
        } elseif ($null -ne $uri) {
            $uri = $uri.ToString()
        }

        [PSCustomObject]@{
            PSTypeName       = 'Shmuelie.Windows.AppInstallerApplication'
            Name             = (Get-AppInstallerValue -InputObject $InputObject -PropertyName @('Name', 'PackageName', 'PackageIdentityName'))
            PackageFullName  = (Get-AppInstallerValue -InputObject $InputObject -PropertyName @('PackageFullName', 'FullName'))
            PackageFamilyName = (Get-AppInstallerValue -InputObject $InputObject -PropertyName @('PackageFamilyName', 'FamilyName'))
            Publisher        = (Get-AppInstallerValue -InputObject $InputObject -PropertyName @('Publisher'))
            Version          = (Get-AppInstallerValue -InputObject $InputObject -PropertyName @('Version'))
            Architecture     = (Get-AppInstallerValue -InputObject $InputObject -PropertyName @('Architecture'))
            AppInstallerUri  = $uri
        }
    }
}

function Get-AppInstallerApp {
    <#
    .SYNOPSIS
    Lists apps installed from App Installer files.
    .DESCRIPTION
    Enumerates MSIX/AppX packages that have an associated .appinstaller file and returns their package identity information plus the configured App Installer update URI.

    The Windows Runtime projection needed to read App Installer metadata is only available from Windows PowerShell 5.1, so this command shells out to powershell.exe for enumeration and returns plain objects to PowerShell 7.
    .EXAMPLE
    Get-AppInstallerApp
    Returns apps installed from .appinstaller files for the current user.
    .NOTES
    Windows only.
    #>
    [CmdletBinding()]
    param()

    Assert-WindowsOnly -CommandName $MyInvocation.MyCommand.Name

    Invoke-AppInstallerEnumeration | ConvertTo-AppInstallerApplication
}

function Invoke-AppInstallerUpdate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$AppInstallerUri
    )

    Add-AppxPackage -AppInstallerFile $AppInstallerUri
}

function Test-AppInstallerAppMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$App,

        [Parameter(Mandatory)]
        [string]$Name
    )

    foreach ($propertyName in @('Name', 'PackageFullName', 'PackageFamilyName')) {
        $value = Get-AppInstallerValue -InputObject $App -PropertyName @($propertyName)
        if ($null -ne $value -and $value.ToString().Equals($Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Update-AppInstallerApp {
    <#
    .SYNOPSIS
    Triggers update checks for App Installer apps.
    .DESCRIPTION
    Discovers apps installed from .appinstaller files and re-registers their App Installer URI with Add-AppxPackage -AppInstallerFile to trigger an update check.

    Pass one or more package names, full names, or family names to update specific apps. When no name is provided, every discovered App Installer app is updated. Objects from Get-AppInstallerApp can be piped to this command by property name.
    .PARAMETER Name
    Package identity name, package full name, or package family name to update. Accepts pipeline input by property name.
    .EXAMPLE
    Update-AppInstallerApp
    Triggers update checks for every discovered App Installer app.
    .EXAMPLE
    Get-AppInstallerApp | Where-Object Name -eq Contoso.App | Update-AppInstallerApp -WhatIf
    Shows the update action that would be triggered for Contoso.App.
    .NOTES
    Windows only.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Position = 0, ValueFromPipelineByPropertyName)]
        [Alias('PackageName', 'PackageFullName', 'PackageFamilyName')]
        [ValidateNotNullOrEmpty()]
        [string[]]$Name
    )

    begin {
        Assert-WindowsOnly -CommandName $MyInvocation.MyCommand.Name
        $requestedNames = [System.Collections.Generic.List[string]]::new()
    }

    process {
        foreach ($requestedName in $Name) {
            if (-not [string]::IsNullOrWhiteSpace($requestedName)) {
                $requestedNames.Add($requestedName)
            }
        }
    }

    end {
        $apps = @(Get-AppInstallerApp)
        if ($requestedNames.Count -gt 0) {
            $apps = @($apps | Where-Object {
                $app = $_
                $isMatch = $false
                foreach ($requestedName in $requestedNames) {
                    if (Test-AppInstallerAppMatch -App $app -Name $requestedName) {
                        $isMatch = $true
                        break
                    }
                }

                $isMatch
            })
        }

        foreach ($app in $apps) {
            $uri = Get-AppInstallerValue -InputObject $app -PropertyName @('AppInstallerUri', 'Uri', 'UpdateUri')
            if ($uri -is [System.Uri]) {
                $uri = $uri.AbsoluteUri
            } elseif ($null -ne $uri) {
                $uri = $uri.ToString()
            }

            if ([string]::IsNullOrWhiteSpace($uri)) {
                continue
            }

            $target = $app.Name
            if ([string]::IsNullOrWhiteSpace($target)) {
                $target = $uri
            }

            if ($PSCmdlet.ShouldProcess($target, "Add-AppxPackage -AppInstallerFile $uri")) {
                Invoke-AppInstallerUpdate -AppInstallerUri $uri
            }
        }
    }
}
