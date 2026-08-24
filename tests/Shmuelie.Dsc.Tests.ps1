#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.2.0' }

BeforeAll {
    $repoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent
    $script:ModuleManifest = [System.IO.Path]::Combine($repoRoot, 'modules', 'Shmuelie.Dsc', 'Shmuelie.Dsc.psd1')
    Import-Module $script:ModuleManifest -Force
}

AfterAll {
    Remove-Module Shmuelie.Dsc -Force -ErrorAction SilentlyContinue
}

Describe 'Shmuelie.Dsc module' {
    It 'exports the expected DSC resources' {
        $data = Import-PowerShellDataFile $script:ModuleManifest
        ($data.DscResourcesToExport | Sort-Object) | Should -Be (@('SavePSResource', 'SymbolicLink', 'CopilotPlugin', 'CopilotMarketplace', 'UvTool') | Sort-Object)
    }

    It 'exports no functions or aliases' {
        $data = Import-PowerShellDataFile $script:ModuleManifest
        $data.FunctionsToExport.Count | Should -Be 0
        $data.AliasesToExport.Count | Should -Be 0
    }
}

Describe 'SavePSResource' {
    It 'is absent when the module folder does not exist and present once it does' {
        InModuleScope Shmuelie.Dsc -Parameters @{ Root = $TestDrive } {
            param($Root)

            $resource = [SavePSResource]@{ Name = 'Pester'; Path = $Root }
            $resource.Test() | Should -BeFalse

            New-Item -ItemType Directory -Path (Join-Path $Root 'Pester') | Out-Null
            $resource.Test() | Should -BeTrue
        }
    }

    It 'saves from the requested repository into the requested path' {
        InModuleScope Shmuelie.Dsc -Parameters @{ Root = $TestDrive } {
            param($Root)

            Mock Save-PSResource { }
            $resource = [SavePSResource]@{ Name = 'Pester'; Path = $Root; Repository = 'PSGallery' }
            $resource.Set()

            Should -Invoke Save-PSResource -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'Pester' -and $Path -eq $Root -and $Repository -eq 'PSGallery'
            }
        }
    }

    It 'defaults the repository to PSGallery' {
        InModuleScope Shmuelie.Dsc {
            ([SavePSResource]@{ Name = 'X'; Path = 'C:\Modules' }).Repository | Should -Be 'PSGallery'
        }
    }
}

Describe 'SymbolicLink' {
    It 'is not in the desired state when the path is missing' {
        InModuleScope Shmuelie.Dsc {
            Mock Get-Item { $null }
            ([SymbolicLink]@{ Path = 'C:\link'; Target = 'C:\target' }).Test() | Should -BeFalse
        }
    }

    It 'is not in the desired state when the item is not a symbolic link' {
        InModuleScope Shmuelie.Dsc {
            Mock Get-Item { [pscustomobject]@{ LinkType = $null; Target = 'C:\target' } }
            ([SymbolicLink]@{ Path = 'C:\link'; Target = 'C:\target' }).Test() | Should -BeFalse
        }
    }

    It 'is in the desired state only when the link target matches' {
        InModuleScope Shmuelie.Dsc {
            Mock Get-Item { [pscustomobject]@{ LinkType = 'SymbolicLink'; Target = 'C:\target' } }
            ([SymbolicLink]@{ Path = 'C:\link'; Target = 'C:\target' }).Test() | Should -BeTrue
            ([SymbolicLink]@{ Path = 'C:\link'; Target = 'C:\other' }).Test() | Should -BeFalse
        }
    }

    It 'creates the parent directory and the symbolic link' {
        InModuleScope Shmuelie.Dsc -Parameters @{ Root = $TestDrive } {
            param($Root)

            Mock New-DscSymbolicLink { }
            $linkPath = Join-Path $Root 'sub\link'

            ([SymbolicLink]@{ Path = $linkPath; Target = 'C:\target' }).Set()

            Test-Path -LiteralPath (Join-Path $Root 'sub') | Should -BeTrue
            Should -Invoke New-DscSymbolicLink -Times 1 -Exactly -ParameterFilter {
                $Path -eq $linkPath -and $Target -eq 'C:\target'
            }
        }
    }
}

Describe 'CopilotPlugin' {
    It 'detects an installed plugin by its name token' {
        InModuleScope Shmuelie.Dsc {
            Mock Invoke-DscCopilot { [pscustomobject]@{ Output = @('my-plugin  installed'); ExitCode = 0 } }
            ([CopilotPlugin]@{ Source = 'owner/my-plugin' }).Test() | Should -BeTrue
            ([CopilotPlugin]@{ Source = 'my-plugin@some-market' }).Test() | Should -BeTrue
        }
    }

    It 'reports not installed when the plugin is absent' {
        InModuleScope Shmuelie.Dsc {
            Mock Invoke-DscCopilot { [pscustomobject]@{ Output = @('other-plugin'); ExitCode = 0 } }
            ([CopilotPlugin]@{ Source = 'owner/my-plugin' }).Test() | Should -BeFalse
        }
    }

    It 'installs the source and throws on a non-zero exit code' {
        InModuleScope Shmuelie.Dsc {
            Mock Invoke-DscCopilot { [pscustomobject]@{ Output = 'ok'; ExitCode = 0 } }
            { ([CopilotPlugin]@{ Source = 'owner/my-plugin' }).Set() } | Should -Not -Throw
            Should -Invoke Invoke-DscCopilot -ParameterFilter { $Arguments -join ' ' -eq 'plugin install owner/my-plugin' }

            Mock Invoke-DscCopilot { [pscustomobject]@{ Output = 'boom'; ExitCode = 1 } }
            { ([CopilotPlugin]@{ Source = 'owner/my-plugin' }).Set() } | Should -Throw '*Failed to install Copilot plugin*'
        }
    }
}

Describe 'CopilotMarketplace' {
    It 'detects a registered marketplace by name' {
        InModuleScope Shmuelie.Dsc {
            Mock Invoke-DscCopilot { [pscustomobject]@{ Output = @('dotnet-skills  dotnet/skills'); ExitCode = 0 } }
            ([CopilotMarketplace]@{ Name = 'dotnet-skills'; Repository = 'dotnet/skills' }).Test() | Should -BeTrue
            ([CopilotMarketplace]@{ Name = 'absent'; Repository = 'x/y' }).Test() | Should -BeFalse
        }
    }

    It 'registers the marketplace and throws on a non-zero exit code' {
        InModuleScope Shmuelie.Dsc {
            Mock Invoke-DscCopilot { [pscustomobject]@{ Output = 'ok'; ExitCode = 0 } }
            { ([CopilotMarketplace]@{ Name = 'dotnet-skills'; Repository = 'dotnet/skills' }).Set() } | Should -Not -Throw
            Should -Invoke Invoke-DscCopilot -ParameterFilter {
                $Arguments -join ' ' -eq 'plugin marketplace add dotnet-skills dotnet/skills'
            }

            Mock Invoke-DscCopilot { [pscustomobject]@{ Output = 'boom'; ExitCode = 2 } }
            { ([CopilotMarketplace]@{ Name = 'dotnet-skills'; Repository = 'dotnet/skills' }).Set() } | Should -Throw '*Failed to register Copilot marketplace*'
        }
    }
}

Describe 'UvTool' {
    It 'detects an installed tool and reports absence' {
        InModuleScope Shmuelie.Dsc {
            Mock Invoke-DscUv { [pscustomobject]@{ Output = @('fast-agent-mcp v1.2.3'); ExitCode = 0 } }
            ([UvTool]@{ Name = 'fast-agent-mcp' }).Test() | Should -BeTrue
            ([UvTool]@{ Name = 'not-installed' }).Test() | Should -BeFalse
        }
    }

    It 'installs the tool and throws on a non-zero exit code' {
        InModuleScope Shmuelie.Dsc {
            Mock Invoke-DscUv { [pscustomobject]@{ Output = 'ok'; ExitCode = 0 } }
            { ([UvTool]@{ Name = 'fast-agent-mcp' }).Set() } | Should -Not -Throw
            Should -Invoke Invoke-DscUv -ParameterFilter { $Arguments -join ' ' -eq 'tool install fast-agent-mcp' }

            Mock Invoke-DscUv { [pscustomobject]@{ Output = 'boom'; ExitCode = 1 } }
            { ([UvTool]@{ Name = 'fast-agent-mcp' }).Set() } | Should -Throw '*Failed to install uv tool*'
        }
    }
}
