#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.2.0' }

BeforeAll {
    $repoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent
    $script:ModuleManifest = [System.IO.Path]::Combine($repoRoot, 'modules', 'Shmuelie.Dsc', 'Shmuelie.Dsc.psd1')
    Import-Module $script:ModuleManifest -Force
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

Describe 'SymbolicLink' -Tag 'DscSymbolicLink' {
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
        InModuleScope Shmuelie.Dsc -Parameters @{ Root = $TestDrive } {
            param($Root)
            $link = Join-Path $Root 'link'
            $target = Join-Path $Root 'target'
            Mock Get-Item { [pscustomobject]@{ LinkType = 'SymbolicLink'; Target = $target } } -ParameterFilter { $LiteralPath -ceq $link }
            ([SymbolicLink]@{ Path = $link; Target = $target }).Test() | Should -BeTrue
            ([SymbolicLink]@{ Path = $link; Target = (Join-Path $Root 'other') }).Test() | Should -BeFalse
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

Describe 'SymbolicLink pathname comparison' -Tag 'DscSymbolicLink' {
    BeforeEach {
        Mock -ModuleName Shmuelie.Dsc Get-Item { throw 'Unexpected filesystem lookup.' }
        Mock -ModuleName Shmuelie.Dsc Get-ChildItem { throw 'Unexpected directory enumeration.' }
        Mock -ModuleName Shmuelie.Dsc New-DscSymbolicLink { throw 'Comparison must not replace a link.' }
    }

    It 'compares normalized pathnames without metadata: <Case>' -ForEach @(
        @{ Case = 'exact dangling spelling'; Actual = 'missing'; Desired = 'missing'; Expected = $true }
        @{ Case = 'dot component'; Actual = './missing'; Desired = 'missing'; Expected = $true }
        @{ Case = 'relative to absolute'; Actual = 'missing'; Desired = 'missing'; AbsoluteDesired = $true; Expected = $true }
        @{ Case = 'absolute to relative'; Actual = 'missing'; Desired = 'missing'; AbsoluteActual = $true; Expected = $true }
        @{ Case = 'parent-relative spelling'; Actual = '../missing'; Desired = '../missing'; AbsoluteDesired = $true; Expected = $true }
        @{ Case = 'trailing separator'; Actual = 'missing/'; Desired = 'missing'; Expected = $true }
        @{ Case = 'distinct missing names'; Actual = 'missing'; Desired = 'other'; Expected = $false }
        @{ Case = 'different immediate chains'; Actual = 'first/leaf'; Desired = 'second/leaf'; Expected = $false }
    ) {
        InModuleScope Shmuelie.Dsc -Parameters @{
            Root = $TestDrive; Actual = $Actual; Desired = $Desired
            AbsoluteActual = $AbsoluteActual; AbsoluteDesired = $AbsoluteDesired; Expected = $Expected
        } {
            param($Root, $Actual, $Desired, $AbsoluteActual, $AbsoluteDesired, $Expected)
            $linkParent = Join-Path $Root 'links'
            if ($AbsoluteActual) { $Actual = [IO.Path]::GetFullPath($Actual, $linkParent) }
            if ($AbsoluteDesired) { $Desired = [IO.Path]::GetFullPath($Desired, $linkParent) }
            Test-DscSymbolicLinkTarget -LinkPath (Join-Path $linkParent 'link') -ActualTarget $Actual -DesiredTarget $Desired | Should -Be $Expected
            Should -Invoke Get-Item -Times 0 -Exactly
            Should -Invoke Get-ChildItem -Times 0 -Exactly
            Should -Invoke New-DscSymbolicLink -Times 0 -Exactly
        }
    }

    It 'requires actual directory-entry evidence: <Case>' -ForEach @(
        @{ Case = 'case-insensitive existing entry'; Names = @('Foo'); Expected = $true }
        @{ Case = 'lowercase stored entry'; Names = @('foo'); Expected = $true }
        @{ Case = 'case-sensitive distinct entries'; Names = @('Foo', 'foo'); Expected = $false }
        @{ Case = 'no matching entries'; Names = @('other'); Unknown = $true; ErrorLike = '*No unambiguous directory entry*' }
        @{ Case = 'ambiguous nonexact spelling'; Names = @('Foo', 'FOO'); Unknown = $true; ErrorLike = '*No unambiguous directory entry*' }
        @{ Case = 'directory is inaccessible'; Names = @('Foo'); Failure = 'Enumeration'; Unknown = $true; ErrorLike = '*fixture directory access denied*' }
        @{ Case = 'alternate spelling is missing'; Names = @('Foo'); Failure = 'Lookup'; Unknown = $true; ErrorLike = '*fixture entry missing*' }
        @{ Case = 'lookup returns no entry'; Names = @('Foo'); Failure = 'EmptyLookup'; Unknown = $true; ErrorLike = '*Literal lookup did not identify one entry*' }
    ) {
        InModuleScope Shmuelie.Dsc -Parameters @{
            Root = $TestDrive; Names = $Names; Expected = $Expected; Unknown = $Unknown; Failure = $Failure; ErrorLike = $ErrorLike
        } {
            param($Root, $Names, $Expected, $Unknown, $Failure, $ErrorLike)
            $fixtureParent = $Root
            $fixtureNames = $Names
            $fixtureUpper = Join-Path $Root 'Foo'
            $fixtureLower = Join-Path $Root 'foo'
            Mock Get-ChildItem {
                if ($Failure -eq 'Enumeration') { throw [UnauthorizedAccessException]::new('fixture directory access denied') }
                foreach ($name in $fixtureNames) { [pscustomobject]@{ Name = $name } }
            } -ParameterFilter { $LiteralPath -ceq $fixtureParent -and $Force }
            Mock Get-Item {
                if ($LiteralPath -ceq $fixtureLower -and $Failure -eq 'Lookup') { throw [IO.FileNotFoundException]::new('fixture entry missing') }
                if ($Failure -eq 'EmptyLookup') { return }
                [pscustomobject]@{ Name = [IO.Path]::GetFileName($LiteralPath); FullName = $LiteralPath }
            } -ParameterFilter { ($LiteralPath -ceq $fixtureUpper -or $LiteralPath -ceq $fixtureLower) -and $Force }
            $invoke = { Test-DscSymbolicLinkTarget -LinkPath (Join-Path $fixtureParent 'link') -ActualTarget $fixtureUpper -DesiredTarget $fixtureLower }
            if ($Unknown) {
                $values = [System.Collections.Generic.List[object]]::new()
                $failureRecord = $null
                try { & $invoke | ForEach-Object { $values.Add($_) } } catch { $failureRecord = $_ }
                $values.Count | Should -Be 0
                $failureRecord.FullyQualifiedErrorId | Should -BeLike 'DscSymbolicLinkComparisonUnknown*'
                $failureRecord.Exception.Message | Should -BeLike '*Cannot determine symbolic-link target case equivalence*'
                $failureRecord.Exception.InnerException | Should -Not -BeNullOrEmpty
                $failureRecord.Exception.InnerException.Message | Should -BeLike $ErrorLike
            } else {
                & $invoke | Should -Be $Expected
            }
            Should -Invoke Get-ChildItem -Times 1 -Exactly -ParameterFilter { $LiteralPath -ceq $fixtureParent -and $Force }
            Should -Invoke New-DscSymbolicLink -Times 0 -Exactly
        }
    }

    It 'checks differing parent components instead of folding an entire path' {
        InModuleScope Shmuelie.Dsc -Parameters @{ Root = $TestDrive } {
            param($Root)
            $fixtureParent = $Root
            $fixtureUpper = Join-Path $Root 'Folder'
            $fixtureLower = Join-Path $Root 'folder'
            Mock Get-ChildItem { @([pscustomobject]@{ Name = 'Folder' }, [pscustomobject]@{ Name = 'folder' }) } -ParameterFilter { $LiteralPath -ceq $fixtureParent }
            Mock Get-Item { [pscustomobject]@{ FullName = $LiteralPath } } -ParameterFilter { $LiteralPath -ceq $fixtureUpper -or $LiteralPath -ceq $fixtureLower }
            Test-DscSymbolicLinkTarget -LinkPath (Join-Path $Root 'link') -ActualTarget (Join-Path $fixtureUpper 'same') -DesiredTarget (Join-Path $fixtureLower 'same') | Should -BeFalse
        }
    }

    It 'normalizes Windows drive-letter syntax without assuming directory case behavior' -Skip:(-not $IsWindows) {
        InModuleScope Shmuelie.Dsc -Parameters @{ Root = $TestDrive } {
            param($Root)
            $target = Join-Path $Root 'missing'
            $lowerDrive = $target.Substring(0, 1).ToLowerInvariant() + $target.Substring(1)
            Test-DscSymbolicLinkTarget -LinkPath (Join-Path $Root 'link') -ActualTarget $target -DesiredTarget $lowerDrive | Should -BeTrue
            Should -Invoke Get-Item -Times 0 -Exactly
            Should -Invoke Get-ChildItem -Times 0 -Exactly
        }
    }

    It 'uses canonical parent spelling for subsequent case comparisons' {
        InModuleScope Shmuelie.Dsc -Parameters @{ Root = $TestDrive } {
            param($Root)
            $fixtureRoot = $Root
            $fixtureParent = Join-Path $Root 'Folder'
            $fixtureAlias = Join-Path $Root 'folder'
            $fixtureUpper = Join-Path $fixtureParent 'Leaf'
            $fixtureLower = Join-Path $fixtureParent 'leaf'
            Mock Get-ChildItem { [pscustomobject]@{ Name = 'Folder' } } -ParameterFilter { $LiteralPath -ceq $fixtureRoot }
            Mock Get-ChildItem { [pscustomobject]@{ Name = 'Leaf' } } -ParameterFilter { $LiteralPath -ceq $fixtureParent }
            Mock Get-Item { [pscustomobject]@{ FullName = $LiteralPath } } -ParameterFilter {
                $LiteralPath -cin @($fixtureParent, $fixtureAlias, $fixtureUpper, $fixtureLower)
            }
            Test-DscSymbolicLinkTarget -LinkPath (Join-Path $Root 'link') -ActualTarget $fixtureUpper -DesiredTarget (Join-Path $fixtureAlias 'leaf') | Should -BeTrue
            Should -Invoke Get-ChildItem -Times 2 -Exactly
        }
    }
}

Describe 'SymbolicLink owned filesystem' -Tag 'DscSymbolicLink' {
    BeforeEach {
        $script:linkFixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:ownedLinks = [System.Collections.Generic.List[string]]::new()
        $null = [IO.Directory]::CreateDirectory($script:linkFixture)
        $script:fixtureTarget = Join-Path $script:linkFixture 'CaseTarget.txt'
        [IO.File]::WriteAllText($script:fixtureTarget, 'owned target')
        $script:fixtureLower = Join-Path $script:linkFixture 'casetarget.txt'
        $script:fixtureCaseSensitive = -not [IO.File]::Exists($script:fixtureLower)

        function New-OwnedFileLink {
            param([string]$Name, [string]$Target)
            $path = Join-Path $script:linkFixture $Name
            $absoluteTarget = [IO.Path]::GetFullPath($Target, $script:linkFixture)
            if (-not $absoluteTarget.StartsWith($script:linkFixture + [IO.Path]::DirectorySeparatorChar, [StringComparison]::Ordinal)) {
                throw 'Fixture link target escaped its owned root.'
            }
            $script:ownedLinks.Add($path)
            try { $null = [IO.File]::CreateSymbolicLink($path, $Target) }
            catch {
                $exception = $_.Exception
                while ($exception.InnerException) { $exception = $exception.InnerException }
                if ($IsWindows -and $exception.HResult -eq -2147023582) {
                    Set-ItResult -Skipped -Because 'Windows denied symbolic-link creation; no elevation or settings change is allowed.'
                } else { throw }
            }
            return $path
        }

        function Get-OwnedLinkCompliance {
            param([string]$Path, [string]$Target)
            InModuleScope Shmuelie.Dsc -Parameters @{ Path = $Path; Target = $Target } {
                param($Path, $Target)
                ([SymbolicLink]@{ Path = $Path; Target = $Target }).Test()
            }
        }
    }

    AfterEach {
        foreach ($path in $script:ownedLinks) {
            if ([IO.Path]::GetDirectoryName($path) -cne $script:linkFixture) { throw 'Refusing out-of-scope fixture cleanup.' }
            [IO.File]::Delete($path)
        }
        foreach ($item in Get-ChildItem -LiteralPath $script:linkFixture -Recurse -Force) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Unexpected fixture reparse point remains.' }
        }
        Remove-Item -LiteralPath $script:linkFixture -Recurse -Force -ErrorAction Stop
        Test-Path -LiteralPath $script:linkFixture | Should -BeFalse
    }

    It 'accepts a real relative target and its absolute representation without changing the link' {
        $link = New-OwnedFileLink -Name 'link' -Target 'CaseTarget.txt'
        $before = (Get-Item -LiteralPath $link).Target
        Get-OwnedLinkCompliance -Path $link -Target $script:fixtureTarget | Should -BeTrue
        Get-OwnedLinkCompliance -Path $link -Target 'CaseTarget.txt' | Should -BeTrue
        (Get-Item -LiteralPath $link).Target | Should -BeExactly $before
        [IO.File]::ReadAllText($script:fixtureTarget) | Should -BeExactly 'owned target'
    }

    It 'proves equivalence on an actually case-insensitive directory' {
        if ($script:fixtureCaseSensitive) { Set-ItResult -Skipped -Because 'Owned fixture is case-sensitive.' }
        [IO.File]::ReadAllText($script:fixtureLower) | Should -BeExactly 'owned target'
        @([IO.Directory]::EnumerateFiles($script:linkFixture)).Count | Should -Be 1
        $link = New-OwnedFileLink -Name 'link' -Target $script:fixtureTarget
        Get-OwnedLinkCompliance -Path $link -Target $script:fixtureLower | Should -BeTrue
    }

    It 'rejects distinct actual case-sensitive entries' -Tag 'DscSymbolicLinkCaseSensitive' {
        if (-not $script:fixtureCaseSensitive) { Set-ItResult -Skipped -Because 'Owned fixture is case-insensitive; this case requires the portable CI filesystem.' }
        [IO.File]::WriteAllText($script:fixtureLower, 'different owned target')
        [IO.File]::ReadAllText($script:fixtureTarget) | Should -BeExactly 'owned target'
        [IO.File]::ReadAllText($script:fixtureLower) | Should -BeExactly 'different owned target'
        @([IO.Directory]::EnumerateFiles($script:linkFixture)).Count | Should -Be 2
        $link = New-OwnedFileLink -Name 'link' -Target $script:fixtureTarget
        Get-OwnedLinkCompliance -Path $link -Target $script:fixtureLower | Should -BeFalse
        Get-OwnedLinkCompliance -Path $link -Target $script:fixtureTarget | Should -BeTrue
    }

    It 'errors rather than guessing when only the wrong-case target exists' -Tag 'DscSymbolicLinkCaseSensitive' {
        if (-not $script:fixtureCaseSensitive) { Set-ItResult -Skipped -Because 'Owned fixture is case-insensitive; this case requires the portable CI filesystem.' }
        $link = New-OwnedFileLink -Name 'link' -Target $script:fixtureTarget
        { Get-OwnedLinkCompliance -Path $link -Target $script:fixtureLower } | Should -Throw '*Cannot determine symbolic-link target case equivalence*'
        (Get-Item -LiteralPath $link).Target | Should -BeExactly $script:fixtureTarget
    }

    It 'accepts exact dangling names but errors for differently cased dangling names' {
        $link = New-OwnedFileLink -Name 'link' -Target 'Missing.txt'
        Get-OwnedLinkCompliance -Path $link -Target (Join-Path $script:linkFixture 'Missing.txt') | Should -BeTrue
        { Get-OwnedLinkCompliance -Path $link -Target (Join-Path $script:linkFixture 'missing.txt') } | Should -Throw '*Cannot determine symbolic-link target case equivalence*'
        (Get-Item -LiteralPath $link -Force).Target | Should -BeExactly 'Missing.txt'
    }

    It 'does not equate distinct immediate symlink chains to the same final file' {
        $first = New-OwnedFileLink -Name 'first' -Target $script:fixtureTarget
        $second = New-OwnedFileLink -Name 'second' -Target $script:fixtureTarget
        $link = New-OwnedFileLink -Name 'link' -Target $first
        Get-OwnedLinkCompliance -Path $link -Target $second | Should -BeFalse
    }

    It 'does not equate different hard-link names for the same file' {
        $second = Join-Path $script:linkFixture 'other-name.txt'
        $null = New-Item -ItemType HardLink -Path $second -Target $script:fixtureTarget -ErrorAction Stop
        [IO.File]::WriteAllText($second, 'shared hard-link content')
        [IO.File]::ReadAllText($script:fixtureTarget) | Should -BeExactly 'shared hard-link content'
        $link = New-OwnedFileLink -Name 'link' -Target $script:fixtureTarget
        Get-OwnedLinkCompliance -Path $link -Target $second | Should -BeFalse
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
    BeforeEach {
        Mock -ModuleName Shmuelie.Dsc copilot { throw "Unexpected Copilot operation: $($Arguments -join ' ')" }
    }

    It 'detects a registered marketplace by whole-token match and avoids substring false positives' {
        InModuleScope Shmuelie.Dsc {
            Mock copilot {
                $global:LASTEXITCODE = 0
                'team-tools  example-org/plugin-catalog'
            } -ParameterFilter {
                $Arguments.Count -eq 3 -and ($Arguments -join ' ') -eq 'plugin marketplace list'
            }
            foreach ($name in 'team-tools', 'team', 'plugin-catalog', 'custom-alias') {
                $resource = [CopilotMarketplace]@{ Name = $name; Repository = 'example-org/plugin-catalog' }
                $expected = $name -eq 'team-tools'
                $resource.Test() | Should -Be $expected
                $state = $resource.Get()
                $state.Installed | Should -Be $expected
                $state.Name | Should -BeExactly $name
                $state.Repository | Should -BeExactly $resource.Repository
            }
            Should -Invoke copilot -Times 8 -Exactly
        }
    }

    It 'passes one <SourceKind> source unchanged and converges on its manifest identity' -ForEach @(
        @{ SourceKind = 'GitHub'; Repository = 'example-org/plugin-catalog' }
        @{ SourceKind = 'GitHub ref'; Repository = 'example-org/plugin-catalog#stable' }
        @{ SourceKind = 'HTTPS URL'; Repository = 'https://example.com/plugin-catalog.git' }
        @{ SourceKind = 'SSH URL'; Repository = 'ssh://git@example.com/plugin-catalog.git' }
        @{ SourceKind = 'local path with spaces'; Repository = [IO.Path]::Combine('.', 'plugin catalog') }
    ) {
        InModuleScope Shmuelie.Dsc -Parameters @{ Repository = $Repository } {
            param($Repository)
            $fixture = @{
                Source = $Repository
                Manifest = '{"name":"team-tools","plugins":[]}' | ConvertFrom-Json
                Registered = $false
                Captured = [System.Collections.Generic.List[object]]::new()
            }
            Mock copilot {
                $global:LASTEXITCODE = 0
                if ($fixture.Registered) { "$($fixture.Manifest.name)  $($fixture.Source)" }
            } -ParameterFilter {
                $Arguments.Count -eq 3 -and ($Arguments -join ' ') -eq 'plugin marketplace list'
            }
            Mock copilot {
                $fixture.Captured.Add([string[]]$Arguments)
                $fixture.Registered = $true
                $global:LASTEXITCODE = 0
                "Registered $($fixture.Manifest.name)"
            } -ParameterFilter {
                $Arguments.Count -eq 4 -and ($Arguments[0..2] -join ' ') -eq 'plugin marketplace add' -and
                $Arguments[3] -ceq $fixture.Source
            }
            $resource = [CopilotMarketplace]@{ Name = 'team-tools'; Repository = $Repository }
            $resource.Test() | Should -BeFalse
            $resource.Get().Installed | Should -BeFalse
            $resource.Set()
            $fixture.Captured.Count | Should -Be 1
            $fixture.Captured[0] | Should -Be @('plugin', 'marketplace', 'add', $Repository)
            $resource.Test() | Should -BeTrue
            $state = $resource.Get()
            $state.Installed | Should -BeTrue
            $state.Name | Should -BeExactly 'team-tools'
            $state.Repository | Should -BeExactly $Repository

            if (-not $resource.Test()) { $resource.Set() }
            $fixture.Captured.Count | Should -Be 1
            $alias = [CopilotMarketplace]@{ Name = 'custom-alias'; Repository = $Repository }
            $alias.Test() | Should -BeFalse
            $alias.Get().Installed | Should -BeFalse
            Should -Invoke copilot -Times 1 -Exactly -ParameterFilter { $Arguments.Count -eq 4 }
            Should -Invoke copilot -Times 7 -Exactly -ParameterFilter { $Arguments.Count -eq 3 }
        }
    }

    It 'preserves registration failure output for native exit <ExitCode>' -ForEach @(
        @{ ExitCode = 1 }
        @{ ExitCode = 2 }
        @{ ExitCode = -7 }
    ) {
        InModuleScope Shmuelie.Dsc -Parameters @{ ExitCode = $ExitCode } {
            param($ExitCode)
            Mock copilot {
                $global:LASTEXITCODE = $ExitCode
                'team-tools registration failed'
                'fixture diagnostic'
            } -ParameterFilter {
                $Arguments.Count -eq 4 -and
                ($Arguments -join ' ') -eq 'plugin marketplace add example-org/plugin-catalog'
            }
            $ErrorActionPreference = 'Continue'
            { ([CopilotMarketplace]@{ Name = 'team-tools'; Repository = 'example-org/plugin-catalog' }).Set() } |
                Should -Throw "*Failed to register Copilot marketplace 'team-tools':*team-tools registration failed*fixture diagnostic*"
            Should -Invoke copilot -Times 1 -Exactly
        }
    }

    It 'rejects shell-unsafe <Case> before invoking the CLI' -ForEach @(
        @{ Case = 'Name'; Name = 'bad&name'; Repository = 'example-org/plugin-catalog' }
        @{ Case = 'repository'; Name = 'team-tools'; Repository = 'example-org/plugin-catalog&other' }
        @{ Case = 'URL'; Name = 'team-tools'; Repository = 'https://example.com/catalog?ref="%PATH%"' }
        @{ Case = 'local path'; Name = 'team-tools'; Repository = "plugin`ncatalog" }
    ) {
        InModuleScope Shmuelie.Dsc -Parameters @{ Name = $Name; Repository = $Repository } {
            param($Name, $Repository)
            { ([CopilotMarketplace]@{ Name = $Name; Repository = $Repository }).Set() } | Should -Throw '*not allowed*'
            Should -Invoke copilot -Times 0 -Exactly
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
        @{ Resource = 'CopilotMarketplace'; Command = 'copilot'; Arguments = 'plugin marketplace add owner/repository' }
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
