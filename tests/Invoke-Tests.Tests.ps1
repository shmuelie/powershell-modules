#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.2.0' }

BeforeAll {
    $script:repoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent
    $script:runnerPath = Join-Path $script:repoRoot 'build' 'Invoke-Tests.ps1'

    function New-RunnerTestPesterModule {
        param([version]$Version, [string]$Prerelease = '')

        [pscustomobject]@{
            Name = 'Pester'
            Version = $Version
            Path = Join-Path $script:repoRoot 'mock-modules' 'Pester' $Version.ToString() 'Pester.psd1'
            PrivateData = @{ PSData = @{ Prerelease = $Prerelease } }
        }
    }

    # Keep bootstrap tests independent of installed package managers and feeds.
    function Install-Module {
        [CmdletBinding()]
        param(
            [string[]]$Name,
            [version]$MinimumVersion,
            [version]$MaximumVersion,
            [string]$Scope,
            [switch]$Force,
            [switch]$AllowPrerelease
        )
        throw 'Unmocked module installation is forbidden.'
    }
}

Describe 'Invoke-Tests runner policy' {
    # Dot-source the runner below so its mocks share the test's script-scoped state.
    BeforeEach {
        $script:availableModules = @()
        $script:runnerConfiguration = New-PesterConfiguration

        Mock Get-Module { $script:availableModules } -ParameterFilter {
            $ListAvailable -and $Name -eq 'Pester'
        }
        Mock Install-Module { throw 'Unexpected module installation.' }
        Mock Import-Module {}
        Mock New-PesterConfiguration { $script:runnerConfiguration }
        Mock Invoke-Pester {}
        Mock Write-Information {}
    }

    It 'selects <ExpectedVersion> from <Scenario> without installing' -ForEach @(
        @{
            Scenario = 'mixed installed major versions in non-version order'
            Versions = @('7.0.0', '6.9.0', '6.12.0', '5.12.0', '6.2.0', '6.10.0', '8.0.0')
            ExpectedVersion = '6.12.0'
        }
        @{
            Scenario = 'the exact minimum with older and newer unsupported releases'
            Versions = @('6.1.999', '7.0.0', '6.2.0')
            ExpectedVersion = '6.2.0'
        }
        @{
            Scenario = 'four-component patch versions'
            Versions = @('6.2.0', '6.2.0.1', '7.0.0')
            ExpectedVersion = '6.2.0.1'
        }
        @{
            Scenario = 'the highest representable version in the supported major'
            Versions = @('7.0.0', '6.2147483647.2147483647.2147483647', '6.9.0')
            ExpectedVersion = '6.2147483647.2147483647.2147483647'
        }
    ) {
        $script:availableModules = @($Versions | ForEach-Object { New-RunnerTestPesterModule $_ })
        $script:expectedModulePath = (New-RunnerTestPesterModule $ExpectedVersion).Path

        . $script:runnerPath -Path 'selected.Tests.ps1'

        Should -Invoke Get-Module -Exactly -Times 1 -ParameterFilter {
            $ListAvailable -and $Name -eq 'Pester'
        }
        Should -Invoke Install-Module -Times 0
        Should -Invoke Import-Module -Exactly -Times 1
        Should -Invoke Import-Module -Exactly -Times 1 -ParameterFilter {
            $Name -eq $script:expectedModulePath -and $Force
        }
        Should -Invoke Invoke-Pester -Exactly -Times 1
        $script:runnerConfiguration.Run.Path.Value | Should -Be @('selected.Tests.ps1')
        $script:runnerConfiguration.Run.Throw.Value | Should -BeTrue
        $script:runnerConfiguration.Output.Verbosity.Value | Should -Be 'Detailed'
        $script:runnerConfiguration.TestResult.Enabled.Value | Should -BeFalse
    }

    It 'prefers a stable release over a newer prerelease' {
        $script:availableModules = @(
            New-RunnerTestPesterModule '6.3.0' -Prerelease 'beta.1'
            New-RunnerTestPesterModule '6.2.0'
        )
        $script:expectedModulePath = (New-RunnerTestPesterModule '6.2.0').Path

        . $script:runnerPath

        Should -Invoke Install-Module -Times 0
        Should -Invoke Import-Module -Exactly -Times 1 -ParameterFilter {
            $Name -eq $script:expectedModulePath -and $Force
        }
    }

    It 'installs only the supported range when <Scenario>' -ForEach @(
        @{ Scenario = 'no Pester is installed'; Versions = @(); Prerelease = '' }
        @{ Scenario = 'only versions below the minimum are installed'; Versions = @('3.4.0', '5.12.0', '6.1.999'); Prerelease = '' }
        @{ Scenario = 'only unsupported newer majors are installed'; Versions = @('7.0.0', '7.2.0', '8.0.0'); Prerelease = '' }
        @{ Scenario = 'only prereleases are installed'; Versions = @('6.2.0', '6.3.0'); Prerelease = 'beta.1' }
    ) {
        $script:availableModules = @($Versions | ForEach-Object { New-RunnerTestPesterModule $_ -Prerelease $Prerelease })
        $script:expectedModulePath = (New-RunnerTestPesterModule '6.9.0').Path
        Mock Install-Module {
            $script:availableModules += @(
                New-RunnerTestPesterModule '6.2.0'
                New-RunnerTestPesterModule '6.9.0'
                New-RunnerTestPesterModule '7.0.0'
                New-RunnerTestPesterModule '6.10.0' -Prerelease 'beta.1'
            )
        }

        . $script:runnerPath -Path 'selected.Tests.ps1'

        Should -Invoke Install-Module -Exactly -Times 1
        Should -Invoke Install-Module -Exactly -Times 1 -ParameterFilter {
            $Name -eq 'Pester' -and
            [version]$MinimumVersion -eq [version]'6.2.0' -and
            [version]$MaximumVersion -eq [version]'6.2147483647.2147483647.2147483647' -and
            $Scope -eq 'CurrentUser' -and $Force -and -not $AllowPrerelease
        }
        Should -Invoke Get-Module -Exactly -Times 2 -ParameterFilter {
            $ListAvailable -and $Name -eq 'Pester'
        }
        Should -Invoke Import-Module -Exactly -Times 1 -ParameterFilter {
            $Name -eq $script:expectedModulePath -and $Force
        }
        Should -Invoke Invoke-Pester -Exactly -Times 1
    }

    It 'fails rather than importing an unsupported version after installation' {
        $script:availableModules = @(New-RunnerTestPesterModule '7.0.0')
        Mock Install-Module {}

        { . $script:runnerPath } |
            Should -Throw '*Unable to locate or install stable Pester >=6.2.0 and <7.0.0.*'

        Should -Invoke Install-Module -Exactly -Times 1
        Should -Invoke Import-Module -Times 0
        Should -Invoke Invoke-Pester -Times 0
    }

    It 'propagates installation errors without importing or running tests' {
        Mock Install-Module { throw 'Module installation failed.' }

        { . $script:runnerPath } | Should -Throw '*Module installation failed.*'

        Should -Invoke Import-Module -Times 0
        Should -Invoke Invoke-Pester -Times 0
    }

    It 'propagates import errors without running tests' {
        $script:availableModules = @(New-RunnerTestPesterModule '6.9.0')
        Mock Import-Module { throw 'Module import failed.' }

        { . $script:runnerPath } | Should -Throw '*Module import failed.*'

        Should -Invoke Install-Module -Times 0
        Should -Invoke Invoke-Pester -Times 0
    }

    It 'defaults to the repository tests directory' {
        $script:availableModules = @(New-RunnerTestPesterModule '6.9.0')

        . $script:runnerPath

        $script:runnerConfiguration.Run.Path.Value | Should -Be @(Join-Path $script:repoRoot 'tests')
        Should -Invoke Invoke-Pester -Exactly -Times 1 -ParameterFilter {
            $Configuration -eq $script:runnerConfiguration
        }
    }

    It 'propagates test failures to the caller' {
        $script:availableModules = @(New-RunnerTestPesterModule '6.9.0')
        Mock Invoke-Pester { throw 'Test run failed.' }

        { . $script:runnerPath } | Should -Throw '*Test run failed.*'

        $script:runnerConfiguration.Run.Throw.Value | Should -BeTrue
    }
}
