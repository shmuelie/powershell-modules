#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.2.0' }

BeforeDiscovery {
    $repoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent
    Import-Module (Join-Path $repoRoot 'modules' 'Shmuelie.PackageManagement' 'Shmuelie.PackageManagement.psd1') -Force
}

BeforeAll {
    $repoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent
    $script:Manifest = Join-Path $repoRoot 'modules' 'Shmuelie.PackageManagement' 'Shmuelie.PackageManagement.psd1'
    Import-Module $script:Manifest
}

AfterAll {
    Remove-Module Shmuelie.PackageManagement -Force -ErrorAction SilentlyContinue
}

Describe 'PackageManagement foundation surface' {
    It 'exports only the aggregate command and has no hard dependencies or aliases' {
        $manifest = Test-ModuleManifest $script:Manifest
        @($manifest.ExportedFunctions.Keys) | Should -Be @('Update-AllPackages')
        @($manifest.ExportedAliases.Keys) | Should -HaveCount 0
        @($manifest.RequiredModules) | Should -HaveCount 0
        $manifest.Version | Should -Be ([version]'0.1.0')
    }

    It 'reports unavailable providers without importing optional modules' {
        Mock Get-PackageProviderPlatform -ModuleName Shmuelie.PackageManagement { 'Windows' }
        Mock Import-Module -ModuleName Shmuelie.PackageManagement { throw 'Must not import optional modules.' }
        Mock Get-PackageProviderAvailability -ModuleName Shmuelie.PackageManagement {
            [pscustomobject]@{ Available = $false; Reason = 'Provider unavailable for this test.' }
        }
        $results = @(Update-AllPackages)
        $results.Provider | Should -Be @('PSResourceGet', 'DotNet', 'Npm', 'Pip', 'Uv', 'VSCode', 'WinGet', 'AppInstaller')
        foreach ($result in $results) {
            $result.PSTypeNames[0] | Should -BeExactly 'Shmuelie.PackageManagement.UpdateResult'
            $result.Status | Should -BeExactly 'Skipped'
            $result.Reason | Should -BeExactly 'Provider unavailable for this test.'
            $result.Error | Should -BeNullOrEmpty
        }
        Should -Invoke Import-Module -ModuleName Shmuelie.PackageManagement -Times 0 -Exactly
    }

    It 'completes exactly the validated provider catalog for <Parameter>' -ForEach @(
        @{ Parameter = 'Provider' }
        @{ Parameter = 'ExcludeProvider' }
    ) {
        $inputText = "Update-AllPackages -$Parameter "
        $completion = [System.Management.Automation.CommandCompletion]::CompleteInput($inputText, $inputText.Length, $null)
        $expected = & (Get-Module Shmuelie.PackageManagement) { @(Get-PackageProvider).Name }
        @($completion.CompletionMatches.CompletionText | Sort-Object) | Should -Be @($expected | Sort-Object)
    }
}

Describe 'Update-AllPackages orchestration' {
    InModuleScope Shmuelie.PackageManagement {
        BeforeAll {
            function New-TestProvider {
                param([string]$Name)
                $targets = @(New-PackageUpdateTarget -Target "$Name.tool" -PreviousVersion '1.0' -ProposedVersion '2.0' -Data $Name)
                [pscustomobject]@{
                    Name = $Name
                    Platforms = @('Windows', 'Linux', 'MacOS')
                    RequiredModules = @()
                    RequiredCommands = @()
                    OptionNames = @('Channel')
                    TestAvailable = $null
                    GetTargets = { param($Options) $targets }.GetNewClosure()
                    Update = {
                        param($Target, $Options)
                        $script:Updates.Add($Target.Target)
                        $script:SeenOptions.Add($Options)
                        New-PackageUpdateResult -Provider $Target.Data -Target $Target.Target -PreviousVersion $Target.PreviousVersion -ResultingVersion '2.0' -Status Updated
                    }
                }
            }
        }

        BeforeEach {
            $script:Providers = @(New-TestProvider DotNet; New-TestProvider Npm; New-TestProvider Uv)
            $script:Updates = [System.Collections.Generic.List[string]]::new()
            $script:SeenOptions = [System.Collections.Generic.List[hashtable]]::new()
            Mock Get-PackageProvider { $script:Providers }
            Mock Get-PackageProviderPlatform { 'Windows' }
        }

        It 'selects all available providers in catalog order' {
            $results = @(Update-AllPackages -Confirm:$false)
            $results.Provider | Should -Be @('DotNet', 'Npm', 'Uv')
            $script:Updates | Should -Be @('DotNet.tool', 'Npm.tool', 'Uv.tool')
        }

        It 'deduplicates includes case-insensitively and preserves catalog order' {
            $results = @(Update-AllPackages -Provider npm, DOTNET, Npm -Confirm:$false)
            $results.Provider | Should -Be @('DotNet', 'Npm')
        }

        It 'lets exclusion win over inclusion and does not probe excluded providers' {
            $script:Providers[0].TestAvailable = { throw 'Excluded availability must not run.' }
            $results = @(Update-AllPackages -Provider DotNet, Npm -ExcludeProvider dotnet -Confirm:$false)
            $results.Provider | Should -Be @('Npm')
        }

        It 'supports exclusions with default selection' {
            @(Update-AllPackages -ExcludeProvider Npm -Confirm:$false).Provider | Should -Be @('DotNet', 'Uv')
        }

        It 'returns nothing when every provider is excluded' {
            @(Update-AllPackages -ExcludeProvider DotNet, Npm, Uv -Confirm:$false) | Should -HaveCount 0
            $script:Updates | Should -HaveCount 0
        }

        It 'rejects invalid <Label> before any update' -ForEach @(
            @{ Label = 'include'; Arguments = @{ Provider = @('DotNet', 'Typo') } }
            @{ Label = 'exclude'; Arguments = @{ ExcludeProvider = 'Typo' } }
            @{ Label = 'option provider'; Arguments = @{ ProviderOptions = @{ Typo = @{} } } }
            @{ Label = 'option type'; Arguments = @{ ProviderOptions = @{ Npm = 'bad' } } }
            @{ Label = 'option name'; Arguments = @{ ProviderOptions = @{ Npm = @{ Typo = 'value' } } } }
            @{ Label = 'confirmation override'; Arguments = @{ ProviderOptions = @{ Npm = @{ Confirm = $false } } } }
        ) {
            { Update-AllPackages @Arguments -Confirm:$false } | Should -Throw
            $script:Updates | Should -HaveCount 0
        }

        It 'passes only a shallow copy of the owning provider option table' {
            $options = @{ npm = @{ Channel = 'preview' } }
            Update-AllPackages -ProviderOptions $options -Confirm:$false | Out-Null
            $script:SeenOptions[0].Count | Should -Be 0
            $script:SeenOptions[1].Channel | Should -BeExactly 'preview'
            [object]::ReferenceEquals($script:SeenOptions[1], $options.npm) | Should -BeFalse
            $script:SeenOptions[2].Count | Should -Be 0
        }

        It 'passes options to read-only availability and target discovery' {
            $script:Providers[0].TestAvailable = {
                param($Options)
                [pscustomobject]@{ Available = ($Options.Channel -eq 'preview'); Reason = 'Wrong channel.' }
            }
            $script:Providers[0].GetTargets = {
                param($Options)
                New-PackageUpdateTarget -Target $Options.Channel -Data 'DotNet'
            }
            $result = Update-AllPackages -Provider DotNet -ProviderOptions @{ DotNet = @{ Channel = 'preview' } } -Confirm:$false
            $result.Target | Should -BeExactly 'preview'
            $result.Status | Should -BeExactly 'Updated'
        }

        It 'normalizes <Label> options without changing caller maps' -ForEach @(
            @{ Label = 'JSON lowercase provider'; CreateOptions = { '{"npm":{"Channel":"requested-channel"}}' | ConvertFrom-Json -AsHashtable } }
            @{ Label = 'JSON lowercase option'; CreateOptions = { '{"Npm":{"channel":"requested-channel"}}' | ConvertFrom-Json -AsHashtable } }
            @{ Label = 'JSON lowercase provider and option'; CreateOptions = { '{"npm":{"channel":"requested-channel"}}' | ConvertFrom-Json -AsHashtable } }
            @{ Label = 'JSON canonical'; CreateOptions = { '{"Npm":{"Channel":"requested-channel"}}' | ConvertFrom-Json -AsHashtable } }
            @{ Label = 'ordinary lowercase'; CreateOptions = { @{ npm = @{ channel = 'requested-channel' } } } }
            @{ Label = 'ordered outer'; CreateOptions = { [ordered]@{ npm = @{ channel = 'requested-channel' } } } }
            @{ Label = 'case-sensitive lowercase'; CreateOptions = {
                $inner = [hashtable]::new([System.StringComparer]::Ordinal)
                $inner.Add('channel', 'requested-channel')
                $outer = [hashtable]::new([System.StringComparer]::Ordinal)
                $outer.Add('npm', $inner)
                $outer
            } }
            @{ Label = 'case-sensitive canonical'; CreateOptions = {
                $inner = [hashtable]::new([System.StringComparer]::Ordinal)
                $inner.Add('Channel', 'requested-channel')
                $outer = [hashtable]::new([System.StringComparer]::Ordinal)
                $outer.Add('Npm', $inner)
                $outer
            } }
        ) {
            $inputOptions = & $CreateOptions
            $before = ConvertTo-Json -InputObject $inputOptions -Depth 5 -Compress
            $originalInner = $inputOptions[@($inputOptions.Keys)[0]]
            $script:ReadOnlyChannels = [System.Collections.Generic.List[string]]::new()
            $script:Providers[1].TestAvailable = {
                param($Options)
                $script:ReadOnlyChannels.Add($Options.Channel)
                [pscustomobject]@{ Available = $true; Reason = $null }
            }
            $script:Providers[1].GetTargets = {
                param($Options)
                $script:ReadOnlyChannels.Add($Options.Channel)
                New-PackageUpdateTarget -Target Npm.tool -Data Npm
            }

            $result = Update-AllPackages -Provider Npm -ProviderOptions $inputOptions -Confirm:$false

            $result.Status | Should -BeExactly 'Updated'
            $script:ReadOnlyChannels | Should -Be @('requested-channel', 'requested-channel')
            $script:SeenOptions | Should -HaveCount 1
            $script:SeenOptions[0].Channel | Should -BeExactly 'requested-channel'
            $script:SeenOptions[0].ContainsKey('CHANNEL') | Should -BeTrue
            [object]::ReferenceEquals($script:SeenOptions[0], $originalInner) | Should -BeFalse
            (ConvertTo-Json -InputObject $inputOptions -Depth 5 -Compress) | Should -BeExactly $before
            [object]::ReferenceEquals($inputOptions[@($inputOptions.Keys)[0]], $originalInner) | Should -BeTrue
        }

        It 'keeps callback option-map changes separate from the caller input' {
            $inputOptions = '{"npm":{"channel":"requested-channel"}}' | ConvertFrom-Json -AsHashtable
            $before = ConvertTo-Json -InputObject $inputOptions -Depth 5 -Compress
            $script:Providers[1].Update = {
                param($Target, $Options)
                $Options.Channel = 'changed-by-callback'
                $Options.Add('CallbackState', 'changed')
                New-PackageUpdateResult -Provider Npm -Target $Target.Target -Status Updated
            }

            (Update-AllPackages -Provider Npm -ProviderOptions $inputOptions -Confirm:$false).Status | Should -BeExactly 'Updated'

            (ConvertTo-Json -InputObject $inputOptions -Depth 5 -Compress) | Should -BeExactly $before
            $inputOptions.ContainsKey('Npm') | Should -BeFalse
            $inputOptions.npm.ContainsKey('Channel') | Should -BeFalse
        }

        It 'rejects <Label> collisions before any provider starts' -ForEach @(
            @{ Label = 'JSON provider'; Message = '*Duplicate provider key*case-insensitive*'; CreateOptions = {
                '{"npm":{"Channel":"first"},"Npm":{"Channel":"second"}}' | ConvertFrom-Json -AsHashtable
            } }
            @{ Label = 'JSON option'; Message = '*Duplicate option key*case-insensitive*'; CreateOptions = {
                '{"Npm":{"Channel":"first","channel":"second"}}' | ConvertFrom-Json -AsHashtable
            } }
            @{ Label = 'case-sensitive provider'; Message = '*Duplicate provider key*case-insensitive*'; CreateOptions = {
                $outer = [hashtable]::new([System.StringComparer]::Ordinal)
                $outer.Add('Npm', @{ Channel = 'first' })
                $outer.Add('npm', @{ Channel = 'second' })
                $outer
            } }
            @{ Label = 'case-sensitive option'; Message = '*Duplicate option key*case-insensitive*'; CreateOptions = {
                $inner = [hashtable]::new([System.StringComparer]::Ordinal)
                $inner.Add('Channel', 'first')
                $inner.Add('channel', 'second')
                @{ Npm = $inner }
            } }
        ) {
            $inputOptions = & $CreateOptions
            $before = ConvertTo-Json -InputObject $inputOptions -Depth 5 -Compress
            Mock Get-PackageProviderAvailability { throw 'Must reject collisions before provider discovery.' }

            { Update-AllPackages -ProviderOptions $inputOptions -Confirm:$false } | Should -Throw $Message

            Should -Invoke Get-PackageProviderAvailability -Times 0 -Exactly
            $script:Updates | Should -HaveCount 0
            (ConvertTo-Json -InputObject $inputOptions -Depth 5 -Compress) | Should -BeExactly $before
        }

        It 'skips unsupported platforms before importing any dependencies' {
            $script:Providers[0].Platforms = @('Windows')
            $script:Providers[0].RequiredModules = @('Fake.PackageProvider')
            Mock Get-PackageProviderPlatform { 'Linux' }
            Mock Import-Module { throw 'Do not import on an unsupported platform.' }
            $result = Update-AllPackages -Provider DotNet
            $result.Status | Should -BeExactly 'Skipped'
            $result.Reason | Should -Match 'does not support Linux'
            Should -Invoke Import-Module -Times 0 -Exactly
        }

        It 'skips missing modules without attempting import' {
            $script:Providers[0].RequiredModules = @('Fake.PackageProvider')
            Mock Get-Module { $null }
            Mock Import-Module { throw 'Cannot import a missing module.' }
            $result = Update-AllPackages -Provider DotNet
            $result.Status | Should -BeExactly 'Skipped'
            $result.Reason | Should -Match "Install.*Fake.PackageProvider"
            Should -Invoke Import-Module -Times 0 -Exactly
        }

        It 'imports selected modules lazily before checking required commands' {
            $script:Providers[0].RequiredModules = @('Fake.PackageProvider')
            $script:Providers[0].RequiredCommands = @('fake-tool')
            Mock Get-Module { [pscustomobject]@{ Name = 'Fake.PackageProvider' } }
            Mock Import-Module { $script:Imported = $true }
            Mock Get-Command {
                if (-not $script:Imported) { throw 'Commands checked before import.' }
                [pscustomobject]@{ Name = 'fake-tool' }
            }
            $script:Imported = $false
            $result = Update-AllPackages -Provider DotNet -Confirm:$false
            $result.Status | Should -BeExactly 'Updated'
            Should -Invoke Import-Module -Times 1 -Exactly -ParameterFilter { $Name -eq 'Fake.PackageProvider' }
            Should -Invoke Get-Command -Times 1 -Exactly -ParameterFilter { $Name -eq 'fake-tool' -and $ListImported }
        }

        It 'skips missing commands with an actionable reason' {
            $script:Providers[0].RequiredCommands = @('fake-tool')
            Mock Get-Command { $null }
            $result = Update-AllPackages -Provider DotNet
            $result.Status | Should -BeExactly 'Skipped'
            $result.Reason | Should -Match "fake-tool.*PATH"
        }

        It 'can call a lazily imported integration from both read-only and update callbacks' {
            $moduleRoot = Join-Path $TestDrive 'provider-modules'
            $moduleDir = Join-Path $moduleRoot 'Fake.PackageProvider'
            New-Item -ItemType Directory -Path $moduleDir -Force | Out-Null
            @'
function Get-FakePackageName { 'fake-tool' }
function Update-FakePackage { '2.0' }
Export-ModuleMember -Function Get-FakePackageName, Update-FakePackage
'@ | Set-Content (Join-Path $moduleDir 'Fake.PackageProvider.psm1')
            $script:Providers[0].RequiredModules = @('Fake.PackageProvider')
            $script:Providers[0].RequiredCommands = @('Fake.PackageProvider\Get-FakePackageName', 'Fake.PackageProvider\Update-FakePackage')
            $script:Providers[0].GetTargets = {
                New-PackageUpdateTarget -Target (Fake.PackageProvider\Get-FakePackageName) -PreviousVersion '1.0'
            }
            $script:Providers[0].Update = {
                param($Target, $Options)
                $version = Fake.PackageProvider\Update-FakePackage
                New-PackageUpdateResult -Provider DotNet -Target $Target.Target -PreviousVersion $Target.PreviousVersion -ResultingVersion $version -Status Updated
            }
            $originalModulePath = $env:PSModulePath
            try {
                $env:PSModulePath = $moduleRoot + [System.IO.Path]::PathSeparator + $originalModulePath
                $result = Update-AllPackages -Provider DotNet -Confirm:$false
                $result.Status | Should -BeExactly 'Updated'
                $result.Target | Should -BeExactly 'fake-tool'
                $result.ResultingVersion | Should -BeExactly '2.0'
            } finally {
                $env:PSModulePath = $originalModulePath
                Remove-Module Fake.PackageProvider -Force -ErrorAction SilentlyContinue
            }
        }

        It 'reports broken module imports as failures and continues' {
            $script:Providers[0].RequiredModules = @('Fake.PackageProvider')
            Mock Get-Module { [pscustomobject]@{ Name = 'Fake.PackageProvider' } }
            Mock Import-Module { throw 'Broken dependency.' }
            $results = @(Update-AllPackages -Confirm:$false)
            $results.Status | Should -Be @('Failed', 'Updated', 'Updated')
            $results[0].Error.Exception.Message | Should -BeLike '*Broken dependency.*'
        }

        It 'honors custom unavailable reasons without triggering StopOnFailure' {
            $script:Providers[0].TestAvailable = {
                [pscustomobject]@{ Available = $false; Reason = 'No configured environment.' }
            }
            $results = @(Update-AllPackages -StopOnFailure -Confirm:$false)
            $results.Status | Should -Be @('Skipped', 'Updated', 'Updated')
            $results[0].Reason | Should -BeExactly 'No configured environment.'
        }

        It 'rejects invalid availability output rather than assuming success' -ForEach @(
            @{ Callback = { } }
            @{ Callback = { $true } }
            @{ Callback = { [pscustomobject]@{ Available = $false; Reason = '' } } }
            @{ Callback = { [pscustomobject]@{ Available = 'true'; Reason = '' } } }
        ) {
            $script:Providers[0].TestAvailable = $Callback
            $results = @(Update-AllPackages -Confirm:$false)
            $results.Status | Should -Be @('Failed', 'Updated', 'Updated')
            $results[0].Reason | Should -Match 'invalid availability'
        }

        It 'does not update partial discovery after a <Kind> error' -ForEach @(
            @{ Kind = 'throw'; Failure = { throw 'Discovery failed.' } }
            @{ Kind = 'nonterminating'; Failure = { Write-Error 'Discovery failed.' } }
        ) {
            $script:DiscoveryFailure = $Failure
            $script:Providers[0].GetTargets = {
                New-PackageUpdateTarget -Target 'partial' -Data 'DotNet'
                & $script:DiscoveryFailure
            }
            $results = @(Update-AllPackages -Confirm:$false)
            $results.Status | Should -Be @('Failed', 'Updated', 'Updated')
            $script:Updates | Should -Be @('Npm.tool', 'Uv.tool')
        }

        It 'fails invalid target discovery before invoking updates' {
            $script:Providers[0].GetTargets = { 'Unexpected native stdout.' }
            $results = @(Update-AllPackages -Confirm:$false)
            $results.Status | Should -Be @('Failed', 'Updated', 'Updated')
            $results[0].Reason | Should -Match 'invalid targets'
        }

        It 'rejects corrupted target fields before starting any target' {
            $script:Providers[0].GetTargets = {
                New-PackageUpdateTarget -Target valid -Data DotNet
                $bad = New-PackageUpdateTarget -Target bad
                $bad.PreviousVersion = @{ Unexpected = 'object' }
                $bad
            }
            @(Update-AllPackages -StopOnFailure -Confirm:$false).Status | Should -Be @('Failed')
            $script:Updates | Should -HaveCount 0
        }

        It 'reports an empty successful discovery as unchanged with a reason' {
            $script:Providers[0].GetTargets = { }
            $result = Update-AllPackages -Provider DotNet
            $result.Status | Should -BeExactly 'Unchanged'
            $result.Reason | Should -BeExactly 'Provider reported no update targets.'
            $script:Updates | Should -HaveCount 0
        }

        It 'preserves typed output, versions, extra properties and unknown versions' {
            $script:Actual = New-PackageUpdateResult -Provider DotNet -Target DotNet.tool -PreviousVersion '1.0' -ResultingVersion '2.0' -Status Updated
            $script:Actual | Add-Member -NotePropertyName Detail -NotePropertyValue 'adapter detail'
            $script:Providers[0].Update = { $script:Actual }
            $result = Update-AllPackages -Provider DotNet -Confirm:$false
            [object]::ReferenceEquals($result, $script:Actual) | Should -BeTrue
            $result.Detail | Should -BeExactly 'adapter detail'
            $result.PreviousVersion | Should -BeExactly '1.0'
            $result.ResultingVersion | Should -BeExactly '2.0'
            $unknown = New-PackageUpdateResult -Provider DotNet -Target unknown -Status Unchanged
            $unknown.PreviousVersion | Should -BeNullOrEmpty
            $unknown.ResultingVersion | Should -BeNullOrEmpty
        }

        It 'preserves successes before <Kind> failures and continues independent providers' -ForEach @(
            @{ Kind = 'terminating'; Failure = { throw 'Update failed.' } }
            @{ Kind = 'nonterminating'; Failure = { Write-Error 'Update failed.' } }
            @{ Kind = 'explicit nonterminating'; Failure = { Write-Error 'Update failed.' -ErrorAction Continue } }
        ) {
            $script:UpdateFailure = $Failure
            $script:Providers[0].Update = {
                New-PackageUpdateResult -Provider DotNet -Target DotNet.tool -ResultingVersion '2.0' -Status Updated
                & $script:UpdateFailure
            }
            $results = @(Update-AllPackages -ErrorAction Stop -Confirm:$false)
            $results.Provider | Should -Be @('DotNet', 'DotNet', 'Npm', 'Uv')
            $results.Status | Should -Be @('Updated', 'Failed', 'Updated', 'Updated')
            $results[1].Error | Should -BeOfType ([System.Management.Automation.ErrorRecord])
            $results[1].Error.Exception.Message | Should -Match 'Update failed'
        }

        It 'continues callback output after a nonterminating failure in emission order' {
            $script:Providers[0].Update = {
                Write-Error 'Partial failure.'
                New-PackageUpdateResult -Provider DotNet -Target DotNet.tool -Status Updated
            }
            $results = @(Update-AllPackages -StopOnFailure -Confirm:$false)
            $results.Status | Should -Be @('Failed', 'Updated')
            $results.Provider | Should -Be @('DotNet', 'DotNet')
            $script:Updates | Should -HaveCount 0
        }

        It 'retains provider-reported failed results and honors fail-fast' {
            $script:FailureRecord = [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new('Provider reported failure.'),
                'ProviderFailure',
                [System.Management.Automation.ErrorCategory]::InvalidOperation,
                'DotNet.tool'
            )
            $script:Actual = New-PackageUpdateResult -Provider DotNet -Target DotNet.tool -PreviousVersion '1.0' -ResultingVersion '1.0' -Status Failed -Error $script:FailureRecord
            $script:Providers[0].Update = { $script:Actual }
            $results = @(Update-AllPackages -StopOnFailure -Confirm:$false)
            $results | Should -HaveCount 1
            [object]::ReferenceEquals($results[0], $script:Actual) | Should -BeTrue
            [object]::ReferenceEquals($results[0].Error, $script:FailureRecord) | Should -BeTrue
            $script:Updates | Should -HaveCount 0
        }

        It 'continues independent providers after provider-reported failures by default' {
            $script:Providers[0].Update = { New-PackageProviderFailure -Provider DotNet -Target DotNet.tool -Message 'Reported failure.' }
            @(Update-AllPackages -Confirm:$false).Status | Should -Be @('Failed', 'Updated', 'Updated')
        }

        It 'stops before the next target and provider after a failing update' {
            $script:Providers[0].GetTargets = {
                New-PackageUpdateTarget -Target first -Data DotNet
                New-PackageUpdateTarget -Target second -Data DotNet
            }
            $script:Providers[0].Update = {
                param($Target, $Options)
                $script:Updates.Add($Target.Target)
                throw 'Stop here.'
            }
            @(Update-AllPackages -StopOnFailure -Confirm:$false).Status | Should -Be @('Failed')
            $script:Updates | Should -Be @('first')
        }

        It 'continues the next target after a failure without StopOnFailure' {
            $script:Providers[0].GetTargets = {
                New-PackageUpdateTarget -Target first -Data DotNet
                New-PackageUpdateTarget -Target second -Data DotNet
            }
            $script:Providers[0].Update = {
                param($Target, $Options)
                if ($Target.Target -eq 'first') { throw 'First failed.' }
                New-PackageUpdateResult -Provider DotNet -Target $Target.Target -Status Updated
            }
            $results = @(Update-AllPackages -Provider DotNet -Confirm:$false)
            $results.Target | Should -Be @('first', 'second')
            $results.Status | Should -Be @('Failed', 'Updated')
        }

        It 'captures native nonzero exit errors and retains subsequent adapter results' {
            $script:Providers[0].Update = {
                & (Get-Process -Id $PID).Path -NoLogo -NoProfile -NonInteractive -Command 'exit 9'
                New-PackageUpdateResult -Provider DotNet -Target DotNet.tool -Status Unchanged
            }
            $results = @(Update-AllPackages -StopOnFailure -Confirm:$false)
            $results.Status | Should -Be @('Failed', 'Unchanged')
            $results[0].Error.Exception.ExitCode | Should -Be 9
        }

        It 'stops after availability or discovery failure with StopOnFailure' -ForEach @(
            @{ Phase = 'TestAvailable' }
            @{ Phase = 'GetTargets' }
        ) {
            $script:Providers[0].$Phase = { throw 'Cannot discover provider.' }
            @(Update-AllPackages -StopOnFailure -Confirm:$false).Status | Should -Be @('Failed')
            $script:Updates | Should -HaveCount 0
        }

        It 'treats empty update output as unknown failure, never success' {
            $script:Providers[0].Update = { }
            $results = @(Update-AllPackages -Confirm:$false)
            $results.Status | Should -Be @('Failed', 'Updated', 'Updated')
            $results[0].Reason | Should -Match 'outcome is unknown'
        }

        It 'rejects invalid update output without preventing the next provider' -ForEach @(
            @{ Callback = { $null } }
            @{ Callback = { 'Updated tool!' } }
            @{ Callback = { [pscustomobject]@{ Status = 'Updated'; Target = 'DotNet.tool' } } }
            @{ Callback = { New-PackageUpdateResult -Provider Npm -Target DotNet.tool -Status Updated } }
            @{ Callback = { New-PackageUpdateResult -Provider DotNet -Target wrong -Status Updated } }
            @{ Callback = { New-PackageUpdateResult -Provider DotNet -Target DotNet.tool -Status Planned } }
        ) {
            $script:Providers[0].Update = $Callback
            $results = @(Update-AllPackages -Confirm:$false)
            $results.Status | Should -Be @('Failed', 'Updated', 'Updated')
            $results[0].Reason | Should -Match 'invalid update output'
        }

        It 'preserves per-target discovery order' {
            $script:Providers[0].GetTargets = {
                New-PackageUpdateTarget -Target z-last -Data DotNet
                New-PackageUpdateTarget -Target a-first -Data DotNet
            }
            @(Update-AllPackages -Provider DotNet -Confirm:$false).Target | Should -Be @('z-last', 'a-first')
        }

        It 'never invokes mutating callbacks under WhatIf and returns useful typed previews' {
            foreach ($descriptor in $script:Providers) {
                $descriptor.Update = { throw 'Mutation must not run under WhatIf.' }
            }
            $results = @(Update-AllPackages -WhatIf -Confirm:$false)
            $results.Status | Should -Be @('Planned', 'Planned', 'Planned')
            $results.Target | Should -Be @('DotNet.tool', 'Npm.tool', 'Uv.tool')
            foreach ($result in $results) {
                $result.PreviousVersion | Should -BeExactly '1.0'
                $result.ResultingVersion | Should -BeExactly '2.0'
                $result.PSTypeNames[0] | Should -BeExactly 'Shmuelie.PackageManagement.UpdateResult'
            }
        }

        It 'honors inherited WhatIfPreference without executing updates' {
            $WhatIfPreference = $true
            @(Update-AllPackages).Status | Should -Be @('Planned', 'Planned', 'Planned')
            $script:Updates | Should -HaveCount 0
        }

        It 'retains explicit skips under WhatIf' {
            $script:Providers[0].Update = $null
            $results = @(Update-AllPackages -WhatIf)
            $results.Status | Should -Be @('Skipped', 'Planned', 'Planned')
            $results[0].Reason | Should -Match 'not implemented'
        }
    }
}

Describe 'Update-AllPackages Npm adapter' {
    BeforeAll {
        $script:NpmModuleWasLoaded = [bool](Get-Module Shmuelie.Node)
        $script:NpmNodeModule = Import-Module (Join-Path $repoRoot 'modules' 'Shmuelie.Node' 'Shmuelie.Node.psd1') -PassThru
        $script:CanonicalNpmGetter = (Get-Command Shmuelie.Node\Get-NpmPackage).ScriptBlock
        $script:OriginalNpmFunction = & $script:NpmNodeModule { Get-Item Function:script:npm -ErrorAction Ignore }
        & $script:NpmNodeModule {
            function script:npm { throw 'Tests must never invoke real npm.' }
        }
        function New-NpmAdapterTestPackage {
            param([string]$Name = '@scope/tool', [string]$Version = '1.0.0', [string]$Latest = '2.0.0', [bool]$Global = $true)
            [pscustomobject]@{ PSTypeName = 'NpmPackage'; Name = $Name; Version = $Version; Latest = $Latest; Global = $Global }
        }
    }

    AfterAll {
        & $script:NpmNodeModule {
            param($Original)
            if ($Original) { Set-Item Function:script:npm -Value $Original.ScriptBlock }
            else { Remove-Item Function:script:npm }
        } $script:OriginalNpmFunction
        if (-not $script:NpmModuleWasLoaded) { Remove-Module Shmuelie.Node -Force }
    }

    BeforeEach {
        $script:NpmOutdated = @(New-NpmAdapterTestPackage)
        $script:NpmInstalled = @(New-NpmAdapterTestPackage -Version '2.1.0')
        $script:NpmDiscoveryExit = 1
        $script:NpmListExit = 0
        Mock Get-Module -ModuleName Shmuelie.PackageManagement { $script:NpmNodeModule } -ParameterFilter { $Name -eq 'Shmuelie.Node' }
        Mock Import-Module -ModuleName Shmuelie.PackageManagement { }
        Mock Get-Command -ModuleName Shmuelie.PackageManagement { [pscustomobject]@{ Name = $Name } }
        Mock Get-NpmPackage -ModuleName Shmuelie.Node {
            if (-not $Global) { throw 'Local discovery must never run.' }
            if ($Outdated) {
                $global:LASTEXITCODE = $script:NpmDiscoveryExit
                $script:NpmOutdated
            } else {
                $global:LASTEXITCODE = $script:NpmListExit
                $script:NpmInstalled
            }
        }
        Mock Shmuelie.Node\Update-NpmPackage -ModuleName Shmuelie.PackageManagement {
            if (-not $Global -or $Confirm) { throw 'Only already-confirmed global updates are allowed.' }
            [pscustomobject]@{ PSTypeName = 'NpmUpdateResult'; Name = $Name; Global = $true; Success = $true }
        }
    }

    It 'keeps the eight-name catalog side-effect-free and declares Npm dependencies' {
        $catalog = & (Get-Module Shmuelie.PackageManagement) { @(Get-PackageProvider) }
        $catalog.Name | Should -Be @('PSResourceGet', 'DotNet', 'Npm', 'Pip', 'Uv', 'VSCode', 'WinGet', 'AppInstaller')
        $catalog[2].GetTargets | Should -BeOfType ([scriptblock])
        $catalog[2].Update | Should -BeOfType ([scriptblock])
        $catalog[2].RequiredModules | Should -Be @('Shmuelie.Node')
        $catalog[2].OptionNames | Should -HaveCount 0
        Should -Invoke Import-Module -ModuleName Shmuelie.PackageManagement -Times 0 -Exactly
        Should -Invoke Get-Command -ModuleName Shmuelie.PackageManagement -Times 0 -Exactly
    }

    It 'preserves scoped names and uses observed rather than proposed versions' {
        $result = Update-AllPackages -Provider Npm -Confirm:$false
        $result.PSTypeNames[0] | Should -BeExactly 'Shmuelie.PackageManagement.UpdateResult'
        $result.Provider | Should -BeExactly 'Npm'
        $result.Target | Should -BeExactly '@scope/tool'
        $result.Status | Should -BeExactly 'Updated'
        $result.PreviousVersion | Should -BeExactly '1.0.0'
        $result.ResultingVersion | Should -BeExactly '2.1.0'
        Should -Invoke Get-NpmPackage -ModuleName Shmuelie.Node -Times 1 -Exactly -ParameterFilter { $Global -and $Outdated }
        Should -Invoke Get-NpmPackage -ModuleName Shmuelie.Node -Times 1 -Exactly -ParameterFilter { $Global -and -not $Outdated }
        Should -Invoke Shmuelie.Node\Update-NpmPackage -ModuleName Shmuelie.PackageManagement -Times 1 -Exactly -ParameterFilter {
            $Name -ceq '@scope/tool' -and $Global -and $null -ne $Confirm -and -not $Confirm
        }
    }

    It 'reports no outdated global packages as Unchanged' {
        $script:NpmOutdated = @()
        $script:NpmDiscoveryExit = 0
        $result = Update-AllPackages -Provider Npm -Confirm:$false
        $result.Status | Should -BeExactly 'Unchanged'
        $result.Target | Should -BeExactly 'Npm'
        Should -Invoke Shmuelie.Node\Update-NpmPackage -ModuleName Shmuelie.PackageManagement -Times 0 -Exactly
    }

    It 'does not update an already-current package from discovery' {
        $script:NpmOutdated = @(New-NpmAdapterTestPackage -Version '2.0.0')
        (Update-AllPackages -Provider Npm -Confirm:$false).Status | Should -BeExactly 'Unchanged'
        Should -Invoke Shmuelie.Node\Update-NpmPackage -ModuleName Shmuelie.PackageManagement -Times 0 -Exactly
    }

    It 'skips a missing module without importing or running npm' {
        Mock Get-Module -ModuleName Shmuelie.PackageManagement { $null } -ParameterFilter { $Name -eq 'Shmuelie.Node' }
        $result = Update-AllPackages -Provider Npm -Confirm:$false
        $result.Status | Should -BeExactly 'Skipped'
        $result.Reason | Should -Match 'Install.*Shmuelie.Node'
        Should -Invoke Import-Module -ModuleName Shmuelie.PackageManagement -Times 0 -Exactly
        Should -Invoke Get-NpmPackage -ModuleName Shmuelie.Node -Times 0 -Exactly
    }

    It 'skips a missing npm command after lazy module import' {
        Mock Get-Command -ModuleName Shmuelie.PackageManagement { $null } -ParameterFilter { $Name -eq 'npm' }
        $result = Update-AllPackages -Provider Npm -Confirm:$false
        $result.Status | Should -BeExactly 'Skipped'
        $result.Reason | Should -Match 'npm.*PATH'
        Should -Invoke Import-Module -ModuleName Shmuelie.PackageManagement -Times 1 -Exactly -ParameterFilter { $Name -eq 'Shmuelie.Node' }
        Should -Invoke Get-NpmPackage -ModuleName Shmuelie.Node -Times 0 -Exactly
    }

    It 'does not discover dependencies for excluded Npm' {
        @(Update-AllPackages -Provider Npm -ExcludeProvider Npm) | Should -HaveCount 0
        Should -Invoke Import-Module -ModuleName Shmuelie.PackageManagement -Times 0 -Exactly
        Should -Invoke Get-Command -ModuleName Shmuelie.PackageManagement -Times 0 -Exactly
        Should -Invoke Get-NpmPackage -ModuleName Shmuelie.Node -Times 0 -Exactly
    }

    It 'rejects unsupported <Option> options before discovery' -ForEach @(
        @{ Option = 'Global' }, @{ Option = 'Name' }, @{ Option = 'Path' },
        @{ Option = 'Confirm' }, @{ Option = 'WhatIf' }, @{ Option = 'ErrorAction' },
        @{ Option = 'ScriptBlock' }
    ) {
        { Update-AllPackages -Provider Npm -ProviderOptions @{ Npm = @{ $Option = $false } } -Confirm:$false } | Should -Throw '*Unknown option*'
        Should -Invoke Get-NpmPackage -ModuleName Shmuelie.Node -Times 0 -Exactly
        Should -Invoke Shmuelie.Node\Update-NpmPackage -ModuleName Shmuelie.PackageManagement -Times 0 -Exactly
    }

    It 'returns previews without invoking updates or post-update observation' {
        $result = Update-AllPackages -Provider Npm -WhatIf
        $result.Status | Should -BeExactly 'Planned'
        $result.ResultingVersion | Should -BeExactly '2.0.0'
        Should -Invoke Get-NpmPackage -ModuleName Shmuelie.Node -Times 1 -Exactly -ParameterFilter { $Global -and $Outdated }
        Should -Invoke Get-NpmPackage -ModuleName Shmuelie.Node -Times 0 -Exactly -ParameterFilter { -not $Outdated }
        Should -Invoke Shmuelie.Node\Update-NpmPackage -ModuleName Shmuelie.PackageManagement -Times 0 -Exactly
    }

    It 'rejects unsafe package identifiers before invoking the canonical updater: <Name>' -ForEach @(
        @{ Name = 'tool&whoami' }, @{ Name = 'tool|whoami' }, @{ Name = 'tool>file' },
        @{ Name = 'tool<file' }, @{ Name = 'tool^name' }, @{ Name = 'tool%PATH%' },
        @{ Name = 'tool!PATH!' }, @{ Name = 'tool(name)' }, @{ Name = 'tool"name' },
        @{ Name = "tool`nname" }, @{ Name = 'tool name' }, @{ Name = '--prefix' },
        @{ Name = 'tool@next' }, @{ Name = 'file:../tool' }, @{ Name = '../tool' },
        @{ Name = '@scope/tool&whoami' }
    ) {
        $script:NpmOutdated = @(New-NpmAdapterTestPackage -Name $Name)
        $result = Update-AllPackages -Provider Npm -Confirm:$false
        $result.Status | Should -BeExactly 'Failed'
        $result.Error.Exception.Message | Should -Match 'Invalid npm registry package name'
        Should -Invoke Shmuelie.Node\Update-NpmPackage -ModuleName Shmuelie.PackageManagement -Times 0 -Exactly
    }

    It 'does not mutate any local dependency or lockfile' {
        $project = Join-Path $TestDrive 'project'
        New-Item -ItemType Directory -Path $project -ErrorAction Stop | Out-Null
        '{"dependencies":{"local-only":"1.0.0"}}' | Set-Content (Join-Path $project 'package.json')
        '{"lockfileVersion":3}' | Set-Content (Join-Path $project 'package-lock.json')
        $before = @(Get-ChildItem $project -File | Get-FileHash).Hash
        $script:NpmInstalled += New-NpmAdapterTestPackage -Name 'current-global' -Version '3.0.0'
        Push-Location $project
        try { $result = Update-AllPackages -Provider Npm -Confirm:$false }
        finally { Pop-Location }
        $result.Status | Should -BeExactly 'Updated'
        @(Get-ChildItem $project -File | Get-FileHash).Hash | Should -Be $before
        Should -Invoke Get-NpmPackage -ModuleName Shmuelie.Node -Times 0 -Exactly -ParameterFilter { -not $Global }
        Should -Invoke Shmuelie.Node\Update-NpmPackage -ModuleName Shmuelie.PackageManagement -Times 0 -Exactly -ParameterFilter {
            -not $Global -or $Name -ne '@scope/tool'
        }
    }

    It 'rejects non-global discovery output rather than updating it' {
        $script:NpmOutdated = @(New-NpmAdapterTestPackage -Global $false)
        (Update-AllPackages -Provider Npm -Confirm:$false).Status | Should -BeExactly 'Failed'
        Should -Invoke Shmuelie.Node\Update-NpmPackage -ModuleName Shmuelie.PackageManagement -Times 0 -Exactly
    }

    It 'rejects incomplete discovery data for <Kind> before any package is updated' -ForEach @(
        @{ Kind = 'npm error metadata'; Package = [pscustomobject]@{ PSTypeName = 'NpmPackage'; Name = 'error'; Version = $null; Latest = $null; Global = $true } }
        @{ Kind = 'missing installed package'; Package = [pscustomobject]@{ PSTypeName = 'NpmPackage'; Name = 'missing'; Version = $null; Latest = '2.0.0'; Global = $true } }
        @{ Kind = 'missing latest version'; Package = [pscustomobject]@{ PSTypeName = 'NpmPackage'; Name = 'tool'; Version = '1.0.0'; Latest = $null; Global = $true } }
    ) {
        $script:NpmOutdated = @(New-NpmAdapterTestPackage; $Package)
        $result = Update-AllPackages -Provider Npm -Confirm:$false
        $result.Status | Should -BeExactly 'Failed'
        $result.Reason | Should -Match 'outdated global discovery is incomplete'
        Should -Invoke Shmuelie.Node\Update-NpmPackage -ModuleName Shmuelie.PackageManagement -Times 0 -Exactly
    }

    It 'reports an observed unchanged version honestly' {
        $script:NpmInstalled = @(New-NpmAdapterTestPackage)
        $result = Update-AllPackages -Provider Npm -Confirm:$false
        $result.Status | Should -BeExactly 'Unchanged'
        $result.ResultingVersion | Should -BeExactly '1.0.0'
    }

    It 'does not invent observed versions when verification <Kind>' -ForEach @(
        @{ Kind = 'finds no package'; Packages = @(); Exit = 0 }
        @{ Kind = 'finds an unknown version'; Packages = @([pscustomobject]@{ PSTypeName = 'NpmPackage'; Name = '@scope/tool'; Version = $null; Global = $true }); Exit = 0 }
        @{ Kind = 'fails'; Packages = @(); Exit = 2 }
    ) {
        $script:NpmInstalled = $Packages
        $script:NpmListExit = $Exit
        $result = Update-AllPackages -Provider Npm -Confirm:$false
        $result.Status | Should -BeExactly 'Failed'
        $result.ResultingVersion | Should -BeNullOrEmpty
    }

    It 'does not treat <Kind> update output as success' -ForEach @(
        @{ Kind = 'void'; Callback = {} }
        @{ Kind = 'native text'; Callback = { 'added one package' } }
        @{ Kind = 'false success'; Callback = { [pscustomobject]@{ PSTypeName = 'NpmUpdateResult'; Name = '@scope/tool'; Global = $true; Success = $false } } }
    ) {
        Mock Shmuelie.Node\Update-NpmPackage -ModuleName Shmuelie.PackageManagement $Callback
        $result = Update-AllPackages -Provider Npm -Confirm:$false
        $result.Status | Should -BeExactly 'Failed'
        $result.ResultingVersion | Should -BeNullOrEmpty
        Should -Invoke Get-NpmPackage -ModuleName Shmuelie.Node -Times 0 -Exactly -ParameterFilter { -not $Outdated }
    }

    It 'continues individual failures unless StopOnFailure is <Stop>' -ForEach @(
        @{ Stop = $false; Expected = @('Failed', 'Updated'); Updates = 2 }
        @{ Stop = $true; Expected = @('Failed'); Updates = 1 }
    ) {
        $script:NpmOutdated = @(New-NpmAdapterTestPackage -Name 'first'; New-NpmAdapterTestPackage)
        Mock Shmuelie.Node\Update-NpmPackage -ModuleName Shmuelie.PackageManagement {
            [pscustomobject]@{ PSTypeName = 'NpmUpdateResult'; Name = $Name; Global = $true; Success = $false }
        } -ParameterFilter { $Name -eq 'first' }
        $results = @(Update-AllPackages -Provider Npm -StopOnFailure:$Stop -Confirm:$false)
        $results.Status | Should -Be $Expected
        Should -Invoke Shmuelie.Node\Update-NpmPackage -ModuleName Shmuelie.PackageManagement -Times $Updates -Exactly
    }

    It 'continues after a canonical nonterminating update error' {
        $script:NpmOutdated = @(New-NpmAdapterTestPackage -Name 'first'; New-NpmAdapterTestPackage)
        Mock Shmuelie.Node\Update-NpmPackage -ModuleName Shmuelie.PackageManagement { Write-Error 'npm update failed.' } -ParameterFilter { $Name -eq 'first' }
        $results = @(Update-AllPackages -Provider Npm -Confirm:$false)
        $results.Status | Should -Be @('Failed', 'Updated')
        $results[0].Error.Exception.Message | Should -Match 'npm update failed'
    }

    It 'fails native discovery errors instead of reporting no updates' {
        $script:NpmOutdated = @()
        $script:NpmDiscoveryExit = 1
        $result = Update-AllPackages -Provider Npm -Confirm:$false
        $result.Status | Should -BeExactly 'Failed'
        $result.Reason | Should -Match 'exit code 1'
        Should -Invoke Shmuelie.Node\Update-NpmPackage -ModuleName Shmuelie.PackageManagement -Times 0 -Exactly
    }

    It 'restores native exit status and preference after read-only discovery' {
        $oldExit = $global:LASTEXITCODE
        $oldPreference = $global:PSNativeCommandUseErrorActionPreference
        try {
            $global:LASTEXITCODE = 37
            $global:PSNativeCommandUseErrorActionPreference = $true
            (Update-AllPackages -Provider Npm -WhatIf).Status | Should -BeExactly 'Planned'
            $global:LASTEXITCODE | Should -Be 37
            $global:PSNativeCommandUseErrorActionPreference | Should -BeTrue
        } finally {
            $global:LASTEXITCODE = $oldExit
            $global:PSNativeCommandUseErrorActionPreference = $oldPreference
        }
    }

    It 'accepts canonical npm outdated JSON with exit one using only mocked npm' {
        Mock Get-NpmPackage -ModuleName Shmuelie.Node {
            & $script:CanonicalNpmGetter -Global:$Global -Outdated:$Outdated
        }
        Mock npm -ModuleName Shmuelie.Node {
            $global:LASTEXITCODE = 1
            '{"@scope/tool":{"current":"1.0.0","wanted":"1.5.0","latest":"2.0.0"}}'
        }
        $result = Update-AllPackages -Provider Npm -WhatIf
        $result.Status | Should -BeExactly 'Planned'
        $result.Target | Should -BeExactly '@scope/tool'
        $result.PreviousVersion | Should -BeExactly '1.0.0'
        $result.ResultingVersion | Should -BeExactly '2.0.0'
        Should -Invoke npm -ModuleName Shmuelie.Node -Times 1 -Exactly -ParameterFilter {
            $args.Count -eq 3 -and $args[0] -eq 'outdated' -and $args[1] -eq '--json' -and $args[2] -eq '--global'
        }
        Should -Invoke Shmuelie.Node\Update-NpmPackage -ModuleName Shmuelie.PackageManagement -Times 0 -Exactly
    }
}

Describe 'Update-AllPackages native confirmation' {
    It '<Answer> returns <Status> and invokes update <Count> times' -ForEach @(
        @{ Answer = 'n'; Status = 'Skipped'; Count = 0 }
        @{ Answer = 'y'; Status = 'Updated'; Count = 1 }
    ) {
        $escapedManifest = $script:Manifest.Replace("'", "''")
        $childScript = @'
$ErrorActionPreference = 'Stop'
Import-Module '__MANIFEST__'
& (Get-Module Shmuelie.PackageManagement) {
    $script:UpdateCount = 0
    function script:Get-PackageProvider {
        [pscustomobject]@{
            Name = 'Npm'
            Platforms = @('Windows', 'Linux', 'MacOS')
            RequiredModules = @()
            RequiredCommands = @()
            OptionNames = @()
            TestAvailable = $null
            GetTargets = { New-PackageUpdateTarget -Target tool }
            Update = {
                $script:UpdateCount++
                New-PackageUpdateResult -Provider Npm -Target tool -Status Updated
            }
        }
    }
}
$result = Update-AllPackages -Provider Npm -Confirm
$count = & (Get-Module Shmuelie.PackageManagement) { $script:UpdateCount }
'RESULT:' + (@{ Status = $result.Status; Count = $count; Reason = $result.Reason } | ConvertTo-Json -Compress)
'@.Replace('__MANIFEST__', $escapedManifest)
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript))
        $output = $Answer | & (Get-Process -Id $PID).Path -NoLogo -NoProfile -EncodedCommand $encoded -OutputFormat Text 2>&1
        $LASTEXITCODE | Should -Be 0
        $jsonLine = @($output | Where-Object { "$_" -like 'RESULT:*' })
        $jsonLine | Should -HaveCount 1
        $actual = "$($jsonLine[0])".Substring(7) | ConvertFrom-Json
        $actual.Status | Should -BeExactly $Status
        $actual.Count | Should -Be $Count
        if ($Answer -eq 'n') {
            $actual.Reason | Should -BeExactly 'Update was not confirmed.'
        }
    }
}
