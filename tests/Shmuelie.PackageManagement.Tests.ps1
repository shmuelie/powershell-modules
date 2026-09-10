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

    It 'reports unavailable integrations without depending on installed tools' {
        Mock Get-PackageProviderPlatform -ModuleName Shmuelie.PackageManagement { 'Windows' }
        Mock Get-Module -ModuleName Shmuelie.PackageManagement { $null }
        Mock Import-Module -ModuleName Shmuelie.PackageManagement { throw 'Must not import optional modules.' }
        $results = @(Update-AllPackages)
        $results.Provider | Should -Be @('PSResourceGet', 'DotNet', 'Npm', 'Pip', 'Uv', 'VSCode', 'WinGet', 'AppInstaller')
        foreach ($result in $results) {
            $result.PSTypeNames[0] | Should -BeExactly 'Shmuelie.PackageManagement.UpdateResult'
            $result.Status | Should -BeExactly 'Skipped'
            $result.Reason | Should -Not -BeNullOrEmpty
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

Describe 'PSResourceGet package provider' {
    BeforeAll {
        $utilitiesManifest = Join-Path $repoRoot 'modules' 'Shmuelie.Utilities' 'Shmuelie.Utilities.psd1'
        Import-Module $utilitiesManifest -Force
        $script:CanonicalPSResourceCommand = Get-Command 'Shmuelie.Utilities\Update-InstalledPSResource' -ListImported
        # Test-only dependency: a missed mock fails closed, never reaches a feed.
        $script:PSResourceStub = New-Module -Name Microsoft.PowerShell.PSResourceGet -ScriptBlock {
            function Find-PSResource {
                [CmdletBinding()]
                param($Name, $Repository, [switch]$Prerelease)
                throw 'Unmocked Find-PSResource.'
            }
            function Save-PSResource {
                [CmdletBinding(SupportsShouldProcess)]
                param($Name, $Version, $Path, $Repository, [switch]$TrustRepository,
                    [switch]$IncludeXml, [switch]$AcceptLicense, [switch]$SkipDependencyCheck)
                throw 'Unmocked Save-PSResource.'
            }
            function Get-PSResourceRepository {
                [CmdletBinding()]
                param()
                throw 'Unmocked Get-PSResourceRepository.'
            }
            Export-ModuleMember -Function Find-PSResource, Save-PSResource, Get-PSResourceRepository
        }
        Import-Module $script:PSResourceStub -Global -Force

        function New-PSResourceProviderTestLayout {
            param($Root, $Name, $Version = '1.0.0', $Repository = 'FeedA', $Prerelease = '', $RepositorySourceLocation = '')
            if (-not $TestDrive -or -not (Test-Path -LiteralPath $TestDrive -PathType Container)) {
                throw 'Pester TestDrive must exist before creating module fixtures.'
            }
            $fullRoot = [IO.Path]::GetFullPath($Root)
            $testPrefix = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($TestDrive)) + [IO.Path]::DirectorySeparatorChar
            if (-not $fullRoot.StartsWith($testPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Fixture root must be inside TestDrive.'
            }
            $directory = Join-Path $Root $Name $Version
            New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop | Out-Null
            New-ModuleManifest -Path (Join-Path $directory "$Name.psd1") -ModuleVersion $Version -ErrorAction Stop
            [pscustomobject]@{
                Version = $Version
                Prerelease = $Prerelease
                Repository = $Repository
                RepositorySourceLocation = $RepositorySourceLocation
            } | Export-Clixml -LiteralPath (Join-Path $directory 'PSGetModuleInfo.xml') -ErrorAction Stop
        }
    }

    AfterAll {
        if ($script:PSResourceStub) {
            Remove-Module -ModuleInfo $script:PSResourceStub -Force -ErrorAction Stop
        }
        Remove-Module Shmuelie.Utilities -Force -ErrorAction Stop
    }

    BeforeEach {
        if (-not $TestDrive -or -not (Test-Path -LiteralPath $TestDrive -PathType Container)) {
            throw 'Pester TestDrive must exist before provider setup.'
        }
        $script:ResourceRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $script:ResourceRoot -Force -ErrorAction Stop | Out-Null
        Mock Import-Module -ModuleName Shmuelie.PackageManagement {}
        # Keep metadata tied to the actual dependency when individual tests mock
        # the public command at its module-qualified call site.
        Mock Get-Command -ModuleName Shmuelie.PackageManagement { $script:CanonicalPSResourceCommand } -ParameterFilter {
            $Name -eq 'Shmuelie.Utilities\Update-InstalledPSResource'
        }
        Mock Find-PSResource -ModuleName Shmuelie.Utilities { [pscustomobject]@{ Version = '2.0.0' } }
        Mock Save-PSResource -ModuleName Shmuelie.Utilities {
            New-PSResourceProviderTestLayout -Root $Path -Name $Name -Version (($Version -split '-', 2)[0]) `
                -Prerelease (($Version -split '-', 2)[1]) -Repository $Repository
        }
        Mock Get-PSResourceRepository -ModuleName Shmuelie.Utilities { throw 'Unexpected repository resolution.' }
    }

    It 'keeps descriptor discovery side-effect-free and declares only its own options' {
        Mock Get-Command -ModuleName Shmuelie.PackageManagement { throw 'Catalog must not probe dependencies.' }
        $descriptor = & (Get-Module Shmuelie.PackageManagement) { Get-PSResourceGetPackageProvider }
        $descriptor.OptionNames | Should -Be @('Path', 'Name', 'Exclude', 'Repository')
        $descriptor.RequiredModules | Should -Be @('Microsoft.PowerShell.PSResourceGet', 'Shmuelie.Utilities')
        Should -Invoke Import-Module -ModuleName Shmuelie.PackageManagement -Times 0 -Exactly
    }

    It 'skips missing <Dependency> without discovery or mutation' -ForEach @(
        @{ Dependency = 'Microsoft.PowerShell.PSResourceGet' }
        @{ Dependency = 'Shmuelie.Utilities' }
    ) {
        Mock Get-Module -ModuleName Shmuelie.PackageManagement { $null } -ParameterFilter { $Name -eq $Dependency }
        $result = Update-AllPackages -Provider PSResourceGet -ProviderOptions @{ PSResourceGet = @{ Path = $script:ResourceRoot } }
        $result.Status | Should -BeExactly Skipped
        $result.Reason | Should -BeLike "*$Dependency*"
        Should -Invoke Find-PSResource -ModuleName Shmuelie.Utilities -Times 0 -Exactly
        Should -Invoke Save-PSResource -ModuleName Shmuelie.Utilities -Times 0 -Exactly
    }

    It 'skips when the canonical public update command is missing' {
        Mock Get-Command -ModuleName Shmuelie.PackageManagement { $null } -ParameterFilter {
            $Name -eq 'Shmuelie.Utilities\Update-InstalledPSResource'
        }
        $result = Update-AllPackages -Provider PSResourceGet -ProviderOptions @{ PSResourceGet = @{ Path = $script:ResourceRoot } }
        $result.Status | Should -BeExactly Skipped
        $result.Reason | Should -Match 'Update-InstalledPSResource'
    }

    It 'skips <Label> roots with actionable configuration guidance' -ForEach @(
        @{ Label = 'unconfigured'; Options = @{} }
        @{ Label = 'empty'; Options = @{ Path = @() } }
    ) {
        $result = Update-AllPackages -Provider PSResourceGet -ProviderOptions @{ PSResourceGet = $Options }
        $result.Status | Should -BeExactly Skipped
        $result.Reason | Should -Match 'ProviderOptions.PSResourceGet.Path'
        Should -Invoke Save-PSResource -ModuleName Shmuelie.Utilities -Times 0 -Exactly
    }

    It 'skips nonexistent roots without creating them' {
        $missing = Join-Path $TestDrive 'missing'
        $result = Update-AllPackages -Provider PSResourceGet -ProviderOptions @{ PSResourceGet = @{ Path = $missing } } `
            -WarningAction SilentlyContinue -WarningVariable warnings
        $result.Status | Should -BeExactly Skipped
        $warnings | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $missing | Should -BeFalse
    }

    It 'rejects invalid <Key> option values before any lookup' -ForEach @(
        @{ Key = 'Path'; Value = 1 }
        @{ Key = 'Path'; Value = @('valid', 1) }
        @{ Key = 'Path'; Value = $null }
        @{ Key = 'Name'; Value = { throw 'Must not execute.' } }
        @{ Key = 'Name'; Value = ' ' }
        @{ Key = 'Exclude'; Value = @{ Bad = 'value' } }
        @{ Key = 'Repository'; Value = @('FeedA', 'FeedB') }
        @{ Key = 'Repository'; Value = '' }
    ) {
        $options = @{ Path = $script:ResourceRoot }
        $options[$Key] = $Value
        $result = Update-AllPackages -Provider PSResourceGet -ProviderOptions @{ PSResourceGet = $options } -WhatIf
        $result.Status | Should -BeExactly Failed
        $result.Error | Should -BeOfType ([System.Management.Automation.ErrorRecord])
        Should -Invoke Find-PSResource -ModuleName Shmuelie.Utilities -Times 0 -Exactly
        Should -Invoke Save-PSResource -ModuleName Shmuelie.Utilities -Times 0 -Exactly
    }

    It 'returns the core no-target outcome for an empty root' {
        $result = Update-AllPackages -Provider PSResourceGet -ProviderOptions @{ PSResourceGet = @{ Path = $script:ResourceRoot } }
        $result.Status | Should -BeExactly Unchanged
        $result.Target | Should -BeExactly PSResourceGet
        $result.ResultingVersion | Should -BeNullOrEmpty
        Should -Invoke Find-PSResource -ModuleName Shmuelie.Utilities -Times 0 -Exactly
    }

    It 'preserves mixed repository provenance and observes actual saved versions' {
        New-PSResourceProviderTestLayout -Root $script:ResourceRoot -Name ModuleA -Repository FeedA
        New-PSResourceProviderTestLayout -Root $script:ResourceRoot -Name ModuleB -Repository FeedB
        $results = @(Update-AllPackages -Provider PSResourceGet -ProviderOptions @{ PSResourceGet = @{ Path = $script:ResourceRoot } } -Confirm:$false)
        $results | Should -HaveCount 2
        $results.Status | Should -Be @('Updated', 'Updated')
        $results.PreviousVersion | Should -Be @('1.0.0', '1.0.0')
        $results.ResultingVersion | Should -Be @('2.0.0', '2.0.0')
        $results[0].PSTypeNames[0] | Should -BeExactly 'Shmuelie.PackageManagement.UpdateResult'
        Should -Invoke Save-PSResource -ModuleName Shmuelie.Utilities -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'ModuleA' -and $Repository -eq 'FeedA' -and $TrustRepository -and $IncludeXml -and $AcceptLicense -and $SkipDependencyCheck
        }
        Should -Invoke Save-PSResource -ModuleName Shmuelie.Utilities -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'ModuleB' -and $Repository -eq 'FeedB'
        }
    }

    It 'honors an explicit repository override without changing caller options' {
        New-PSResourceProviderTestLayout -Root $script:ResourceRoot -Name ModuleA -Repository FeedA
        $options = @{ psresourceget = @{ path = $script:ResourceRoot; repository = 'OverrideFeed' } }
        $before = $options | ConvertTo-Json -Depth 4 -Compress
        $result = Update-AllPackages -Provider PSResourceGet -ProviderOptions $options -Confirm:$false
        $result.Status | Should -BeExactly Updated
        ($options | ConvertTo-Json -Depth 4 -Compress) | Should -BeExactly $before
        Should -Invoke Save-PSResource -ModuleName Shmuelie.Utilities -Times 1 -Exactly -ParameterFilter { $Repository -eq 'OverrideFeed' }
    }

    It 'preserves source-URI repository resolution' {
        New-PSResourceProviderTestLayout -Root $script:ResourceRoot -Name ModuleA -Repository '' -RepositorySourceLocation 'https://packages.example.test/feed/'
        Mock Get-PSResourceRepository -ModuleName Shmuelie.Utilities { [pscustomobject]@{ Name = 'SourceFeed'; Uri = 'https://packages.example.test/feed' } }
        (Update-AllPackages -Provider PSResourceGet -ProviderOptions @{ PSResourceGet = @{ Path = $script:ResourceRoot } } -Confirm:$false).Status | Should -Be Updated
        Should -Invoke Save-PSResource -ModuleName Shmuelie.Utilities -Times 1 -Exactly -ParameterFilter { $Repository -eq 'SourceFeed' }
    }

    It 'preserves prerelease tracking and semantic comparison through canonical helpers' {
        New-PSResourceProviderTestLayout -Root $script:ResourceRoot -Name Preview -Version '2.0.0' -Prerelease 'beta.2'
        New-PSResourceProviderTestLayout -Root $script:ResourceRoot -Name Stable -Version '2.0.0'
        Mock Find-PSResource -ModuleName Shmuelie.Utilities {
            [pscustomobject]@{ Version = '2.0.0'; Prerelease = 'beta.10' }
            [pscustomobject]@{ Version = '1.0.0' }
        }
        $results = @(Update-AllPackages -Provider PSResourceGet -ProviderOptions @{ PSResourceGet = @{ Path = $script:ResourceRoot } } -Confirm:$false)
        $results.Status | Should -Be @('Updated', 'Unchanged')
        $results[0].PreviousVersion | Should -BeExactly '2.0.0-beta.2'
        $results[0].ResultingVersion | Should -BeExactly '2.0.0-beta.10'
        Should -Invoke Find-PSResource -ModuleName Shmuelie.Utilities -Times 1 -Exactly -ParameterFilter { $Name -eq 'Preview' -and $Prerelease }
        Should -Invoke Find-PSResource -ModuleName Shmuelie.Utilities -Times 1 -Exactly -ParameterFilter { $Name -eq 'Stable' -and -not $Prerelease }
    }

    It 'reuses comma-separated wildcard filters before repository lookup' {
        foreach ($name in 'Managed.One', 'Managed.Two', 'Managed.Local', 'Other') {
            New-PSResourceProviderTestLayout -Root $script:ResourceRoot -Name $name
        }
        $results = @(Update-AllPackages -Provider PSResourceGet -ProviderOptions @{ PSResourceGet = @{
            Path = $script:ResourceRoot; Name = 'Managed.*,Nothing'; Exclude = '*.Two,*.Local'
        } } -Confirm:$false)
        $results | Should -HaveCount 1
        $results[0].Target | Should -BeExactly (Join-Path $script:ResourceRoot 'Managed.One')
        Should -Invoke Find-PSResource -ModuleName Shmuelie.Utilities -Times 1 -Exactly
    }

    It 'keeps roots distinct but deduplicates equivalent configured paths' {
        $second = Join-Path $TestDrive 'second'
        New-PSResourceProviderTestLayout -Root $script:ResourceRoot -Name ModuleA
        New-PSResourceProviderTestLayout -Root $second -Name ModuleA
        $results = @(Update-AllPackages -Provider PSResourceGet -ProviderOptions @{ PSResourceGet = @{
            Path = @($script:ResourceRoot, (Join-Path $script:ResourceRoot '.'), $second)
        } } -Confirm:$false)
        $results.Target | Should -Be @((Join-Path $script:ResourceRoot 'ModuleA'), (Join-Path $second 'ModuleA'))
        Should -Invoke Save-PSResource -ModuleName Shmuelie.Utilities -Times 2 -Exactly
    }

    It 'does not infer Updated from a void update with no observed change' {
        New-PSResourceProviderTestLayout -Root $script:ResourceRoot -Name ModuleA
        Mock Save-PSResource -ModuleName Shmuelie.Utilities {}
        $result = Update-AllPackages -Provider PSResourceGet -ProviderOptions @{ PSResourceGet = @{ Path = $script:ResourceRoot } } -Confirm:$false
        $result.Status | Should -BeExactly Unchanged
        $result.ResultingVersion | Should -BeExactly '1.0.0'
        $result.Reason | Should -Match 'No newer installed version was observed'
    }

    It 'returns observed Unchanged for an already-current module' {
        New-PSResourceProviderTestLayout -Root $script:ResourceRoot -Name ModuleA -Version '2.0.0'
        $result = Update-AllPackages -Provider PSResourceGet -ProviderOptions @{ PSResourceGet = @{ Path = $script:ResourceRoot } } -Confirm:$false
        $result.Status | Should -BeExactly Unchanged
        $result.ResultingVersion | Should -BeExactly '2.0.0'
        Should -Invoke Save-PSResource -ModuleName Shmuelie.Utilities -Times 0 -Exactly
    }

    It 'preserves canonical lookup warnings and reports the module as skipped' {
        New-PSResourceProviderTestLayout -Root $script:ResourceRoot -Name ModuleA
        Mock Find-PSResource -ModuleName Shmuelie.Utilities { throw 'Repository offline.' }
        $result = Update-AllPackages -Provider PSResourceGet -ProviderOptions @{ PSResourceGet = @{ Path = $script:ResourceRoot } } `
            -Confirm:$false -WarningAction SilentlyContinue -WarningVariable warnings
        $result.Status | Should -BeExactly Skipped
        $result.Reason | Should -Match 'Repository offline'
        $warnings | Should -Not -BeNullOrEmpty
        $result.Error | Should -BeNullOrEmpty
        Should -Invoke Save-PSResource -ModuleName Shmuelie.Utilities -Times 0 -Exactly
    }

    It 'returns Failed with an unknown resulting version when post-update discovery disappears' {
        New-PSResourceProviderTestLayout -Root $script:ResourceRoot -Name ModuleA
        Mock Get-PSResourceGetPackageResource -ModuleName Shmuelie.PackageManagement {}
        Mock Get-PSResourceGetPackageResource -ModuleName Shmuelie.PackageManagement {
            [pscustomobject]@{ Name = 'ModuleA'; Version = '1.0.0' }
        } -ParameterFilter { $PesterBoundParameters.ContainsKey('Exclude') }
        $result = Update-AllPackages -Provider PSResourceGet -ProviderOptions @{ PSResourceGet = @{ Path = $script:ResourceRoot } } -Confirm:$false
        $result.Status | Should -BeExactly Failed
        $result.ResultingVersion | Should -BeNullOrEmpty
        $result.Reason | Should -Match 'outcome is unknown'
    }

    It 'stops between individual modules only when fail-fast is requested: <Stop>' -ForEach @(
        @{ Stop = $true; Expected = @('Failed'); Calls = 1 }
        @{ Stop = $false; Expected = @('Failed', 'Updated'); Calls = 2 }
    ) {
        New-PSResourceProviderTestLayout -Root $script:ResourceRoot -Name AFailure
        New-PSResourceProviderTestLayout -Root $script:ResourceRoot -Name BSuccess
        Mock Save-PSResource -ModuleName Shmuelie.Utilities { throw 'Save failed.' } -ParameterFilter { $Name -eq 'AFailure' }
        $results = @(Update-AllPackages -Provider PSResourceGet -ProviderOptions @{ PSResourceGet = @{ Path = $script:ResourceRoot } } `
            -Confirm:$false -StopOnFailure:$Stop -ErrorAction Stop)
        $results.Status | Should -Be $Expected
        $results[0].Error.Exception.Message | Should -Match 'Save failed'
        $results[0].ResultingVersion | Should -BeNullOrEmpty
        Should -Invoke Save-PSResource -ModuleName Shmuelie.Utilities -Times $Calls -Exactly
    }

    It 'retains a nonterminating canonical error as Failed rather than emitting Unchanged' {
        New-PSResourceProviderTestLayout -Root $script:ResourceRoot -Name ModuleA
        Mock 'Shmuelie.Utilities\Update-InstalledPSResource' -ModuleName Shmuelie.PackageManagement { Write-Error 'Canonical update failed.' }
        $result = Update-AllPackages -Provider PSResourceGet -ProviderOptions @{ PSResourceGet = @{ Path = $script:ResourceRoot } } -Confirm:$false
        $result.Status | Should -BeExactly Failed
        $result.Reason | Should -Match 'Canonical update failed'
    }

    It 'suppresses inner confirmation after aggregate approval' {
        New-PSResourceProviderTestLayout -Root $script:ResourceRoot -Name ModuleA
        Mock 'Shmuelie.Utilities\Update-InstalledPSResource' -ModuleName Shmuelie.PackageManagement {}
        Update-AllPackages -Provider PSResourceGet -ProviderOptions @{ PSResourceGet = @{ Path = $script:ResourceRoot } } -Confirm:$false | Out-Null
        Should -Invoke 'Shmuelie.Utilities\Update-InstalledPSResource' -ModuleName Shmuelie.PackageManagement -Times 1 -Exactly -ParameterFilter {
            $PesterBoundParameters.ContainsKey('Confirm') -and -not $Confirm
        }
    }

    It 'does not treat a warning-only skipped module as a fail-fast failure' {
        New-PSResourceProviderTestLayout -Root $script:ResourceRoot -Name AWarning
        New-PSResourceProviderTestLayout -Root $script:ResourceRoot -Name BSuccess
        Mock Find-PSResource -ModuleName Shmuelie.Utilities { throw 'Feed unavailable.' } -ParameterFilter { $Name -eq 'AWarning' }
        $results = @(Update-AllPackages -Provider PSResourceGet -ProviderOptions @{ PSResourceGet = @{ Path = $script:ResourceRoot } } `
            -StopOnFailure -Confirm:$false -WarningAction SilentlyContinue)
        $results.Status | Should -Be @('Skipped', 'Updated')
        Should -Invoke Save-PSResource -ModuleName Shmuelie.Utilities -Times 1 -Exactly -ParameterFilter { $Name -eq 'BSuccess' }
    }

    It 'returns honest Unchanged when the canonical lookup finds no module' {
        New-PSResourceProviderTestLayout -Root $script:ResourceRoot -Name ModuleA
        Mock Find-PSResource -ModuleName Shmuelie.Utilities {}
        $result = Update-AllPackages -Provider PSResourceGet -ProviderOptions @{ PSResourceGet = @{ Path = $script:ResourceRoot } } -Confirm:$false
        $result.Status | Should -BeExactly Unchanged
        $result.Reason | Should -Match 'silent skips'
        $result.ResultingVersion | Should -BeExactly '1.0.0'
        Should -Invoke Save-PSResource -ModuleName Shmuelie.Utilities -Times 0 -Exactly
    }

    It 'fails rather than calling a lower observed version unchanged' {
        New-PSResourceProviderTestLayout -Root $script:ResourceRoot -Name ModuleA
        Mock Get-PSResourceGetPackageResource -ModuleName Shmuelie.PackageManagement {
            [pscustomobject]@{ Name = 'ModuleA'; Version = '0.5.0'; NumericVersion = [version]'0.5.0'; IsPrerelease = $false }
        }
        Mock Get-PSResourceGetPackageResource -ModuleName Shmuelie.PackageManagement {
            [pscustomobject]@{ Name = 'ModuleA'; Version = '1.0.0'; NumericVersion = [version]'1.0.0'; IsPrerelease = $false }
        } -ParameterFilter { $PesterBoundParameters.ContainsKey('Exclude') }
        $result = Update-AllPackages -Provider PSResourceGet -ProviderOptions @{ PSResourceGet = @{ Path = $script:ResourceRoot } } -Confirm:$false
        $result.Status | Should -BeExactly Failed
        $result.Reason | Should -Match 'decreased'
    }

    It 'performs only local read-only discovery under WhatIf with unknown proposed versions' {
        New-PSResourceProviderTestLayout -Root $script:ResourceRoot -Name ModuleA
        Mock 'Shmuelie.Utilities\Update-InstalledPSResource' -ModuleName Shmuelie.PackageManagement { throw 'WhatIf must not call the mutator.' }
        $results = @(Update-AllPackages -Provider PSResourceGet -ProviderOptions @{ PSResourceGet = @{ Path = $script:ResourceRoot } } -WhatIf)
        $results | Should -HaveCount 1
        $results[0].Status | Should -BeExactly Planned
        $results[0].PreviousVersion | Should -BeExactly '1.0.0'
        $results[0].ResultingVersion | Should -BeNullOrEmpty
        Should -Invoke 'Shmuelie.Utilities\Update-InstalledPSResource' -ModuleName Shmuelie.PackageManagement -Times 0 -Exactly
        Should -Invoke Find-PSResource -ModuleName Shmuelie.Utilities -Times 0 -Exactly
        Should -Invoke Save-PSResource -ModuleName Shmuelie.Utilities -Times 0 -Exactly
        Should -Invoke Get-PSResourceRepository -ModuleName Shmuelie.Utilities -Times 0 -Exactly
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
