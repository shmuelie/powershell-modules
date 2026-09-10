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

    It 'reports unavailable catalog integrations without assuming installed dependencies' {
        Mock Get-PackageProviderAvailability -ModuleName Shmuelie.PackageManagement {
            [pscustomobject]@{ Available = $false; Reason = 'Dependency unavailable in this test.' }
        }
        Mock Import-Module -ModuleName Shmuelie.PackageManagement { throw 'Must not import optional modules.' }
        $results = @(Update-AllPackages)
        $results.Provider | Should -Be @('PSResourceGet', 'DotNet', 'Npm', 'Pip', 'Uv', 'VSCode', 'WinGet', 'AppInstaller')
        foreach ($result in $results) {
            $result.PSTypeNames[0] | Should -BeExactly 'Shmuelie.PackageManagement.UpdateResult'
            $result.Status | Should -BeExactly 'Skipped'
            $result.Reason | Should -BeExactly 'Dependency unavailable in this test.'
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

Describe 'Uv package provider' {
    BeforeAll {
        $script:HadUtilities = $null -ne (Get-Module Shmuelie.Utilities)
        if (-not $script:HadUtilities) {
            Import-Module (Join-Path $repoRoot 'modules' 'Shmuelie.Utilities' 'Shmuelie.Utilities.psd1') -ErrorAction Stop
        }
    }
    AfterAll {
        if (-not $script:HadUtilities) { Remove-Module Shmuelie.Utilities -Force -ErrorAction Stop }
    }

    InModuleScope Shmuelie.PackageManagement {
        BeforeAll {
            # A scoped fake native command prevents any real uv invocation.
            function script:uv {
                $script:NativeCalls.Add(@($args))
                $global:LASTEXITCODE = $script:UvExitCode
                if ($script:NativeOverride) { & $script:NativeOverride; return }
                if ($args[1] -eq 'upgrade') {
                    $name = $args[-1]
                    if ($name -eq $script:FailTool) {
                        $global:LASTEXITCODE = 7
                        'Tool update failed.'
                    } else {
                        $script:ToolVersions[$name] = $script:AfterToolVersion
                        'Resolved packages'
                    }
                } else {
                    foreach ($name in $script:ToolVersions.Keys) {
                        "$name v$($script:ToolVersions[$name])"
                        "- $name"
                    }
                }
            }
        }
        AfterAll {
            Remove-Item Function:uv -ErrorAction Stop
        }

        BeforeEach {
            $script:NativeCalls = [System.Collections.Generic.List[object]]::new()
            $script:UvExitCode = 0
            $script:NativeOverride = $null
            $script:FailTool = $null
            $script:ToolVersions = [ordered]@{ ruff = '1.0' }
            $script:AfterToolVersion = '2.0'
            $script:Packages = @([pscustomobject]@{ name = 'requests'; version = '1.0'; latest_version = '9.0' })
            $script:InstalledPackages = @([pscustomobject]@{ name = 'requests'; version = '2.0' })
            Mock Get-PackageProviderPlatform { 'Windows' }
            Mock Get-Module { [pscustomobject]@{ Name = 'Shmuelie.Utilities' } }
            Mock Import-Module {}
            Mock Get-Command { [pscustomobject]@{ Name = $Name } }
            Mock Get-UvProviderPackages {
                if ($Outdated) { $script:Packages } else { $script:InstalledPackages }
            }
            Mock 'Shmuelie.Utilities\Update-UvPackage' {
                [pscustomobject]@{ PSTypeName = 'UvUpdateResult'; Name = $PackageName; Success = $true }
            }
        }

        It 'keeps catalog order and descriptor discovery side-effect-free' {
            $catalog = @(Get-PackageProvider)
            $catalog.Name | Should -Be @('PSResourceGet', 'DotNet', 'Npm', 'Pip', 'Uv', 'VSCode', 'WinGet', 'AppInstaller')
            ($catalog | Where-Object Name -EQ Uv).OptionNames | Should -Be @('Scope', 'TopLevelOnly')
            Should -Invoke Get-Module -Times 0 -Exactly
            Should -Invoke Get-Command -Times 0 -Exactly
            Should -Invoke Import-Module -Times 0 -Exactly
            $script:NativeCalls | Should -HaveCount 0
        }

        It 'updates system top-level outdated packages and tools with distinct typed identities' {
            $results = @(Update-AllPackages -Provider Uv -Confirm:$false)
            $results.Target | Should -Be @('pip:system:requests', 'tool:ruff')
            $results.Status | Should -Be @('Updated', 'Updated')
            $results.Provider | Should -Be @('Uv', 'Uv')
            $results.PreviousVersion | Should -Be @('1.0', '1.0')
            $results.ResultingVersion | Should -Be @('2.0', '2.0')
            foreach ($row in $results) { $row.PSTypeNames[0] | Should -BeExactly 'Shmuelie.PackageManagement.UpdateResult' }
            Should -Invoke Get-UvProviderPackages -Times 1 -Exactly -ParameterFilter { $Outdated -and $TopLevelOnly }
            Should -Invoke 'Shmuelie.Utilities\Update-UvPackage' -Times 1 -Exactly -ParameterFilter { $PackageName -eq 'requests' -and $Confirm -eq $false }
            $script:NativeCalls[0] | Should -Be @('tool', 'list', '--color', 'never', '--no-progress')
            $script:NativeCalls[1] | Should -Be @('tool', 'upgrade', '--color', 'never', '--no-progress', '--', 'ruff')
            $script:NativeCalls[2] | Should -Be @('tool', 'list', '--color', 'never', '--no-progress')
        }

        It 'previews both scopes without executing an update or proposing unobserved tool versions' {
            $results = @(Update-AllPackages -Provider Uv -WhatIf)
            $results.Target | Should -Be @('pip:system:requests', 'tool:ruff')
            $results.Status | Should -Be @('Planned', 'Planned')
            $results[0].ResultingVersion | Should -BeExactly '9.0'
            $results[1].ResultingVersion | Should -BeNullOrEmpty
            Should -Invoke 'Shmuelie.Utilities\Update-UvPackage' -Times 0 -Exactly
            $script:NativeCalls | Should -HaveCount 1
        }

        It 'supports package dependency opt-in without discovering tools' {
            $result = Update-AllPackages -Provider uv -ProviderOptions @{ uv = @{ scope = 'packages'; toplevelonly = $false } } -Confirm:$false
            $result.Target | Should -BeExactly 'pip:system:requests'
            Should -Invoke Get-UvProviderPackages -Times 1 -Exactly -ParameterFilter { $Outdated -and -not $TopLevelOnly }
            $script:NativeCalls | Should -HaveCount 0
        }

        It 'supports tools without importing the package-command module' {
            $result = Update-AllPackages -Provider Uv -ProviderOptions @{ Uv = @{ Scope = 'Tools' } } -Confirm:$false
            $result.Target | Should -BeExactly 'tool:ruff'
            $result.Status | Should -BeExactly 'Updated'
            Should -Invoke Import-Module -Times 0 -Exactly
            Should -Invoke Get-UvProviderPackages -Times 0 -Exactly
        }

        It 'skips missing <Dependency> dynamically' -ForEach @(
            @{ Dependency = 'uv' }
            @{ Dependency = 'module' }
            @{ Dependency = 'Shmuelie.Utilities\Get-UvPackages' }
            @{ Dependency = 'Shmuelie.Utilities\Update-UvPackage' }
        ) {
            if ($Dependency -eq 'module') { Mock Get-Module { $null } }
            else {
                $script:MissingCommand = $Dependency
                Mock Get-Command { $null } -ParameterFilter { $Name -eq $script:MissingCommand }
            }
            $result = Update-AllPackages -Provider Uv -Confirm:$false
            $result.Status | Should -BeExactly 'Skipped'
            $result.Reason | Should -Match 'required (module|command)'
            $script:NativeCalls | Should -HaveCount 0
            Should -Invoke 'Shmuelie.Utilities\Update-UvPackage' -Times 0 -Exactly
        }

        It 'preserves dependency import exceptions as failures' {
            Mock Import-Module { throw 'Import failed.' }
            $result = Update-AllPackages -Provider Uv -Confirm:$false
            $result.Status | Should -BeExactly 'Failed'
            $result.Reason | Should -BeExactly 'Import failed.'
        }

        It 'reports an empty package and tool set unchanged' {
            $script:Packages = @()
            $script:NativeOverride = { 'No tools installed' }
            $result = Update-AllPackages -Provider Uv -Confirm:$false
            $result.Target | Should -BeExactly 'Uv'
            $result.Status | Should -BeExactly 'Unchanged'
            Should -Invoke 'Shmuelie.Utilities\Update-UvPackage' -Times 0 -Exactly
        }

        It 'retains successful package results after tool failures and continues between tools' {
            $script:ToolVersions.Add('black', '1.0')
            $script:FailTool = 'ruff'
            $results = @(Update-AllPackages -Provider Uv -Confirm:$false)
            $results.Target | Should -Be @('pip:system:requests', 'tool:ruff', 'tool:black')
            $results.Status | Should -Be @('Updated', 'Failed', 'Updated')
            $results[1].Reason | Should -Match 'exit 7'
            $results[1].Error | Should -BeOfType ([System.Management.Automation.ErrorRecord])
        }

        It 'stops between tools without losing the preceding package result' {
            $script:ToolVersions.Add('black', '1.0')
            $script:FailTool = 'ruff'
            $results = @(Update-AllPackages -Provider Uv -StopOnFailure -Confirm:$false)
            $results.Status | Should -Be @('Updated', 'Failed')
            @($script:NativeCalls | Where-Object { $_[1] -eq 'upgrade' }) | Should -HaveCount 1
        }

        It 'stops after package failure before updating any tools' {
            Mock 'Shmuelie.Utilities\Update-UvPackage' {
                [pscustomobject]@{ PSTypeName = 'UvUpdateResult'; Name = $PackageName; Success = $false }
            }
            $results = @(Update-AllPackages -Provider Uv -StopOnFailure -Confirm:$false)
            $results | Should -HaveCount 1
            $results[0].Status | Should -BeExactly 'Failed'
            @($script:NativeCalls | Where-Object { $_[1] -eq 'upgrade' }) | Should -HaveCount 0
        }

        It 'rejects invalid or absent package update evidence: <Label>' -ForEach @(
            @{ Label = 'void'; Output = {} }
            @{ Label = 'untyped'; Output = { [pscustomobject]@{ Name = 'requests'; Success = $true } } }
            @{ Label = 'wrong name'; Output = { [pscustomobject]@{ PSTypeName = 'UvUpdateResult'; Name = 'other'; Success = $true } } }
            @{ Label = 'string success'; Output = { [pscustomobject]@{ PSTypeName = 'UvUpdateResult'; Name = 'requests'; Success = 'true' } } }
            @{ Label = 'nonterminating error'; Output = { Write-Error 'Update error.' } }
        ) {
            Mock 'Shmuelie.Utilities\Update-UvPackage' $Output
            (Update-AllPackages -Provider Uv -ProviderOptions @{ Uv = @{ Scope = 'Packages' } } -Confirm:$false).Status | Should -BeExactly 'Failed'
        }

        It 'fails an unknown <Field> version rather than assuming an update' -ForEach @(
            @{ Field = 'observed' }
            @{ Field = 'previous' }
        ) {
            if ($Field -eq 'observed') { $script:InstalledPackages[0].version = $null }
            else { $script:Packages[0].version = $null }
            $result = Update-AllPackages -Provider Uv -ProviderOptions @{ Uv = @{ Scope = 'Packages' } } -Confirm:$false
            $result.Status | Should -BeExactly 'Failed'
            $result.ResultingVersion | Should -BeNullOrEmpty
            $result.Reason | Should -Match 'version is unknown'
        }

        It 'uses actual native exit status and restores the caller status' {
            $previous = Get-Variable LASTEXITCODE -Scope Global -ErrorAction Ignore
            $previousValue = if ($previous) { $previous.Value } else { $null }
            try {
                $global:LASTEXITCODE = 37
                $script:UvExitCode = 9
                $script:NativeOverride = {
                    & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -Command 'exit 0'
                    'ruff v1.0'
                    '- ruff'
                }
                @(Get-UvProviderTools).name | Should -BeExactly 'ruff'
                $global:LASTEXITCODE | Should -Be 37

                $script:NativeOverride = {
                    & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -Command 'exit 7'
                    'Native tool failure.'
                }
                { Get-UvProviderTools } | Should -Throw '*exit 7*'
                $global:LASTEXITCODE | Should -Be 37
            } finally {
                if ($previous) { $global:LASTEXITCODE = $previousValue }
                else { Remove-Variable LASTEXITCODE -Scope Global -ErrorAction Ignore }
            }
        }

        It 'reports unchanged installed versions rather than assuming the proposed version won' {
            $script:InstalledPackages[0].version = '1.0'
            $script:AfterToolVersion = '1.0'
            $results = @(Update-AllPackages -Provider Uv -Confirm:$false)
            $results.Status | Should -Be @('Unchanged', 'Unchanged')
            $results.ResultingVersion | Should -Be @('1.0', '1.0')
        }

        It 'fails instead of inventing an observed package after update' {
            $script:InstalledPackages = @()
            $result = Update-AllPackages -Provider Uv -ProviderOptions @{ Uv = @{ Scope = 'Packages' } } -Confirm:$false
            $result.Status | Should -BeExactly 'Failed'
            $result.Reason | Should -Match 'Cannot observe'
        }

        It 'fails if a tool disappears after the upgrade rather than trusting exit zero' {
            $script:AfterToolVersion = $null
            $result = Update-AllPackages -Provider Uv -ProviderOptions @{ Uv = @{ Scope = 'Tools' } } -Confirm:$false
            $result.Status | Should -BeExactly 'Failed'
            $result.ResultingVersion | Should -BeNullOrEmpty
        }

        It 'retains a package failure and continues to the next target by default' {
            Mock 'Shmuelie.Utilities\Update-UvPackage' { throw 'Package failed.' }
            $results = @(Update-AllPackages -Provider Uv -Confirm:$false)
            $results.Target | Should -Be @('pip:system:requests', 'tool:ruff')
            $results.Status | Should -Be @('Failed', 'Updated')
        }

        It 'treats empty tool stdout as no installed tools' {
            $script:ToolVersions.Clear()
            $result = Update-AllPackages -Provider Uv -ProviderOptions @{ Uv = @{ Scope = 'Tools' } } -Confirm:$false
            $result.Target | Should -BeExactly 'Uv'
            $result.Status | Should -BeExactly 'Unchanged'
        }

        It 'validates the update target identity before passing any native arguments' {
            $target = New-PackageUpdateTarget -Target 'tool:other' -Data @{ Kind = 'Tool'; Name = 'ruff' }
            { Update-UvProviderTarget -Target $target -Confirm:$false } | Should -Throw '*identity*'
            $script:NativeCalls | Should -HaveCount 0
        }

        It 'keeps provider failures as result data with ErrorAction Stop' {
            $script:FailTool = 'ruff'
            $results = @(Update-AllPackages -Provider Uv -ErrorAction Stop -Confirm:$false)
            $results.Status | Should -Be @('Updated', 'Failed')
        }

        It 'fails read-only discovery for invalid native exit code <Code>' -ForEach @(
            @{ Code = 5 }
            @{ Code = $null }
            @{ Code = '0' }
        ) {
            $script:UvExitCode = $Code
            $result = Update-AllPackages -Provider Uv -Confirm:$false
            $result.Status | Should -BeExactly 'Failed'
            Should -Invoke 'Shmuelie.Utilities\Update-UvPackage' -Times 0 -Exactly
        }

        It 'rejects unexpected tool listing <Label> without updating packages' -ForEach @(
            @{ Label = 'JSON'; Lines = @('[{"name":"ruff","version":"1.0"}]') }
            @{ Label = 'malformed warning'; Lines = @('warning: Ignoring malformed tool `ruff`') }
            @{ Label = 'orphan entrypoint'; Lines = @('- ruff') }
            @{ Label = 'duplicate name'; Lines = @('a_b v1.0', 'a-b v2.0') }
            @{ Label = 'unsafe name'; Lines = @('ruff&echo v1.0') }
        ) {
            $script:NativeOverride = { $Lines }.GetNewClosure()
            $result = Update-AllPackages -Provider Uv -Confirm:$false
            $result.Status | Should -BeExactly 'Failed'
            Should -Invoke 'Shmuelie.Utilities\Update-UvPackage' -Times 0 -Exactly
        }

        It 'rejects unsafe package identifiers: <Name>' -ForEach @(
            @{ Name = '--all' }; @{ Name = 'foo&bar' }; @{ Name = 'foo;bar' }
            @{ Name = 'foo bar' }; @{ Name = 'foo@https://example.org' }; @{ Name = "foo`nbar" }
        ) {
            $script:Packages[0].name = $Name
            (Update-AllPackages -Provider Uv -Confirm:$false).Status | Should -BeExactly 'Failed'
            Should -Invoke 'Shmuelie.Utilities\Update-UvPackage' -Times 0 -Exactly
        }

        It 'explicitly fails unsupported option values: <Label>' -ForEach @(
            @{ Label = 'virtual environment'; Options = @{ Scope = 'VirtualEnvironment' } }
            @{ Label = 'scope array'; Options = @{ Scope = @('Packages', 'Tools') } }
            @{ Label = 'null scope'; Options = @{ Scope = $null } }
            @{ Label = 'string Boolean'; Options = @{ TopLevelOnly = 'false' } }
            @{ Label = 'integer Boolean'; Options = @{ TopLevelOnly = 1 } }
            @{ Label = 'tool top-level'; Options = @{ Scope = 'Tools'; TopLevelOnly = $true } }
        ) {
            $result = Update-AllPackages -Provider Uv -ProviderOptions @{ Uv = $Options } -Confirm:$false
            $result.Status | Should -BeExactly 'Failed'
            $result.Error | Should -BeOfType ([System.Management.Automation.ErrorRecord])
            $script:NativeCalls | Should -HaveCount 0
            Should -Invoke Get-UvProviderPackages -Times 0 -Exactly
        }

        It 'rejects unknown option names before dependency discovery' {
            { Update-AllPackages -Provider Uv -ProviderOptions @{ Uv = @{ Python = 'custom' } } } | Should -Throw '*Unknown option*'
            Should -Invoke Get-Command -Times 0 -Exactly
        }

        It 'preserves nonterminating discovery errors as failures without mutation' {
            Mock Get-UvProviderPackages { Write-Error 'Discovery failed.' }
            $result = Update-AllPackages -Provider Uv -Confirm:$false
            $result.Status | Should -BeExactly 'Failed'
            Should -Invoke 'Shmuelie.Utilities\Update-UvPackage' -Times 0 -Exactly
        }
    }
}

Describe 'Uv Utilities native discovery boundary' {
    BeforeAll {
        $script:HadUtilities = $null -ne (Get-Module Shmuelie.Utilities)
        if (-not $script:HadUtilities) {
            Import-Module (Join-Path $repoRoot 'modules' 'Shmuelie.Utilities' 'Shmuelie.Utilities.psd1') -ErrorAction Stop
        }
        $script:UtilitiesModule = Get-Module Shmuelie.Utilities
        $script:OriginalUvFunction = & $script:UtilitiesModule { Get-Item Function:uv -ErrorAction Ignore }
        & $script:UtilitiesModule {
            function script:uv {
                $script:UvTestCalls.Add(@($args))
                if ($script:UvTestFailCommand -eq $args[1]) {
                    # Harmless native failure exercises PowerShell's actual error boundary.
                    & pwsh -NoProfile -Command 'exit 7'
                    return
                }
                if ($args[1] -eq 'list') {
                    '[{"name":"requests","version":"1.0","latest_version":"2.0"}]'
                } else {
                    'Name: requests'
                    'Required-by:'
                }
            }
        }
    }
    BeforeEach {
        & $script:UtilitiesModule {
            $script:UvTestCalls = [System.Collections.Generic.List[object]]::new()
            $script:UvTestFailCommand = $null
        }
    }
    AfterAll {
        if ($script:OriginalUvFunction) {
            & $script:UtilitiesModule { param($Original) Set-Item Function:script:uv -Value $Original.ScriptBlock } $script:OriginalUvFunction
        } else {
            & $script:UtilitiesModule { Remove-Item Function:uv -ErrorAction Stop }
        }
        & $script:UtilitiesModule {
            Remove-Variable UvTestCalls, UvTestFailCommand -Scope Script -ErrorAction Ignore
        }
        if (-not $script:HadUtilities) { Remove-Module Shmuelie.Utilities -Force -ErrorAction Stop }
    }

    It 'reuses the canonical package listing and its top-level JSON pipeline' {
        $packages = @(& (Get-Module Shmuelie.PackageManagement) { Get-UvProviderPackages -Outdated -TopLevelOnly })
        $packages.name | Should -BeExactly 'requests'
        $calls = & $script:UtilitiesModule { ,$script:UvTestCalls }
        $calls[0] | Should -Be @('pip', 'list', '--no-progress', '--outdated', '--format', 'json', '--system')
        $calls[1] | Should -Be @('pip', 'show', 'requests', '--system')
    }

    It 'propagates a failing native <Subcommand> even when it returns no JSON' -ForEach @(
        @{ Subcommand = 'list' }
        @{ Subcommand = 'show' }
    ) {
        & $script:UtilitiesModule { param($Name) $script:UvTestFailCommand = $Name } $Subcommand
        { & (Get-Module Shmuelie.PackageManagement) { Get-UvProviderPackages -Outdated -TopLevelOnly } } |
            Should -Throw '*exit code*7*'
    }

    It 'does not change Utilities native error or ErrorAction preferences' {
        $before = & $script:UtilitiesModule { @($PSNativeCommandUseErrorActionPreference, $ErrorActionPreference) }
        & (Get-Module Shmuelie.PackageManagement) { Get-UvProviderPackages } | Out-Null
        $after = & $script:UtilitiesModule { @($PSNativeCommandUseErrorActionPreference, $ErrorActionPreference) }
        $after | Should -Be $before
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
