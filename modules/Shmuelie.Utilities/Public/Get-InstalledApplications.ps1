function Get-InstalledApplications {
    <#
    .SYNOPSIS
    Retrieve installed applications from the Windows registry.
    .DESCRIPTION
    Queries the Windows registry uninstall keys to find installed applications.
    Supports multiple scopes: global (HKLM), current user, all users, or combinations.
    Querying all users requires administrative privileges to mount offline user hives.
    .PARAMETER Scope
    The scope of applications to query. Defaults to 'GlobalAndAllUsers'.
    Valid values: Global, GlobalAndCurrentUser, GlobalAndAllUsers, CurrentUser, AllUsers.
    .EXAMPLE
    Get-InstalledApplications
    Returns all installed applications (global + all users). Requires elevation.
    .EXAMPLE
    Get-InstalledApplications -Scope Global
    Returns only machine-wide installed applications.
    .EXAMPLE
    Get-InstalledApplications -Scope CurrentUser
    Returns applications installed for the current user only.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [ValidateSet('Global', 'GlobalAndCurrentUser', 'GlobalAndAllUsers', 'CurrentUser', 'AllUsers')]
        [string]$Scope = 'GlobalAndAllUsers'
    )

    # Check if running with Administrative privileges if required
    if ($Scope -in @('GlobalAndAllUsers', 'AllUsers')) {
        if (-not (Test-IsElevated)) {
            throw 'Finding all user applications requires an elevated (Administrator) PowerShell session.'
        }
    }

    # Empty array to store applications
    $Apps = [System.Collections.Generic.List[PSObject]]::new()
    $32BitPath = "SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    $64BitPath = "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"

    # Retrieve globally installed applications
    if ($Scope -in @('Global', 'GlobalAndAllUsers', 'GlobalAndCurrentUser')) {
        Write-Verbose "Processing global hive"
        Get-ItemProperty "HKLM:\$32BitPath" | ForEach-Object { $Apps.Add($_) }
        Get-ItemProperty "HKLM:\$64BitPath" | ForEach-Object { $Apps.Add($_) }
    }

    if ($Scope -in @('CurrentUser', 'GlobalAndCurrentUser')) {
        Write-Verbose "Processing current user hive"
        Get-ItemProperty "Registry::\HKEY_CURRENT_USER\$32BitPath" | ForEach-Object { $Apps.Add($_) }
        Get-ItemProperty "Registry::\HKEY_CURRENT_USER\$64BitPath" | ForEach-Object { $Apps.Add($_) }
    }

    if ($Scope -in @('AllUsers', 'GlobalAndAllUsers')) {
        Write-Verbose "Collecting hive data for all users"
        $AllProfiles = Get-CimInstance Win32_UserProfile | Select-Object LocalPath, SID, Loaded, Special | Where-Object {$_.SID -like "S-1-5-21-*"}
        $MountedProfiles = $AllProfiles | Where-Object {$_.Loaded -eq $true}
        $UnmountedProfiles = $AllProfiles | Where-Object {$_.Loaded -eq $false}

        Write-Verbose "Processing mounted hives"
        $MountedProfiles | ForEach-Object {
            Get-ItemProperty -Path "Registry::\HKEY_USERS\$($_.SID)\$32BitPath" | ForEach-Object { $Apps.Add($_) }
            Get-ItemProperty -Path "Registry::\HKEY_USERS\$($_.SID)\$64BitPath" | ForEach-Object { $Apps.Add($_) }
        }

        Write-Verbose "Processing unmounted hives"
        $UnmountedProfiles | ForEach-Object {

            $Hive = "$($_.LocalPath)\NTUSER.DAT"
            Write-Verbose " -> Mounting hive at $Hive"

            if (Test-Path $Hive) {
            
                REG LOAD HKU\temp $Hive

                Get-ItemProperty -Path "Registry::\HKEY_USERS\temp\$32BitPath" | ForEach-Object { $Apps.Add($_) }
                Get-ItemProperty -Path "Registry::\HKEY_USERS\temp\$64BitPath" | ForEach-Object { $Apps.Add($_) }

                # Run manual GC to allow hive to be unmounted
                [GC]::Collect()
                [GC]::WaitForPendingFinalizers()
            
                REG UNLOAD HKU\temp

            } else {
                Write-Warning "Unable to access registry hive at $Hive"
            }
        }
    }

    Write-Output $Apps
}
