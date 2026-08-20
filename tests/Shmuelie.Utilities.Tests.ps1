#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.2.0' }

BeforeAll {
    $repoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent
    Import-Module (Join-Path $repoRoot 'modules\Shmuelie.Utilities\Shmuelie.Utilities.psd1') -Force

    $script:OriginalPath = $env:PATH

    function Add-FakeCode {
        param([Parameter(Mandatory)][string]$Path)

        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        Set-Content -Path (Join-Path $Path 'code.cmd') -Value @(
            '@echo off'
            'if defined VSCODE_TEST_LOG echo %*>>"%VSCODE_TEST_LOG%"'
            'exit /b 0'
        )
        $env:PATH = "$Path$([IO.Path]::PathSeparator)$script:OriginalPath"
    }
}

AfterAll {
    $env:PATH = $script:OriginalPath
    Remove-Module Shmuelie.Utilities -Force -ErrorAction SilentlyContinue
}

Describe 'Test-IsElevated' {
    It 'returns a boolean' {
        Test-IsElevated | Should -BeOfType [bool]
    }
}

Describe 'Get-SessionTitle' {
    It 'includes the PowerShell moniker' {
        Get-SessionTitle | Should -Match 'PowerShell'
    }

    It 'includes the running version' {
        Get-SessionTitle | Should -Match ([regex]::Escape("$($PSVersionTable.PSVersion)"))
    }
}

Describe 'New-GlobalConstant' {
    It 'creates a global constant with the supplied value' {
        $name = 'ShmuelieTest_' + [guid]::NewGuid().ToString('N')
        New-GlobalConstant $name 42
        (Get-Variable -Name $name -Scope Global -ValueOnly) | Should -Be 42
    }

    It 'makes the variable read-only' {
        $name = 'ShmuelieTest_' + [guid]::NewGuid().ToString('N')
        New-GlobalConstant $name 'locked'
        { Set-Variable -Name $name -Value 'other' -Scope Global } | Should -Throw
    }
}

Describe 'New-PathVariable' {
    It 'creates the variable when the path exists' {
        $name = 'ShmuelieTest_' + [guid]::NewGuid().ToString('N')
        New-PathVariable $name $TestDrive
        (Get-Variable -Name $name -Scope Global -ValueOnly) | Should -Be "$TestDrive"
    }

    It 'does not create the variable when the path is missing' {
        $name = 'ShmuelieTest_' + [guid]::NewGuid().ToString('N')
        New-PathVariable $name (Join-Path $TestDrive 'does-not-exist')
        { Get-Variable -Name $name -Scope Global -ErrorAction Stop } | Should -Throw
    }
}

Describe 'Import-ModuleSafe' {
    It 'does nothing when the path is missing' {
        { Import-ModuleSafe -Path (Join-Path $TestDrive 'missing.psd1') } | Should -Not -Throw
    }
}

Describe 'Format-Duration' {
    $durationCases = @(
        # sub-minute: fractional TotalSeconds with no trailing label punctuation
        @{ Seconds = 45;     Expected = '45 seconds' }
        @{ Seconds = 0.5;    Expected = '0.5 seconds' }
        @{ Seconds = 5.3;    Expected = '5.3 seconds' }
        # fractional rounding to three decimals
        @{ Seconds = 1.2344; Expected = '1.234 seconds' }
        @{ Seconds = 2.5678; Expected = '2.568 seconds' }
        # just under the one-minute boundary
        @{ Seconds = 59.999; Expected = '59.999 seconds' }
        # exact one-minute boundary switches to M:SS.mmm
        @{ Seconds = 60;     Expected = '1:00.000' }
        @{ Seconds = 90.25;  Expected = '1:30.250' }
        @{ Seconds = 3599;   Expected = '59:59.000' }
        # exact one-hour boundary switches to H:MM:SS.mmm
        @{ Seconds = 3600;   Expected = '1:00:00.000' }
        @{ Seconds = 3661.5; Expected = '1:01:01.500' }
    )

    It 'formats <Seconds>s as <Expected>' -ForEach $durationCases {
        Format-Duration ([TimeSpan]::FromSeconds($Seconds)) | Should -BeExactly $Expected
    }

    It 'folds days into the hours field' {
        Format-Duration ([TimeSpan]::FromHours(25)) | Should -BeExactly '25:00:00.000'
    }

    It 'accepts pipeline input' {
        [TimeSpan]::FromSeconds(5.3) | Format-Duration | Should -BeExactly '5.3 seconds'
    }
}

Describe 'Invoke-InLocation' {
    It 'runs the script block in the requested location' {
        $target = Join-Path $TestDrive 'work'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        $seen = Invoke-InLocation -Location $target -ScriptBlock { (Get-Location).Path }
        $seen | Should -Be (Resolve-Path $target).Path
    }

    It 'restores the original location afterward' {
        $target = Join-Path $TestDrive 'work'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        $before = (Get-Location).Path
        Invoke-InLocation -Location $target -ScriptBlock { $null } | Out-Null
        (Get-Location).Path | Should -Be $before
    }
}

Describe 'Get-InstalledApplications all-user hive handling' -Skip:(-not $IsWindows) {
    BeforeEach {
        Mock -ModuleName Shmuelie.Utilities Test-IsElevated { $true }
        Mock -ModuleName Shmuelie.Utilities Get-CimInstance {
            [PSCustomObject]@{
                LocalPath = 'C:\Users\OfflineUser'
                SID       = 'S-1-5-21-1000'
                Loaded    = $false
                Special   = $false
            }
        } -ParameterFilter { $ClassName -eq 'Win32_UserProfile' }
        Mock -ModuleName Shmuelie.Utilities Test-Path { $true } -ParameterFilter { $Path -eq 'C:\Users\OfflineUser\NTUSER.DAT' }
    }

    It 'does not load or unload offline hives under WhatIf' {
        Mock -ModuleName Shmuelie.Utilities Invoke-RegistryHiveCommand { throw 'REG should not be invoked under WhatIf' }
        Mock -ModuleName Shmuelie.Utilities Get-ItemProperty { throw 'Offline hive should not be read when WhatIf skips loading' }

        Get-InstalledApplications -Scope AllUsers -WhatIf | Should -BeNullOrEmpty

        Should -Invoke -ModuleName Shmuelie.Utilities Invoke-RegistryHiveCommand -Times 0
        Should -Invoke -ModuleName Shmuelie.Utilities Get-ItemProperty -Times 0
    }

    It 'surfaces failed loads and skips dependent reads' {
        Mock -ModuleName Shmuelie.Utilities Invoke-RegistryHiveCommand { 5 } -ParameterFilter { $Action -eq 'LOAD' }
        Mock -ModuleName Shmuelie.Utilities Invoke-RegistryHiveCommand { throw 'Unload should not run after a failed load' } -ParameterFilter { $Action -eq 'UNLOAD' }
        Mock -ModuleName Shmuelie.Utilities Get-ItemProperty { throw 'Offline hive should not be read after a failed load' }
        Mock -ModuleName Shmuelie.Utilities Write-Warning { }

        Get-InstalledApplications -Scope AllUsers | Should -BeNullOrEmpty

        Should -Invoke -ModuleName Shmuelie.Utilities Invoke-RegistryHiveCommand -Times 1 -ParameterFilter { $Action -eq 'LOAD' }
        Should -Invoke -ModuleName Shmuelie.Utilities Invoke-RegistryHiveCommand -Times 0 -ParameterFilter { $Action -eq 'UNLOAD' }
        Should -Invoke -ModuleName Shmuelie.Utilities Get-ItemProperty -Times 0
        Should -Invoke -ModuleName Shmuelie.Utilities Write-Warning -Times 1 -ParameterFilter { $Message -like '*REG LOAD exited with code 5*' }
    }

    It 'unloads offline hives in a finally block when reads throw' {
        Mock -ModuleName Shmuelie.Utilities Invoke-RegistryHiveCommand { 0 } -ParameterFilter { $Action -eq 'LOAD' }
        Mock -ModuleName Shmuelie.Utilities Invoke-RegistryHiveCommand { 0 } -ParameterFilter { $Action -eq 'UNLOAD' }
        Mock -ModuleName Shmuelie.Utilities Get-ItemProperty { throw 'read failed' }

        { Get-InstalledApplications -Scope AllUsers } | Should -Throw '*read failed*'

        Should -Invoke -ModuleName Shmuelie.Utilities Invoke-RegistryHiveCommand -Times 1 -ParameterFilter { $Action -eq 'LOAD' }
        Should -Invoke -ModuleName Shmuelie.Utilities Invoke-RegistryHiveCommand -Times 1 -ParameterFilter { $Action -eq 'UNLOAD' }
    }

    It 'surfaces failed unloads' {
        Mock -ModuleName Shmuelie.Utilities Invoke-RegistryHiveCommand { 0 } -ParameterFilter { $Action -eq 'LOAD' }
        Mock -ModuleName Shmuelie.Utilities Invoke-RegistryHiveCommand { 7 } -ParameterFilter { $Action -eq 'UNLOAD' }
        Mock -ModuleName Shmuelie.Utilities Get-ItemProperty { [PSCustomObject]@{ DisplayName = 'Example App' } }
        Mock -ModuleName Shmuelie.Utilities Write-Warning { }

        $apps = @(Get-InstalledApplications -Scope AllUsers)

        $apps | Should -HaveCount 2
        Should -Invoke -ModuleName Shmuelie.Utilities Invoke-RegistryHiveCommand -Times 1 -ParameterFilter { $Action -eq 'LOAD' }
        Should -Invoke -ModuleName Shmuelie.Utilities Invoke-RegistryHiveCommand -Times 1 -ParameterFilter { $Action -eq 'UNLOAD' }
        Should -Invoke -ModuleName Shmuelie.Utilities Write-Warning -Times 1 -ParameterFilter { $Message -like '*REG UNLOAD exited with code 7*' }
    }
}

Describe 'VS Code CLI shim argument validation' {
    BeforeEach {
        $script:VsCodeTestLog = Join-Path $TestDrive 'code.log'
        Remove-Item $script:VsCodeTestLog -Force -ErrorAction SilentlyContinue
        $env:VSCODE_TEST_LOG = $script:VsCodeTestLog
        Add-FakeCode -Path (Join-Path $TestDrive 'bin')
    }

    AfterEach {
        Remove-Item Env:\VSCODE_TEST_LOG -ErrorAction SilentlyContinue
    }

    It 'rejects an unsafe extension id before invoking code' {
        { Install-VsCodeExtension -Id 'publisher.extension&echo-bad' -Confirm:$false } |
            Should -Throw '*Unsafe InstallExtension value*'
        Test-Path $script:VsCodeTestLog | Should -BeFalse
    }

    It 'allows a normal extension id through to code' {
        Install-VsCodeExtension -Id 'ms-python.python' -Confirm:$false

        Get-Content $script:VsCodeTestLog -Raw | Should -Match '--install-extension ms-python.python'
    }

    It 'rejects an invalid goto target before invoking code' {
        { Start-VsCode -Goto 'src\file.ps1:not-a-line' -Confirm:$false } |
            Should -Throw '*Unsafe Goto value*'
        Test-Path $script:VsCodeTestLog | Should -BeFalse
    }

    It 'passes path arguments after an option separator' {
        $workspace = Join-Path $TestDrive 'workspace'
        New-Item -ItemType Directory -Path $workspace -Force | Out-Null

        Start-VsCode -Path $workspace -Confirm:$false

        Get-Content $script:VsCodeTestLog -Raw | Should -Match ([regex]::Escape("-- $workspace"))
    }
}

Describe 'Get-PipPackages' {
    BeforeEach {
        function global:pip { }
    }

    AfterEach {
        Remove-Item Function:\pip -ErrorAction SilentlyContinue
    }

    It 'parses package names and versions from JSON output' {
        Mock -ModuleName Shmuelie.Utilities pip {
            '[{"name":"requests","version":"2.31.0"},{"name":"pytest","version":"8.0.0"}]'
        }

        $packages = @(Get-PipPackages)

        $packages | Should -HaveCount 2
        $packages[0].name | Should -BeExactly 'requests'
        $packages[0].version | Should -BeExactly '2.31.0'
        $packages[1].name | Should -BeExactly 'pytest'
        $packages[1].version | Should -BeExactly '8.0.0'
        Should -Invoke -ModuleName Shmuelie.Utilities pip -Times 1
    }

    It 'parses JSON when stdout includes warning lines' {
        Mock -ModuleName Shmuelie.Utilities pip {
            @(
                'WARNING: Ignoring invalid distribution -ip'
                '[{"name":"setuptools","version":"70.0.0"}]'
                '[notice] A new release of pip is available'
            )
        }

        $packages = @(Get-PipPackages -PackageState Outdated)

        $packages | Should -HaveCount 1
        $packages[0].name | Should -BeExactly 'setuptools'
        $packages[0].version | Should -BeExactly '70.0.0'
    }
}

Describe 'Get-UvPackages' {
    BeforeEach {
        function global:uv { }
    }

    AfterEach {
        Remove-Item Function:\uv -ErrorAction SilentlyContinue
    }

    It 'parses package names and versions from JSON output' {
        Mock -ModuleName Shmuelie.Utilities uv {
            '[{"name":"ruff","version":"0.6.1"},{"name":"mypy","version":"1.11.0"}]'
        }

        $packages = @(Get-UvPackages)

        $packages | Should -HaveCount 2
        $packages[0].name | Should -BeExactly 'ruff'
        $packages[0].version | Should -BeExactly '0.6.1'
        $packages[1].name | Should -BeExactly 'mypy'
        $packages[1].version | Should -BeExactly '1.11.0'
        Should -Invoke -ModuleName Shmuelie.Utilities uv -Times 1
    }

    It 'parses JSON when stdout includes warning lines' {
        Mock -ModuleName Shmuelie.Utilities uv {
            @(
                'Using Python 3.12.0 environment at .venv'
                '[{"name":"black","version":"24.8.0","latest_version":"24.10.0"}]'
                'warning: cache entry ignored'
            )
        }

        $packages = @(Get-UvPackages -Outdated)

        $packages | Should -HaveCount 1
        $packages[0].name | Should -BeExactly 'black'
        $packages[0].version | Should -BeExactly '24.8.0'
    }
}

Describe 'Get-DotNetTool' {
    BeforeEach {
        function global:dotnet { }
    }

    AfterEach {
        Remove-Item Function:\dotnet -ErrorAction SilentlyContinue
    }

    It 'parses package ids, versions, and commands from tool list output' {
        Mock -ModuleName Shmuelie.Utilities dotnet {
            @(
                'Package Id        Version      Commands'
                '---------------------------------------'
                'dotnet-ef         8.0.7        dotnet-ef'
                'dotnet-outdated   4.6.4        dotnet-outdated'
            )
        }

        $tools = @(Get-DotNetTool)

        $tools | Should -HaveCount 2
        $tools[0].PackageId | Should -BeExactly 'dotnet-ef'
        $tools[0].Version | Should -BeExactly '8.0.7'
        $tools[0].Commands | Should -BeExactly 'dotnet-ef'
        $tools[0].Global | Should -BeTrue
        $tools[1].PackageId | Should -BeExactly 'dotnet-outdated'
        $tools[1].Version | Should -BeExactly '4.6.4'
    }

    It 'filters tools by package id' {
        Mock -ModuleName Shmuelie.Utilities dotnet {
            @(
                'Package Id        Version      Commands'
                '---------------------------------------'
                'dotnet-ef         8.0.7        dotnet-ef'
                'dotnet-outdated   4.6.4        dotnet-outdated'
            )
        }

        $tools = @(Get-DotNetTool -Name 'dotnet-e*')

        $tools | Should -HaveCount 1
        $tools[0].PackageId | Should -BeExactly 'dotnet-ef'
        $tools[0].Version | Should -BeExactly '8.0.7'
    }
}

Describe 'Repair-GlobalJson' {
    It 'sets sdk.rollForward to disable' {
        $globalJson = Join-Path $TestDrive 'global.json'
        Set-Content -Path $globalJson -Value '{"sdk":{"version":"9.0.100","rollForward":"latestFeature"}}'

        Push-Location $TestDrive
        try {
            Repair-GlobalJson -Confirm:$false
        } finally {
            Pop-Location
        }

        $content = Get-Content $globalJson -Raw | ConvertFrom-Json
        $content.sdk.version | Should -BeExactly '9.0.100'
        $content.sdk.rollForward | Should -BeExactly 'disable'
    }

    It 'does not change global.json under WhatIf' {
        $globalJson = Join-Path $TestDrive 'global.json'
        $original = '{"sdk":{"version":"9.0.100","rollForward":"latestFeature"}}'
        Set-Content -Path $globalJson -Value $original

        Push-Location $TestDrive
        try {
            Repair-GlobalJson -WhatIf
        } finally {
            Pop-Location
        }

        (Get-Content $globalJson -Raw).Trim() | Should -BeExactly $original
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
        Mock -ModuleName Shmuelie.Utilities Get-CimInstance {
            [PSCustomObject]@{
                Name      = 'ExampleSvc'
                ProcessId = 4242
                PathName  = 'C:\Windows\System32\svchost.exe -k netsvcs'
            }
        }
        Mock -ModuleName Shmuelie.Utilities Get-Service {
            [PSCustomObject]@{
                Name        = 'ExampleSvc'
                DisplayName = 'Example Service'
                Status      = 'Running'
            }
        }
        Mock -ModuleName Shmuelie.Utilities Get-Process { $fakeProcess } -ParameterFilter { $Id -eq 4242 }

        $process = Get-ServiceProcess -Name ExampleSvc

        $process.Id | Should -Be 4242
        $process.ProcessName | Should -BeExactly 'svchost'
        Should -Invoke -ModuleName Shmuelie.Utilities Get-CimInstance -Times 1
        Should -Invoke -ModuleName Shmuelie.Utilities Get-Service -Times 1
        Should -Invoke -ModuleName Shmuelie.Utilities Get-Process -Times 1 -ParameterFilter { $Id -eq 4242 }
    }
}
