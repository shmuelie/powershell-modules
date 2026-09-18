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

Describe 'SavePSResource' -Tag 'SavedModulePresence' {
    BeforeAll {
        $script:savedModuleFixtures = [System.Collections.Generic.List[string]]::new()

        function New-SavedModuleFixture {
            param(
                [string]$Root = $script:savedModuleRoot,
                [string]$Name = 'ExampleModule',
                [string]$DirectoryVersion = '',
                [string]$ManifestName = 'ExampleModule',
                [AllowNull()][string]$Manifest = "@{ ModuleVersion = '1.0.0' }",
                [hashtable]$Files = @{}
            )
            $directory = Join-Path $Root $Name
            if ($DirectoryVersion) { $directory = Join-Path $directory $DirectoryVersion }
            $null = [System.IO.Directory]::CreateDirectory($directory)
            if ($null -ne $Manifest) {
                Set-Content -LiteralPath (Join-Path $directory "$ManifestName.psd1") -Value $Manifest
            }
            foreach ($file in $Files.Keys) {
                $path = Join-Path $directory $file
                $null = [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($path))
                Set-Content -LiteralPath $path -Value $Files[$file]
            }
            return $directory
        }

        function Assert-SavedModuleState {
            param(
                [bool]$Expected,
                [string]$Root = $script:savedModuleRoot,
                [string]$Name = 'ExampleModule',
                [string]$Version = ''
            )
            InModuleScope Shmuelie.Dsc -Parameters @{ Root = $Root; Name = $Name; Version = $Version; Expected = $Expected } {
                param($Root, $Name, $Version, $Expected)
                $resource = [SavePSResource]@{ Name = $Name; Path = $Root; Version = $Version; Repository = 'FixtureRepository' }
                $resource.Test() | Should -Be $Expected
                $state = $resource.Get()
                $state.Installed | Should -Be $Expected
                $state.Name | Should -BeExactly $Name
                $state.Path | Should -BeExactly $Root
                $state.Version | Should -BeExactly $Version
                $state.Repository | Should -BeExactly 'FixtureRepository'
            }
        }
    }

    BeforeEach {
        $script:savedModuleCase = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:savedModuleRoot = Join-Path $script:savedModuleCase 'modules-[ab]'
        $script:savedModuleFixtures.Add($script:savedModuleCase)
        $null = [System.IO.Directory]::CreateDirectory($script:savedModuleRoot)
        Mock -ModuleName Shmuelie.Dsc Save-PSResource { throw 'Unexpected real save.' }
        Mock -ModuleName Shmuelie.Dsc Find-PSResource { throw 'Unexpected repository lookup.' }
        Mock -ModuleName Shmuelie.Dsc Import-Module { throw 'Candidate module import is forbidden.' }
        Mock -ModuleName Shmuelie.Dsc Test-ModuleManifest { throw 'Framework dependency discovery is forbidden.' }
    }

    AfterEach {
        Should -Invoke -ModuleName Shmuelie.Dsc Find-PSResource -Times 0 -Exactly
        Should -Invoke -ModuleName Shmuelie.Dsc Import-Module -Times 0 -Exactly
        Should -Invoke -ModuleName Shmuelie.Dsc Test-ModuleManifest -Times 0 -Exactly
    }

    AfterAll {
        foreach ($directory in $script:savedModuleFixtures) {
            Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction Stop
            Test-Path -LiteralPath $directory | Should -BeFalse
        }
    }

    It 'rejects the incomplete layout: <Case>' -ForEach @(
        @{ Case = 'missing module'; Kind = 'Missing'; Version = '' }
        @{ Case = 'empty parent'; Kind = 'Empty'; Version = '' }
        @{ Case = 'empty version unpinned'; Kind = 'Empty'; Version = ''; DirectoryVersion = '1.0.0' }
        @{ Case = 'empty requested version'; Kind = 'Empty'; Version = '1.0.0'; DirectoryVersion = '1.0.0' }
        @{ Case = 'module is a file'; Kind = 'ModuleFile'; Version = '' }
        @{ Case = 'version is a file'; Kind = 'VersionFile'; Version = '1.0.0' }
        @{ Case = 'manifest is a directory'; Kind = 'ManifestDirectory'; Version = '' }
        @{ Case = 'wrong manifest name'; Kind = 'WrongName'; Version = '' }
    ) {
        $moduleDirectory = Join-Path $script:savedModuleRoot 'ExampleModule'
        switch ($Kind) {
            Missing { }
            Empty {
                $directory = if ($DirectoryVersion) { Join-Path $moduleDirectory $DirectoryVersion } else { $moduleDirectory }
                $null = [System.IO.Directory]::CreateDirectory($directory)
            }
            ModuleFile { Set-Content -LiteralPath $moduleDirectory -Value 'not a directory' }
            VersionFile {
                $null = [System.IO.Directory]::CreateDirectory($moduleDirectory)
                Set-Content -LiteralPath (Join-Path $moduleDirectory '1.0.0') -Value 'not a directory'
            }
            ManifestDirectory { $null = [System.IO.Directory]::CreateDirectory((Join-Path $moduleDirectory 'ExampleModule.psd1')) }
            WrongName { $null = New-SavedModuleFixture -ManifestName OtherModule }
        }
        Assert-SavedModuleState -Expected $false -Version $Version
        Should -Invoke -ModuleName Shmuelie.Dsc Save-PSResource -Times 0 -Exactly
    }

    It 'rejects invalid manifest or entry data: <Case>' -ForEach @(
        @{ Case = 'empty manifest'; Manifest = '' }
        @{ Case = 'malformed manifest'; Manifest = '@{ ModuleVersion =' }
        @{ Case = 'not a hashtable'; Manifest = "'not a manifest'" }
        @{ Case = 'missing module version'; Manifest = '@{}' }
        @{ Case = 'invalid module version'; Manifest = "@{ ModuleVersion = 'invalid' }" }
        @{ Case = 'array module version'; Manifest = "@{ ModuleVersion = @('1.0.0') }" }
        @{ Case = 'missing root script'; Manifest = "@{ ModuleVersion = '1.0.0'; RootModule = 'missing.psm1' }" }
        @{ Case = 'missing root binary'; Manifest = "@{ ModuleVersion = '1.0.0'; RootModule = 'missing.dll' }" }
        @{ Case = 'root is a directory'; Manifest = "@{ ModuleVersion = '1.0.0'; RootModule = 'directory.psm1' }"; RootDirectory = 'directory.psm1' }
        @{ Case = 'unsupported root extension'; Manifest = "@{ ModuleVersion = '1.0.0'; RootModule = 'entry.txt' }" }
        @{ Case = 'array root'; Manifest = "@{ ModuleVersion = '1.0.0'; RootModule = @('entry.psm1') }" }
        @{ Case = 'boolean root'; Manifest = "@{ ModuleVersion = '1.0.0'; RootModule = `$false }" }
        @{ Case = 'missing startup script'; Manifest = "@{ ModuleVersion = '1.0.0'; ScriptsToProcess = @('missing.ps1') }" }
        @{ Case = 'missing type file'; Manifest = "@{ ModuleVersion = '1.0.0'; TypesToProcess = @('missing.ps1xml') }" }
        @{ Case = 'missing format file'; Manifest = "@{ ModuleVersion = '1.0.0'; FormatsToProcess = @('missing.ps1xml') }" }
        @{ Case = 'invalid startup entry'; Manifest = "@{ ModuleVersion = '1.0.0'; ScriptsToProcess = @(@{ Path = 'entry.ps1' }) }" }
        @{ Case = 'missing local nested script'; Manifest = "@{ ModuleVersion = '1.0.0'; NestedModules = @('missing.psm1') }" }
        @{ Case = 'missing local nested manifest'; Manifest = "@{ ModuleVersion = '1.0.0'; NestedModules = @(@{ ModuleName = 'missing.psd1'; ModuleVersion = '1.0.0' }) }" }
        @{ Case = 'missing local assembly'; Manifest = "@{ ModuleVersion = '1.0.0'; RequiredAssemblies = @('missing.dll') }" }
        @{ Case = 'invalid nested module specification'; Manifest = "@{ ModuleVersion = '1.0.0'; NestedModules = @(@{ Version = '1.0.0' }) }" }
    ) {
        $directory = New-SavedModuleFixture -Manifest $Manifest -Files @{ 'entry.txt' = 'fixture'; 'entry.psm1' = 'throw "never import me"' }
        if ($RootDirectory) { $null = [System.IO.Directory]::CreateDirectory((Join-Path $directory $RootDirectory)) }
        Assert-SavedModuleState -Expected $false
    }

    It 'accepts the valid saved layout: <Case>' -ForEach @(
        @{ Case = 'flat data manifest'; Manifest = "@{ ModuleVersion = '1.0.0' }"; Files = @{}; DirectoryVersion = ''; Version = '' }
        @{ Case = 'empty root data manifest'; Manifest = "@{ ModuleVersion = '1.0.0'; RootModule = '' }"; Files = @{}; DirectoryVersion = ''; Version = '' }
        @{ Case = 'unversioned script'; Manifest = "@{ ModuleVersion = '1.0.0'; RootModule = 'entry.psm1' }"; Files = @{ 'entry.psm1' = 'throw "never import me"' }; DirectoryVersion = ''; Version = '' }
        @{ Case = 'unversioned binary'; Manifest = "@{ ModuleVersion = '1.0.0'; RootModule = 'entry.dll' }"; Files = @{ 'entry.dll' = 'inert binary fixture' }; DirectoryVersion = ''; Version = '' }
        @{ Case = 'extensionless script'; Manifest = "@{ ModuleVersion = '1.0.0'; RootModule = 'entry' }"; Files = @{ 'entry.psm1' = 'throw "never import me"' }; DirectoryVersion = ''; Version = '' }
        @{ Case = 'extensionless binary'; Manifest = "@{ ModuleVersion = '1.0.0'; RootModule = 'entry' }"; Files = @{ 'entry.dll' = 'inert binary fixture' }; DirectoryVersion = ''; Version = '' }
        @{ Case = 'legacy ModuleToProcess'; Manifest = "@{ ModuleVersion = '1.0.0'; ModuleToProcess = 'entry.psm1' }"; Files = @{ 'entry.psm1' = 'throw "never import me"' }; DirectoryVersion = ''; Version = '' }
        @{ Case = 'versioned data unpinned'; Manifest = "@{ ModuleVersion = '1.0.0' }"; Files = @{}; DirectoryVersion = '1.0.0'; Version = '' }
        @{ Case = 'versioned script pinned'; Manifest = "@{ ModuleVersion = '1.0.0'; RootModule = 'entry.psm1' }"; Files = @{ 'entry.psm1' = 'throw "never import me"' }; DirectoryVersion = '1.0.0'; Version = '1.0.0' }
        @{ Case = 'versioned binary pinned'; Manifest = "@{ ModuleVersion = '1.0.0'; RootModule = 'entry.dll' }"; Files = @{ 'entry.dll' = 'inert binary fixture' }; DirectoryVersion = '1.0.0'; Version = '1.0.0' }
        @{ Case = 'local startup files'; Manifest = "@{ ModuleVersion = '1.0.0'; ScriptsToProcess = @('entry.ps1'); TypesToProcess = @('types.ps1xml'); FormatsToProcess = @('format.ps1xml') }"; Files = @{ 'entry.ps1' = 'throw "never execute me"'; 'types.ps1xml' = 'fixture'; 'format.ps1xml' = 'fixture' }; DirectoryVersion = '1.0.0'; Version = '' }
        @{ Case = 'local nested script'; Manifest = "@{ ModuleVersion = '1.0.0'; NestedModules = @('entry.psm1') }"; Files = @{ 'entry.psm1' = 'throw "never import me"' }; DirectoryVersion = '1.0.0'; Version = '' }
        @{ Case = 'local nested manifest'; Manifest = "@{ ModuleVersion = '1.0.0'; NestedModules = @(@{ ModuleName = 'inner.psd1'; ModuleVersion = '1.0.0' }) }"; Files = @{ 'inner.psd1' = "@{ ModuleVersion = '1.0.0' }" }; DirectoryVersion = '1.0.0'; Version = '' }
        @{ Case = 'local assembly'; Manifest = "@{ ModuleVersion = '1.0.0'; RequiredAssemblies = @('entry.dll') }"; Files = @{ 'entry.dll' = 'inert binary fixture' }; DirectoryVersion = '1.0.0'; Version = '' }
        @{ Case = 'unresolved dependencies do not imply absence'; Manifest = "@{ ModuleVersion = '1.0.0'; RequiredModules = @('Issue258MissingDependency'); RequiredAssemblies = @('Issue258MissingAssembly'); NestedModules = @(@{ ModuleName = 'Issue258MissingNestedDependency'; ModuleVersion = '1.0.0' }) }"; Files = @{}; DirectoryVersion = '1.0.0'; Version = '' }
    ) {
        $null = New-SavedModuleFixture -Manifest $Manifest -Files $Files -DirectoryVersion $DirectoryVersion
        $before = @(Get-ChildItem -LiteralPath $script:savedModuleRoot -Recurse -File | ForEach-Object { Get-FileHash -LiteralPath $_.FullName })
        Assert-SavedModuleState -Expected $true -Version $Version
        foreach ($file in $before) { (Get-FileHash -LiteralPath $file.Path).Hash | Should -Be $file.Hash }
        @(Get-ChildItem -LiteralPath $script:savedModuleRoot -Recurse -File).Count | Should -Be $before.Count
        Should -Invoke -ModuleName Shmuelie.Dsc Save-PSResource -Times 0 -Exactly
    }

    It 'requires the directory version to match the manifest when pinned = <Pinned>' -ForEach @(
        @{ Pinned = $false }
        @{ Pinned = $true }
    ) {
        $null = New-SavedModuleFixture -DirectoryVersion '2.0.0'
        $version = if ($Pinned) { '2.0.0' } else { '' }
        Assert-SavedModuleState -Expected $false -Version $version
    }

    It 'compares numeric metadata <Value> with directory <DirectoryVersion> as <Expected>' -ForEach @(
        @{ Value = "'1.0'"; DirectoryVersion = '1.0.0'; Expected = $true }
        @{ Value = "'1.0.0.0'"; DirectoryVersion = '1.0.0'; Expected = $true }
        @{ Value = "'1.0.0'"; DirectoryVersion = '1.0'; Expected = $true }
        @{ Value = "'1.0.0'"; DirectoryVersion = '1.0.0.0'; Expected = $true }
        @{ Value = "'1.0.1'"; DirectoryVersion = '1.0.0'; Expected = $false }
        @{ Value = "'1.0.0.1'"; DirectoryVersion = '1.0.0'; Expected = $false }
        @{ Value = "'1.0.0'"; DirectoryVersion = '1.0.0.1'; Expected = $false }
        @{ Value = "[version]'1.0'"; DirectoryVersion = '1.0.0'; Expected = $false }
        @{ Value = "[System.Version]'1.0.0.0'"; DirectoryVersion = '1.0.0'; Expected = $false }
        @{ Value = "[version]('1.0.0')"; DirectoryVersion = '1.0.0'; Expected = $false }
        @{ Value = "[version]'invalid'"; DirectoryVersion = '1.0.0'; Expected = $false }
    ) {
        $null = New-SavedModuleFixture -DirectoryVersion $DirectoryVersion -Manifest "@{ ModuleVersion = $Value }"
        Assert-SavedModuleState -Expected $Expected -Version $DirectoryVersion
        Assert-SavedModuleState -Expected $Expected
    }

    It 'does not broaden exact folder selection when numeric metadata is equivalent' {
        $null = New-SavedModuleFixture -DirectoryVersion '1.0.0' -Manifest "@{ ModuleVersion = '1.0' }"
        Assert-SavedModuleState -Expected $true -Version '1.0.0'
        Assert-SavedModuleState -Expected $false -Version '1.0'
        Assert-SavedModuleState -Expected $false -Version '1.0.0.0'
    }

    It 'never executes dynamic code in version-related manifest expressions' -ForEach @(
        @{ Field = 'ModuleVersion' }
        @{ Field = 'Description' }
    ) {
        $marker = Join-Path $script:savedModuleCase 'executed.txt'
        $code = "Set-Content -LiteralPath '$($marker.Replace("'", "''"))' -Value executed"
        $manifest = if ($Field -eq 'ModuleVersion') {
            "@{ ModuleVersion = [version]($code) }"
        } else {
            "@{ ModuleVersion = [version]'1.0.0'; Description = ($code) }"
        }
        $null = New-SavedModuleFixture -Manifest $manifest
        Assert-SavedModuleState -Expected $false
        Test-Path -LiteralPath $marker | Should -BeFalse
    }

    It 'finds one valid saved version among incomplete siblings without relaxing exact selection' {
        $null = New-SavedModuleFixture -DirectoryVersion '1.0.0' -Manifest ''
        $null = New-SavedModuleFixture -DirectoryVersion '2.0.0' -Manifest "@{ ModuleVersion = '2.0.0' }"
        Assert-SavedModuleState -Expected $true
        Assert-SavedModuleState -Expected $false -Version '1.0.0'
        Assert-SavedModuleState -Expected $true -Version '2.0.0'
        Assert-SavedModuleState -Expected $false -Version '3.0.0'
    }

    It 'does not use a flat manifest or arbitrary subfolder as an exact version match' {
        $null = New-SavedModuleFixture
        $null = New-SavedModuleFixture -DirectoryVersion 'backup'
        Assert-SavedModuleState -Expected $false -Version '1.0.0'
        Remove-Item -LiteralPath (Join-Path $script:savedModuleRoot 'ExampleModule' 'ExampleModule.psd1')
        Assert-SavedModuleState -Expected $false
    }

    It 'treats module names and entry files literally' {
        $null = New-SavedModuleFixture -Name 'Example[ab]' -ManifestName 'Example[ab]' -Manifest "@{ ModuleVersion = '1.0.0'; RootModule = 'entry-[ab].psm1' }" -Files @{ 'entry-[ab].psm1' = 'throw "never import me"' }
        Assert-SavedModuleState -Expected $true -Name 'Example[ab]'
        Remove-Item -LiteralPath (Join-Path $script:savedModuleRoot 'Example[ab]' 'entry-[ab].psm1')
        Set-Content -LiteralPath (Join-Path $script:savedModuleRoot 'Example[ab]' 'entry-a.psm1') -Value 'neighbor'
        Assert-SavedModuleState -Expected $false -Name 'Example[ab]'
        Assert-SavedModuleState -Expected $false -Root (Join-Path $script:savedModuleCase 'modules-a')
    }

    It 'does not execute dynamic manifest expressions or candidate scripts' {
        $marker = Join-Path $script:savedModuleCase 'executed.txt'
        $code = "Set-Content -LiteralPath '$($marker.Replace("'", "''"))' -Value executed"
        $directory = New-SavedModuleFixture -Manifest "@{ ModuleVersion = '1.0.0'; RootModule = 'entry.psm1'; Description = ($code) }" -Files @{ 'entry.psm1' = $code }
        Assert-SavedModuleState -Expected $false
        Test-Path -LiteralPath $marker | Should -BeFalse
        Set-Content -LiteralPath (Join-Path $directory 'ExampleModule.psd1') -Value "@{ ModuleVersion = '1.0.0'; RootModule = 'entry.psm1' }"
        Assert-SavedModuleState -Expected $true
        Test-Path -LiteralPath $marker | Should -BeFalse
    }

    It 'does not accept an entry outside the candidate module directory' {
        Set-Content -LiteralPath (Join-Path $script:savedModuleRoot 'outside.psm1') -Value 'throw "never import me"'
        $null = New-SavedModuleFixture -Manifest "@{ ModuleVersion = '1.0.0'; RootModule = '../outside.psm1' }"
        Assert-SavedModuleState -Expected $false
    }

    It 'checks only the configured path and does not require repository provenance metadata' {
        $otherRoot = Join-Path $script:savedModuleCase 'other-modules'
        $null = New-SavedModuleFixture -Root $otherRoot
        Assert-SavedModuleState -Expected $false
        $null = New-SavedModuleFixture -Files @{ 'PSGetModuleInfo.xml' = 'unread metadata fixture'; 'PSResourceInfo.xml' = 'unread metadata fixture' }
        Assert-SavedModuleState -Expected $true
    }

    It 'reports malformed static data diagnostically without executing it' {
        $null = New-SavedModuleFixture -Manifest '@{ ModuleVersion ='
        Mock -ModuleName Shmuelie.Dsc Write-Verbose { }
        Assert-SavedModuleState -Expected $false
        Should -Invoke -ModuleName Shmuelie.Dsc Write-Verbose -Times 2 -Exactly -ParameterFilter {
            $Message -like '*manifest is not readable static data*'
        }
    }

    It 'propagates unexpected manifest read failures instead of reporting success' {
        $directory = New-SavedModuleFixture
        $manifestPath = Join-Path $directory 'ExampleModule.psd1'
        Mock -ModuleName Shmuelie.Dsc Import-PowerShellDataFile {
            throw [System.UnauthorizedAccessException]::new('fixture access denied')
        } -ParameterFilter { $LiteralPath -eq $manifestPath }
        InModuleScope Shmuelie.Dsc -Parameters @{ Root = $script:savedModuleRoot } {
            param($Root)
            $resource = [SavePSResource]@{ Name = 'ExampleModule'; Path = $Root }
            { $resource.Test() } | Should -Throw '*fixture access denied*'
            { $resource.Get() } | Should -Throw '*fixture access denied*'
        }
    }

    It 'defaults Repository and preserves all save options with explicit Version = <Version>' -ForEach @(
        @{ Version = '' }
        @{ Version = '1.0.0' }
    ) {
        InModuleScope Shmuelie.Dsc -Parameters @{ Root = $script:savedModuleRoot; DesiredVersion = $Version } {
            param($Root, $DesiredVersion)
            ([SavePSResource]@{ Name = 'ExampleModule'; Path = $Root }).Repository | Should -Be 'PSGallery'
            Mock Save-PSResource { } -ParameterFilter {
                $Name -eq 'ExampleModule' -and $Path -eq $Root -and $Repository -eq 'FixtureRepository' -and
                $TrustRepository -and $IncludeXml -and $AcceptLicense -and $SkipDependencyCheck -and
                (($DesiredVersion -and $Version -eq $DesiredVersion) -or (-not $DesiredVersion -and -not $PSBoundParameters.ContainsKey('Version')))
            }
            ([SavePSResource]@{ Name = 'ExampleModule'; Path = $Root; Repository = 'FixtureRepository'; Version = $DesiredVersion }).Set()
            Should -Invoke Save-PSResource -Times 1 -Exactly
        }
    }

    It 'repairs an empty version layout through a mocked save and then reports the saved state' {
        $null = [System.IO.Directory]::CreateDirectory((Join-Path $script:savedModuleRoot 'ExampleModule' '1.0.0'))
        InModuleScope Shmuelie.Dsc -Parameters @{ Root = $script:savedModuleRoot } {
            param($Root)
            Mock Save-PSResource {
                Set-Content -LiteralPath (Join-Path $Path $Name $Version "$Name.psd1") -Value "@{ ModuleVersion = '$Version' }"
            } -ParameterFilter {
                $Name -eq 'ExampleModule' -and $Path -eq $Root -and $Repository -eq 'FixtureRepository' -and
                $Version -eq '1.0.0' -and $SkipDependencyCheck
            }
            $resource = [SavePSResource]@{ Name = 'ExampleModule'; Path = $Root; Version = '1.0.0'; Repository = 'FixtureRepository' }
            $resource.Test() | Should -BeFalse
            $resource.Get().Installed | Should -BeFalse
            $resource.Set()
            $resource.Test() | Should -BeTrue
            $resource.Get().Installed | Should -BeTrue
            Should -Invoke Save-PSResource -Times 1 -Exactly
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
