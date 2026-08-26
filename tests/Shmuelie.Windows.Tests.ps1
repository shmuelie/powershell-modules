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
