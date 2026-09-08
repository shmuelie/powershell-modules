#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.2.0' }

BeforeAll {
    $script:repoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent
    $script:modulePath = Join-Path $script:repoRoot 'modules' 'Shmuelie.DotNet' 'Shmuelie.DotNet.psd1'
    Import-Module $script:modulePath -Force
    $script:originalExitCode = $global:LASTEXITCODE
    & (Get-Module Shmuelie.DotNet) {
        function script:dotnet { }
    }
}

AfterAll {
    $global:LASTEXITCODE = $script:originalExitCode
    Remove-Module Shmuelie.DotNet -Force -ErrorAction SilentlyContinue
}

Describe 'Shmuelie.DotNet module contract' {
    It 'exports only the four tool commands without dependencies or aliases' {
        $module = Get-Module Shmuelie.DotNet
        $expected = @('Get-DotNetTool', 'Install-DotNetTool', 'Uninstall-DotNetTool', 'Update-DotNetTool')
        @($module.ExportedFunctions.Keys | Sort-Object) | Should -Be $expected
        $module.ExportedAliases.Count | Should -Be 0
        $module.RequiredModules.Count | Should -Be 0
        $manifest = Test-ModuleManifest $script:modulePath
        $module.Version | Should -Be $manifest.Version
        @($manifest.ExportedFunctions.Keys | Sort-Object) | Should -Be $expected
    }

    It 'provides comment-based help for <Command>' -ForEach @(
        @{ Command = 'Get-DotNetTool' }
        @{ Command = 'Install-DotNetTool' }
        @{ Command = 'Update-DotNetTool' }
        @{ Command = 'Uninstall-DotNetTool' }
    ) {
        $help = Get-Help "Shmuelie.DotNet\$Command" -Full
        $help.Synopsis | Should -Not -BeNullOrEmpty
        $help.examples.example | Should -Not -BeNullOrEmpty
    }

    It 'imports in isolation without invoking dotnet or loading Utilities' {
        $originalRoot = $env:SHMUELIE_DOTNET_TEST_ROOT
        try {
            $env:SHMUELIE_DOTNET_TEST_ROOT = $script:repoRoot
            $result = & pwsh -NoProfile -NonInteractive -Command {
                $ErrorActionPreference = 'Stop'
                function global:dotnet { throw 'Import must not invoke dotnet.' }
                Import-Module (Join-Path $env:SHMUELIE_DOTNET_TEST_ROOT 'modules' 'Shmuelie.DotNet' 'Shmuelie.DotNet.psd1') -WarningAction Stop
                if (Get-Module Shmuelie.Utilities) { throw 'Utilities was loaded.' }
                $PSModuleAutoLoadingPreference = 'None'
                if (Get-Command Invoke-InLocation -ErrorAction SilentlyContinue) { throw 'Private helper was exported.' }
                (Get-Module Shmuelie.DotNet).ExportedFunctions.Count
            }
            $LASTEXITCODE | Should -Be 0
            $result | Should -Be 4
        } finally {
            $env:SHMUELIE_DOTNET_TEST_ROOT = $originalRoot
        }
    }

    It 'preserves Utilities parameter sets, aliases, binding, output types, and ShouldProcess metadata' {
        $originalRoot = $env:SHMUELIE_DOTNET_TEST_ROOT
        try {
            $env:SHMUELIE_DOTNET_TEST_ROOT = $script:repoRoot
            $result = & pwsh -NoProfile -NonInteractive -Command {
                $ErrorActionPreference = 'Stop'
                function Get-Contract {
                    param($Command)
                    $binding = $Command.ScriptBlock.Attributes |
                        Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] }
                    [ordered]@{
                        DefaultParameterSet = $Command.DefaultParameterSet
                        OutputTypes = @($Command.OutputType.Name)
                        SupportsShouldProcess = $binding.SupportsShouldProcess
                        ConfirmImpact = [string]$binding.ConfirmImpact
                        ParameterSets = @(
                            $Command.ParameterSets | Sort-Object Name | ForEach-Object {
                                [ordered]@{
                                    Name = $_.Name
                                    IsDefault = $_.IsDefault
                                    Parameters = @(
                                        $_.Parameters | Sort-Object Name | ForEach-Object {
                                            [ordered]@{
                                                Name = $_.Name
                                                Type = $_.ParameterType.FullName
                                                Position = $_.Position
                                                Mandatory = $_.IsMandatory
                                                Pipeline = $_.ValueFromPipeline
                                                PipelineByPropertyName = $_.ValueFromPipelineByPropertyName
                                                RemainingArguments = $_.ValueFromRemainingArguments
                                                Aliases = @($_.Aliases)
                                            }
                                        }
                                    )
                                }
                            }
                        )
                    } | ConvertTo-Json -Depth 10 -Compress
                }
                $root = Join-Path $env:SHMUELIE_DOTNET_TEST_ROOT 'modules'
                $canonical = Import-Module (Join-Path $root 'Shmuelie.DotNet' 'Shmuelie.DotNet.psd1') -PassThru
                $legacy = Import-Module (Join-Path $root 'Shmuelie.Utilities' 'Shmuelie.Utilities.psd1') -PassThru -WarningAction Stop
                foreach ($name in $canonical.ExportedFunctions.Keys) {
                    if ((Get-Contract $canonical.ExportedFunctions[$name]) -cne (Get-Contract $legacy.ExportedFunctions[$name])) {
                        throw "Contract mismatch for $name"
                    }
                }
                'Compatible'
            }
            $LASTEXITCODE | Should -Be 0
            $result | Should -BeExactly 'Compatible'
        } finally {
            $env:SHMUELIE_DOTNET_TEST_ROOT = $originalRoot
        }
    }

    It 'builds a self-contained publishable module with private helpers' {
        $artifact = & (Join-Path $script:repoRoot 'build' 'Build-Module.ps1') -Module Shmuelie.DotNet -OutputPath $TestDrive
        foreach ($name in @('Shmuelie.DotNet.psd1', 'Shmuelie.DotNet.psm1', 'DotNetHelpers.ps1', 'PrivateHelpers.ps1', 'README.md', 'CHANGELOG.md')) {
            Join-Path $artifact.FullName $name | Should -Exist
        }
        $manifest = Test-ModuleManifest (Join-Path $artifact.FullName 'Shmuelie.DotNet.psd1')
        $manifest.ExportedFunctions.Count | Should -Be 4
        $manifest.RequiredModules.Count | Should -Be 0
    }
}

Describe 'Shmuelie.DotNet tool commands' {
    BeforeEach {
        Mock -ModuleName Shmuelie.DotNet dotnet {
            $global:LASTEXITCODE = 0
        }
    }

    Context 'Get-DotNetTool' {
        BeforeEach {
            Mock -ModuleName Shmuelie.DotNet dotnet {
                $global:LASTEXITCODE = 0
                @(
                    'Package Id        Version      Commands'
                    '---------------------------------------'
                    'dotnet-ef         8.0.7        dotnet-ef'
                    'dotnet-outdated   4.6.4        dotnet-outdated'
                )
            }
        }

        It 'parses package ids, versions, commands, and the existing type name' {
            $tools = @(Shmuelie.DotNet\Get-DotNetTool)
            $tools | Should -HaveCount 2
            $tools[0].PSTypeNames[0] | Should -BeExactly 'DotNetTool'
            $tools[0].PackageId | Should -BeExactly 'dotnet-ef'
            $tools[0].Version | Should -BeExactly '8.0.7'
            $tools[0].Commands | Should -BeExactly 'dotnet-ef'
            $tools[0].Global | Should -BeTrue
            $tools[1].PackageId | Should -BeExactly 'dotnet-outdated'
            $tools[1].Version | Should -BeExactly '4.6.4'
            @($tools[0].PSObject.Properties.Name) | Should -Be @('PackageId', 'Version', 'Commands', 'Global')
        }

        It 'filters tools by package id wildcards' {
            $tools = @(Shmuelie.DotNet\Get-DotNetTool 'dotnet-e*')
            $tools | Should -HaveCount 1
            $tools[0].PackageId | Should -BeExactly 'dotnet-ef'
        }

        It 'returns no objects when a filter matches nothing' {
            @(Shmuelie.DotNet\Get-DotNetTool 'missing-*') | Should -HaveCount 0
        }

        It 'preserves <Scope> list arguments and scope output' -ForEach @(
            @{ Scope = 'global'; Local = $false; Expected = '-g' }
            @{ Scope = 'local'; Local = $true; Expected = '--local' }
        ) {
            $tools = @(Shmuelie.DotNet\Get-DotNetTool -Local:$Local)
            $tools[0].Global | Should -Be (-not $Local)
            Should -Invoke -ModuleName Shmuelie.DotNet dotnet -Times 1 -Exactly -ParameterFilter {
                $args.Count -eq 3 -and $args[0] -eq 'tool' -and $args[1] -eq 'list' -and $args[2] -eq $Expected
            }
        }

        It 'ignores empty lists and malformed rows' {
            Mock -ModuleName Shmuelie.DotNet dotnet {
                'Package Id        Version      Commands'
                '---------------------------------------'
                ''
                'not a tool row'
            }
            @(Shmuelie.DotNet\Get-DotNetTool) | Should -HaveCount 0
        }

        It 'preserves home-directory discovery and restores the caller location' {
            Mock -ModuleName Shmuelie.DotNet dotnet {
                (Get-Location).Path | Should -Be $HOME
            }
            Push-Location $TestDrive
            try {
                Shmuelie.DotNet\Get-DotNetTool | Out-Null
                (Get-Location).Path | Should -Be $TestDrive
                Should -Invoke -ModuleName Shmuelie.DotNet dotnet -Times 1 -Exactly
            } finally {
                Pop-Location
            }
        }

        It 'restores the caller location after a terminating native invocation error' {
            Mock -ModuleName Shmuelie.DotNet dotnet { throw 'dotnet unavailable' }
            Push-Location $TestDrive
            try {
                { Shmuelie.DotNet\Get-DotNetTool } | Should -Throw '*dotnet unavailable*'
                (Get-Location).Path | Should -Be $TestDrive
            } finally {
                Pop-Location
            }
        }

        It 'restores the caller location when downstream stops early' {
            Push-Location $TestDrive
            try {
                Shmuelie.DotNet\Get-DotNetTool | Select-Object -First 1 | Out-Null
                (Get-Location).Path | Should -Be $TestDrive
            } finally {
                Pop-Location
            }
        }
    }

    Context 'Update-DotNetTool' {
        BeforeEach {
            Mock -ModuleName Shmuelie.DotNet dotnet {
                $global:LASTEXITCODE = 0
                "Tool 'dotnet-ef' was successfully updated from version '8.0.7' to version '8.0.8'."
            }
        }

        It 'updates <Scope> tools by name with the original typed output' -ForEach @(
            @{ Scope = 'global'; Local = $false; Expected = '-g' }
            @{ Scope = 'local'; Local = $true; Expected = '--local' }
        ) {
            $result = Shmuelie.DotNet\Update-DotNetTool dotnet-ef -Local:$Local -Confirm:$false
            $result.PSTypeNames[0] | Should -BeExactly 'DotNetToolUpdateResult'
            $result.PackageId | Should -BeExactly 'dotnet-ef'
            $result.Version | Should -BeExactly '8.0.8'
            $result.Updated | Should -BeTrue
            @($result.PSObject.Properties.Name) | Should -Be @('PackageId', 'Version', 'Updated')
            Should -Invoke -ModuleName Shmuelie.DotNet dotnet -Times 1 -Exactly -ParameterFilter {
                ($args -join '|') -eq "tool|update|dotnet-ef|$Expected"
            }
        }

        It 'binds each pipeline object and selects its own global/local scope' {
            $tools = @(
                [pscustomobject]@{ PackageId = 'global-tool'; Global = $true; Version = '1.0.0' }
                [pscustomobject]@{ PackageId = 'local-tool'; Global = $false; Version = '1.0.0' }
            )
            $results = @($tools | Shmuelie.DotNet\Update-DotNetTool -Confirm:$false)
            $results | Should -HaveCount 2
            $results.PackageId | Should -Be @('global-tool', 'local-tool')
            Should -Invoke -ModuleName Shmuelie.DotNet dotnet -Times 1 -Exactly -ParameterFilter {
                ($args -join '|') -eq 'tool|update|global-tool|-g'
            }
            Should -Invoke -ModuleName Shmuelie.DotNet dotnet -Times 1 -Exactly -ParameterFilter {
                ($args -join '|') -eq 'tool|update|local-tool|--local'
            }
        }

        It 'updates from the caller location rather than the discovery location' {
            Mock -ModuleName Shmuelie.DotNet dotnet {
                (Get-Location).Path | Should -Be $TestDrive
            }
            Push-Location $TestDrive
            try {
                Shmuelie.DotNet\Update-DotNetTool dotnet-ef -Local -Confirm:$false | Out-Null
                Should -Invoke -ModuleName Shmuelie.DotNet dotnet -Times 1 -Exactly
            } finally {
                Pop-Location
            }
        }

        It 'retains Updated false when the existing version is reinstalled' {
            Mock -ModuleName Shmuelie.DotNet dotnet {
                "Tool 'dotnet-ef' was successfully reinstalled (version '8.0.8')."
            }
            $result = Shmuelie.DotNet\Update-DotNetTool dotnet-ef -Confirm:$false
            $result.Updated | Should -BeFalse
        }

        It 'parses a trailing version without changing the result shape' {
            Mock -ModuleName Shmuelie.DotNet dotnet { "Installed version '8.0.9'." }
            $result = Shmuelie.DotNet\Update-DotNetTool dotnet-ef -Confirm:$false
            $result.Version | Should -BeExactly '8.0.9'
            $result.Updated | Should -BeFalse
        }

        It 'does not execute updates or produce results under WhatIf by name' {
            @(Shmuelie.DotNet\Update-DotNetTool dotnet-ef -Local -WhatIf) | Should -HaveCount 0
            Should -Invoke -ModuleName Shmuelie.DotNet dotnet -Times 0 -Exactly
        }

        It 'does not execute updates or produce results under WhatIf by object' {
            $tool = [pscustomobject]@{ PackageId = 'dotnet-ef'; Global = $true; Version = '8.0.7' }
            @($tool | Shmuelie.DotNet\Update-DotNetTool -WhatIf) | Should -HaveCount 0
            Should -Invoke -ModuleName Shmuelie.DotNet dotnet -Times 0 -Exactly
        }

        It 'propagates terminating invocation failures rather than fabricating output' {
            Mock -ModuleName Shmuelie.DotNet dotnet { throw 'dotnet unavailable' }
            { Shmuelie.DotNet\Update-DotNetTool dotnet-ef -Confirm:$false } | Should -Throw '*dotnet unavailable*'
        }
    }

    Context 'Install-DotNetTool' {
        BeforeEach {
            Mock -ModuleName Shmuelie.DotNet Get-DotNetTool { }
        }

        It 'installs missing global tools without writing success-stream objects' {
            @(Shmuelie.DotNet\Install-DotNetTool dotnet-ef -Confirm:$false) | Should -HaveCount 0
            Should -Invoke -ModuleName Shmuelie.DotNet Get-DotNetTool -Times 1 -Exactly -ParameterFilter { $Name -eq 'dotnet-ef' }
            Should -Invoke -ModuleName Shmuelie.DotNet dotnet -Times 1 -Exactly -ParameterFilter {
                ($args -join '|') -eq 'tool|install|-g|dotnet-ef'
            }
        }

        It 'skips installation when discovery finds the tool' {
            Mock -ModuleName Shmuelie.DotNet Get-DotNetTool {
                [pscustomobject]@{ PackageId = 'dotnet-ef'; Version = '8.0.7'; Global = $true }
            }
            @(Shmuelie.DotNet\Install-DotNetTool dotnet-ef -Confirm:$false) | Should -HaveCount 0
            Should -Invoke -ModuleName Shmuelie.DotNet dotnet -Times 0 -Exactly
        }

        It 'does not discover or install tools under WhatIf' {
            @(Shmuelie.DotNet\Install-DotNetTool dotnet-ef -WhatIf) | Should -HaveCount 0
            Should -Invoke -ModuleName Shmuelie.DotNet Get-DotNetTool -Times 0 -Exactly
            Should -Invoke -ModuleName Shmuelie.DotNet dotnet -Times 0 -Exactly
        }

        It 'preserves failed installation error text and respects ErrorAction' {
            Mock -ModuleName Shmuelie.DotNet dotnet {
                $global:LASTEXITCODE = 1
                'Native installation failure'
            }
            { Shmuelie.DotNet\Install-DotNetTool dotnet-ef -Confirm:$false -ErrorAction Stop } |
                Should -Throw 'Failed to install tool: dotnet-ef'
        }

        It 'rejects an empty package name before invoking dotnet' {
            { Shmuelie.DotNet\Install-DotNetTool -Name '' -Confirm:$false } | Should -Throw
            Should -Invoke -ModuleName Shmuelie.DotNet dotnet -Times 0 -Exactly
        }
    }

    Context 'Uninstall-DotNetTool' {
        It 'uninstalls global tools by name without success-stream output' {
            @(Shmuelie.DotNet\Uninstall-DotNetTool dotnet-ef -Confirm:$false) | Should -HaveCount 0
            Should -Invoke -ModuleName Shmuelie.DotNet dotnet -Times 1 -Exactly -ParameterFilter {
                ($args -join '|') -eq 'tool|uninstall|-g|dotnet-ef'
            }
        }

        It 'uninstalls every pipeline package with the existing global-only contract' {
            $tools = @(
                [pscustomobject]@{ PackageId = 'first-tool'; Global = $true }
                [pscustomobject]@{ PackageId = 'second-tool'; Global = $true }
            )
            @($tools | Shmuelie.DotNet\Uninstall-DotNetTool -Confirm:$false) | Should -HaveCount 0
            Should -Invoke -ModuleName Shmuelie.DotNet dotnet -Times 1 -Exactly -ParameterFilter {
                ($args -join '|') -eq 'tool|uninstall|-g|first-tool'
            }
            Should -Invoke -ModuleName Shmuelie.DotNet dotnet -Times 1 -Exactly -ParameterFilter {
                ($args -join '|') -eq 'tool|uninstall|-g|second-tool'
            }
        }

        It 'does not execute uninstall under WhatIf by name' {
            @(Shmuelie.DotNet\Uninstall-DotNetTool dotnet-ef -WhatIf) | Should -HaveCount 0
            Should -Invoke -ModuleName Shmuelie.DotNet dotnet -Times 0 -Exactly
        }

        It 'does not execute uninstall under WhatIf by object' {
            $tool = [pscustomobject]@{ PackageId = 'dotnet-ef'; Global = $true }
            @($tool | Shmuelie.DotNet\Uninstall-DotNetTool -WhatIf) | Should -HaveCount 0
            Should -Invoke -ModuleName Shmuelie.DotNet dotnet -Times 0 -Exactly
        }

        It 'preserves failed uninstall error text and respects ErrorAction' {
            Mock -ModuleName Shmuelie.DotNet dotnet {
                $global:LASTEXITCODE = 1
                'Native uninstall failure'
            }
            { Shmuelie.DotNet\Uninstall-DotNetTool dotnet-ef -Confirm:$false -ErrorAction Stop } |
                Should -Throw 'Failed to uninstall tool: dotnet-ef'
        }
    }
}
