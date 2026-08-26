#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.2.0' }

BeforeAll {
    $repoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent
    Import-Module (Join-Path $repoRoot 'modules\Shmuelie.Windows\Shmuelie.Windows.psd1') -Force
}

AfterAll {
    Remove-Module Shmuelie.Windows -Force -ErrorAction SilentlyContinue
}
Describe 'Windows-only guards' {
    Context 'when the platform is not Windows' {
        BeforeEach {
            Mock -ModuleName Shmuelie.Windows Test-IsWindowsPlatform { $false }
        }

        It 'stops Get-InstalledApplications before registry or profile lookups' {
            Mock -ModuleName Shmuelie.Windows Test-IsElevated { throw 'elevation side effect' }
            Mock -ModuleName Shmuelie.Windows Get-CimInstance { throw 'profile side effect' }
            Mock -ModuleName Shmuelie.Windows Get-ItemProperty { throw 'registry side effect' }

            { Get-InstalledApplications -Scope GlobalAndAllUsers } |
                Should -Throw '*Get-InstalledApplications is only supported on Windows.*'

            Should -Invoke -ModuleName Shmuelie.Windows Test-IsElevated -Times 0
            Should -Invoke -ModuleName Shmuelie.Windows Get-CimInstance -Times 0
            Should -Invoke -ModuleName Shmuelie.Windows Get-ItemProperty -Times 0
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

        It 'stops subst cmdlets before filesystem or subst helper access' {
            InModuleScope Shmuelie.Windows {
                Mock Test-IsWindowsPlatform { $false }
                Mock Get-SubstDriveMapping { throw 'subst list side effect' }
                Mock New-SubstDriveMapping { throw 'subst create side effect' }
                Mock Remove-SubstDriveMapping { throw 'subst remove side effect' }
                Mock Get-Item { throw 'filesystem side effect' }

                { Get-SubstDrive } | Should -Throw '*Get-SubstDrive is only supported on Windows.*'
                { New-SubstDrive -DriveLetter S -TargetPath C:\Missing -Confirm:$false } |
                    Should -Throw '*New-SubstDrive is only supported on Windows.*'
                { Remove-SubstDrive -DriveLetter S -Confirm:$false } |
                    Should -Throw '*Remove-SubstDrive is only supported on Windows.*'

                Should -Invoke Get-SubstDriveMapping -Times 0
                Should -Invoke New-SubstDriveMapping -Times 0
                Should -Invoke Remove-SubstDriveMapping -Times 0
                Should -Invoke Get-Item -Times 0
            }
        }
    }

    Context 'when the platform is Windows' {
        BeforeEach {
            Mock -ModuleName Shmuelie.Windows Test-IsWindowsPlatform { $true }
        }

        It 'allows Get-InstalledApplications to query global registry paths' {
            Mock -ModuleName Shmuelie.Windows Get-ItemProperty { [PSCustomObject]@{ DisplayName = 'Example App' } }

            $apps = @(Get-InstalledApplications -Scope Global)

            $apps | Should -HaveCount 2
            Should -Invoke -ModuleName Shmuelie.Windows Get-ItemProperty -Times 2
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

Describe 'Get-SubstDrive' {
    BeforeEach {
        Mock -ModuleName Shmuelie.Windows Test-IsWindowsPlatform { $true }
    }

    It 'returns typed objects from subst mappings' {
        $targetOne = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'TargetOne')
        $targetTwo = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'TargetTwo')

        InModuleScope Shmuelie.Windows -Parameters @{ TargetOne = $targetOne.FullName; TargetTwo = $targetTwo.FullName } {
            param($TargetOne, $TargetTwo)

            Mock Get-SubstDriveMapping {
                @(
                    [PSCustomObject]@{ DriveLetter = 'S:'; TargetPath = $TargetOne }
                    [PSCustomObject]@{ DriveLetter = 'T:'; TargetPath = $TargetTwo }
                )
            }

            $drives = @(Get-SubstDrive)

            $drives | Should -HaveCount 2
            $drives[0].PSTypeNames[0] | Should -BeExactly 'SubstDrive'
            $drives[0].DriveLetter | Should -BeExactly 'S:'
            $drives[0].TargetPath | Should -BeExactly $TargetOne
            $drives[1].DriveLetter | Should -BeExactly 'T:'
            $drives[1].TargetPath | Should -BeExactly $TargetTwo
            Should -Invoke Get-SubstDriveMapping -Times 1
        }
    }

    It 'filters by drive letter with or without a colon' {
        $targetOne = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'FilterOne')
        $targetTwo = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'FilterTwo')

        InModuleScope Shmuelie.Windows -Parameters @{ TargetOne = $targetOne.FullName; TargetTwo = $targetTwo.FullName } {
            param($TargetOne, $TargetTwo)

            Mock Get-SubstDriveMapping {
                @(
                    [PSCustomObject]@{ DriveLetter = 'S:'; TargetPath = $TargetOne }
                    [PSCustomObject]@{ DriveLetter = 'T:'; TargetPath = $TargetTwo }
                )
            }

            $drive = Get-SubstDrive -DriveLetter t:

            $drive.DriveLetter | Should -BeExactly 'T:'
            $drive.TargetPath | Should -BeExactly $TargetTwo
        }
    }
}

Describe 'New-SubstDrive' {
    BeforeEach {
        Mock -ModuleName Shmuelie.Windows Test-IsWindowsPlatform { $true }
    }

    It 'creates a mapping with normalized drive letter and resolved path' {
        $target = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'CreateTarget')

        InModuleScope Shmuelie.Windows -Parameters @{ ExpectedTargetPath = $target.FullName } {
            param($ExpectedTargetPath)

            Mock Test-SubstDriveLetterInUse { $false }
            Mock New-SubstDriveMapping { }

            $drive = New-SubstDrive -DriveLetter s -TargetPath $ExpectedTargetPath -Confirm:$false

            $drive.PSTypeNames[0] | Should -BeExactly 'SubstDrive'
            $drive.DriveLetter | Should -BeExactly 'S:'
            $drive.TargetPath | Should -BeExactly $ExpectedTargetPath
            Should -Invoke Test-SubstDriveLetterInUse -Times 1 -ParameterFilter { $DriveLetter -eq 'S:' }
            Should -Invoke New-SubstDriveMapping -Times 1 -ParameterFilter {
                $DriveLetter -eq 'S:' -and $TargetPath -eq $ExpectedTargetPath
            }
        }
    }

    It 'does not create a mapping under WhatIf' {
        $target = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'WhatIfTarget')

        InModuleScope Shmuelie.Windows -Parameters @{ TargetPath = $target.FullName } {
            param($TargetPath)

            Mock Test-SubstDriveLetterInUse { $false }
            Mock New-SubstDriveMapping { throw 'subst create side effect' }

            New-SubstDrive -DriveLetter S -TargetPath $TargetPath -WhatIf | Should -BeNullOrEmpty

            Should -Invoke New-SubstDriveMapping -Times 0
        }
    }

    It 'rejects invalid drive letters without invoking the create helper' -ForEach @(
        @{ DriveLetter = '1' }
        @{ DriveLetter = 'AB' }
        @{ DriveLetter = 'S:&' }
    ) {
        $safeName = $DriveLetter -replace '[^A-Za-z0-9]', '_'
        $target = New-Item -ItemType Directory -Path (Join-Path $TestDrive "Invalid-$safeName")

        InModuleScope Shmuelie.Windows -Parameters @{ DriveLetter = $DriveLetter; TargetPath = $target.FullName } {
            param($DriveLetter, $TargetPath)

            Mock Test-SubstDriveLetterInUse { throw 'in-use helper side effect' }
            Mock New-SubstDriveMapping { throw 'subst create side effect' }

            { New-SubstDrive -DriveLetter $DriveLetter -TargetPath $TargetPath -Confirm:$false } |
                Should -Throw '*DriveLetter must be a single letter A-Z*'

            Should -Invoke Test-SubstDriveLetterInUse -Times 0
            Should -Invoke New-SubstDriveMapping -Times 0
        }
    }

    It 'rejects a non-existent target without invoking the create helper' {
        $target = Join-Path $TestDrive 'MissingTarget'

        InModuleScope Shmuelie.Windows -Parameters @{ TargetPath = $target } {
            param($TargetPath)

            Mock Test-SubstDriveLetterInUse { throw 'in-use helper side effect' }
            Mock New-SubstDriveMapping { throw 'subst create side effect' }

            { New-SubstDrive -DriveLetter S -TargetPath $TargetPath -Confirm:$false } |
                Should -Throw '*TargetPath must be an existing directory*'

            Should -Invoke Test-SubstDriveLetterInUse -Times 0
            Should -Invoke New-SubstDriveMapping -Times 0
        }
    }

    It 'rejects an already-used drive letter without invoking the create helper' {
        $target = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'UsedDriveTarget')

        InModuleScope Shmuelie.Windows -Parameters @{ TargetPath = $target.FullName } {
            param($TargetPath)

            Mock Test-SubstDriveLetterInUse { $true }
            Mock New-SubstDriveMapping { throw 'subst create side effect' }

            { New-SubstDrive -DriveLetter S -TargetPath $TargetPath -Confirm:$false } |
                Should -Throw '*Drive letter S: is already in use*'

            Should -Invoke New-SubstDriveMapping -Times 0
        }
    }
}

Describe 'Remove-SubstDrive' {
    BeforeEach {
        Mock -ModuleName Shmuelie.Windows Test-IsWindowsPlatform { $true }
    }

    It 'removes an existing mapping by drive letter' {
        InModuleScope Shmuelie.Windows {
            Mock Get-SubstDriveMapping { [PSCustomObject]@{ DriveLetter = 'S:'; TargetPath = 'Target' } }
            Mock Remove-SubstDriveMapping { }

            Remove-SubstDrive -DriveLetter s -Confirm:$false

            Should -Invoke Get-SubstDriveMapping -Times 1
            Should -Invoke Remove-SubstDriveMapping -Times 1 -ParameterFilter { $DriveLetter -eq 'S:' }
        }
    }

    It 'does not remove a mapping under WhatIf' {
        InModuleScope Shmuelie.Windows {
            Mock Get-SubstDriveMapping { [PSCustomObject]@{ DriveLetter = 'S:'; TargetPath = 'Target' } }
            Mock Remove-SubstDriveMapping { throw 'subst remove side effect' }

            Remove-SubstDrive -DriveLetter S -WhatIf

            Should -Invoke Remove-SubstDriveMapping -Times 0
        }
    }

    It 'accepts pipeline input by property name' {
        InModuleScope Shmuelie.Windows {
            Mock Get-SubstDriveMapping { [PSCustomObject]@{ DriveLetter = 'R:'; TargetPath = 'Target' } }
            Mock Remove-SubstDriveMapping { }

            [PSCustomObject]@{ DriveLetter = 'R:' } | Remove-SubstDrive -Confirm:$false

            Should -Invoke Remove-SubstDriveMapping -Times 1 -ParameterFilter { $DriveLetter -eq 'R:' }
        }
    }
}

Describe 'Get-InstalledApplications all-user hive handling' -Skip:(-not $IsWindows) {
    BeforeEach {
        Mock -ModuleName Shmuelie.Windows Test-IsElevated { $true }
        Mock -ModuleName Shmuelie.Windows Get-CimInstance {
            [PSCustomObject]@{
                LocalPath = 'C:\Users\OfflineUser'
                SID       = 'S-1-5-21-1000'
                Loaded    = $false
                Special   = $false
            }
        } -ParameterFilter { $ClassName -eq 'Win32_UserProfile' }
        Mock -ModuleName Shmuelie.Windows Test-Path { $true } -ParameterFilter { $Path -eq 'C:\Users\OfflineUser\NTUSER.DAT' }
    }

    It 'does not load or unload offline hives under WhatIf' {
        Mock -ModuleName Shmuelie.Windows Invoke-RegistryHiveCommand { throw 'REG should not be invoked under WhatIf' }
        Mock -ModuleName Shmuelie.Windows Get-ItemProperty { throw 'Offline hive should not be read when WhatIf skips loading' }

        Get-InstalledApplications -Scope AllUsers -WhatIf | Should -BeNullOrEmpty

        Should -Invoke -ModuleName Shmuelie.Windows Invoke-RegistryHiveCommand -Times 0
        Should -Invoke -ModuleName Shmuelie.Windows Get-ItemProperty -Times 0
    }

    It 'surfaces failed loads and skips dependent reads' {
        Mock -ModuleName Shmuelie.Windows Invoke-RegistryHiveCommand { 5 } -ParameterFilter { $Action -eq 'LOAD' }
        Mock -ModuleName Shmuelie.Windows Invoke-RegistryHiveCommand { throw 'Unload should not run after a failed load' } -ParameterFilter { $Action -eq 'UNLOAD' }
        Mock -ModuleName Shmuelie.Windows Get-ItemProperty { throw 'Offline hive should not be read after a failed load' }
        Mock -ModuleName Shmuelie.Windows Write-Warning { }

        Get-InstalledApplications -Scope AllUsers | Should -BeNullOrEmpty

        Should -Invoke -ModuleName Shmuelie.Windows Invoke-RegistryHiveCommand -Times 1 -ParameterFilter { $Action -eq 'LOAD' }
        Should -Invoke -ModuleName Shmuelie.Windows Invoke-RegistryHiveCommand -Times 0 -ParameterFilter { $Action -eq 'UNLOAD' }
        Should -Invoke -ModuleName Shmuelie.Windows Get-ItemProperty -Times 0
        Should -Invoke -ModuleName Shmuelie.Windows Write-Warning -Times 1 -ParameterFilter { $Message -like '*REG LOAD exited with code 5*' }
    }

    It 'unloads offline hives in a finally block when reads throw' {
        Mock -ModuleName Shmuelie.Windows Invoke-RegistryHiveCommand { 0 } -ParameterFilter { $Action -eq 'LOAD' }
        Mock -ModuleName Shmuelie.Windows Invoke-RegistryHiveCommand { 0 } -ParameterFilter { $Action -eq 'UNLOAD' }
        Mock -ModuleName Shmuelie.Windows Get-ItemProperty { throw 'read failed' }

        { Get-InstalledApplications -Scope AllUsers } | Should -Throw '*read failed*'

        Should -Invoke -ModuleName Shmuelie.Windows Invoke-RegistryHiveCommand -Times 1 -ParameterFilter { $Action -eq 'LOAD' }
        Should -Invoke -ModuleName Shmuelie.Windows Invoke-RegistryHiveCommand -Times 1 -ParameterFilter { $Action -eq 'UNLOAD' }
    }

    It 'surfaces failed unloads' {
        Mock -ModuleName Shmuelie.Windows Invoke-RegistryHiveCommand { 0 } -ParameterFilter { $Action -eq 'LOAD' }
        Mock -ModuleName Shmuelie.Windows Invoke-RegistryHiveCommand { 7 } -ParameterFilter { $Action -eq 'UNLOAD' }
        Mock -ModuleName Shmuelie.Windows Get-ItemProperty { [PSCustomObject]@{ DisplayName = 'Example App' } }
        Mock -ModuleName Shmuelie.Windows Write-Warning { }

        $apps = @(Get-InstalledApplications -Scope AllUsers)

        $apps | Should -HaveCount 2
        Should -Invoke -ModuleName Shmuelie.Windows Invoke-RegistryHiveCommand -Times 1 -ParameterFilter { $Action -eq 'LOAD' }
        Should -Invoke -ModuleName Shmuelie.Windows Invoke-RegistryHiveCommand -Times 1 -ParameterFilter { $Action -eq 'UNLOAD' }
        Should -Invoke -ModuleName Shmuelie.Windows Write-Warning -Times 1 -ParameterFilter { $Message -like '*REG UNLOAD exited with code 7*' }
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
    It 'returns the hosting process when a single running service is matched' {
        $fakeProcess = [PSCustomObject]@{
            Id          = 4242
            ProcessName = 'svchost'
        }
        Mock -ModuleName Shmuelie.Windows Get-CimInstance {
            [PSCustomObject]@{
                Name      = 'ExampleSvc'
                ProcessId = 4242
                PathName  = 'C:\Windows\System32\svchost.exe -k netsvcs'
            }
        }
        Mock -ModuleName Shmuelie.Windows Get-Service {
            [PSCustomObject]@{
                Name        = 'ExampleSvc'
                DisplayName = 'Example Service'
                Status      = 'Running'
            }
        }
        Mock -ModuleName Shmuelie.Windows Get-Process { $fakeProcess } -ParameterFilter { $Id -eq 4242 }

        $process = Get-ServiceProcess -Name ExampleSvc

        $process.Id | Should -Be 4242
        $process.ProcessName | Should -BeExactly 'svchost'
        Should -Invoke -ModuleName Shmuelie.Windows Get-CimInstance -Times 1
        Should -Invoke -ModuleName Shmuelie.Windows Get-Service -Times 1
        Should -Invoke -ModuleName Shmuelie.Windows Get-Process -Times 1 -ParameterFilter { $Id -eq 4242 }
    }
}
