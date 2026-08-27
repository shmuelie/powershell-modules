#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.2.0' }

BeforeAll {
    $repoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent
    $cmdletsProject = Join-Path $repoRoot 'modules' 'Shmuelie.Windows' 'Cmdlets' 'Shmuelie.Windows.Cmdlets.csproj'
    $cmdletsBin = Join-Path $repoRoot 'modules' 'Shmuelie.Windows' 'bin'
    dotnet build $cmdletsProject --configuration Release --output $cmdletsBin --nologo
    if ($LASTEXITCODE -ne 0) {
        throw 'Shmuelie.Windows.Cmdlets build failed; cannot run Shmuelie.Windows tests.'
    }
    if ($IsWindows) {
        $appInstallerProject = Join-Path $repoRoot 'modules' 'Shmuelie.Windows' 'Cmdlets.AppInstaller' 'Shmuelie.Windows.AppInstaller.csproj'
        # Publish so the WinRT projection runtime assemblies land next to the
        # cmdlet DLL in the shared source bin; a plain build omits them.
        dotnet publish $appInstallerProject --configuration Release --output $cmdletsBin --nologo
        if ($LASTEXITCODE -ne 0) {
            throw 'Shmuelie.Windows.AppInstaller publish failed; cannot run Shmuelie.Windows tests.'
        }
    }
    Import-Module (Join-Path $repoRoot 'modules' 'Shmuelie.Windows' 'Shmuelie.Windows.psd1') -Force

    function Get-FreeSubstDriveLetter {
        $used = [System.IO.Directory]::GetLogicalDrives() |
            ForEach-Object { $_.Substring(0, 1).ToUpperInvariant() }
        $substUsed = @()
        if ($IsWindows) {
            $substUsed = @(Get-SubstDrive | ForEach-Object { $_.DriveLetter.Substring(0, 1) })
        }
        foreach ($code in ([int][char]'D')..([int][char]'Z')) {
            $letter = [string][char]$code
            if ($letter -notin $used -and $letter -notin $substUsed) {
                return $letter
            }
        }
        return $null
    }
}

AfterAll {
    Remove-Module Shmuelie.Windows -Force -ErrorAction SilentlyContinue
}
Describe 'Windows-only guards' {
    Context 'when the platform is not Windows' {
        BeforeEach {
            Mock -ModuleName Shmuelie.Windows Test-IsWindowsPlatform { $false }
        }

        It 'stops Get-WindowsTerminalSettings before filesystem access' {
            Mock -ModuleName Shmuelie.Windows Test-Path { throw 'filesystem side effect' }
            Mock -ModuleName Shmuelie.Windows Get-Content { throw 'content side effect' }

            { Get-WindowsTerminalSettings } |
                Should -Throw '*Get-WindowsTerminalSettings is only supported on Windows.*'

            Should -Invoke -ModuleName Shmuelie.Windows Test-Path -Times 0
            Should -Invoke -ModuleName Shmuelie.Windows Get-Content -Times 0
        }

        It 'stops Get-WindowsTerminalProfile before loading settings or fragments' {
            Mock -ModuleName Shmuelie.Windows Get-WindowsTerminalSettings { throw 'settings side effect' }
            Mock -ModuleName Shmuelie.Windows Test-Path { throw 'fragment side effect' }
            Mock -ModuleName Shmuelie.Windows Get-ChildItem { throw 'fragment enumeration side effect' }

            { Get-WindowsTerminalProfile -Name PowerShell } |
                Should -Throw '*Get-WindowsTerminalProfile is only supported on Windows.*'

            Should -Invoke -ModuleName Shmuelie.Windows Get-WindowsTerminalSettings -Times 0
            Should -Invoke -ModuleName Shmuelie.Windows Test-Path -Times 0
            Should -Invoke -ModuleName Shmuelie.Windows Get-ChildItem -Times 0
        }

        It 'stops Start-WindowsPerformanceRecorder before invoking WPR' {
            { Start-WindowsPerformanceRecorder -PerformanceProfile GeneralProfile -Confirm:$false } |
                Should -Throw '*Start-WindowsPerformanceRecorder is only supported on Windows.*'
        }

        It 'stops Stop-WindowsPerformanceRecorder before invoking WPR' {
            { Stop-WindowsPerformanceRecorder -File C:\trace.etl -Confirm:$false } |
                Should -Throw '*Stop-WindowsPerformanceRecorder is only supported on Windows.*'
        }
    }

    Context 'when the platform is Windows' {
        BeforeEach {
            Mock -ModuleName Shmuelie.Windows Test-IsWindowsPlatform { $true }
        }

        It 'allows Get-WindowsTerminalSettings to read settings JSON' {
            Mock -ModuleName Shmuelie.Windows Test-Path { $true } -ParameterFilter { $Path -like '*Microsoft.WindowsTerminal_8wekyb3d8bbwe*' }
            Mock -ModuleName Shmuelie.Windows Test-Path { $false }
            Mock -ModuleName Shmuelie.Windows Get-Content { '{"profiles":{"list":[{"name":"PowerShell","guid":"{11111111-1111-1111-1111-111111111111}"}]}}' }

            $settings = Get-WindowsTerminalSettings

            $settings.profiles.list[0].name | Should -BeExactly 'PowerShell'
            Should -Invoke -ModuleName Shmuelie.Windows Test-Path -Times 1 -ParameterFilter { $Path -like '*Microsoft.WindowsTerminal_8wekyb3d8bbwe*' }
            Should -Invoke -ModuleName Shmuelie.Windows Get-Content -Times 1
        }

        It 'allows Get-WindowsTerminalProfile to search loaded profiles' {
            Mock -ModuleName Shmuelie.Windows Get-WindowsTerminalSettings {
                [PSCustomObject]@{
                    profiles = [PSCustomObject]@{
                        list = @(
                            [PSCustomObject]@{
                                name = 'PowerShell'
                                guid = '{11111111-1111-1111-1111-111111111111}'
                            }
                        )
                    }
                }
            }

            $profile = Get-WindowsTerminalProfile -Name PowerShell

            $profile.name | Should -BeExactly 'PowerShell'
            Should -Invoke -ModuleName Shmuelie.Windows Get-WindowsTerminalSettings -Times 1
        }

        It 'allows Start-WindowsPerformanceRecorder to reach ShouldProcess' {
            { Start-WindowsPerformanceRecorder -PerformanceProfile GeneralProfile -WhatIf } | Should -Not -Throw
        }

        It 'allows Stop-WindowsPerformanceRecorder to reach ShouldProcess' {
            { Stop-WindowsPerformanceRecorder -File C:\trace.etl -WhatIf } | Should -Not -Throw
        }
    }
}

Describe 'New-SubstDrive validation' -Skip:(-not $IsWindows) {
    It 'rejects invalid drive letters without creating a mapping' -ForEach @(
        @{ DriveLetter = '1' }
        @{ DriveLetter = 'AB' }
        @{ DriveLetter = 'S:&' }
    ) {
        $safeName = $DriveLetter -replace '[^A-Za-z0-9]', '_'
        $target = New-Item -ItemType Directory -Path (Join-Path $TestDrive "Invalid-$safeName")

        { New-SubstDrive -DriveLetter $DriveLetter -TargetPath $target.FullName -Confirm:$false } |
            Should -Throw '*single letter A-Z*'
    }

    It 'rejects a non-existent target directory' {
        $missing = Join-Path $TestDrive 'MissingTarget'

        { New-SubstDrive -DriveLetter S -TargetPath $missing -Confirm:$false } |
            Should -Throw '*existing directory*'
    }

    It 'creates nothing under -WhatIf' {
        $free = Get-FreeSubstDriveLetter
        if (-not $free) {
            Set-ItResult -Skipped -Because 'no free drive letter is available'
            return
        }

        $target = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'WhatIfTarget')

        New-SubstDrive -DriveLetter $free -TargetPath $target.FullName -WhatIf | Should -BeNullOrEmpty
        Get-SubstDrive -DriveLetter $free | Should -BeNullOrEmpty
        Test-Path ($free + ':\') | Should -BeFalse
    }
}

Describe 'subst drive integration' -Skip:(-not $IsWindows) {
    It 'creates, lists, and removes a subst mapping as typed objects' {
        $free = Get-FreeSubstDriveLetter
        if (-not $free) {
            Set-ItResult -Skipped -Because 'no free drive letter is available'
            return
        }

        $target = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'IntegrationTarget')

        try {
            $created = New-SubstDrive -DriveLetter $free -TargetPath $target.FullName -Confirm:$false
            $created | Should -BeOfType ([Shmuelie.Windows.Cmdlets.SubstDrive])
            $created.DriveLetter | Should -BeExactly ($free + ':')
            $created.TargetPath | Should -BeExactly $target.FullName

            $listed = Get-SubstDrive -DriveLetter $free
            $listed | Should -BeOfType ([Shmuelie.Windows.Cmdlets.SubstDrive])
            $listed.DriveLetter | Should -BeExactly ($free + ':')
            $listed.TargetPath | Should -BeExactly $target.FullName

            Test-Path ($free + ':\') | Should -BeTrue

            Remove-SubstDrive -DriveLetter $free -Confirm:$false
            Get-SubstDrive -DriveLetter $free | Should -BeNullOrEmpty
        }
        finally {
            if (Get-SubstDrive -DriveLetter $free) {
                Remove-SubstDrive -DriveLetter $free -Confirm:$false
            }
        }
    }

    It 'removes a mapping supplied through the pipeline by property name' {
        $free = Get-FreeSubstDriveLetter
        if (-not $free) {
            Set-ItResult -Skipped -Because 'no free drive letter is available'
            return
        }

        $target = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'PipelineTarget')

        try {
            New-SubstDrive -DriveLetter $free -TargetPath $target.FullName -Confirm:$false | Out-Null
            Get-SubstDrive -DriveLetter $free | Remove-SubstDrive -Confirm:$false
            Get-SubstDrive -DriveLetter $free | Should -BeNullOrEmpty
        }
        finally {
            if (Get-SubstDrive -DriveLetter $free) {
                Remove-SubstDrive -DriveLetter $free -Confirm:$false
            }
        }
    }

    It 'errors when removing a drive letter that is not mapped' {
        $free = Get-FreeSubstDriveLetter
        if (-not $free) {
            Set-ItResult -Skipped -Because 'no free drive letter is available'
            return
        }

        { Remove-SubstDrive -DriveLetter $free -Confirm:$false } |
            Should -Throw '*No subst mapping exists*'
    }
}

Describe 'Get-InstalledApplications' -Skip:(-not $IsWindows) {
    $isElevated = $IsWindows -and ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    It 'is a compiled binary cmdlet' {
        (Get-Command Get-InstalledApplications).CommandType | Should -Be 'Cmdlet'
    }

    It 'returns machine-wide applications carrying a DisplayName' {
        # Every Windows install has HKLM uninstall entries; no elevation needed.
        $apps = @(Get-InstalledApplications -Scope Global)

        $apps.Count | Should -BeGreaterThan 0
        $named = @($apps | Where-Object { $_.DisplayName })
        $named.Count | Should -BeGreaterThan 0
        $named[0].PSTypeNames | Should -Contain 'System.Management.Automation.PSCustomObject'
        $named[0].PSObject.Properties.Name | Should -Contain 'PSChildName'
    }

    It 'shapes each uninstall subkey value into a note property on the emitted object' {
        $keyName = "ShmuelieWindowsPesterApp_$([guid]::NewGuid().ToString('N'))"
        $key = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$keyName"
        try {
            New-Item -Path $key -Force | Out-Null
            Set-ItemProperty -Path $key -Name DisplayName -Value 'Pester Fake App'
            Set-ItemProperty -Path $key -Name DisplayVersion -Value '9.9.9'

            $match = @(Get-InstalledApplications -Scope CurrentUser |
                Where-Object { $_.PSChildName -eq $keyName })

            $match | Should -HaveCount 1
            $match[0].DisplayName | Should -BeExactly 'Pester Fake App'
            $match[0].DisplayVersion | Should -BeExactly '9.9.9'
        }
        finally {
            Remove-Item -Path $key -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'previews AllUsers under -WhatIf without elevation and without mounting a hive' {
        # -WhatIf performs no offline mount, so it must not require elevation and
        # must not surface any load/unload failure warnings.
        $warnings = $null
        { Get-InstalledApplications -Scope AllUsers -WhatIf -WarningVariable warnings -WarningAction SilentlyContinue } |
            Should -Not -Throw

        @($warnings | Where-Object { $_ -like '*Failed to load*' -or $_ -like '*Failed to unload*' }) |
            Should -BeNullOrEmpty
    }

    It 'requires an elevated session for AllUsers when not previewing' -Skip:($isElevated) {
        { Get-InstalledApplications -Scope AllUsers } |
            Should -Throw '*requires an elevated*'
    }

    It 'mounts and unmounts offline hives without throwing when elevated' -Skip:(-not $isElevated) {
        # Real offline-hive coverage: exercises RegLoadKey/RegUnLoadKey against
        # the machine's actual unmounted profiles. Requires elevation.
        { Get-InstalledApplications -Scope AllUsers -WarningAction SilentlyContinue | Out-Null } |
            Should -Not -Throw
    }
}

Describe 'Windows Terminal settings parsing' -Skip:(-not $IsWindows) {
    BeforeEach {
        $script:OriginalLocalAppData = $env:LOCALAPPDATA
        $script:OriginalProgramData = $env:ProgramData
        $env:LOCALAPPDATA = Join-Path $TestDrive 'LocalAppData'
        $env:ProgramData = Join-Path $TestDrive 'ProgramData'

        $settingsDir = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState'
        New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
        Set-Content -Path (Join-Path $settingsDir 'settings.json') -Value @'
{
  "profiles": {
    "list": [
      { "guid": "{11111111-1111-1111-1111-111111111111}", "name": "PowerShell", "commandline": "pwsh.exe" },
      { "guid": "{22222222-2222-2222-2222-222222222222}", "name": "Developer Command Prompt", "commandline": "cmd.exe" }
    ]
  }
}
'@
    }

    AfterEach {
        $env:LOCALAPPDATA = $script:OriginalLocalAppData
        $env:ProgramData = $script:OriginalProgramData
    }

    It 'reads the stable settings.json as an object' {
        $settings = Get-WindowsTerminalSettings

        $settings.profiles.list | Should -HaveCount 2
        $settings.profiles.list[0].name | Should -BeExactly 'PowerShell'
        $settings.profiles.list[0].guid | Should -BeExactly '{11111111-1111-1111-1111-111111111111}'
    }

    It 'finds profiles by name and GUID' {
        $byName = Get-WindowsTerminalProfile -Name '*Command Prompt'
        $byId = Get-WindowsTerminalProfile -Id '{11111111-1111-1111-1111-111111111111}'

        $byName.name | Should -BeExactly 'Developer Command Prompt'
        $byName.guid | Should -BeExactly '{22222222-2222-2222-2222-222222222222}'
        $byId.name | Should -BeExactly 'PowerShell'
    }
}

Describe 'Get-ServiceProcess' -Skip:(-not $IsWindows) {
    BeforeAll {
        $script:runningService = Get-Service -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -eq 'Running' } |
            Select-Object -First 1
    }

    It 'is a compiled binary cmdlet' {
        (Get-Command Get-ServiceProcess).CommandType | Should -Be 'Cmdlet'
    }

    It 'returns the hosting process for a single running service' {
        if (-not $script:runningService) { Set-ItResult -Skipped -Because 'no running service is available' }
        $result = Get-ServiceProcess -Name $script:runningService.Name

        $result | Should -Not -BeNullOrEmpty
        $result.Id | Should -BeGreaterThan 0
        $result.ProcessName | Should -Not -BeNullOrEmpty
    }

    It 'returns a System.Diagnostics.Process when a single running service is matched' {
        if (-not $script:runningService) { Set-ItResult -Skipped -Because 'no running service is available' }
        $result = Get-ServiceProcess -Name $script:runningService.Name

        $result | Should -BeOfType [System.Diagnostics.Process]
        $realProcess = Get-Process -Id $result.Id -ErrorAction Stop
        $result.Id | Should -Be $realProcess.Id
    }

    It 'accepts pipeline input from Get-Service' {
        if (-not $script:runningService) { Set-ItResult -Skipped -Because 'no running service is available' }
        $result = Get-Service -Name $script:runningService.Name | Get-ServiceProcess

        $result | Should -Not -BeNullOrEmpty
        $result.Id | Should -BeGreaterThan 0
    }

    It 'accepts input by property name from a custom object' {
        if (-not $script:runningService) { Set-ItResult -Skipped -Because 'no running service is available' }
        $result = [pscustomobject]@{ Name = $script:runningService.Name } | Get-ServiceProcess

        $result | Should -Not -BeNullOrEmpty
        $result.Id | Should -BeGreaterThan 0
    }

    It 'supports wildcards in -Name and emits ServiceProcessInfo objects for multiple matches' {
        $results = @(Get-ServiceProcess -Name '*')

        $results.Count | Should -BeGreaterThan 1
        $results[0].PSObject.TypeNames | Should -Contain 'Shmuelie.Windows.Cmdlets.ServiceProcessInfo'
        if ($script:runningService) {
            $results.Name | Should -Contain $script:runningService.Name
        }
    }

    It 'writes a non-terminating error when no service matches' {
        Get-ServiceProcess -Name 'ThisServiceDoesNotExist_ZZZ*' -ErrorVariable svcErr -ErrorAction SilentlyContinue |
            Out-Null

        $svcErr | Should -Not -BeNullOrEmpty
        [string]$svcErr[0] | Should -BeLike "*No service matched*"
    }

    It 'does not reconfigure anything with -PerService -WhatIf' {
        if (-not $script:runningService) { Set-ItResult -Skipped -Because 'no running service is available' }
        { Get-ServiceProcess -Name $script:runningService.Name -PerService -WhatIf } |
            Should -Not -Throw
    }
}

Describe 'AppInstaller helpers (unit)' -Skip:(-not $IsWindows) {
    It 'formats a package version as Major.Minor.Build.Revision' {
        [Shmuelie.Windows.Cmdlets.AppInstallerHelpers]::FormatVersion(1, 2, 3, 4) |
            Should -BeExactly '1.2.3.4'
    }

    It 'matches <Field> case-insensitively' -ForEach @(
        @{ Field = 'Name'; Value = 'Contoso.App' }
        @{ Field = 'PackageFullName'; Value = 'Contoso.App_1.0.0.0_x64__8wekyb3d8bbwe' }
        @{ Field = 'PackageFamilyName'; Value = 'Contoso.App_8wekyb3d8bbwe' }
    ) {
        $app = [Shmuelie.Windows.Cmdlets.AppInstallerApplication]@{
            Name              = 'Contoso.App'
            PackageFullName   = 'Contoso.App_1.0.0.0_x64__8wekyb3d8bbwe'
            PackageFamilyName = 'Contoso.App_8wekyb3d8bbwe'
        }

        [Shmuelie.Windows.Cmdlets.AppInstallerHelpers]::NameMatches($app, $Value.ToUpperInvariant()) |
            Should -BeTrue
    }

    It 'does not match an unrelated name' {
        $app = [Shmuelie.Windows.Cmdlets.AppInstallerApplication]@{ Name = 'Contoso.App' }
        [Shmuelie.Windows.Cmdlets.AppInstallerHelpers]::NameMatches($app, 'Fabrikam.App') |
            Should -BeFalse
    }

    It 'returns every app when no names are requested' {
        $apps = [Shmuelie.Windows.Cmdlets.AppInstallerApplication[]]@(
            [Shmuelie.Windows.Cmdlets.AppInstallerApplication]@{ Name = 'Contoso.App' }
            [Shmuelie.Windows.Cmdlets.AppInstallerApplication]@{ Name = 'Fabrikam.App' }
        )

        $filtered = @([Shmuelie.Windows.Cmdlets.AppInstallerHelpers]::FilterByNames($apps, $null))
        $filtered | Should -HaveCount 2
    }

    It 'filters to only the requested names' {
        $apps = [Shmuelie.Windows.Cmdlets.AppInstallerApplication[]]@(
            [Shmuelie.Windows.Cmdlets.AppInstallerApplication]@{ Name = 'Contoso.App' }
            [Shmuelie.Windows.Cmdlets.AppInstallerApplication]@{ Name = 'Fabrikam.App' }
        )
        $names = [System.Collections.Generic.List[string]]::new()
        $names.Add('fabrikam.app')

        $filtered = @([Shmuelie.Windows.Cmdlets.AppInstallerHelpers]::FilterByNames($apps, $names))
        $filtered | Should -HaveCount 1
        $filtered[0].Name | Should -BeExactly 'Fabrikam.App'
    }
}

Describe 'Get-AppInstallerApp' -Skip:(-not $IsWindows) {
    It 'is exported as a compiled cmdlet' {
        $command = Get-Command Get-AppInstallerApp
        $command.CommandType | Should -Be 'Cmdlet'
    }

    It 'enumerates without throwing and returns zero or more apps' {
        # CI has no .appinstaller-installed apps, so an empty result is the
        # expected pass. The live WinRT PackageManager enumeration cannot be
        # mocked; assert only that it runs (a throw fails the test) and yields an
        # array (count >= 0).
        $apps = @(Get-AppInstallerApp)
        $apps.Count | Should -BeGreaterOrEqual 0
    }
}

Describe 'Update-AppInstallerApp' -Skip:(-not $IsWindows) {
    It 'is exported as a compiled cmdlet supporting ShouldProcess' {
        $command = Get-Command Update-AppInstallerApp
        $command.CommandType | Should -Be 'Cmdlet'
        $command.Parameters['WhatIf'] | Should -Not -BeNullOrEmpty
    }

    It 'is a no-op under -WhatIf when nothing matches' {
        # No apps match a name that cannot exist, so no update is attempted and
        # -WhatIf must not throw regardless of what is installed.
        { Update-AppInstallerApp -Name 'NoSuch.App.That.Cannot.Exist' -WhatIf } |
            Should -Not -Throw
    }

    It 'accepts pipeline input by package identity property name' {
        $command = Get-Command Update-AppInstallerApp
        $nameParam = $command.Parameters['Name']
        $nameParam.Aliases | Should -Contain 'PackageFamilyName'
        $nameParam.Attributes.ValueFromPipelineByPropertyName | Should -Contain $true
    }
}
