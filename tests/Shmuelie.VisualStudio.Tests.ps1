#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.2.0' }

BeforeAll {
    $repoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent
    $script:ModuleManifest = [System.IO.Path]::Combine($repoRoot, 'modules', 'Shmuelie.VisualStudio', 'Shmuelie.VisualStudio.psd1')
    Import-Module $script:ModuleManifest -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module Shmuelie.VisualStudio -Force -ErrorAction SilentlyContinue
}

Describe 'Shmuelie.VisualStudio module' {
    It 'exports the expected functions and no aliases' {
        $data = Import-PowerShellDataFile $script:ModuleManifest
        $expected = @('Get-InstalledVsVersion', 'Resolve-MSBuild', 'Start-DevShell') | Sort-Object
        ($data.FunctionsToExport | Sort-Object) | Should -Be $expected
        ((Get-Module Shmuelie.VisualStudio).ExportedFunctions.Keys | Sort-Object) | Should -Be $expected
        $data.AliasesToExport.Count | Should -Be 0
    }

    Describe 'Resolve-MSBuild' {
        BeforeAll {
            if (-not $TestDrive -or -not (Test-Path -LiteralPath $TestDrive -PathType Container -ErrorAction Stop)) {
                throw 'Pester TestDrive is required for synthetic Visual Studio paths.'
            }
            InModuleScope Shmuelie.VisualStudio -Parameters @{ FixtureRoot = $TestDrive } {
                param($FixtureRoot)
                $script:MSBuildFixtureRoot = $FixtureRoot
            }
        }

        BeforeEach {
            InModuleScope Shmuelie.VisualStudio {
                $script:MSBuildInstances = @(
                    [pscustomobject]@{ installationVersion = '17.9.12345.1'; installationPath = (Join-Path $script:MSBuildFixtureRoot 'VS Old') },
                    [pscustomobject]@{ installationVersion = '18.0.100.1'; installationPath = (Join-Path $script:MSBuildFixtureRoot 'Build Tools') },
                    [pscustomobject]@{ installationVersion = '17.10.12345.2'; installationPath = (Join-Path $script:MSBuildFixtureRoot 'VS New') }
                )
                Mock Test-IsWindowsPlatform { $true }
                Mock Get-MSBuildDefaultArchitecture { 'x64' }
                Mock Invoke-VsWhere { $script:MSBuildInstances }
                Mock Test-Path { $true }
                Mock Invoke-MSBuildVsWhere { throw 'Unexpected native discovery' }
                Mock Get-InstalledVsVersion { throw 'Unexpected Set-VS provider discovery' }
                Mock Invoke-DevShellProcess { throw 'Unexpected developer shell' }
                Mock Start-Process { throw 'Unexpected process launch' }
            }
        }

        It 'returns one typed result from the newest installation without changing the environment' {
            InModuleScope Shmuelie.VisualStudio {
                $originalPath = $env:PATH
                $originalLocation = (Get-Location).Path
                $results = @(Resolve-MSBuild)

                $results | Should -HaveCount 1
                $result = $results[0]
                $result.PSTypeNames | Should -Contain 'MSBuildInstallation'
                $result.Path | Should -Be (Join-Path $script:MSBuildInstances[1].installationPath 'MSBuild' 'Current' 'Bin' 'amd64' 'MSBuild.exe')
                $result.VisualStudioVersion | Should -BeOfType ([version])
                $result.VisualStudioVersion | Should -Be ([version]'18.0.100.1')
                $result.VisualStudioYear | Should -Be 2026
                $result.InstallationPath | Should -Be $script:MSBuildInstances[1].installationPath
                $result.Architecture | Should -Be 'x64'
                $env:PATH | Should -Be $originalPath
                (Get-Location).Path | Should -Be $originalLocation
                Should -Invoke Invoke-VsWhere -Times 1 -Exactly -ParameterFilter { $MSBuild }
                Should -Invoke Get-InstalledVsVersion -Times 0
                Should -Invoke Start-Process -Times 0
                Should -Invoke Invoke-DevShellProcess -Times 0
            }
        }

        It 'filters version <Filter> numerically' -ForEach @(
            @{ Filter = '2022'; Expected = '17.10.12345.2' }
            @{ Filter = '17'; Expected = '17.10.12345.2' }
            @{ Filter = '17.9'; Expected = '17.9.12345.1' }
            @{ Filter = '17.09'; Expected = '17.9.12345.1' }
            @{ Filter = '17.10.12345'; Expected = '17.10.12345.2' }
            @{ Filter = '17.10.12345.2'; Expected = '17.10.12345.2' }
            @{ Filter = '2026'; Expected = '18.0.100.1' }
            @{ Filter = '18.0'; Expected = '18.0.100.1' }
        ) {
            InModuleScope Shmuelie.VisualStudio -Parameters @{ Filter = $Filter; Expected = $Expected } {
                param($Filter, $Expected)
                (Resolve-MSBuild -Version $Filter).VisualStudioVersion | Should -Be ([version]$Expected)
            }
        }

        It 'resolves architecture <Arch> without fallback' -ForEach @(
            @{ Arch = 'x86'; Folder = ''; Expected = 'x86' }
            @{ Arch = 'x64'; Folder = 'amd64'; Expected = 'x64' }
            @{ Arch = 'amd64'; Folder = 'amd64'; Expected = 'x64' }
            @{ Arch = 'ARM64'; Folder = 'arm64'; Expected = 'arm64' }
        ) {
            InModuleScope Shmuelie.VisualStudio -Parameters @{ Arch = $Arch; Folder = $Folder; Expected = $Expected } {
                param($Arch, $Folder, $Expected)
                $bin = Join-Path $script:MSBuildInstances[1].installationPath 'MSBuild' 'Current' 'Bin'
                if ($Folder) { $bin = Join-Path $bin $Folder }

                $result = Resolve-MSBuild -Arch $Arch

                $result.Path | Should -Be (Join-Path $bin 'MSBuild.exe')
                $result.Architecture | Should -Be $Expected
                Should -Invoke Get-MSBuildDefaultArchitecture -Times 0
                Should -Invoke Test-Path -Times 1 -Exactly -ParameterFilter { $PathType -eq 'Leaf' }
            }
        }

        It 'uses the native OS architecture when none is requested' {
            InModuleScope Shmuelie.VisualStudio {
                Mock Get-MSBuildDefaultArchitecture { 'arm64' }
                (Resolve-MSBuild).Architecture | Should -Be 'arm64'
            }
        }

        It 'returns just a string with PathOnly' {
            InModuleScope Shmuelie.VisualStudio {
                $result = @(Resolve-MSBuild -PathOnly)
                $result | Should -HaveCount 1
                $result[0] | Should -BeOfType ([string])
                $result[0] | Should -Be (Resolve-MSBuild).Path
            }
        }

        It 'skips newer installations without the requested executable' {
            InModuleScope Shmuelie.VisualStudio {
                Mock Test-Path { $LiteralPath -notlike '*Build Tools*' }
                (Resolve-MSBuild).VisualStudioVersion | Should -Be ([version]'17.10.12345.2')
            }
        }

        It 'breaks equal version ties by installation path' {
            InModuleScope Shmuelie.VisualStudio {
                $script:MSBuildInstances = @(
                    [pscustomobject]@{ installationVersion = '18.0.100.1'; installationPath = (Join-Path $script:MSBuildFixtureRoot 'Z') },
                    [pscustomobject]@{ installationVersion = '18.0.100.1'; installationPath = (Join-Path $script:MSBuildFixtureRoot 'A') }
                )
                (Resolve-MSBuild).InstallationPath | Should -Be $script:MSBuildInstances[1].installationPath
            }
        }

        It 'uses the Visual Studio 2017 toolset layout for <Arch>' -ForEach @(
            @{ Arch = 'x86'; Folder = '' }
            @{ Arch = 'x64'; Folder = 'amd64' }
        ) {
            InModuleScope Shmuelie.VisualStudio -Parameters @{ Arch = $Arch; Folder = $Folder } {
                param($Arch, $Folder)
                $script:MSBuildInstances = @(
                    [pscustomobject]@{ installationVersion = '15.9.100.1'; installationPath = (Join-Path $script:MSBuildFixtureRoot 'VS2017') }
                )
                $bin = Join-Path $script:MSBuildInstances[0].installationPath 'MSBuild' '15.0' 'Bin'
                if ($Folder) { $bin = Join-Path $bin $Folder }
                (Resolve-MSBuild -Version 2017 -Architecture $Arch).Path | Should -Be (Join-Path $bin 'MSBuild.exe')
            }
        }

        It 'does not invent a year for an unknown future Visual Studio major' {
            InModuleScope Shmuelie.VisualStudio {
                $script:MSBuildInstances = @(
                    [pscustomobject]@{ installationVersion = '19.0.100.1'; installationPath = (Join-Path $script:MSBuildFixtureRoot 'Future') }
                )
                $result = Resolve-MSBuild
                $result.VisualStudioVersion | Should -Be ([version]'19.0.100.1')
                $result.VisualStudioYear | Should -BeNullOrEmpty
            }
        }

        It 'reports a clear error when no installation exists' {
            InModuleScope Shmuelie.VisualStudio {
                Mock Invoke-VsWhere { @() }
                { Resolve-MSBuild } | Should -Throw "*No compatible Visual Studio MSBuild.exe*architecture 'x64'*"
            }
        }

        It 'reports the requested version and architecture when none match' {
            InModuleScope Shmuelie.VisualStudio {
                { Resolve-MSBuild -Version 2019 -Architecture x86 } | Should -Throw "*Visual Studio '2019'*architecture 'x86'*"
            }
        }

        It 'does not choose an executable of a different architecture' {
            InModuleScope Shmuelie.VisualStudio {
                Mock Test-Path { $LiteralPath -notlike '*arm64*' }
                { Resolve-MSBuild -Architecture arm64 } | Should -Throw "*No compatible Visual Studio MSBuild.exe*architecture 'arm64'*"
            }
        }

        It 'does not treat a directory named MSBuild.exe as an executable' {
            InModuleScope Shmuelie.VisualStudio {
                Mock Test-Path { $PathType -ne 'Leaf' }
                { Resolve-MSBuild } | Should -Throw '*No compatible Visual Studio MSBuild.exe*'
            }
        }

        It 'propagates filesystem discovery failures instead of trying another installation' {
            InModuleScope Shmuelie.VisualStudio {
                Mock Test-Path { throw 'Access denied fixture' }
                { Resolve-MSBuild } | Should -Throw '*Access denied fixture*'
                Should -Invoke Test-Path -Times 1 -Exactly
            }
        }

        It 'propagates vswhere failures without a success-shaped result' {
            InModuleScope Shmuelie.VisualStudio {
                Mock Invoke-VsWhere { throw 'Discovery failed fixture' }
                { Resolve-MSBuild } | Should -Throw '*Discovery failed fixture*'
                Should -Invoke Test-Path -Times 0
            }
        }

        It 'rejects invalid version <Filter> before discovery' -ForEach @(
            @{ Filter = 'latest' }, @{ Filter = '[17,18)' }, @{ Filter = '2025' }, @{ Filter = '17.*' }, @{ Filter = '14' }
            @{ Filter = '17.999999999999999999999999' }, @{ Filter = '' }
        ) {
            InModuleScope Shmuelie.VisualStudio -Parameters @{ Filter = $Filter } {
                param($Filter)
                { Resolve-MSBuild -Version $Filter } | Should -Throw
                Should -Invoke Invoke-VsWhere -Times 0
            }
        }

        It 'rejects an unsupported executable architecture before discovery' {
            InModuleScope Shmuelie.VisualStudio {
                { Resolve-MSBuild -Architecture sparc } | Should -Throw
                Should -Invoke Invoke-VsWhere -Times 0
            }
        }

        It 'throws off Windows before inspecting the OS architecture or installations' {
            InModuleScope Shmuelie.VisualStudio {
                Mock Test-IsWindowsPlatform { $false }
                { Resolve-MSBuild } | Should -Throw '*Resolve-MSBuild is only supported on Windows.*'
                Should -Invoke Get-MSBuildDefaultArchitecture -Times 0
                Should -Invoke Invoke-VsWhere -Times 0
                Should -Invoke Test-Path -Times 0
            }
        }
    }

    Describe 'MSBuild vswhere discovery' {
        BeforeEach {
            InModuleScope Shmuelie.VisualStudio {
                Mock Get-VsInstallerPath { (Get-Location).Path }
                Mock Test-Path { $true }
                Mock Invoke-MSBuildVsWhere { '[]' }
            }
        }

        It 'uses the existing installer path helper and parses metadata' {
            InModuleScope Shmuelie.VisualStudio {
                Mock Invoke-MSBuildVsWhere {
                    ConvertTo-Json -InputObject @(
                        @{ installationVersion = '18.0.100.1'; installationPath = (Get-Location).Path }
                    )
                }
                $result = @(Invoke-VsWhere -MSBuild)
                $result | Should -HaveCount 1
                $result[0].installationVersion | Should -Be '18.0.100.1'
                Should -Invoke Get-VsInstallerPath -Times 1 -Exactly
                Should -Invoke Invoke-MSBuildVsWhere -Times 1 -Exactly -ParameterFilter {
                    $Path -eq (Join-Path (Get-Location).Path 'vswhere.exe')
                }
            }
        }

        It 'returns no instances for valid empty discovery' {
            InModuleScope Shmuelie.VisualStudio {
                @(Invoke-VsWhere -MSBuild) | Should -HaveCount 0
            }
        }

        It 'reports a missing installer directory' {
            InModuleScope Shmuelie.VisualStudio {
                Mock Get-VsInstallerPath { $null }
                { Invoke-VsWhere -MSBuild } | Should -Throw '*vswhere.exe was not found*'
                Should -Invoke Invoke-MSBuildVsWhere -Times 0
            }
        }

        It 'reports a missing vswhere executable' {
            InModuleScope Shmuelie.VisualStudio {
                Mock Test-Path { $false }
                { Invoke-VsWhere -MSBuild } | Should -Throw '*vswhere.exe was not found*'
                Should -Invoke Invoke-MSBuildVsWhere -Times 0
            }
        }

        It 'rejects an invalid installation version even with an absolute path' {
            InModuleScope Shmuelie.VisualStudio {
                Mock Invoke-MSBuildVsWhere {
                    ConvertTo-Json -InputObject @(
                        @{ installationVersion = 'invalid'; installationPath = (Get-Location).Path }
                    )
                }
                { Invoke-VsWhere -MSBuild } | Should -Throw '*invalid installation metadata*'
            }
        }

        It 'rejects invalid discovery output <Json>' -ForEach @(
            @{ Json = '' }
            @{ Json = 'invalid json' }
            @{ Json = 'null' }
            @{ Json = '{}' }
            @{ Json = '[{}]' }
            @{ Json = '[{"installationPath":"relative","installationVersion":"18.0"}]' }
        ) {
            InModuleScope Shmuelie.VisualStudio -Parameters @{ Json = $Json } {
                param($Json)
                Mock Invoke-MSBuildVsWhere { $Json }
                { Invoke-VsWhere -MSBuild } | Should -Throw
            }
        }
    }

    Describe 'MSBuild native discovery arguments' {
        BeforeAll {
            InModuleScope Shmuelie.VisualStudio {
                function script:Invoke-VsWhereFixture {
                    [CmdletBinding()]
                    param($products, $requires, $format, [switch]$utf8)
                    throw 'Fixture must be mocked; no native process is allowed.'
                }
            }
        }

        BeforeEach {
            $script:SavedLastExitCode = $global:LASTEXITCODE
            InModuleScope Shmuelie.VisualStudio {
                Mock Invoke-VsWhereFixture { $global:LASTEXITCODE = 0; '[]' }
            }
        }

        AfterEach {
            $global:LASTEXITCODE = $script:SavedLastExitCode
        }

        AfterAll {
            InModuleScope Shmuelie.VisualStudio {
                Remove-Item Function:\Invoke-VsWhereFixture -ErrorAction Stop
            }
        }

        It 'requests all products with MSBuild without opting into preview or incomplete installations' {
            InModuleScope Shmuelie.VisualStudio {
                Invoke-MSBuildVsWhere -Path Invoke-VsWhereFixture | Should -Be '[]'
                Should -Invoke Invoke-VsWhereFixture -Times 1 -Exactly -ParameterFilter {
                    $products -eq '*' -and $requires -eq 'Microsoft.Component.MSBuild' -and $format -eq 'json' -and $utf8
                }
            }
        }

        It 'reports the exit code and diagnostics when vswhere fails' {
            InModuleScope Shmuelie.VisualStudio {
                Mock Invoke-VsWhereFixture { $global:LASTEXITCODE = 5; 'Fixture failure' }
                { Invoke-MSBuildVsWhere -Path Invoke-VsWhereFixture } | Should -Throw '*exited with code 5*Fixture failure*'
            }
        }
    }
}

Describe 'Get-InstalledVsVersion' {
    Context 'when the platform is Windows' {
        BeforeEach {
            InModuleScope Shmuelie.VisualStudio {
                Mock Test-IsWindowsPlatform { $true }
            }
        }

        It 'returns only vswhere years that have Set-VS commands' {
            InModuleScope Shmuelie.VisualStudio {
                Mock Invoke-VsWhere {
                    @(
                        [pscustomobject]@{ installationVersion = '17.9.12345.1' },
                        [pscustomobject]@{ installationVersion = '18.0.100.1' }
                    )
                }
                Mock Get-Command {
                    if ($Name -eq 'Set-VS2022') { [pscustomobject]@{ Name = $Name } }
                }

                @(Get-InstalledVsVersion) | Should -Be @(2022)
            }
        }

        It 'returns nothing when vswhere is absent' {
            InModuleScope Shmuelie.VisualStudio {
                Mock Invoke-VsWhere { @() }
                Mock Get-Command { [pscustomobject]@{ Name = $Name } }

                @(Get-InstalledVsVersion) | Should -HaveCount 0
            }
        }
    }

    Context 'when the platform is not Windows' {
        It 'throws before attempting discovery' {
            InModuleScope Shmuelie.VisualStudio {
                Mock Test-IsWindowsPlatform { $false }
                Mock Invoke-VsWhere { throw 'vswhere side effect' }

                { Get-InstalledVsVersion } | Should -Throw '*Get-InstalledVsVersion is only supported on Windows.*'
                Should -Invoke Invoke-VsWhere -Times 0
            }
        }
    }
}

Describe 'Start-DevShell' {
    Context 'when the platform is Windows' {
        BeforeEach {
            InModuleScope Shmuelie.VisualStudio {
                Mock Test-IsWindowsPlatform { $true }
                Mock Get-CleanLoginPath { 'C:\Windows\System32;C:\Users\Example\bin;C:\Program Files (x86)\Microsoft Visual Studio\Installer' }
            }
        }

        It 'launches the chosen version without spawning a real process' {
            InModuleScope Shmuelie.VisualStudio {
                $script:SeenEnvironment = $null
                Mock Get-InstalledVsVersion { 2022; 2026 }
                Mock Invoke-DevShellProcess { $script:SeenEnvironment = $Environment }

                Start-DevShell -Version 2022

                $script:SeenEnvironment.VSDEV_VERSION | Should -Be '2022'
                $script:SeenEnvironment.VSDEV_ARCH | Should -Be 'amd64'
                $script:SeenEnvironment.VSDEV_HOSTARCH | Should -Be 'amd64'
                $script:SeenEnvironment.PATH | Should -Match 'Visual Studio\\Installer'
                Should -Invoke Invoke-DevShellProcess -Times 1 -Exactly
            }
        }

        It 'defaults to the latest installed version' {
            InModuleScope Shmuelie.VisualStudio {
                $script:SeenEnvironment = $null
                Mock Get-InstalledVsVersion { 2022; 2026 }
                Mock Invoke-DevShellProcess { $script:SeenEnvironment = $Environment }

                Start-DevShell

                $script:SeenEnvironment.VSDEV_VERSION | Should -Be '2026'
            }
        }

        It 'does not launch a child process under WhatIf' {
            InModuleScope Shmuelie.VisualStudio {
                Mock Get-InstalledVsVersion { 2022 }
                Mock Invoke-DevShellProcess { throw 'launch side effect' }

                Start-DevShell -Version 2022 -WhatIf

                Should -Invoke Invoke-DevShellProcess -Times 0
            }
        }
    }

    Context 'when the platform is not Windows' {
        It 'throws before launching pwsh' {
            InModuleScope Shmuelie.VisualStudio {
                Mock Test-IsWindowsPlatform { $false }
                Mock Get-InstalledVsVersion { 2022 }
                Mock Invoke-DevShellProcess { throw 'launch side effect' }

                { Start-DevShell } | Should -Throw '*Start-DevShell is only supported on Windows.*'
                Should -Invoke Get-InstalledVsVersion -Times 0
                Should -Invoke Invoke-DevShellProcess -Times 0
            }
        }
    }
}
