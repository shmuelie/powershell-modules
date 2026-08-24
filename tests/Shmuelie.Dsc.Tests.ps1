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

Describe 'Private helpers' {
    It 'strips ANSI escape sequences from CLI output' {
        InModuleScope Shmuelie.Dsc {
            $esc = [char]27
            Remove-DscAnsiEscape "$esc[32mfast-agent-mcp$esc[0m v1.2.3" | Should -Be 'fast-agent-mcp v1.2.3'
        }
    }

    It 'matches whole tokens, not substrings' {
        InModuleScope Shmuelie.Dsc {
            Test-DscListContainsToken -Lines @('fast-agent-mcp v1.2.3') -Token 'fast-agent-mcp' | Should -BeTrue
            Test-DscListContainsToken -Lines @('fast-agent-mcp v1.2.3') -Token 'mcp' | Should -BeFalse
            Test-DscListContainsToken -Lines @() -Token 'anything' | Should -BeFalse
        }
    }

    It 'rejects shell-unsafe arguments' {
        InModuleScope Shmuelie.Dsc {
            { Assert-DscSafeArgument -Value 'owner/repo' -Name 'Source' } | Should -Not -Throw
            { Assert-DscSafeArgument -Value 'owner/repo & calc.exe' -Name 'Source' } | Should -Throw '*not allowed*'
        }
    }
}

Describe 'SavePSResource' {
    It 'is absent when the module folder does not exist and present once it does' {
        InModuleScope Shmuelie.Dsc -Parameters @{ Root = $TestDrive } {
            param($Root)

            $dir = Join-Path $Root ([guid]::NewGuid())
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $resource = [SavePSResource]@{ Name = 'Pester'; Path = $dir }
            $resource.Test() | Should -BeFalse

            New-Item -ItemType Directory -Path (Join-Path $dir 'Pester') -Force | Out-Null
            $resource.Test() | Should -BeTrue
        }
    }

    It 'honors an explicit Version by checking the versioned subfolder' {
        InModuleScope Shmuelie.Dsc -Parameters @{ Root = $TestDrive } {
            param($Root)

            $dir = Join-Path $Root ([guid]::NewGuid())
            New-Item -ItemType Directory -Path (Join-Path $dir 'Pester') -Force | Out-Null
            ([SavePSResource]@{ Name = 'Pester'; Path = $dir; Version = '5.5.0' }).Test() | Should -BeFalse

            New-Item -ItemType Directory -Path (Join-Path $dir 'Pester\5.5.0') -Force | Out-Null
            ([SavePSResource]@{ Name = 'Pester'; Path = $dir; Version = '5.5.0' }).Test() | Should -BeTrue
        }
    }

    It 'saves from the requested repository into the requested path' {
        InModuleScope Shmuelie.Dsc -Parameters @{ Root = $TestDrive } {
            param($Root)

            Mock Save-PSResource { }
            ([SavePSResource]@{ Name = 'Pester'; Path = $Root; Repository = 'PSGallery' }).Set()

            Should -Invoke Save-PSResource -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'Pester' -and $Path -eq $Root -and $Repository -eq 'PSGallery'
            }
        }
    }

    It 'passes an explicit Version to Save-PSResource' {
        InModuleScope Shmuelie.Dsc -Parameters @{ Root = $TestDrive } {
            param($Root)

            Mock Save-PSResource { }
            ([SavePSResource]@{ Name = 'Pester'; Path = $Root; Version = '5.5.0' }).Set()

            Should -Invoke Save-PSResource -Times 1 -Exactly -ParameterFilter { $Version -eq '5.5.0' }
        }
    }

    It 'Get() reports Installed and defaults Repository to PSGallery' {
        InModuleScope Shmuelie.Dsc -Parameters @{ Root = $TestDrive } {
            param($Root)

            $dir = Join-Path $Root ([guid]::NewGuid())
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $resource = [SavePSResource]@{ Name = 'Pester'; Path = $dir }
            $resource.Repository | Should -Be 'PSGallery'
            $resource.Get().Installed | Should -BeFalse

            New-Item -ItemType Directory -Path (Join-Path $dir 'Pester') -Force | Out-Null
            $resource.Get().Installed | Should -BeTrue
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

    It 'Get() reports the actual current target across all three states' {
        InModuleScope Shmuelie.Dsc {
            Mock Get-Item { $null }
            ([SymbolicLink]@{ Path = 'C:\link'; Target = 'C:\target' }).Get().Target | Should -Be ''

            Mock Get-Item { [pscustomobject]@{ LinkType = $null; Target = 'C:\whatever' } }
            ([SymbolicLink]@{ Path = 'C:\link'; Target = 'C:\target' }).Get().Target | Should -Be ''

            Mock Get-Item { [pscustomobject]@{ LinkType = 'SymbolicLink'; Target = 'C:\real' } }
            ([SymbolicLink]@{ Path = 'C:\link'; Target = 'C:\target' }).Get().Target | Should -Be 'C:\real'
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
    It 'detects an installed plugin by whole-token match (owner/repo and plugin@marketplace)' {
        InModuleScope Shmuelie.Dsc {
            Mock Invoke-DscCopilot { [pscustomobject]@{ Output = @('my-plugin  installed'); ExitCode = 0 } }
            ([CopilotPlugin]@{ Source = 'owner/my-plugin' }).Test() | Should -BeTrue
            ([CopilotPlugin]@{ Source = 'my-plugin@some-market' }).Test() | Should -BeTrue
        }
    }

    It 'does not false-positive when the desired name is a substring of an installed one' {
        InModuleScope Shmuelie.Dsc {
            Mock Invoke-DscCopilot { [pscustomobject]@{ Output = @('changelog  installed'); ExitCode = 0 } }
            ([CopilotPlugin]@{ Source = 'owner/log' }).Test() | Should -BeFalse
        }
    }

    It 'resolves the name from a market: source and from an explicit Name for URL sources' {
        InModuleScope Shmuelie.Dsc {
            Mock Invoke-DscCopilot { [pscustomobject]@{ Output = @('my-plugin  installed'); ExitCode = 0 } }
            ([CopilotPlugin]@{ Source = 'market:my-plugin@dotnet/skills' }).Test() | Should -BeTrue
            ([CopilotPlugin]@{ Source = 'https://example.com/x/my-plugin.zip'; Name = 'my-plugin' }).Test() | Should -BeTrue
            ([CopilotPlugin]@{ Source = 'https://example.com/x/my-plugin.zip' }).Test() | Should -BeFalse
        }
    }

    It 'installs the source, includes CLI output in errors, and throws on a non-zero exit code' {
        InModuleScope Shmuelie.Dsc {
            Mock Invoke-DscCopilot { [pscustomobject]@{ Output = 'ok'; ExitCode = 0 } }
            { ([CopilotPlugin]@{ Source = 'owner/my-plugin' }).Set() } | Should -Not -Throw
            Should -Invoke Invoke-DscCopilot -ParameterFilter { $Arguments -join ' ' -eq 'plugin install owner/my-plugin' }

            Mock Invoke-DscCopilot { [pscustomobject]@{ Output = 'auth failed'; ExitCode = 1 } }
            { ([CopilotPlugin]@{ Source = 'owner/my-plugin' }).Set() } | Should -Throw '*auth failed*'
        }
    }

    It 'rejects a shell-unsafe Source before invoking the CLI' {
        InModuleScope Shmuelie.Dsc {
            Mock Invoke-DscCopilot { [pscustomobject]@{ Output = 'ok'; ExitCode = 0 } }
            { ([CopilotPlugin]@{ Source = 'owner/repo & calc.exe' }).Set() } | Should -Throw '*not allowed*'
            Should -Invoke Invoke-DscCopilot -Times 0
        }
    }
}

Describe 'CopilotMarketplace' {
    It 'detects a registered marketplace by whole-token match and avoids substring false positives' {
        InModuleScope Shmuelie.Dsc {
            Mock Invoke-DscCopilot { [pscustomobject]@{ Output = @('dotnet-skills  dotnet/skills'); ExitCode = 0 } }
            ([CopilotMarketplace]@{ Name = 'dotnet-skills'; Repository = 'dotnet/skills' }).Test() | Should -BeTrue
            ([CopilotMarketplace]@{ Name = 'dotnet'; Repository = 'dotnet/skills' }).Test() | Should -BeFalse
        }
    }

    It 'registers the marketplace and throws (with output) on a non-zero exit code' {
        InModuleScope Shmuelie.Dsc {
            Mock Invoke-DscCopilot { [pscustomobject]@{ Output = 'ok'; ExitCode = 0 } }
            { ([CopilotMarketplace]@{ Name = 'dotnet-skills'; Repository = 'dotnet/skills' }).Set() } | Should -Not -Throw
            Should -Invoke Invoke-DscCopilot -ParameterFilter {
                $Arguments -join ' ' -eq 'plugin marketplace add dotnet-skills dotnet/skills'
            }

            Mock Invoke-DscCopilot { [pscustomobject]@{ Output = 'nope'; ExitCode = 2 } }
            { ([CopilotMarketplace]@{ Name = 'dotnet-skills'; Repository = 'dotnet/skills' }).Set() } | Should -Throw '*nope*'
        }
    }

    It 'rejects shell-unsafe Name or Repository before invoking the CLI' {
        InModuleScope Shmuelie.Dsc {
            Mock Invoke-DscCopilot { [pscustomobject]@{ Output = 'ok'; ExitCode = 0 } }
            { ([CopilotMarketplace]@{ Name = 'bad&name'; Repository = 'x/y' }).Set() } | Should -Throw '*not allowed*'
            Should -Invoke Invoke-DscCopilot -Times 0
        }
    }
}

Describe 'UvTool' {
    It 'detects an installed tool and avoids substring false positives' {
        InModuleScope Shmuelie.Dsc {
            Mock Invoke-DscUv { [pscustomobject]@{ Output = @('fast-agent-mcp v1.2.3', '- fast-agent'); ExitCode = 0 } }
            ([UvTool]@{ Name = 'fast-agent-mcp' }).Test() | Should -BeTrue
            ([UvTool]@{ Name = 'mcp' }).Test() | Should -BeFalse
            ([UvTool]@{ Name = 'not-installed' }).Test() | Should -BeFalse
        }
    }

    It 'Get() reports Installed via Test()' {
        InModuleScope Shmuelie.Dsc {
            Mock Invoke-DscUv { [pscustomobject]@{ Output = @('fast-agent-mcp v1.2.3'); ExitCode = 0 } }
            ([UvTool]@{ Name = 'fast-agent-mcp' }).Get().Installed | Should -BeTrue
            ([UvTool]@{ Name = 'absent' }).Get().Installed | Should -BeFalse
        }
    }

    It 'installs the tool and throws (with output) on a non-zero exit code' {
        InModuleScope Shmuelie.Dsc {
            Mock Invoke-DscUv { [pscustomobject]@{ Output = 'ok'; ExitCode = 0 } }
            { ([UvTool]@{ Name = 'fast-agent-mcp' }).Set() } | Should -Not -Throw
            Should -Invoke Invoke-DscUv -ParameterFilter { $Arguments -join ' ' -eq 'tool install fast-agent-mcp' }

            Mock Invoke-DscUv { [pscustomobject]@{ Output = 'network error'; ExitCode = 1 } }
            { ([UvTool]@{ Name = 'fast-agent-mcp' }).Set() } | Should -Throw '*network error*'
        }
    }
}
