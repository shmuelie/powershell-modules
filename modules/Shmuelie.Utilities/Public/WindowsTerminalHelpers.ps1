function Get-WindowsTerminalSettings {
    <#
    .SYNOPSIS
        Get the parsed Windows Terminal settings.json.
    .DESCRIPTION
        Reads and parses the Windows Terminal settings.json file. Checks both
        stable and preview package paths.
    .EXAMPLE
        Get-WindowsTerminalSettings
        Returns the parsed settings object.
    .EXAMPLE
        (Get-WindowsTerminalSettings).profiles.list | Select-Object name, guid
        Lists all profiles defined in settings.json.
    .NOTES
        Windows only.
    #>
    [CmdletBinding()]
    param()

    Assert-WindowsOnly -CommandName $MyInvocation.MyCommand.Name

    foreach ($pkg in @('Microsoft.WindowsTerminal_8wekyb3d8bbwe', 'Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe')) {
        $path = Join-Path $env:LOCALAPPDATA "Packages\$pkg\LocalState\settings.json"
        if (Test-Path $path) {
            return Get-Content $path -Raw | ConvertFrom-Json
        }
    }
    Write-Verbose "Windows Terminal settings.json not found."
}

function Get-WindowsTerminalProfile {
    <#
    .SYNOPSIS
        Get Windows Terminal profiles by name or GUID.
    .DESCRIPTION
        Searches for profiles across settings.json and fragment JSON files.
        Without parameters, returns the current session's profile (from WT_PROFILE_ID).
    .PARAMETER Name
        Filter by profile name. Supports wildcards.
    .PARAMETER Id
        Filter by profile GUID (e.g., {574e775e-...}).
    .PARAMETER IncludeFragments
        Also search fragment JSON files in LOCALAPPDATA and ProgramData.
        Enabled by default when searching by Id, since fragments may define
        profiles not present in settings.json.
    .EXAMPLE
        Get-WindowsTerminalProfile
        Returns the current session's terminal profile.
    .EXAMPLE
        Get-WindowsTerminalProfile -Name *Elevated*
        Returns all profiles with "Elevated" in the name.
    .EXAMPLE
        Get-WindowsTerminalProfile -Name PowerShell
        Returns the PowerShell profile.
    .EXAMPLE
        Get-WindowsTerminalProfile -IncludeFragments
        Returns all profiles including those from fragment files.
    .NOTES
        Windows only.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Current')]
    param(
        [Parameter(ParameterSetName = 'ByName', Position = 0)]
        [string]$Name,

        [Parameter(ParameterSetName = 'ById')]
        [string]$Id,

        [switch]$IncludeFragments
    )

    Assert-WindowsOnly -CommandName $MyInvocation.MyCommand.Name

    $profiles = @()

    # Collect profiles from settings.json
    $settings = Get-WindowsTerminalSettings
    if ($settings -and $settings.profiles -and $settings.profiles.list) {
        $profiles += @($settings.profiles.list)
    }

    # Collect profiles from fragment files
    if ($IncludeFragments -or $PSCmdlet.ParameterSetName -eq 'ById' -or $PSCmdlet.ParameterSetName -eq 'Current') {
        $fragmentDirs = @(
            Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\Fragments'
            Join-Path $env:ProgramData 'Microsoft\Windows Terminal\Fragments'
        )
        foreach ($dir in $fragmentDirs) {
            if (-not (Test-Path $dir)) { continue }
            foreach ($file in Get-ChildItem $dir -Recurse -Filter '*.json' -ErrorAction SilentlyContinue) {
                $fragment = Get-Content $file.FullName -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($fragment.profiles) {
                    $profiles += @($fragment.profiles)
                }
            }
        }
    }

    # Filter
    switch ($PSCmdlet.ParameterSetName) {
        'Current' {
            if ($env:WT_PROFILE_ID) {
                $profiles | Where-Object guid -eq $env:WT_PROFILE_ID | Select-Object -First 1
            } else {
                Write-Verbose "Not running in Windows Terminal (WT_PROFILE_ID not set)."
            }
        }
        'ByName' {
            $profiles | Where-Object { $_.name -like $Name }
        }
        'ById' {
            $profiles | Where-Object guid -eq $Id | Select-Object -First 1
        }
    }
}
