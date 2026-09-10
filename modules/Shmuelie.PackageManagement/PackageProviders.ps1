function Get-PackageProvider {
    [CmdletBinding()]
    param()

    # Only checked-in integrations belong in this catalog, never user-supplied code.
    foreach ($name in 'PSResourceGet', 'DotNet', 'Npm', 'Pip', 'Uv', 'VSCode', 'WinGet', 'AppInstaller') {
        if ($name -eq 'PSResourceGet') {
            Get-PSResourceGetPackageProvider
            continue
        }
        if ($name -eq 'DotNet') {
            Get-DotNetPackageProvider
            continue
        }
        if ($name -eq 'Npm') {
            Get-NpmPackageProvider
            continue
        }
        if ($name -eq 'Pip') {
            Get-PipPackageProvider
            continue
        }
        if ($name -eq 'Uv') {
            Get-UvPackageProvider
            continue
        }
        if ($name -eq 'VSCode') {
            Get-VSCodePackageProvider
            continue
        }
        [pscustomobject]@{
            Name             = $name
            Platforms        = if ($name -in 'WinGet', 'AppInstaller') { @('Windows') } else { @('Windows', 'Linux', 'MacOS') }
            RequiredModules  = @()
            RequiredCommands = @()
            OptionNames      = @()
            TestAvailable    = $null
            GetTargets       = $null
            Update           = $null
        }
    }
}

function Get-PackageProviderPlatform {
    if ($IsWindows) { return 'Windows' }
    if ($IsLinux) { return 'Linux' }
    if ($IsMacOS) { return 'MacOS' }
    return 'Unknown'
}

function Get-PackageProviderAvailability {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Descriptor,
        [Parameter(Mandatory)][hashtable]$Options
    )

    $platform = Get-PackageProviderPlatform
    if ($platform -notin $Descriptor.Platforms) {
        return [pscustomobject]@{ Available = $false; Reason = "Provider '$($Descriptor.Name)' does not support $platform." }
    }
    if ($Descriptor.GetTargets -isnot [scriptblock] -or $Descriptor.Update -isnot [scriptblock]) {
        return [pscustomobject]@{ Available = $false; Reason = "Provider '$($Descriptor.Name)' integration is not implemented in this module version." }
    }

    foreach ($module in $Descriptor.RequiredModules) {
        if (-not (Get-Module -Name $module) -and -not (Get-Module -ListAvailable -Name $module -ErrorAction Stop)) {
            return [pscustomobject]@{ Available = $false; Reason = "Install the required module '$module' to use provider '$($Descriptor.Name)'." }
        }
        Import-Module -Name $module -ErrorAction Stop
    }
    foreach ($command in $Descriptor.RequiredCommands) {
        if (-not (Get-Command -Name $command -ListImported -ErrorAction Ignore)) {
            return [pscustomobject]@{ Available = $false; Reason = "Install or expose the required command '$command' on PATH for provider '$($Descriptor.Name)'." }
        }
    }
    if ($Descriptor.TestAvailable) {
        & $Descriptor.TestAvailable -Options $Options
    } else {
        [pscustomobject]@{ Available = $true; Reason = $null }
    }
}

function Invoke-PackageProviderCallback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$Callback,
        [Parameter(Mandatory)][hashtable]$Arguments
    )

    # Capture both error streams and throws without losing output already emitted.
    # Provider failures are result data, independent of the caller's ErrorAction.
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $true
    try {
        & $Callback @Arguments 2>&1
    } catch {
        $_
    }
}

function New-PackageUpdateTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Target,
        [string]$PreviousVersion,
        [string]$ProposedVersion,
        [object]$Data
    )

    [pscustomobject]@{
        PSTypeName      = 'Shmuelie.PackageManagement.UpdateTarget'
        Target          = $Target
        PreviousVersion = if ($PreviousVersion) { $PreviousVersion } else { $null }
        ProposedVersion = if ($ProposedVersion) { $ProposedVersion } else { $null }
        Data            = $Data
    }
}

function New-PackageUpdateResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Provider,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Target,
        [string]$PreviousVersion,
        [string]$ResultingVersion,
        [Parameter(Mandatory)][ValidateSet('Planned', 'Updated', 'Unchanged', 'Skipped', 'Failed')][string]$Status,
        [System.Management.Automation.ErrorRecord]$Error,
        [string]$Reason
    )

    if ($Status -eq 'Failed' -and -not $Error) {
        throw 'Failed results must include an ErrorRecord.'
    }
    if ($Status -ne 'Failed' -and $Error) {
        throw 'Only Failed results may contain an ErrorRecord.'
    }
    if ($Status -eq 'Skipped' -and [string]::IsNullOrWhiteSpace($Reason)) {
        throw 'Skipped results must include a reason.'
    }
    [pscustomobject]@{
        PSTypeName       = 'Shmuelie.PackageManagement.UpdateResult'
        Provider         = $Provider
        Target           = $Target
        PreviousVersion  = if ($PreviousVersion) { $PreviousVersion } else { $null }
        ResultingVersion = if ($ResultingVersion) { $ResultingVersion } else { $null }
        Status           = $Status
        Error            = $Error
        Reason           = if ($Reason) { $Reason } elseif ($Error) { $Error.Exception.Message } else { $null }
    }
}

function New-PackageProviderFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Provider,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Message,
        [string]$PreviousVersion
    )

    $errorRecord = [System.Management.Automation.ErrorRecord]::new(
        [System.InvalidOperationException]::new($Message),
        'InvalidPackageProviderOutput',
        [System.Management.Automation.ErrorCategory]::InvalidData,
        $Target
    )
    New-PackageUpdateResult -Provider $Provider -Target $Target -PreviousVersion $PreviousVersion -Status Failed -Error $errorRecord
}

function Test-PackageUpdateResult {
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Result,
        [Parameter(Mandatory)][string]$Provider,
        [Parameter(Mandatory)][string]$Target
    )

    if ($null -eq $Result -or $Result.PSTypeNames -notcontains 'Shmuelie.PackageManagement.UpdateResult') { return $false }
    foreach ($property in 'Provider', 'Target', 'PreviousVersion', 'ResultingVersion', 'Status', 'Error', 'Reason') {
        if (-not $Result.PSObject.Properties[$property]) { return $false }
    }
    if ($Result.Provider -cne $Provider -or $Result.Target -cne $Target) { return $false }
    if ($Result.Status -cnotin 'Updated', 'Unchanged', 'Skipped', 'Failed') { return $false }
    foreach ($property in 'PreviousVersion', 'ResultingVersion', 'Reason') {
        if ($null -ne $Result.$property -and $Result.$property -isnot [string]) { return $false }
    }
    if ($Result.Status -eq 'Failed') { return $Result.Error -is [System.Management.Automation.ErrorRecord] }
    if ($null -ne $Result.Error) { return $false }
    if ($Result.Status -eq 'Skipped' -and [string]::IsNullOrWhiteSpace($Result.Reason)) { return $false }
    return $true
}
