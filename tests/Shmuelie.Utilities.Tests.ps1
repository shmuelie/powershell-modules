#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.2.0' }

BeforeAll {
    $repoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent
    Import-Module (Join-Path $repoRoot 'modules' 'Shmuelie.Utilities' 'Shmuelie.Utilities.psd1') -Force

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

Describe 'Update-InstalledPSResource' {
    BeforeEach {
        function New-TestSaveLayout {
            param(
                [Parameter(Mandatory)]
                [string]$Root,

                [Parameter(Mandatory)]
                [string]$Name,

                [string]$Version = '1.0.0'
            )

            # Create a versioned Save-PSResource layout: <Root>/<Name>/<Version>/<Name>.psd1
            $versionRoot = Join-Path $Root $Name $Version
            New-Item -ItemType Directory -Path $versionRoot -Force | Out-Null
            New-ModuleManifest -Path (Join-Path $versionRoot "$Name.psd1") -ModuleVersion $Version -RootModule "$Name.psm1"
        }

        # Default: remote has 2.0.0 available; individual tests set their own installed version.
        Mock -ModuleName Shmuelie.Utilities Find-PSResource {
            [PSCustomObject]@{ Version = [version]'2.0.0' }
        }
        Mock -ModuleName Shmuelie.Utilities Save-PSResource {}
    }

    It 'calls Save-PSResource with correct parameters for an outdated module (1.0.0 installed, 2.0.0 available)' {
        $modulesPath = Join-Path $TestDrive 'Outdated'
        New-TestSaveLayout -Root $modulesPath -Name 'ModuleA' -Version '1.0.0'

        Update-InstalledPSResource -Path $modulesPath -Confirm:$false

        Should -Invoke -ModuleName Shmuelie.Utilities Save-PSResource -Times 1 -ParameterFilter {
            $Name -eq 'ModuleA' -and
            $Version -eq '2.0.0' -and
            $Path -eq (Resolve-Path -LiteralPath $modulesPath).ProviderPath -and
            $Repository -eq 'PSGallery' -and
            $TrustRepository -and $IncludeXml -and $AcceptLicense -and $SkipDependencyCheck
        }
    }

    It 'does not call Save-PSResource for a module already at the latest version' {
        $modulesPath = Join-Path $TestDrive 'Current'
        New-TestSaveLayout -Root $modulesPath -Name 'ModuleA' -Version '2.0.0'

        Update-InstalledPSResource -Path $modulesPath -Confirm:$false

        Should -Invoke -ModuleName Shmuelie.Utilities Save-PSResource -Times 0
    }

    It 'updates only modules under the supplied path, not those in other paths' {
        $modulesPath = Join-Path $TestDrive 'InScope'
        $otherPath = Join-Path $TestDrive 'OutOfScope'
        New-TestSaveLayout -Root $modulesPath -Name 'ModuleA' -Version '1.0.0'
        New-TestSaveLayout -Root $otherPath -Name 'ModuleB' -Version '1.0.0'

        Update-InstalledPSResource -Path $modulesPath -Confirm:$false

        Should -Invoke -ModuleName Shmuelie.Utilities Save-PSResource -Times 1 -ParameterFilter { $Name -eq 'ModuleA' }
        Should -Invoke -ModuleName Shmuelie.Utilities Save-PSResource -Times 0 -ParameterFilter { $Name -eq 'ModuleB' }
    }

    It 'does not call Save-PSResource under -WhatIf, but still queries the repository' {
        $modulesPath = Join-Path $TestDrive 'WhatIf'
        New-TestSaveLayout -Root $modulesPath -Name 'ModuleA' -Version '1.0.0'

        Update-InstalledPSResource -Path $modulesPath -WhatIf

        Should -Invoke -ModuleName Shmuelie.Utilities Find-PSResource -Times 1
        Should -Invoke -ModuleName Shmuelie.Utilities Save-PSResource -Times 0
    }

    It 'is a no-op for a missing path' {
        $modulesPath = Join-Path $TestDrive 'MissingPath'

        { Update-InstalledPSResource -Path $modulesPath -Confirm:$false } | Should -Not -Throw

        Should -Invoke -ModuleName Shmuelie.Utilities Find-PSResource -Times 0
        Should -Invoke -ModuleName Shmuelie.Utilities Save-PSResource -Times 0
    }

    It 'is a no-op for an empty path' {
        $modulesPath = Join-Path $TestDrive 'EmptyPath'
        New-Item -ItemType Directory -Path $modulesPath -Force | Out-Null

        { Update-InstalledPSResource -Path $modulesPath -Confirm:$false } | Should -Not -Throw

        Should -Invoke -ModuleName Shmuelie.Utilities Find-PSResource -Times 0
        Should -Invoke -ModuleName Shmuelie.Utilities Save-PSResource -Times 0
    }
}
