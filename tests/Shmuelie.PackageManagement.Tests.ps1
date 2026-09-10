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

    It 'honestly reports unavailable providers in catalog order without importing dependencies' {
        Mock Get-PackageProviderPlatform -ModuleName Shmuelie.PackageManagement { 'Windows' }
        Mock Get-PackageProviderAvailability -ModuleName Shmuelie.PackageManagement {
            [pscustomobject]@{ Available = $false; Reason = 'Unavailable in this test environment.' }
        }
        Mock Import-Module -ModuleName Shmuelie.PackageManagement { throw 'Must not import optional modules.' }
        $results = @(Update-AllPackages)
        $results.Provider | Should -Be @('PSResourceGet', 'DotNet', 'Npm', 'Pip', 'Uv', 'VSCode', 'WinGet', 'AppInstaller')
        foreach ($result in $results) {
            $result.PSTypeNames[0] | Should -BeExactly 'Shmuelie.PackageManagement.UpdateResult'
            $result.Status | Should -BeExactly 'Skipped'
            $result.Reason | Should -BeExactly 'Unavailable in this test environment.'
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

Describe 'DotNet package provider' {
    InModuleScope Shmuelie.PackageManagement {
        BeforeAll {
            $dotnetManifest = Join-Path (Split-Path (Get-Module Shmuelie.PackageManagement).ModuleBase -Parent) 'Shmuelie.DotNet' 'Shmuelie.DotNet.psd1'
            $script:DotNetTestModule = Import-Module $dotnetManifest -PassThru -ErrorAction Stop
            function script:dotnet { throw 'Unexpected SDK operation.' }
            & $script:DotNetTestModule {
                function script:dotnet { throw 'Real .NET tool operations are forbidden in these tests.' }
            }
            function New-TestDotNetTool {
                param([string]$Name = 'example.tool', [AllowNull()][string]$Version = '1.0.0')
                [pscustomobject]@{ PSTypeName = 'DotNetTool'; PackageId = $Name; Version = $Version; Commands = 'example'; Global = $true }
            }
            function New-TestDotNetUpdate {
                param([string]$Name = 'example.tool', [AllowNull()][string]$Version = '2.0.0', [bool]$Updated = $true)
                [pscustomobject]@{ PSTypeName = 'DotNetToolUpdateResult'; PackageId = $Name; Version = $Version; Updated = $Updated }
            }
        }

        AfterAll {
            Remove-Module -ModuleInfo $script:DotNetTestModule -Force -ErrorAction Stop
            Remove-Item Function:\script:dotnet -ErrorAction Stop
        }

        BeforeEach {
            $script:OriginalDotNetExitCode = $global:LASTEXITCODE
            $script:ToolVersion = '1.0.0'
            Mock Get-Module { [pscustomobject]@{ Name = 'Shmuelie.DotNet' } } -ParameterFilter { $Name -eq 'Shmuelie.DotNet' }
            Mock Import-Module { } -ParameterFilter { $Name -eq 'Shmuelie.DotNet' }
            Mock dotnet { '8.0.412 [synthetic SDK]' }
            Mock Shmuelie.DotNet\Get-DotNetTool { New-TestDotNetTool -Version $script:ToolVersion }
            Mock Shmuelie.DotNet\Update-DotNetTool {
                $script:ToolVersion = '2.0.0'
                New-TestDotNetUpdate
            }
        }

        AfterEach {
            $global:LASTEXITCODE = $script:OriginalDotNetExitCode
        }

        It 'keeps the ordered catalog side-effect-free' {
            Mock Get-Module { throw 'Catalog must not discover modules.' }
            Mock Get-Command { throw 'Catalog must not discover commands.' }
            Mock Import-Module { throw 'Catalog must not import modules.' }
            $catalog = @(Get-PackageProvider)
            $catalog.Name | Should -Be @('PSResourceGet', 'DotNet', 'Npm', 'Pip', 'Uv', 'VSCode', 'WinGet', 'AppInstaller')
            $catalog[1].RequiredModules | Should -Be @('Shmuelie.DotNet')
            $catalog[1].OptionNames | Should -Be @('Name')
            $catalog[1].GetTargets | Should -BeOfType ([scriptblock])
            $catalog[1].Update | Should -BeOfType ([scriptblock])
            Should -Invoke dotnet -Times 0 -Exactly
            Should -Invoke Import-Module -Times 0 -Exactly
        }

        It 'skips a missing canonical module without calling native tools' {
            Mock Get-Module { $null } -ParameterFilter { $Name -eq 'Shmuelie.DotNet' }
            Mock Import-Module { throw 'Must not import a missing module.' }
            $result = Update-AllPackages -Provider DotNet
            $result.Status | Should -BeExactly 'Skipped'
            $result.Reason | Should -BeLike '*Install*Shmuelie.DotNet*'
            Should -Invoke dotnet -Times 0 -Exactly
            Should -Invoke Shmuelie.DotNet\Update-DotNetTool -Times 0 -Exactly
        }

        It 'skips missing command <Missing>' -ForEach @(
            @{ Missing = 'dotnet' }
            @{ Missing = 'Shmuelie.DotNet\Get-DotNetTool' }
            @{ Missing = 'Shmuelie.DotNet\Update-DotNetTool' }
        ) {
            Mock Get-Command { $null } -ParameterFilter { $Name -eq $Missing }
            $result = Update-AllPackages -Provider DotNet
            $result.Status | Should -BeExactly 'Skipped'
            $result.Reason | Should -BeLike "*$Missing*"
            Should -Invoke dotnet -Times 0 -Exactly
            Should -Invoke Shmuelie.DotNet\Update-DotNetTool -Times 0 -Exactly
        }

        It 'skips a runtime-only installation without treating it as a failure' {
            Mock dotnet { }
            $result = Update-AllPackages -Provider DotNet -StopOnFailure
            $result.Status | Should -BeExactly 'Skipped'
            $result.Reason | Should -BeLike '*SDK*'
            Should -Invoke Shmuelie.DotNet\Get-DotNetTool -Times 0 -Exactly
        }

        It 'reports SDK probe failures and restores stale caller exit state' {
            $global:LASTEXITCODE = 81
            Mock dotnet { $global:LASTEXITCODE = 3 }
            $result = Update-AllPackages -Provider DotNet
            $result.Status | Should -BeExactly 'Failed'
            $result.Reason | Should -BeLike '*exit code 3*'
            $global:LASTEXITCODE | Should -Be 81
        }

        It 'reports no matching tools as unchanged without invoking update' {
            Mock Shmuelie.DotNet\Get-DotNetTool { }
            $result = Update-AllPackages -Provider DotNet -Confirm:$false
            $result.Status | Should -BeExactly 'Unchanged'
            $result.Target | Should -BeExactly 'DotNet'
            $result.PreviousVersion | Should -BeNullOrEmpty
            $result.ResultingVersion | Should -BeNullOrEmpty
            Should -Invoke Shmuelie.DotNet\Update-DotNetTool -Times 0 -Exactly
        }

        It 'uses the canonical global default and maps observed versions' {
            $global:LASTEXITCODE = 91
            $result = Update-AllPackages -Provider DotNet -Confirm:$false
            $result.PSTypeNames[0] | Should -BeExactly 'Shmuelie.PackageManagement.UpdateResult'
            $result.Provider | Should -BeExactly 'DotNet'
            $result.Target | Should -BeExactly 'example.tool'
            $result.Status | Should -BeExactly 'Updated'
            $result.PreviousVersion | Should -BeExactly '1.0.0'
            $result.ResultingVersion | Should -BeExactly '2.0.0'
            $result.Error | Should -BeNullOrEmpty
            $global:LASTEXITCODE | Should -Be 91
            Should -Invoke Shmuelie.DotNet\Get-DotNetTool -Times 1 -Exactly -ParameterFilter { $Name -eq '*' -and -not $Local }
            Should -Invoke Shmuelie.DotNet\Get-DotNetTool -Times 1 -Exactly -ParameterFilter { $Name -eq 'example.tool' -and -not $Local }
            Should -Invoke Shmuelie.DotNet\Update-DotNetTool -Times 1 -Exactly -ParameterFilter {
                $InputObject.PackageId -eq 'example.tool' -and $InputObject.Global -and $Confirm -eq $false -and $ErrorAction -eq 'Stop'
            }
        }

        It 'maps an already-current tool to unchanged' {
            Mock Shmuelie.DotNet\Update-DotNetTool { New-TestDotNetUpdate -Version '1.0.0' -Updated $false }
            $result = Update-AllPackages -Provider DotNet -Confirm:$false
            $result.Status | Should -BeExactly 'Unchanged'
            $result.ResultingVersion | Should -BeExactly '1.0.0'
        }

        It 'uses observed state instead of localized or inaccurate update version text' {
            Mock Shmuelie.DotNet\Update-DotNetTool {
                $script:ToolVersion = '2.1.0'
                New-TestDotNetUpdate -Version $null -Updated $false
            }
            $result = Update-AllPackages -Provider DotNet -Confirm:$false
            $result.Status | Should -BeExactly 'Updated'
            $result.ResultingVersion | Should -BeExactly '2.1.0'
        }

        It 'keeps unknown versions null when an explicit update was reported' {
            Mock Shmuelie.DotNet\Get-DotNetTool { New-TestDotNetTool -Version $null }
            Mock Shmuelie.DotNet\Update-DotNetTool { New-TestDotNetUpdate -Version 'not-an-observed-version' }
            $result = Update-AllPackages -Provider DotNet -Confirm:$false
            $result.Status | Should -BeExactly 'Updated'
            $result.PreviousVersion | Should -BeNullOrEmpty
            $result.ResultingVersion | Should -BeNullOrEmpty
        }

        It 'fails unknown outcomes instead of assuming unchanged' {
            Mock Shmuelie.DotNet\Get-DotNetTool { New-TestDotNetTool -Version $null }
            Mock Shmuelie.DotNet\Update-DotNetTool { New-TestDotNetUpdate -Version $null -Updated $false }
            $result = Update-AllPackages -Provider DotNet -Confirm:$false
            $result.Status | Should -BeExactly 'Failed'
            $result.Reason | Should -BeLike '*Cannot determine whether*'
        }

        It 'passes the Name option to read-only discovery without changing the input map' {
            $options = '{"dotnet":{"name":"example.*"}}' | ConvertFrom-Json -AsHashtable
            (Update-AllPackages -Provider DotNet -ProviderOptions $options -Confirm:$false).Status | Should -BeExactly 'Updated'
            Should -Invoke Shmuelie.DotNet\Get-DotNetTool -Times 1 -Exactly -ParameterFilter { $Name -eq 'example.*' -and -not $Local }
            $options.dotnet.name | Should -BeExactly 'example.*'
        }

        It 'rejects invalid Name option values before enumerating tools: <Label>' -ForEach @(
            @{ Label = 'null'; Value = $null }
            @{ Label = 'empty'; Value = '' }
            @{ Label = 'whitespace'; Value = ' ' }
            @{ Label = 'array'; Value = @('one', 'two') }
            @{ Label = 'boolean'; Value = $false }
            @{ Label = 'malformed wildcard'; Value = '[a' }
        ) {
            $result = Update-AllPackages -Provider DotNet -ProviderOptions @{ DotNet = @{ Name = $Value } } -Confirm:$false
            $result.Status | Should -BeExactly 'Failed'
            Should -Invoke Shmuelie.DotNet\Get-DotNetTool -Times 0 -Exactly
            Should -Invoke Shmuelie.DotNet\Update-DotNetTool -Times 0 -Exactly
        }

        It 'rejects unsupported option <Option> before any probing' -ForEach @(
            @{ Option = 'Local' }
            @{ Option = 'ManifestPath' }
            @{ Option = 'Version' }
            @{ Option = 'Confirm' }
        ) {
            { Update-AllPackages -Provider DotNet -ProviderOptions @{ DotNet = @{ $Option = 'value' } } } | Should -Throw '*Unknown option*'
            Should -Invoke dotnet -Times 0 -Exactly
        }

        It 'previews installed candidates with unknown proposed versions without updates' {
            $result = Update-AllPackages -Provider DotNet -WhatIf -Confirm:$false
            $result.Status | Should -BeExactly 'Planned'
            $result.PreviousVersion | Should -BeExactly '1.0.0'
            $result.ResultingVersion | Should -BeNullOrEmpty
            Should -Invoke Shmuelie.DotNet\Get-DotNetTool -Times 1 -Exactly
            Should -Invoke Shmuelie.DotNet\Update-DotNetTool -Times 0 -Exactly
        }

        It 'does not probe an excluded DotNet provider' {
            Update-AllPackages -Provider DotNet -ExcludeProvider DotNet -Confirm:$false | Out-Null
            Should -Invoke dotnet -Times 0 -Exactly
            Should -Invoke Shmuelie.DotNet\Get-DotNetTool -Times 0 -Exactly
        }

        It 'retains canonical <Kind> update errors' -ForEach @(
            @{ Kind = 'terminating'; Failure = { throw 'Canonical update failed.' } }
            @{ Kind = 'nonterminating'; Failure = { Write-Error 'Canonical update failed.' } }
        ) {
            $script:DotNetFailure = $Failure
            Mock Shmuelie.DotNet\Update-DotNetTool { & $script:DotNetFailure }
            $result = Update-AllPackages -Provider DotNet -Confirm:$false
            @($result) | Should -HaveCount 1
            $result.Status | Should -BeExactly 'Failed'
            $result.Error | Should -BeOfType ([System.Management.Automation.ErrorRecord])
            $result.Reason | Should -BeLike '*Canonical update failed*'
            $result.ResultingVersion | Should -BeNullOrEmpty
        }

        It 'fails native updates even when the canonical command returns an unchanged-looking result' {
            Mock Shmuelie.DotNet\Update-DotNetTool {
                $global:LASTEXITCODE = 7
                New-TestDotNetUpdate -Version $null -Updated $false
            }
            $result = Update-AllPackages -Provider DotNet -Confirm:$false
            $result.Status | Should -BeExactly 'Failed'
            $result.Reason | Should -BeLike '*exit code 7*'
            Should -Invoke Shmuelie.DotNet\Get-DotNetTool -Times 1 -Exactly
        }

        It 'rejects invalid update output: <Kind>' -ForEach @(
            @{ Kind = 'void'; Output = { } }
            @{ Kind = 'native string'; Output = { 'success' } }
            @{ Kind = 'wrong identity'; Output = { New-TestDotNetUpdate -Name wrong.tool } }
            @{ Kind = 'multiple'; Output = { New-TestDotNetUpdate; New-TestDotNetUpdate } }
            @{ Kind = 'untyped'; Output = { [pscustomobject]@{ PackageId = 'example.tool'; Updated = $true; Version = '2.0.0' } } }
        ) {
            $script:DotNetOutput = $Output
            Mock Shmuelie.DotNet\Update-DotNetTool { & $script:DotNetOutput }
            $result = Update-AllPackages -Provider DotNet -Confirm:$false
            $result.Status | Should -BeExactly 'Failed'
            $result.Reason | Should -BeLike '*invalid update output*'
        }

        It 'fails discovery without updating partial or <Kind> data' -ForEach @(
            @{ Kind = 'local'; Invalid = { $tool = New-TestDotNetTool -Name local.tool; $tool.Global = $false; $tool } }
            @{ Kind = 'unsafe identity'; Invalid = { New-TestDotNetTool -Name 'tool&unexpected' } }
            @{ Kind = 'trailing newline'; Invalid = { New-TestDotNetTool -Name "tool`n" } }
            @{ Kind = 'native string'; Invalid = { 'unexpected native text' } }
        ) {
            $script:InvalidDotNetTool = $Invalid
            Mock Shmuelie.DotNet\Get-DotNetTool {
                New-TestDotNetTool
                & $script:InvalidDotNetTool
            }
            $result = Update-AllPackages -Provider DotNet -Confirm:$false
            $result.Status | Should -BeExactly 'Failed'
            $result.Reason | Should -BeLike '*invalid global tool*'
            Should -Invoke Shmuelie.DotNet\Update-DotNetTool -Times 0 -Exactly
        }

        It 'does not assume success when the post-update tool is missing' {
            Mock Shmuelie.DotNet\Get-DotNetTool {
                if ($Name -eq '*') { New-TestDotNetTool }
            }
            $result = Update-AllPackages -Provider DotNet -Confirm:$false
            $result.Status | Should -BeExactly 'Failed'
            $result.Reason | Should -BeLike '*Cannot observe*'
        }

        It 'honors StopOnFailure=<Stop> between individual tools' -ForEach @(
            @{ Stop = $true; Count = 1; Statuses = @('Failed') }
            @{ Stop = $false; Count = 2; Statuses = @('Failed', 'Updated') }
        ) {
            Mock Shmuelie.DotNet\Get-DotNetTool {
                if ($Name -eq '*') { New-TestDotNetTool; New-TestDotNetTool -Name second.tool }
                else { New-TestDotNetTool -Name second.tool -Version '2.0.0' }
            }
            Mock Shmuelie.DotNet\Update-DotNetTool {
                if ($InputObject.PackageId -eq 'example.tool') { throw 'First failed.' }
                New-TestDotNetUpdate -Name second.tool
            }
            $results = @(Update-AllPackages -Provider DotNet -StopOnFailure:$Stop -Confirm:$false)
            $results.Status | Should -Be $Statuses
            Should -Invoke Shmuelie.DotNet\Update-DotNetTool -Times $Count -Exactly
        }
    }
}

Describe 'DotNet provider canonical command integration' {
    InModuleScope Shmuelie.PackageManagement {
        BeforeAll {
            $script:CanonicalOriginalModulePath = $env:PSModulePath
            $sourceModules = Split-Path (Get-Module Shmuelie.PackageManagement).ModuleBase -Parent
            $env:PSModulePath = $sourceModules + [IO.Path]::PathSeparator + $env:PSModulePath
            $script:CanonicalDotNetModule = Import-Module (Join-Path $sourceModules 'Shmuelie.DotNet' 'Shmuelie.DotNet.psd1') -PassThru -ErrorAction Stop
            & $script:CanonicalDotNetModule { function script:dotnet { throw 'Unexpected native tool operation.' } }
            function script:dotnet { throw 'Unexpected SDK operation.' }
        }

        AfterAll {
            try {
                Remove-Module -ModuleInfo $script:CanonicalDotNetModule -Force -ErrorAction Stop
                Remove-Item Function:\script:dotnet -ErrorAction Stop
            } finally {
                $env:PSModulePath = $script:CanonicalOriginalModulePath
            }
        }

        BeforeEach {
            $script:CanonicalOriginalExitCode = $global:LASTEXITCODE
            $script:CanonicalVersion = '1.0.0'
            $script:NativeCalls = [Collections.Generic.List[string]]::new()
            $script:NativeFailure = $false
            $script:NativeDiscoveryFailure = $false
            $script:NativeUnchanged = $false
            Mock dotnet { '8.0.412 [synthetic SDK]' }
            Mock dotnet -ModuleName Shmuelie.DotNet {
                $arguments = @($args)
                $script:NativeCalls.Add($arguments -join ' ')
                $global:LASTEXITCODE = 0
                if ($arguments[0] -ne 'tool') { throw 'Only tool commands are permitted.' }
                switch ($arguments[1]) {
                    'list' {
                        if (($arguments -join ' ') -ne 'tool list -g') { throw 'Only global listing is permitted.' }
                        if ($script:NativeDiscoveryFailure) {
                            $global:LASTEXITCODE = 2
                            return
                        }
                        'Package Id      Version      Commands'
                        '-------------------------------------'
                        "example.tool    $script:CanonicalVersion    example"
                    }
                    'update' {
                        if (($arguments -join ' ') -ne 'tool update example.tool -g') { throw 'Only the synthetic global tool may be updated.' }
                        if ($script:NativeFailure) {
                            $global:LASTEXITCODE = 7
                            'Unable to update the requested tool.'
                        } elseif ($script:NativeUnchanged) {
                            "Tool 'example.tool' was reinstalled with the stable version (version '1.0.0')."
                        } else {
                            $script:CanonicalVersion = '2.0.0'
                            "Tool 'example.tool' was successfully updated from version '1.0.0' to version '2.0.0'."
                        }
                    }
                    default { throw 'Unexpected dotnet tool operation.' }
                }
            }
        }

        AfterEach {
            $global:LASTEXITCODE = $script:CanonicalOriginalExitCode
        }

        It 'calls only global list/update/list and suppresses canonical confirmation' {
            $ConfirmPreference = 'Low'
            $result = Update-AllPackages -Provider DotNet -Confirm:$false
            $result.Status | Should -BeExactly 'Updated'
            $result.PreviousVersion | Should -BeExactly '1.0.0'
            $result.ResultingVersion | Should -BeExactly '2.0.0'
            $script:NativeCalls | Should -Be @('tool list -g', 'tool update example.tool -g', 'tool list -g')
        }

        It 'maps the canonical reinstall response to unchanged using the installed version' {
            $script:NativeUnchanged = $true
            $result = Update-AllPackages -Provider DotNet -Confirm:$false
            $result.Status | Should -BeExactly 'Unchanged'
            $result.ResultingVersion | Should -BeExactly '1.0.0'
        }

        It 'detects native failure hidden behind the canonical result object' {
            $script:NativeFailure = $true
            $result = Update-AllPackages -Provider DotNet -Confirm:$false
            $result.Status | Should -BeExactly 'Failed'
            $result.Reason | Should -BeLike '*exit code 7*'
            $script:NativeCalls | Should -Be @('tool list -g', 'tool update example.tool -g')
        }

        It 'does not interpret native discovery failure as an empty successful update set' {
            $script:NativeDiscoveryFailure = $true
            $result = Update-AllPackages -Provider DotNet -Confirm:$false
            $result.Status | Should -BeExactly 'Failed'
            $result.Reason | Should -BeLike '*exit code 2*'
            $script:NativeCalls | Should -Be @('tool list -g')
        }

        It 'never reaches the canonical mutating command under WhatIf' {
            $result = Update-AllPackages -Provider DotNet -WhatIf
            $result.Status | Should -BeExactly 'Planned'
            $script:NativeCalls | Should -Be @('tool list -g')
        }
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
            if ([string]::IsNullOrWhiteSpace($TestDrive) -or -not (Test-Path -LiteralPath $TestDrive -PathType Container)) {
                throw 'A valid Pester TestDrive is required for provider fixture setup.'
            }
            $moduleRoot = Join-Path $TestDrive 'provider-modules'
            $moduleDir = Join-Path $moduleRoot 'Fake.PackageProvider'
            New-Item -ItemType Directory -Path $moduleDir -Force -ErrorAction Stop | Out-Null
            @'
function Get-FakePackageName { 'fake-tool' }
function Update-FakePackage { '2.0' }
Export-ModuleMember -Function Get-FakePackageName, Update-FakePackage
'@ | Set-Content -LiteralPath (Join-Path $moduleDir 'Fake.PackageProvider.psm1') -ErrorAction Stop
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

Describe 'Update-AllPackages Pip provider' {
    BeforeAll {
        $script:pipUtilities = Import-Module (Join-Path $repoRoot 'modules' 'Shmuelie.Utilities' 'Shmuelie.Utilities.psd1') -Force -PassThru -ErrorAction Stop
        $script:pipGetCommand = Get-Command Shmuelie.Utilities\Get-PipPackages -ErrorAction Stop
        $script:pipUpdateCommand = Get-Command Shmuelie.Utilities\Update-PipPackage -ErrorAction Stop
        $script:pipHadExitCode = $null -ne (Get-Variable LASTEXITCODE -Scope Global -ErrorAction Ignore)
        $script:pipOriginalExitCode = $global:LASTEXITCODE
        & $script:pipUtilities {
            function script:pip { throw 'Unexpected pip invocation: tests must mock every native operation.' }
        }
    }

    AfterAll {
        if ($script:pipUtilities) {
            & $script:pipUtilities { Remove-Item Function:script:pip -ErrorAction Ignore }
            Remove-Module Shmuelie.Utilities -Force -ErrorAction SilentlyContinue
        }
        if ($script:pipHadExitCode) { $global:LASTEXITCODE = $script:pipOriginalExitCode }
        else { Remove-Variable LASTEXITCODE -Scope Global -ErrorAction Ignore }
    }

    BeforeEach {
        $global:LASTEXITCODE = 0
        Mock Get-PackageProviderPlatform -ModuleName Shmuelie.PackageManagement { 'Windows' }
        Mock Import-Module -ModuleName Shmuelie.PackageManagement {}
        Mock Get-Module -ModuleName Shmuelie.PackageManagement { [pscustomobject]@{ Name = 'Shmuelie.Utilities' } }
        Mock Get-Command -ModuleName Shmuelie.PackageManagement { [pscustomobject]@{ Name = $Name } }
        Mock Shmuelie.Utilities\Get-PipPackages -ModuleName Shmuelie.PackageManagement {
            $global:LASTEXITCODE = 0
            if ($PackageState -eq 'Outdated') {
                [pscustomobject]@{ name = 'requests'; version = '2.31.0'; latest_version = '3.0.0' }
                if (-not $User) { [pscustomobject]@{ name = 'pytest'; version = '8.0.0'; latest_version = '9.0.0' } }
                if (-not $TopLevelOnly) { [pscustomobject]@{ name = 'urllib3'; version = '1.0'; latest_version = '2.0' } }
            } else {
                [pscustomobject]@{ name = 'requests'; version = '2.32.0' }
                [pscustomobject]@{ name = 'pytest'; version = '8.0.0' }
                [pscustomobject]@{ name = 'urllib3'; version = '2.0' }
            }
        }
        Mock Shmuelie.Utilities\Update-PipPackage -ModuleName Shmuelie.PackageManagement {
            $global:LASTEXITCODE = 0
            [pscustomobject]@{ PSTypeName = 'PipUpdateResult'; Name = $PackageName; Success = $true }
        }
    }

    It 'keeps catalog enumeration and completion side-effect-free' {
        $catalog = & (Microsoft.PowerShell.Core\Get-Module Shmuelie.PackageManagement) { @(Get-PackageProvider) }
        $catalog.Name | Should -Be @('PSResourceGet', 'DotNet', 'Npm', 'Pip', 'Uv', 'VSCode', 'WinGet', 'AppInstaller')
        $pip = $catalog | Where-Object Name -EQ Pip
        $pip.RequiredModules | Should -Be @('Shmuelie.Utilities')
        $pip.OptionNames | Should -Be @('User', 'TopLevelOnly')
        $pip.GetTargets | Should -BeOfType ([scriptblock])
        $pip.Update | Should -BeOfType ([scriptblock])
        Should -Invoke Import-Module -ModuleName Shmuelie.PackageManagement -Times 0 -Exactly
        Should -Invoke Get-Command -ModuleName Shmuelie.PackageManagement -Times 0 -Exactly
        Should -Invoke Get-Module -ModuleName Shmuelie.PackageManagement -Times 0 -Exactly
    }

    It 'updates only outdated top-level packages by default and reports observed versions' {
        $results = @(Update-AllPackages -Provider Pip -Confirm:$false)
        $results.Provider | Should -Be @('Pip', 'Pip')
        $results.Target | Should -Be @('requests', 'pytest')
        $results.Status | Should -Be @('Updated', 'Unchanged')
        $results.PreviousVersion | Should -Be @('2.31.0', '8.0.0')
        $results.ResultingVersion | Should -Be @('2.32.0', '8.0.0')
        $results[0].PSTypeNames[0] | Should -BeExactly 'Shmuelie.PackageManagement.UpdateResult'
        Should -Invoke Shmuelie.Utilities\Get-PipPackages -ModuleName Shmuelie.PackageManagement -Times 1 -Exactly -ParameterFilter {
            $PackageState -eq 'Outdated' -and $TopLevelOnly -and -not $User
        }
        Should -Invoke Shmuelie.Utilities\Get-PipPackages -ModuleName Shmuelie.PackageManagement -Times 2 -Exactly -ParameterFilter {
            $PackageState -eq 'Any' -and -not $TopLevelOnly
        }
        Should -Invoke Shmuelie.Utilities\Update-PipPackage -ModuleName Shmuelie.PackageManagement -Times 2 -Exactly -ParameterFilter {
            $Confirm -eq $false -and $ErrorAction -eq 'Stop'
        }
    }

    It 'restricts discovery and observation to user packages without inventing an updater User parameter' {
        $options = @{ pip = @{ user = $true } }
        $result = Update-AllPackages -Provider Pip -ProviderOptions $options -Confirm:$false
        $result.Target | Should -BeExactly 'requests'
        $result.Status | Should -BeExactly 'Updated'
        $options.pip.Count | Should -Be 1
        Should -Invoke Shmuelie.Utilities\Get-PipPackages -ModuleName Shmuelie.PackageManagement -Times 2 -Exactly -ParameterFilter { $User }
        Should -Invoke Shmuelie.Utilities\Update-PipPackage -ModuleName Shmuelie.PackageManagement -Times 1 -Exactly -ParameterFilter { $PackageName -eq 'requests' }
    }

    It 'allows explicit transitive-package selection' {
        $results = @(Update-AllPackages -Provider Pip -ProviderOptions @{ Pip = @{ TopLevelOnly = $false } } -WhatIf)
        $results.Target | Should -Be @('requests', 'pytest', 'urllib3')
        $results.Status | Should -Be @('Planned', 'Planned', 'Planned')
    }

    It 'supports Boolean SwitchParameter values' {
        $results = @(Update-AllPackages -Provider Pip -ProviderOptions @{ Pip = @{
            User = [switch]$true; TopLevelOnly = [switch]$false
        } } -WhatIf)
        $results.Target | Should -Be @('requests', 'urllib3')
    }

    It 'returns planned targets without updates or observation under WhatIf' {
        $results = @(Update-AllPackages -Provider Pip -WhatIf)
        $results.Status | Should -Be @('Planned', 'Planned')
        $results.ResultingVersion | Should -Be @('3.0.0', '9.0.0')
        Should -Invoke Shmuelie.Utilities\Update-PipPackage -ModuleName Shmuelie.PackageManagement -Times 0 -Exactly
        Should -Invoke Shmuelie.Utilities\Get-PipPackages -ModuleName Shmuelie.PackageManagement -Times 1 -Exactly
    }

    It 'skips when <Missing> is unavailable' -ForEach @(
        @{ Missing = 'pip' }
        @{ Missing = 'Shmuelie.Utilities\Get-PipPackages' }
        @{ Missing = 'Shmuelie.Utilities\Update-PipPackage' }
    ) {
        Mock Get-Command -ModuleName Shmuelie.PackageManagement { $null } -ParameterFilter { $Name -eq $Missing }
        $result = Update-AllPackages -Provider Pip -Confirm:$false
        $result.Status | Should -BeExactly 'Skipped'
        $result.Reason | Should -Match ([regex]::Escape($Missing))
        Should -Invoke Shmuelie.Utilities\Get-PipPackages -ModuleName Shmuelie.PackageManagement -Times 0 -Exactly
        Should -Invoke Shmuelie.Utilities\Update-PipPackage -ModuleName Shmuelie.PackageManagement -Times 0 -Exactly
    }

    It 'skips missing optional modules without importing or installing them' {
        Mock Get-Module -ModuleName Shmuelie.PackageManagement { $null }
        $result = Update-AllPackages -Provider Pip -Confirm:$false
        $result.Status | Should -BeExactly 'Skipped'
        $result.Reason | Should -Match 'Shmuelie.Utilities'
        Should -Invoke Import-Module -ModuleName Shmuelie.PackageManagement -Times 0 -Exactly
    }

    It 'does not discover excluded Pip dependencies' {
        Update-AllPackages -Provider Pip -ExcludeProvider Pip -Confirm:$false | Should -BeNullOrEmpty
        Should -Invoke Get-Command -ModuleName Shmuelie.PackageManagement -Times 0 -Exactly
        Should -Invoke Import-Module -ModuleName Shmuelie.PackageManagement -Times 0 -Exactly
    }

    It 'rejects invalid option value <Label> before reading packages' -ForEach @(
        @{ Label = 'string false'; Options = @{ User = 'false' } }
        @{ Label = 'numeric'; Options = @{ TopLevelOnly = 0 } }
        @{ Label = 'null'; Options = @{ User = $null } }
        @{ Label = 'script'; Options = @{ TopLevelOnly = { throw 'Never execute options.' } } }
        @{ Label = 'array'; Options = @{ User = @($true, $false) } }
    ) {
        $result = Update-AllPackages -Provider Pip -ProviderOptions @{ Pip = $Options } -WhatIf
        $result.Status | Should -BeExactly 'Failed'
        $result.Reason | Should -Match 'Boolean'
        Should -Invoke Shmuelie.Utilities\Get-PipPackages -ModuleName Shmuelie.PackageManagement -Times 0 -Exactly
    }

    It 'rejects unsupported <Option> options before provider discovery' -ForEach @(
        @{ Option = 'Confirm' }; @{ Option = 'PackageState' }; @{ Option = 'Arguments' }; @{ Option = 'PythonPath' }
    ) {
        { Update-AllPackages -Provider Pip -ProviderOptions @{ Pip = @{ $Option = 'value' } } -WhatIf } | Should -Throw '*Unknown option*'
        Should -Invoke Import-Module -ModuleName Shmuelie.PackageManagement -Times 0 -Exactly
    }

    It 'rejects unsafe distribution name <Name> before any mutation' -ForEach @(
        @{ Name = '--target' }; @{ Name = 'name&command' }; @{ Name = 'a|b' }; @{ Name = 'a;command' }
        @{ Name = 'name==1' }; @{ Name = 'name[extra]' }; @{ Name = 'https://example.org/a.whl' }
        @{ Name = 'two words' }; @{ Name = 'name%PATH%' }; @{ Name = 'name$(command)' }
        @{ Name = "name`n" }; @{ Name = '../name' }; @{ Name = '' }; @{ Name = $null }
    ) {
        Mock Shmuelie.Utilities\Get-PipPackages -ModuleName Shmuelie.PackageManagement {
            [pscustomobject]@{ name = 'valid'; version = '1'; latest_version = '2' }
            [pscustomobject]@{ name = $Name; version = '1'; latest_version = '2' }
        }
        $result = Update-AllPackages -Provider Pip -Confirm:$false
        $result.Status | Should -BeExactly 'Failed'
        $result.Reason | Should -Match 'invalid package name'
        Should -Invoke Shmuelie.Utilities\Update-PipPackage -ModuleName Shmuelie.PackageManagement -Times 0 -Exactly
    }

    It 'matches normalized names but preserves the original target identifier' {
        Mock Shmuelie.Utilities\Get-PipPackages -ModuleName Shmuelie.PackageManagement {
            if ($PackageState -eq 'Outdated') { [pscustomobject]@{ name = 'Example_Package.Name'; version = '1'; latest_version = '3' } }
            else { [pscustomobject]@{ name = 'example-package-name'; version = '2' } }
        }
        $result = Update-AllPackages -Provider Pip -Confirm:$false
        $result.Target | Should -BeExactly 'Example_Package.Name'
        $result.ResultingVersion | Should -BeExactly '2'
    }

    It 'rejects duplicate normalized discovery names before updates' {
        Mock Shmuelie.Utilities\Get-PipPackages -ModuleName Shmuelie.PackageManagement {
            [pscustomobject]@{ name = 'example_package'; version = '1' }
            [pscustomobject]@{ name = 'example-package'; version = '1' }
        }
        (Update-AllPackages -Provider Pip -Confirm:$false).Reason | Should -Match 'duplicate'
        Should -Invoke Shmuelie.Utilities\Update-PipPackage -ModuleName Shmuelie.PackageManagement -Times 0 -Exactly
    }

    It 'preserves unknown discovery versions under WhatIf' {
        Mock Shmuelie.Utilities\Get-PipPackages -ModuleName Shmuelie.PackageManagement { [pscustomobject]@{ name = 'requests' } }
        $result = Update-AllPackages -Provider Pip -WhatIf
        $result.Status | Should -BeExactly 'Planned'
        $result.PreviousVersion | Should -BeNullOrEmpty
        $result.ResultingVersion | Should -BeNullOrEmpty
    }

    It 'reports an empty discovery set as unchanged' {
        Mock Shmuelie.Utilities\Get-PipPackages -ModuleName Shmuelie.PackageManagement {}
        $result = Update-AllPackages -Provider Pip -Confirm:$false
        $result.Status | Should -BeExactly 'Unchanged'
        $result.Target | Should -BeExactly 'Pip'
        Should -Invoke Shmuelie.Utilities\Update-PipPackage -ModuleName Shmuelie.PackageManagement -Times 0 -Exactly
    }

    It 'fails discovery on a native nonzero exit even with valid output' {
        Mock Shmuelie.Utilities\Get-PipPackages -ModuleName Shmuelie.PackageManagement {
            $global:LASTEXITCODE = 23
            [pscustomobject]@{ name = 'requests'; version = '1' }
        }
        $result = Update-AllPackages -Provider Pip -Confirm:$false
        $result.Status | Should -BeExactly 'Failed'
        $result.Reason | Should -Match 'exit code 23'
        Should -Invoke Shmuelie.Utilities\Update-PipPackage -ModuleName Shmuelie.PackageManagement -Times 0 -Exactly
    }

    It 'preserves warnings and original errors, with StopOnFailure <Stop>' -ForEach @(
        @{ Stop = $false; Count = 2 }; @{ Stop = $true; Count = 1 }
    ) {
        $script:pipExpectedError = [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new('Package update failed.'), 'PipTestFailure',
            [System.Management.Automation.ErrorCategory]::InvalidOperation, 'requests')
        Mock Shmuelie.Utilities\Update-PipPackage -ModuleName Shmuelie.PackageManagement {
            Write-Warning 'Preserved pip warning.'
            Write-Error -ErrorRecord $script:pipExpectedError
        } -ParameterFilter { $PackageName -eq 'requests' }
        $records = @(Update-AllPackages -Provider Pip -StopOnFailure:$Stop -Confirm:$false -ErrorAction Stop 3>&1)
        $warnings = @($records | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
        $results = @($records | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })
        $results | Should -HaveCount $Count
        $results[0].Status | Should -BeExactly 'Failed'
        $results[0].Error.FullyQualifiedErrorId | Should -Match 'PipTestFailure'
        $results[0].Error.Exception.Message | Should -BeExactly 'Package update failed.'
        $warnings.Message | Should -Contain 'Preserved pip warning.'
        if (-not $Stop) { $results[1].Status | Should -BeExactly 'Unchanged' }
        Should -Invoke Shmuelie.Utilities\Update-PipPackage -ModuleName Shmuelie.PackageManagement -Times $Count -Exactly
    }

    It 'does not fabricate success for <Label>' -ForEach @(
        @{ Label = 'empty updater output'; Callback = {} }
        @{ Label = 'untyped updater output'; Callback = { [pscustomobject]@{ Name = 'requests'; Success = $true } } }
        @{ Label = 'failure result'; Callback = { [pscustomobject]@{ PSTypeName = 'PipUpdateResult'; Name = 'requests'; Success = $false } } }
        @{ Label = 'wrong target'; Callback = { [pscustomobject]@{ PSTypeName = 'PipUpdateResult'; Name = 'wrong'; Success = $true } } }
        @{ Label = 'non-Boolean success'; Callback = { [pscustomobject]@{ PSTypeName = 'PipUpdateResult'; Name = 'requests'; Success = 'false' } } }
        @{ Label = 'native nonzero'; Callback = { $global:LASTEXITCODE = 17; [pscustomobject]@{ PSTypeName = 'PipUpdateResult'; Name = 'requests'; Success = $true } } }
    ) {
        Mock Shmuelie.Utilities\Update-PipPackage -ModuleName Shmuelie.PackageManagement { & $Callback }
        $result = Update-AllPackages -Provider Pip -StopOnFailure -Confirm:$false
        $result.Status | Should -BeExactly 'Failed'
        $result.ResultingVersion | Should -BeNullOrEmpty
        $result.Error | Should -BeOfType ([System.Management.Automation.ErrorRecord])
        Should -Invoke Shmuelie.Utilities\Get-PipPackages -ModuleName Shmuelie.PackageManagement -Times 1 -Exactly
    }

    It 'fails rather than presenting the proposal as observed when observation <Label>' -ForEach @(
        @{ Label = 'returns no package'; Callback = {} }
        @{ Label = 'returns unknown version'; Callback = { [pscustomobject]@{ name = 'requests' } } }
        @{ Label = 'fails natively'; Callback = { $global:LASTEXITCODE = 19 } }
        @{ Label = 'throws'; Callback = { throw 'Observation failed.' } }
    ) {
        Mock Shmuelie.Utilities\Get-PipPackages -ModuleName Shmuelie.PackageManagement { & $Callback } -ParameterFilter { $PackageState -eq 'Any' }
        $result = Update-AllPackages -Provider Pip -StopOnFailure -Confirm:$false
        $result.Status | Should -BeExactly 'Failed'
        $result.ResultingVersion | Should -BeNullOrEmpty
    }

    Context 'Canonical Utilities commands with mocked native pip' {
        BeforeEach {
            $script:pipNativeCalls = [System.Collections.Generic.List[string]]::new()
            Mock Shmuelie.Utilities\Get-PipPackages -ModuleName Shmuelie.PackageManagement {
                & $script:pipGetCommand -User:$User -TopLevelOnly:$TopLevelOnly -PackageState $PackageState -ErrorAction Stop
            }
            Mock Shmuelie.Utilities\Update-PipPackage -ModuleName Shmuelie.PackageManagement {
                & $script:pipUpdateCommand -PackageName $PackageName -Confirm:$false -ErrorAction Stop -Verbose
            }
            Mock pip -ModuleName Shmuelie.Utilities {
                $script:pipNativeCalls.Add($args -join '|')
                $global:LASTEXITCODE = 0
                if ($args[0] -eq 'list') {
                    if ($args -contains '--outdated') { '[{"name":"requests","version":"1","latest_version":"3"}]' }
                    else { '[{"name":"requests","version":"2"}]' }
                } else { 'Successfully installed requests-2' }
            }
        }

        It 'uses only supported native flags and never passes the proposed version or a user-install switch' {
            $result = Update-AllPackages -Provider Pip -ProviderOptions @{ Pip = @{ User = $true } } -Confirm:$false
            $result.Status | Should -BeExactly 'Updated'
            $result.ResultingVersion | Should -BeExactly '2'
            $script:pipNativeCalls | Should -Be @(
                'list|--format|json|--disable-pip-version-check|--user|--not-required|--outdated'
                'install|--upgrade|requests'
                'list|--format|json|--disable-pip-version-check|--user'
            )
        }

        It 'retains native failure diagnostics from the public updater verbose stream' {
            Mock pip -ModuleName Shmuelie.Utilities {
                $global:LASTEXITCODE = 12
                'Installer failure diagnostic.'
            } -ParameterFilter { $args[0] -eq 'install' }
            $result = Update-AllPackages -Provider Pip -Confirm:$false
            $result.Status | Should -BeExactly 'Failed'
            $result.Reason | Should -Match 'exit code 12'
            $result.Reason | Should -Match 'Installer failure diagnostic'
            Should -Invoke pip -ModuleName Shmuelie.Utilities -Times 1 -Exactly -ParameterFilter { $args[0] -eq 'list' }
        }

        It 'preserves redirected native errors rather than reducing them to Boolean failure' {
            Mock pip -ModuleName Shmuelie.Utilities {
                Write-Error 'Native package error.' -ErrorId 'NativePipTestError'
            } -ParameterFilter { $args[0] -eq 'install' }
            $result = Update-AllPackages -Provider Pip -Confirm:$false
            $result.Status | Should -BeExactly 'Failed'
            $result.Error.FullyQualifiedErrorId | Should -Match 'NativePipTestError'
            $result.Error.Exception.Message | Should -BeExactly 'Native package error.'
        }

        It 'performs native read-only discovery only under WhatIf' {
            (Update-AllPackages -Provider Pip -WhatIf).Status | Should -BeExactly 'Planned'
            $script:pipNativeCalls | Should -HaveCount 1
            Should -Invoke pip -ModuleName Shmuelie.Utilities -Times 0 -Exactly -ParameterFilter { $args[0] -eq 'install' }
        }
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
