#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.2.0' }

BeforeAll {
    $repoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent
    $script:ModuleManifest = [System.IO.Path]::Combine($repoRoot, 'modules', 'Shmuelie.VisualStudio', 'Shmuelie.VisualStudio.psd1')
    Import-Module $script:ModuleManifest -Force
}

AfterAll {
    Remove-Module Shmuelie.VisualStudio -Force -ErrorAction SilentlyContinue
}

Describe 'Shmuelie.VisualStudio module' {
    It 'exports the expected functions and no aliases' {
        $data = Import-PowerShellDataFile $script:ModuleManifest
        ($data.FunctionsToExport | Sort-Object) | Should -Be (@('Get-InstalledVsVersion', 'Start-DevShell') | Sort-Object)
        $data.AliasesToExport.Count | Should -Be 0
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
