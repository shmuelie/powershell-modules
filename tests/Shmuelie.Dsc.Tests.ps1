#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.2.0' }

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

Describe 'Private helpers' -Tag 'DscDiscovery' {
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

            New-Item -ItemType Directory -Path (Join-Path $dir 'Pester' '5.5.0') -Force | Out-Null
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
            $linkPath = Join-Path $Root 'sub' 'link'

            ([SymbolicLink]@{ Path = $linkPath; Target = 'C:\target' }).Set()

            Test-Path -LiteralPath (Join-Path $Root 'sub') | Should -BeTrue
            Should -Invoke New-DscSymbolicLink -Times 1 -Exactly -ParameterFilter {
                $Path -eq $linkPath -and $Target -eq 'C:\target'
            }
        }
    }
}

Describe 'CopilotPlugin' -Tag 'DscDiscovery' {
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

Describe 'CopilotMarketplace' -Tag 'DscDiscovery' {
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

Describe 'UvTool' -Tag 'DscDiscovery' {
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

Describe 'DSC CLI discovery validation' -Tag 'DscDiscovery' {
    BeforeEach {
        Mock -ModuleName Shmuelie.Dsc Invoke-DscCopilot { throw 'Unexpected Copilot operation.' }
        Mock -ModuleName Shmuelie.Dsc Invoke-DscUv { throw 'Unexpected uv operation.' }
    }

    It '<Resource> handles <Case> without guessing state' -ForEach @(
        foreach ($resource in 'CopilotPlugin', 'CopilotMarketplace', 'UvTool') {
            foreach ($case in @(
                @{ Case = 'successful matching inventory'; Code = 0; Lines = @('example installed'); Expected = $true; Known = $true }
                @{ Case = 'successful nonmatching inventory'; Code = 0; Lines = @('other installed'); Expected = $false; Known = $true }
                @{ Case = 'successful substring-only inventory'; Code = 0; Lines = @('example-extra installed'); Expected = $false; Known = $true }
                @{ Case = 'successful empty inventory'; Code = 0; Lines = @(); Expected = $false; Known = $true }
                @{ Case = 'failed matching diagnostics'; Code = 1; Lines = @('error: inventory for example failed'); Known = $true }
                @{ Case = 'failed nonmatching diagnostics'; Code = 3; Lines = @('service unavailable'); Known = $true }
                @{ Case = 'failed empty inventory'; Code = 2; Lines = @(); Known = $true }
                @{ Case = 'failed partial stdout'; Code = 5; Lines = @('example installed', 'other installed', 'inventory interrupted'); Known = $true }
                @{ Case = 'negative native failure'; Code = -7; Lines = @('example failed'); Known = $true }
                @{ Case = 'missing exit code'; Code = $null; Lines = @('example installed'); Known = $false }
                @{ Case = 'string exit code'; Code = '0'; Lines = @('example installed'); Known = $false }
                @{ Case = 'missing exit property'; Code = $null; Lines = @('inventory incomplete'); Known = $false; Shape = 'MissingExit' }
                @{ Case = 'missing result'; Code = $null; Lines = @(); Known = $false; Shape = 'Null' }
            )) {
                $case + @{ Resource = $resource }
            }
        }
    ) {
        InModuleScope Shmuelie.Dsc -Parameters @{
            Resource = $Resource; Code = $Code; Lines = $Lines; Expected = $Expected; Known = $Known; Shape = $Shape
        } {
            param($Resource, $Code, $Lines, $Expected, $Known, $Shape)

            $result = [pscustomobject]@{ Output = $Lines; ExitCode = $Code }
            if ($Shape -eq 'MissingExit') { $result = [pscustomobject]@{ Output = $Lines } }
            if ($Shape -eq 'Null') { $result = $null }
            switch ($Resource) {
                CopilotPlugin {
                    $instance = [CopilotPlugin]@{ Source = 'owner/example' }
                    $expectedArguments = 'plugin list'
                    Mock Invoke-DscCopilot { $result } -ParameterFilter { ($Arguments -join ' ') -eq $expectedArguments }
                }
                CopilotMarketplace {
                    $instance = [CopilotMarketplace]@{ Name = 'example'; Repository = 'owner/repository' }
                    $expectedArguments = 'plugin marketplace list'
                    Mock Invoke-DscCopilot { $result } -ParameterFilter { ($Arguments -join ' ') -eq $expectedArguments }
                }
                UvTool {
                    $instance = [UvTool]@{ Name = 'example' }
                    $expectedArguments = 'tool list'
                    Mock Invoke-DscUv { $result } -ParameterFilter { ($Arguments -join ' ') -eq $expectedArguments }
                }
            }
            if ($Known -and $Code -eq 0) {
                $instance.Test() | Should -Be $Expected
                $instance.Get().Installed | Should -Be $Expected
            } else {
                $ErrorActionPreference = 'Continue'
                Mock Test-DscListContainsToken { throw 'Failed discovery must not be parsed.' }
                foreach ($method in 'Test', 'Get') {
                    $values = [System.Collections.Generic.List[object]]::new()
                    $failure = $null
                    try { $instance.$method() | ForEach-Object { $values.Add($_) } }
                    catch { $failure = $_ }
                    $failure | Should -Not -BeNullOrEmpty
                    $values.Count | Should -Be 0
                    $exception = $failure.Exception
                    while ($exception -and -not $exception.Data.Contains('ExitCode')) { $exception = $exception.InnerException }
                    $exception | Should -Not -BeNullOrEmpty
                    $exception.Data['ExitCode'] | Should -Be $Code
                    if ($Shape -eq 'Null') {
                        $exception.Data['Output'] | Should -BeNullOrEmpty
                    } else {
                        @($exception.Data['Output']) | Should -Be $Lines
                    }
                    if ($Known) {
                        $exception.Message | Should -BeLike "*discovery failed (exit $Code)*"
                    } else {
                        $exception.Message | Should -BeLike '*discovery did not report a valid native exit code*'
                    }
                    foreach ($line in $Lines) { $exception.Message | Should -BeLike "*$line*" }
                }
                Should -Invoke Test-DscListContainsToken -Times 0 -Exactly
            }
            if ($Resource -eq 'UvTool') {
                Should -Invoke Invoke-DscUv -Times 2 -Exactly -ParameterFilter { ($Arguments -join ' ') -eq $expectedArguments }
                Should -Invoke Invoke-DscCopilot -Times 0 -Exactly
            } else {
                Should -Invoke Invoke-DscCopilot -Times 2 -Exactly -ParameterFilter { ($Arguments -join ' ') -eq $expectedArguments }
                Should -Invoke Invoke-DscUv -Times 0 -Exactly
            }
        }
    }
}

Describe 'DSC CLI native completion capture' -Tag 'DscDiscovery' {
    BeforeAll {
        InModuleScope Shmuelie.Dsc {
            function script:copilot {
                param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
                throw 'Real Copilot invocation is forbidden.'
            }
            function script:uv {
                param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
                throw 'Real uv invocation is forbidden.'
            }
        }
    }

    BeforeEach {
        $script:originalExitVariable = Get-Variable LASTEXITCODE -Scope Global -ErrorAction Ignore
        $script:originalExitValue = if ($script:originalExitVariable) { $script:originalExitVariable.Value } else { $null }
        $script:originalNoColor = [Environment]::GetEnvironmentVariable('NO_COLOR')
        $script:originalUvColor = [Environment]::GetEnvironmentVariable('UV_NO_COLOR')
        [Environment]::SetEnvironmentVariable('NO_COLOR', 'caller-color')
        [Environment]::SetEnvironmentVariable('UV_NO_COLOR', 'caller-uv-color')
    }

    AfterEach {
        if ($null -eq $script:originalNoColor) {
            Remove-Item -LiteralPath Env:NO_COLOR -ErrorAction Ignore -WhatIf:$false -Confirm:$false
        } else {
            [Environment]::SetEnvironmentVariable('NO_COLOR', $script:originalNoColor)
        }
        if ($null -eq $script:originalUvColor) {
            Remove-Item -LiteralPath Env:UV_NO_COLOR -ErrorAction Ignore -WhatIf:$false -Confirm:$false
        } else {
            [Environment]::SetEnvironmentVariable('UV_NO_COLOR', $script:originalUvColor)
        }
        if ($script:originalExitVariable) { $global:LASTEXITCODE = $script:originalExitValue }
        else { Remove-Variable LASTEXITCODE -Scope Global -ErrorAction Ignore }
    }

    It '<Command> rejects missing completion instead of reusing caller exit <Previous>' -ForEach @(
        foreach ($command in 'copilot', 'uv') {
            foreach ($previous in 0, 17, $null) { @{ Command = $command; Previous = $previous } }
        }
    ) {
        InModuleScope Shmuelie.Dsc -Parameters @{ Command = $Command; Previous = $Previous } {
            param($Command, $Previous)
            $global:LASTEXITCODE = $Previous
            Mock $Command { 'example incomplete inventory' } -ParameterFilter { ($Arguments -join ' ') -eq 'fixture-list' }
            $wrapper = if ($Command -eq 'copilot') { 'Invoke-DscCopilot' } else { 'Invoke-DscUv' }
            { & $wrapper -Arguments @('fixture-list') } |
                Should -Throw "*$Command did not report a valid native exit code*example incomplete inventory*"
            $global:LASTEXITCODE | Should -Be $Previous
            $env:NO_COLOR | Should -Be 'caller-color'
            $env:UV_NO_COLOR | Should -Be 'caller-uv-color'
            Should -Invoke $Command -Times 1 -Exactly
        }
    }

    It '<Command> restores absent caller state under inherited WhatIf=<Preview>' -ForEach @(
        @{ Command = 'copilot'; Preview = $false }
        @{ Command = 'uv'; Preview = $false }
        @{ Command = 'copilot'; Preview = $true }
        @{ Command = 'uv'; Preview = $true }
    ) {
        InModuleScope Shmuelie.Dsc -Parameters @{ Command = $Command; Preview = $Preview } {
            param($Command, $Preview)
            Remove-Variable LASTEXITCODE -Scope Global -ErrorAction Ignore
            Remove-Item -LiteralPath Env:NO_COLOR, Env:UV_NO_COLOR -ErrorAction Ignore
            Mock $Command { 'incomplete' } -ParameterFilter { ($Arguments -join ' ') -eq 'fixture-list' }
            $wrapper = if ($Command -eq 'copilot') { 'Invoke-DscCopilot' } else { 'Invoke-DscUv' }
            $WhatIfPreference = $Preview
            $ConfirmPreference = 'Low'
            { & $wrapper -Arguments @('fixture-list') } | Should -Throw '*did not report a valid native exit code*'
            Get-Variable LASTEXITCODE -Scope Global -ErrorAction Ignore | Should -BeNullOrEmpty
            Test-Path -LiteralPath Env:NO_COLOR | Should -BeFalse
            Test-Path -LiteralPath Env:UV_NO_COLOR | Should -BeFalse
        }
    }

    It '<Command> restores caller state when invocation throws' -ForEach @(
        @{ Command = 'copilot' }
        @{ Command = 'uv' }
    ) {
        InModuleScope Shmuelie.Dsc -Parameters @{ Command = $Command } {
            param($Command)
            $global:LASTEXITCODE = 23
            Mock $Command { throw 'fixture command launch failure' } -ParameterFilter { ($Arguments -join ' ') -eq 'fixture-list' }
            $wrapper = if ($Command -eq 'copilot') { 'Invoke-DscCopilot' } else { 'Invoke-DscUv' }
            { & $wrapper -Arguments @('fixture-list') } | Should -Throw '*fixture command launch failure*'
            $global:LASTEXITCODE | Should -Be 23
            $env:NO_COLOR | Should -Be 'caller-color'
            $env:UV_NO_COLOR | Should -Be 'caller-uv-color'
        }
    }

    It '<Resource>.Set rejects unknown completion through the shared wrapper' -ForEach @(
        @{ Resource = 'CopilotPlugin'; Command = 'copilot'; Arguments = 'plugin install owner/example' }
        @{ Resource = 'CopilotMarketplace'; Command = 'copilot'; Arguments = 'plugin marketplace add example owner/repository' }
        @{ Resource = 'UvTool'; Command = 'uv'; Arguments = 'tool install example' }
    ) {
        InModuleScope Shmuelie.Dsc -Parameters @{ Resource = $Resource; Command = $Command; ExpectedArguments = $Arguments } {
            param($Resource, $Command, $ExpectedArguments)
            $global:LASTEXITCODE = 0
            Mock $Command { 'fixture incomplete install' } -ParameterFilter { ($Arguments -join ' ') -eq $ExpectedArguments }
            $instance = switch ($Resource) {
                CopilotPlugin { [CopilotPlugin]@{ Source = 'owner/example' } }
                CopilotMarketplace { [CopilotMarketplace]@{ Name = 'example'; Repository = 'owner/repository' } }
                UvTool { [UvTool]@{ Name = 'example' } }
            }
            { $instance.Set() } | Should -Throw '*did not report a valid native exit code*fixture incomplete install*'
            $global:LASTEXITCODE | Should -Be 0
            $env:NO_COLOR | Should -Be 'caller-color'
            $env:UV_NO_COLOR | Should -Be 'caller-uv-color'
            Should -Invoke $Command -Times 1 -Exactly
        }
    }

    It '<Command> preserves known exit <ExitCode> and stdout/stderr under terminating native policy' -ForEach @(
        @{ Command = 'copilot'; ExitCode = 0 }
        @{ Command = 'copilot'; ExitCode = 7 }
        @{ Command = 'uv'; ExitCode = 0 }
        @{ Command = 'uv'; ExitCode = 7 }
    ) {
        InModuleScope Shmuelie.Dsc -Parameters @{ Command = $Command; ExitCode = $ExitCode } {
            param($Command, $ExitCode)
            $native = (Get-Process -Id $PID).Path
            Set-Alias -Name $Command -Value $native -Scope Script
            $global:LASTEXITCODE = 83
            $LASTEXITCODE = 91
            $PSNativeCommandUseErrorActionPreference = $true
            $ErrorActionPreference = 'Stop'
            $child = @'
if ($env:NO_COLOR -ne '1') { throw 'NO_COLOR was not set for the child.' }
if ($env:UV_NO_COLOR -ne 'EXPECTED_UV_COLOR') { throw 'Unexpected UV_NO_COLOR value.' }
[Console]::Out.WriteLine("$([char]27)[32mexample installed$([char]27)[0m")
[Console]::Error.WriteLine('native diagnostic')
exit EXPECTED_EXIT
'@
            $uvColor = if ($Command -eq 'uv') { '1' } else { 'caller-uv-color' }
            $child = $child.Replace('EXPECTED_UV_COLOR', $uvColor).Replace('EXPECTED_EXIT', [string]$ExitCode)
            try {
                $wrapper = if ($Command -eq 'copilot') { 'Invoke-DscCopilot' } else { 'Invoke-DscUv' }
                $result = & $wrapper -Arguments @('-NoProfile', '-NonInteractive', '-Command', $child)
                $result.ExitCode | Should -BeExactly $ExitCode
                $result.ExitCode | Should -BeOfType ([int])
                $result.Output.Count | Should -Be 2
                $result.Output | Should -Contain 'example installed'
                $result.Output | Should -Contain 'native diagnostic'
                $global:LASTEXITCODE | Should -Be 83
                $LASTEXITCODE | Should -Be 91
                $PSNativeCommandUseErrorActionPreference | Should -BeTrue
                $env:NO_COLOR | Should -Be 'caller-color'
                $env:UV_NO_COLOR | Should -Be 'caller-uv-color'
            } finally {
                Remove-Alias -Name $Command -Scope Script -Force -ErrorAction Stop
            }
        }
    }
}
