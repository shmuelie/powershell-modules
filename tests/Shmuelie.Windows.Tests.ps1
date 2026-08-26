#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.2.0' }

BeforeAll {
    $repoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent
    $cmdletsProject = Join-Path $repoRoot 'modules\Shmuelie.Windows\Cmdlets\Shmuelie.Windows.Cmdlets.csproj'
    $cmdletsBin = Join-Path $repoRoot 'modules\Shmuelie.Windows\bin'
    dotnet build $cmdletsProject --configuration Release --output $cmdletsBin --nologo
    if ($LASTEXITCODE -ne 0) {
        throw 'Shmuelie.Windows.Cmdlets build failed; cannot run Shmuelie.Windows tests.'
    }
    Import-Module (Join-Path $repoRoot 'modules\Shmuelie.Windows\Shmuelie.Windows.psd1') -Force

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

        It 'stops Get-AppInstallerApp before shelling out to Windows PowerShell' {
            Mock -ModuleName Shmuelie.Windows Invoke-AppInstallerEnumeration { throw 'shell-out side effect' }

            { Get-AppInstallerApp } |
                Should -Throw '*Get-AppInstallerApp is only supported on Windows.*'

            Should -Invoke -ModuleName Shmuelie.Windows Invoke-AppInstallerEnumeration -Times 0
        }

        It 'stops Update-AppInstallerApp before discovery or update side effects' {
            Mock -ModuleName Shmuelie.Windows Get-AppInstallerApp { throw 'discovery side effect' }
            Mock -ModuleName Shmuelie.Windows Invoke-AppInstallerUpdate { throw 'update side effect' }

            { Update-AppInstallerApp -Confirm:$false } |
                Should -Throw '*Update-AppInstallerApp is only supported on Windows.*'

            Should -Invoke -ModuleName Shmuelie.Windows Get-AppInstallerApp -Times 0
            Should -Invoke -ModuleName Shmuelie.Windows Invoke-AppInstallerUpdate -Times 0
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

Describe 'Get-AppInstallerApp' {
    BeforeEach {
        Mock -ModuleName Shmuelie.Windows Test-IsWindowsPlatform { $true }
    }

    It 'shapes enumerated App Installer entries' {
        Mock -ModuleName Shmuelie.Windows Invoke-AppInstallerEnumeration {
            @(
                [PSCustomObject]@{
                    Name              = 'Contoso.App'
                    PackageFullName   = 'Contoso.App_1.0.0.0_x64__8wekyb3d8bbwe'
                    PackageFamilyName = 'Contoso.App_8wekyb3d8bbwe'
                    Publisher         = 'CN=Contoso'
                    Version           = '1.0.0.0'
                    Architecture      = 'X64'
                    Uri               = [Uri]'https://example.com/contoso.appinstaller'
                }
            )
        }

        $apps = @(Get-AppInstallerApp)

        $apps | Should -HaveCount 1
        $apps[0].Name | Should -BeExactly 'Contoso.App'
        $apps[0].PackageFullName | Should -BeExactly 'Contoso.App_1.0.0.0_x64__8wekyb3d8bbwe'
        $apps[0].PackageFamilyName | Should -BeExactly 'Contoso.App_8wekyb3d8bbwe'
        $apps[0].AppInstallerUri | Should -BeExactly 'https://example.com/contoso.appinstaller'
        Should -Invoke -ModuleName Shmuelie.Windows Invoke-AppInstallerEnumeration -Times 1
    }

    It 'returns an empty result when no App Installer apps are found' {
        Mock -ModuleName Shmuelie.Windows Invoke-AppInstallerEnumeration { @() }

        Get-AppInstallerApp | Should -BeNullOrEmpty

        Should -Invoke -ModuleName Shmuelie.Windows Invoke-AppInstallerEnumeration -Times 1
    }
}

Describe 'Update-AppInstallerApp' {
    BeforeEach {
        Mock -ModuleName Shmuelie.Windows Test-IsWindowsPlatform { $true }
        Mock -ModuleName Shmuelie.Windows Get-AppInstallerApp {
            @(
                [PSCustomObject]@{
                    Name              = 'Contoso.App'
                    PackageFullName   = 'Contoso.App_1.0.0.0_x64__8wekyb3d8bbwe'
                    PackageFamilyName = 'Contoso.App_8wekyb3d8bbwe'
                    AppInstallerUri   = 'https://example.com/contoso.appinstaller'
                }
                [PSCustomObject]@{
                    Name              = 'Fabrikam.App'
                    PackageFullName   = 'Fabrikam.App_2.0.0.0_x64__8wekyb3d8bbwe'
                    PackageFamilyName = 'Fabrikam.App_8wekyb3d8bbwe'
                    AppInstallerUri   = 'https://example.com/fabrikam.appinstaller'
                }
            )
        }
        Mock -ModuleName Shmuelie.Windows Invoke-AppInstallerUpdate { }
    }

    It 'updates a named app by App Installer URI' {
        Update-AppInstallerApp -Name 'Contoso.App' -Confirm:$false

        Should -Invoke -ModuleName Shmuelie.Windows Get-AppInstallerApp -Times 1
        Should -Invoke -ModuleName Shmuelie.Windows Invoke-AppInstallerUpdate -Times 1 -ParameterFilter {
            $AppInstallerUri -eq 'https://example.com/contoso.appinstaller'
        }
        Should -Invoke -ModuleName Shmuelie.Windows Invoke-AppInstallerUpdate -Times 0 -ParameterFilter {
            $AppInstallerUri -eq 'https://example.com/fabrikam.appinstaller'
        }
    }

    It 'accepts pipeline input by package identity property name' {
        [PSCustomObject]@{ PackageFamilyName = 'Fabrikam.App_8wekyb3d8bbwe' } | Update-AppInstallerApp -Confirm:$false

        Should -Invoke -ModuleName Shmuelie.Windows Invoke-AppInstallerUpdate -Times 1 -ParameterFilter {
            $AppInstallerUri -eq 'https://example.com/fabrikam.appinstaller'
        }
        Should -Invoke -ModuleName Shmuelie.Windows Invoke-AppInstallerUpdate -Times 0 -ParameterFilter {
            $AppInstallerUri -eq 'https://example.com/contoso.appinstaller'
        }
    }

    It 'updates all discovered apps when no name is specified' {
        Update-AppInstallerApp -Confirm:$false

        Should -Invoke -ModuleName Shmuelie.Windows Invoke-AppInstallerUpdate -Times 1 -ParameterFilter {
            $AppInstallerUri -eq 'https://example.com/contoso.appinstaller'
        }
        Should -Invoke -ModuleName Shmuelie.Windows Invoke-AppInstallerUpdate -Times 1 -ParameterFilter {
            $AppInstallerUri -eq 'https://example.com/fabrikam.appinstaller'
        }
    }

    It 'does not invoke the update helper under WhatIf' {
        Update-AppInstallerApp -WhatIf

        Should -Invoke -ModuleName Shmuelie.Windows Get-AppInstallerApp -Times 1
        Should -Invoke -ModuleName Shmuelie.Windows Invoke-AppInstallerUpdate -Times 0
    }

    It 'is a no-op when no App Installer apps are found' {
        Mock -ModuleName Shmuelie.Windows Get-AppInstallerApp { @() }

        { Update-AppInstallerApp -Confirm:$false } | Should -Not -Throw

        Should -Invoke -ModuleName Shmuelie.Windows Invoke-AppInstallerUpdate -Times 0
    }
}
