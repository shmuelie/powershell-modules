function Get-VSCodePackageProvider {
    [CmdletBinding()]
    param()

    [pscustomobject]@{
        Name             = 'VSCode'
        Platforms        = @('Windows', 'Linux', 'MacOS')
        RequiredModules  = @('Shmuelie.Utilities')
        RequiredCommands = @('Shmuelie.Utilities\Get-VsCodeExtension', 'Shmuelie.Utilities\Update-VsCodeExtension')
        OptionNames      = @('Profiles')
        TestAvailable    = {
            param([hashtable]$Options)
            $profiles = @(Get-VSCodePackageProfiles -Options $Options)
            if (-not (Get-Command code -CommandType Application -ListImported -ErrorAction Ignore)) {
                return [pscustomobject]@{ Available = $false; Reason = "Install Visual Studio Code and expose its 'code' CLI on PATH to use provider 'VSCode'." }
            }
            if ($profiles.Count -and -not (Get-Command 'Shmuelie.Utilities\Update-VsCodeExtension' -ListImported -ErrorAction Stop).Parameters.ContainsKey('Profile')) {
                return [pscustomobject]@{ Available = $false; Reason = "Update Shmuelie.Utilities to a version supporting Update-VsCodeExtension -Profile to use VSCode Profiles." }
            }
            [pscustomobject]@{ Available = $true; Reason = $null }
        }
        GetTargets       = {
            param([hashtable]$Options)
            $profiles = @(Get-VSCodePackageProfiles -Options $Options)
            foreach ($profile in @($null) + $profiles) {
                $id = if ($null -eq $profile) { 'extensions (default profile)' } else { "extensions (profile: $profile)" }
                $extensions = @(Get-VSCodePackageInventory -Profile $profile)
                New-PackageUpdateTarget -Target $id -Data ([pscustomobject]@{
                    Profile = $profile
                    PreviousExtensions = $extensions
                })
            }
        }
        Update           = {
            param($Target, [hashtable]$Options)
            Invoke-VSCodePackageCommand -Operation Update -Profile $Target.Data.Profile
            $extensions = @(Get-VSCodePackageInventory -Profile $Target.Data.Profile)
            $result = New-PackageUpdateResult -Provider VSCode -Target $Target.Target -Status Updated -Reason 'Bulk extension update completed for this profile; individual extension outcomes are not reported.'
            $result | Add-Member -NotePropertyName PreviousExtensions -NotePropertyValue $Target.Data.PreviousExtensions
            $result | Add-Member -NotePropertyName ResultingExtensions -NotePropertyValue $extensions
            $result
        }
    }
}

function Get-VSCodePackageProfiles {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Options)

    if (-not $Options.ContainsKey('Profiles')) { return }
    $profiles = $Options.Profiles
    if ($profiles -isnot [string] -and $profiles -isnot [array]) {
        throw "VSCode option 'Profiles' must be a profile name or an array of profile names."
    }
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($profile in @($profiles)) {
        if ($profile -isnot [string] -or [string]::IsNullOrWhiteSpace($profile) -or
            $profile.StartsWith('-') -or $profile -match '[<>&|%!^`"()\x00-\x1f\x7f]') {
            throw "Unsafe VSCode profile name. Profiles must be nonempty strings, must not start with '-', and must not contain control characters or cmd.exe metacharacters."
        }
        if ($seen.Add($profile)) { $profile }
    }
}

function Invoke-VSCodePackageCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Get', 'Update')][string]$Operation,
        [AllowNull()][string]$Profile
    )

    $arguments = @{ ErrorAction = 'Stop' }
    if ($Profile) { $arguments.Profile = $Profile }
    $previousExitCode = Get-Variable LASTEXITCODE -Scope Global -ErrorAction Ignore
    $previousExitCodeValue = if ($previousExitCode) { $previousExitCode.Value } else { $null }
    try {
        # Utilities' CLI wrappers have no success output; require fresh native evidence.
        $global:LASTEXITCODE = $null
        if ($Operation -eq 'Get') {
            $output = @(Shmuelie.Utilities\Get-VsCodeExtension @arguments)
        } else {
            $output = @(Shmuelie.Utilities\Update-VsCodeExtension @arguments -Confirm:$false)
        }
        $exitCode = $global:LASTEXITCODE
        if ($null -eq $exitCode) {
            throw "VSCode $Operation did not report a native exit code; the outcome is unknown."
        }
        if ($exitCode -ne 0) {
            throw "VSCode $Operation failed with native exit code $exitCode."
        }
        if ($Operation -eq 'Get') {
            $output
        } else {
            foreach ($line in $output) { Write-Verbose "$line" }
        }
    } finally {
        if ($previousExitCode) {
            $global:LASTEXITCODE = $previousExitCodeValue
        } else {
            Remove-Variable LASTEXITCODE -Scope Global -ErrorAction Ignore
        }
    }
}

function Get-VSCodePackageInventory {
    [CmdletBinding()]
    param([AllowNull()][string]$Profile)

    foreach ($extension in @(Invoke-VSCodePackageCommand -Operation Get -Profile $Profile)) {
        if ($extension.FullId -isnot [string] -or [string]::IsNullOrWhiteSpace($extension.FullId)) {
            throw 'VSCode extension discovery returned an invalid extension identifier.'
        }
        [pscustomobject]@{
            FullId = $extension.FullId
            Version = if ($extension.Version -is [string] -and -not [string]::IsNullOrWhiteSpace($extension.Version)) { $extension.Version } else { $null }
        }
    }
}
