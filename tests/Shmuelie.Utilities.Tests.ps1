#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.2.0' }

BeforeAll {
    $repoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent
    Import-Module (Join-Path $repoRoot 'modules' 'Shmuelie.Utilities' 'Shmuelie.Utilities.psd1') -Force

    $script:OriginalPath = $env:PATH

    function Add-FakeCode {
        param([Parameter(Mandatory)][string]$Path)

        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        Set-Content -Path (Join-Path $Path 'code.cmd') -Value @(
            '@echo off'
            'if defined VSCODE_TEST_LOG echo %*>>"%VSCODE_TEST_LOG%"'
            'exit /b 0'
        )
        $env:PATH = "$Path$([IO.Path]::PathSeparator)$script:OriginalPath"
    }
}

AfterAll {
    $env:PATH = $script:OriginalPath
    Remove-Module Shmuelie.Utilities -Force -ErrorAction SilentlyContinue
}

Describe 'Test-IsElevated' {
    It 'returns a boolean' {
        Test-IsElevated | Should -BeOfType [bool]
    }
}

Describe 'Get-SessionTitle' {
    It 'includes the PowerShell moniker' {
        Get-SessionTitle | Should -Match 'PowerShell'
    }

    It 'includes the running version' {
        Get-SessionTitle | Should -Match ([regex]::Escape("$($PSVersionTable.PSVersion)"))
    }
}

Describe 'New-GlobalConstant' {
    It 'creates a global constant with the supplied value' {
        $name = 'ShmuelieTest_' + [guid]::NewGuid().ToString('N')
        New-GlobalConstant $name 42
        (Get-Variable -Name $name -Scope Global -ValueOnly) | Should -Be 42
    }

    It 'makes the variable read-only' {
        $name = 'ShmuelieTest_' + [guid]::NewGuid().ToString('N')
        New-GlobalConstant $name 'locked'
        { Set-Variable -Name $name -Value 'other' -Scope Global } | Should -Throw
    }
}

Describe 'New-PathVariable' {
    It 'creates the variable when the path exists' {
        $name = 'ShmuelieTest_' + [guid]::NewGuid().ToString('N')
        New-PathVariable $name $TestDrive
        (Get-Variable -Name $name -Scope Global -ValueOnly) | Should -Be "$TestDrive"
    }

    It 'does not create the variable when the path is missing' {
        $name = 'ShmuelieTest_' + [guid]::NewGuid().ToString('N')
        New-PathVariable $name (Join-Path $TestDrive 'does-not-exist')
        { Get-Variable -Name $name -Scope Global -ErrorAction Stop } | Should -Throw
    }
}

Describe 'Import-ModuleSafe' {
    It 'does nothing when the path is missing' {
        { Import-ModuleSafe -Path (Join-Path $TestDrive 'missing.psd1') } | Should -Not -Throw
    }
}

Describe 'Format-Duration' {
    $durationCases = @(
        # sub-minute: fractional TotalSeconds with no trailing label punctuation
        @{ Seconds = 45;     Expected = '45 seconds' }
        @{ Seconds = 0.5;    Expected = '0.5 seconds' }
        @{ Seconds = 5.3;    Expected = '5.3 seconds' }
        # fractional rounding to three decimals
        @{ Seconds = 1.2344; Expected = '1.234 seconds' }
        @{ Seconds = 2.5678; Expected = '2.568 seconds' }
        # just under the one-minute boundary
        @{ Seconds = 59.999; Expected = '59.999 seconds' }
        # exact one-minute boundary switches to M:SS.mmm
        @{ Seconds = 60;     Expected = '1:00.000' }
        @{ Seconds = 90.25;  Expected = '1:30.250' }
        @{ Seconds = 3599;   Expected = '59:59.000' }
        # exact one-hour boundary switches to H:MM:SS.mmm
        @{ Seconds = 3600;   Expected = '1:00:00.000' }
        @{ Seconds = 3661.5; Expected = '1:01:01.500' }
    )

    It 'formats <Seconds>s as <Expected>' -ForEach $durationCases {
        Format-Duration ([TimeSpan]::FromSeconds($Seconds)) | Should -BeExactly $Expected
    }

    It 'folds days into the hours field' {
        Format-Duration ([TimeSpan]::FromHours(25)) | Should -BeExactly '25:00:00.000'
    }

    It 'accepts pipeline input' {
        [TimeSpan]::FromSeconds(5.3) | Format-Duration | Should -BeExactly '5.3 seconds'
    }
}

Describe 'Invoke-InLocation' {
    It 'runs the script block in the requested location' {
        $target = Join-Path $TestDrive 'work'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        $seen = Invoke-InLocation -Location $target -ScriptBlock { (Get-Location).Path }
        $seen | Should -Be (Resolve-Path $target).Path
    }

    It 'restores the original location afterward' {
        $target = Join-Path $TestDrive 'work'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        $before = (Get-Location).Path
        Invoke-InLocation -Location $target -ScriptBlock { $null } | Out-Null
        (Get-Location).Path | Should -Be $before
    }
}

Describe 'VS Code CLI shim argument validation' {
    BeforeEach {
        $script:VsCodeTestLog = Join-Path $TestDrive 'code.log'
        Remove-Item $script:VsCodeTestLog -Force -ErrorAction SilentlyContinue
        $env:VSCODE_TEST_LOG = $script:VsCodeTestLog
        Add-FakeCode -Path (Join-Path $TestDrive 'bin')
    }

    AfterEach {
        Remove-Item Env:\VSCODE_TEST_LOG -ErrorAction SilentlyContinue
    }

    It 'rejects an unsafe extension id before invoking code' {
        { Install-VsCodeExtension -Id 'publisher.extension&echo-bad' -Confirm:$false } |
            Should -Throw '*Unsafe InstallExtension value*'
        Test-Path $script:VsCodeTestLog | Should -BeFalse
    }

    It 'allows a normal extension id through to code' {
        Install-VsCodeExtension -Id 'ms-python.python' -Confirm:$false

        Get-Content $script:VsCodeTestLog -Raw | Should -Match '--install-extension ms-python.python'
    }

    It 'rejects an invalid goto target before invoking code' {
        { Start-VsCode -Goto 'src\file.ps1:not-a-line' -Confirm:$false } |
            Should -Throw '*Unsafe Goto value*'
        Test-Path $script:VsCodeTestLog | Should -BeFalse
    }

    It 'passes path arguments after an option separator' {
        $workspace = Join-Path $TestDrive 'workspace'
        New-Item -ItemType Directory -Path $workspace -Force | Out-Null

        Start-VsCode -Path $workspace -Confirm:$false

        Get-Content $script:VsCodeTestLog -Raw | Should -Match ([regex]::Escape("-- $workspace"))
    }
}

Describe 'Get-PipPackages' {
    BeforeEach {
        function global:pip { }
    }

    AfterEach {
        Remove-Item Function:\pip -ErrorAction SilentlyContinue
    }

    It 'parses package names and versions from JSON output' {
        Mock -ModuleName Shmuelie.Utilities pip {
            '[{"name":"requests","version":"2.31.0"},{"name":"pytest","version":"8.0.0"}]'
        }

        $packages = @(Get-PipPackages)

        $packages | Should -HaveCount 2
        $packages[0].name | Should -BeExactly 'requests'
        $packages[0].version | Should -BeExactly '2.31.0'
        $packages[1].name | Should -BeExactly 'pytest'
        $packages[1].version | Should -BeExactly '8.0.0'
        Should -Invoke -ModuleName Shmuelie.Utilities pip -Times 1
    }

    It 'parses JSON when stdout includes warning lines' {
        Mock -ModuleName Shmuelie.Utilities pip {
            @(
                'WARNING: Ignoring invalid distribution -ip'
                '[{"name":"setuptools","version":"70.0.0"}]'
                '[notice] A new release of pip is available'
            )
        }

        $packages = @(Get-PipPackages -PackageState Outdated)

        $packages | Should -HaveCount 1
        $packages[0].name | Should -BeExactly 'setuptools'
        $packages[0].version | Should -BeExactly '70.0.0'
    }
}

Describe 'Get-UvPackages' {
    BeforeEach {
        function global:uv { }
    }

    AfterEach {
        Remove-Item Function:\uv -ErrorAction SilentlyContinue
    }

    It 'parses package names and versions from JSON output' {
        Mock -ModuleName Shmuelie.Utilities uv {
            '[{"name":"ruff","version":"0.6.1"},{"name":"mypy","version":"1.11.0"}]'
        }

        $packages = @(Get-UvPackages)

        $packages | Should -HaveCount 2
        $packages[0].name | Should -BeExactly 'ruff'
        $packages[0].version | Should -BeExactly '0.6.1'
        $packages[1].name | Should -BeExactly 'mypy'
        $packages[1].version | Should -BeExactly '1.11.0'
        Should -Invoke -ModuleName Shmuelie.Utilities uv -Times 1
    }

    It 'parses JSON when stdout includes warning lines' {
        Mock -ModuleName Shmuelie.Utilities uv {
            @(
                'Using Python 3.12.0 environment at .venv'
                '[{"name":"black","version":"24.8.0","latest_version":"24.10.0"}]'
                'warning: cache entry ignored'
            )
        }

        $packages = @(Get-UvPackages -Outdated)

        $packages | Should -HaveCount 1
        $packages[0].name | Should -BeExactly 'black'
        $packages[0].version | Should -BeExactly '24.8.0'
    }
}

Describe 'Get-DotNetTool' {
    BeforeEach {
        function global:dotnet { }
    }

    AfterEach {
        Remove-Item Function:\dotnet -ErrorAction SilentlyContinue
    }

    It 'parses package ids, versions, and commands from tool list output' {
        Mock -ModuleName Shmuelie.Utilities dotnet {
            @(
                'Package Id        Version      Commands'
                '---------------------------------------'
                'dotnet-ef         8.0.7        dotnet-ef'
                'dotnet-outdated   4.6.4        dotnet-outdated'
            )
        }

        $tools = @(Get-DotNetTool)

        $tools | Should -HaveCount 2
        $tools[0].PackageId | Should -BeExactly 'dotnet-ef'
        $tools[0].Version | Should -BeExactly '8.0.7'
        $tools[0].Commands | Should -BeExactly 'dotnet-ef'
        $tools[0].Global | Should -BeTrue
        $tools[1].PackageId | Should -BeExactly 'dotnet-outdated'
        $tools[1].Version | Should -BeExactly '4.6.4'
    }

    It 'filters tools by package id' {
        Mock -ModuleName Shmuelie.Utilities dotnet {
            @(
                'Package Id        Version      Commands'
                '---------------------------------------'
                'dotnet-ef         8.0.7        dotnet-ef'
                'dotnet-outdated   4.6.4        dotnet-outdated'
            )
        }

        $tools = @(Get-DotNetTool -Name 'dotnet-e*')

        $tools | Should -HaveCount 1
        $tools[0].PackageId | Should -BeExactly 'dotnet-ef'
        $tools[0].Version | Should -BeExactly '8.0.7'
    }
}

Describe 'Repair-GlobalJson' {
    It 'sets sdk.rollForward to disable' {
        $globalJson = Join-Path $TestDrive 'global.json'
        Set-Content -Path $globalJson -Value '{"sdk":{"version":"9.0.100","rollForward":"latestFeature"}}'

        Push-Location $TestDrive
        try {
            Repair-GlobalJson -Confirm:$false
        } finally {
            Pop-Location
        }

        $content = Get-Content $globalJson -Raw | ConvertFrom-Json
        $content.sdk.version | Should -BeExactly '9.0.100'
        $content.sdk.rollForward | Should -BeExactly 'disable'
    }

    It 'does not change global.json under WhatIf' {
        $globalJson = Join-Path $TestDrive 'global.json'
        $original = '{"sdk":{"version":"9.0.100","rollForward":"latestFeature"}}'
        Set-Content -Path $globalJson -Value $original

        Push-Location $TestDrive
        try {
            Repair-GlobalJson -WhatIf
        } finally {
            Pop-Location
        }

        (Get-Content $globalJson -Raw).Trim() | Should -BeExactly $original
    }
}

Describe 'Update-InstalledPSResource' {
    BeforeEach {
        function New-TestSaveLayout {
            param(
                [Parameter(Mandatory)]
                [string]$Root,

                [Parameter(Mandatory)]
                [string]$Name,

                [string]$Version = '1.0.0',

                [string]$Repository,

                [string]$RepositorySourceLocation,

                [object]$Metadata,

                [switch]$Direct,

                [string]$DirectoryName = $Version
            )

            # Create a versioned Save-PSResource layout: <Root>/<Name>/<Version>/<Name>.psd1
            $versionRoot = Join-Path $Root $Name
            if (-not $Direct) { $versionRoot = Join-Path $versionRoot $DirectoryName }
            New-Item -ItemType Directory -Path $versionRoot -Force | Out-Null
            New-ModuleManifest -Path (Join-Path $versionRoot "$Name.psd1") -ModuleVersion $Version -RootModule "$Name.psm1"

            if ($PSBoundParameters.ContainsKey('Metadata')) {
                $Metadata | Export-Clixml -LiteralPath (Join-Path $versionRoot 'PSGetModuleInfo.xml') -Depth 5
            }
            elseif ($Repository -or $RepositorySourceLocation) {
                [PSCustomObject]@{
                    Name                     = $Name
                    Version                  = [version]$Version
                    Repository               = $Repository
                    RepositorySourceLocation = $RepositorySourceLocation
                } | Export-Clixml -LiteralPath (Join-Path $versionRoot 'PSGetModuleInfo.xml')
            }
        }

        # Default: remote has 2.0.0 available; individual tests set their own installed version.
        Mock -ModuleName Shmuelie.Utilities Find-PSResource {
            [PSCustomObject]@{ Version = [version]'2.0.0' }
        }
        Mock -ModuleName Shmuelie.Utilities Save-PSResource {}
    }

    It 'calls Save-PSResource with correct parameters for an outdated module (1.0.0 installed, 2.0.0 available)' {
        $modulesPath = Join-Path $TestDrive 'Outdated'
        New-TestSaveLayout -Root $modulesPath -Name 'ModuleA' -Version '1.0.0'

        Update-InstalledPSResource -Path $modulesPath -Confirm:$false

        Should -Invoke -ModuleName Shmuelie.Utilities Save-PSResource -Times 1 -ParameterFilter {
            $Name -eq 'ModuleA' -and
            $Version -eq '2.0.0' -and
            $Path -eq (Resolve-Path -LiteralPath $modulesPath).ProviderPath -and
            $Repository -eq 'PSGallery' -and
            $TrustRepository -and $IncludeXml -and $AcceptLicense -and $SkipDependencyCheck
        }
    }

    It 'does not call Save-PSResource for a module already at the latest version' {
        $modulesPath = Join-Path $TestDrive 'Current'
        New-TestSaveLayout -Root $modulesPath -Name 'ModuleA' -Version '2.0.0'

        Update-InstalledPSResource -Path $modulesPath -Confirm:$false

        Should -Invoke -ModuleName Shmuelie.Utilities Save-PSResource -Times 0
    }

    It 'updates only modules under the supplied path, not those in other paths' {
        $modulesPath = Join-Path $TestDrive 'InScope'
        $otherPath = Join-Path $TestDrive 'OutOfScope'
        New-TestSaveLayout -Root $modulesPath -Name 'ModuleA' -Version '1.0.0'
        New-TestSaveLayout -Root $otherPath -Name 'ModuleB' -Version '1.0.0'

        Update-InstalledPSResource -Path $modulesPath -Confirm:$false

        Should -Invoke -ModuleName Shmuelie.Utilities Save-PSResource -Times 1 -ParameterFilter { $Name -eq 'ModuleA' }
        Should -Invoke -ModuleName Shmuelie.Utilities Save-PSResource -Times 0 -ParameterFilter { $Name -eq 'ModuleB' }
    }

    It 'does not call Save-PSResource under -WhatIf, but still queries the repository' {
        $modulesPath = Join-Path $TestDrive 'WhatIf'
        New-TestSaveLayout -Root $modulesPath -Name 'ModuleA' -Version '1.0.0' -Repository 'RepoA'

        Update-InstalledPSResource -Path $modulesPath -WhatIf

        Should -Invoke -ModuleName Shmuelie.Utilities Find-PSResource -Times 1
        Should -Invoke -ModuleName Shmuelie.Utilities Save-PSResource -Times 0
    }

    It 'updates resources from their recorded repositories in a mixed module root' {
        $modulesPath = Join-Path $TestDrive 'MixedRepositories'
        New-TestSaveLayout -Root $modulesPath -Name 'ModuleA' -Version '1.0.0' -Repository 'RepoA'
        New-TestSaveLayout -Root $modulesPath -Name 'ModuleB' -Version '1.0.0' -Repository 'RepoB'
        Mock -ModuleName Shmuelie.Utilities Find-PSResource {
            if ($Repository -eq 'RepoA') { [PSCustomObject]@{ Version = [version]'2.0.0' } }
            if ($Repository -eq 'RepoB') { [PSCustomObject]@{ Version = [version]'3.0.0' } }
        }

        Update-InstalledPSResource -Path $modulesPath -Confirm:$false

        Should -Invoke -ModuleName Shmuelie.Utilities Find-PSResource -Times 1 -ParameterFilter {
            $Name -eq 'ModuleA' -and $Repository -eq 'RepoA'
        }
        Should -Invoke -ModuleName Shmuelie.Utilities Find-PSResource -Times 1 -ParameterFilter {
            $Name -eq 'ModuleB' -and $Repository -eq 'RepoB'
        }
        Should -Invoke -ModuleName Shmuelie.Utilities Save-PSResource -Times 1 -ParameterFilter {
            $Name -eq 'ModuleA' -and $Version -eq '2.0.0' -and $Repository -eq 'RepoA'
        }
        Should -Invoke -ModuleName Shmuelie.Utilities Save-PSResource -Times 1 -ParameterFilter {
            $Name -eq 'ModuleB' -and $Version -eq '3.0.0' -and $Repository -eq 'RepoB'
        }
    }

    It 'uses an explicitly supplied repository instead of recorded provenance' {
        $modulesPath = Join-Path $TestDrive 'RepositoryOverride'
        New-TestSaveLayout -Root $modulesPath -Name 'ModuleA' -Version '1.0.0' -Repository 'RecordedRepo'

        Update-InstalledPSResource -Path $modulesPath -Repository 'OverrideRepo' -Confirm:$false

        Should -Invoke -ModuleName Shmuelie.Utilities Find-PSResource -Times 1 -ParameterFilter {
            $Name -eq 'ModuleA' -and $Repository -eq 'OverrideRepo'
        }
        Should -Invoke -ModuleName Shmuelie.Utilities Save-PSResource -Times 1 -ParameterFilter {
            $Name -eq 'ModuleA' -and $Repository -eq 'OverrideRepo'
        }
    }

    It 'resolves source-only provenance to a configured repository name' {
        $modulesPath = Join-Path $TestDrive 'SourceOnly'
        New-TestSaveLayout -Root $modulesPath -Name 'ModuleA' -Version '1.0.0' `
            -RepositorySourceLocation 'https://packages.example.test/v3/index.json'
        Mock -ModuleName Shmuelie.Utilities Get-PSResourceRepository {
            [PSCustomObject]@{
                Name = 'SourceRepo'
                Uri  = [uri]'https://packages.example.test/v3/index.json'
            }
        }

        Update-InstalledPSResource -Path $modulesPath -Confirm:$false

        Should -Invoke -ModuleName Shmuelie.Utilities Find-PSResource -Times 1 -ParameterFilter {
            $Name -eq 'ModuleA' -and $Repository -eq 'SourceRepo'
        }
        Should -Invoke -ModuleName Shmuelie.Utilities Save-PSResource -Times 1 -ParameterFilter {
            $Name -eq 'ModuleA' -and $Repository -eq 'SourceRepo'
        }
    }

    It 'keeps a versioned module discoverable when its manifest contains dynamic expressions' {
        $modulesPath = Join-Path $TestDrive 'DynamicManifest'
        $versionRoot = Join-Path $modulesPath 'Dynamic.Module' '1.2.3'
        New-Item -ItemType Directory -Path $versionRoot -Force | Out-Null
        @'
@{
    RootModule = 'Dynamic.Module.psm1'
    ModuleVersion = '1.2.3'
    FormatsToProcess = "$PSScriptRoot/Dynamic.format.ps1xml"
}
'@ | Set-Content -LiteralPath (Join-Path $versionRoot 'Dynamic.Module.psd1')

        Update-InstalledPSResource -Path $modulesPath -Confirm:$false

        Should -Invoke -ModuleName Shmuelie.Utilities Find-PSResource -Times 1 -ParameterFilter {
            $Name -eq 'Dynamic.Module'
        }
        Should -Invoke -ModuleName Shmuelie.Utilities Save-PSResource -Times 1 -ParameterFilter {
            $Name -eq 'Dynamic.Module' -and $Repository -eq 'PSGallery'
        }
    }

    It 'inherits recorded provenance from an older version when the newest lacks metadata' {
        $modulesPath = Join-Path $TestDrive 'OlderProvenance'
        New-TestSaveLayout -Root $modulesPath -Name 'ModuleA' -Version '1.0.0' -Repository 'RepoA'
        New-TestSaveLayout -Root $modulesPath -Name 'ModuleA' -Version '1.5.0'

        Update-InstalledPSResource -Path $modulesPath -Confirm:$false

        Should -Invoke -ModuleName Shmuelie.Utilities Find-PSResource -Times 1 -ParameterFilter {
            $Name -eq 'ModuleA' -and $Repository -eq 'RepoA'
        }
        Should -Invoke -ModuleName Shmuelie.Utilities Save-PSResource -Times 1 -ParameterFilter {
            $Name -eq 'ModuleA' -and $Repository -eq 'RepoA'
        }
    }

    It 'skips a module whose recorded source URI cannot be resolved instead of falling back' {
        $modulesPath = Join-Path $TestDrive 'UnresolvedSource'
        New-TestSaveLayout -Root $modulesPath -Name 'Private.Module' -Version '1.0.0' `
            -RepositorySourceLocation 'https://unknown.example.test/v3/index.json'
        Mock -ModuleName Shmuelie.Utilities Get-PSResourceRepository {
            [PSCustomObject]@{
                Name = 'PSGallery'
                Uri  = [uri]'https://www.powershellgallery.com/api/v2'
            }
        }

        Update-InstalledPSResource -Path $modulesPath -Confirm:$false `
            -WarningVariable warnings -WarningAction SilentlyContinue

        $warnings | Should -HaveCount 1
        $warnings[0].Message | Should -Match 'unknown.example.test'
        Should -Invoke -ModuleName Shmuelie.Utilities Find-PSResource -Times 0
        Should -Invoke -ModuleName Shmuelie.Utilities Save-PSResource -Times 0
    }

    It 'rejects an explicitly empty repository override' {
        $modulesPath = Join-Path $TestDrive 'EmptyRepository'
        New-TestSaveLayout -Root $modulesPath -Name 'ModuleA' -Version '1.0.0'

        { Update-InstalledPSResource -Path $modulesPath -Repository '' -Confirm:$false } |
            Should -Throw

        Should -Invoke -ModuleName Shmuelie.Utilities Find-PSResource -Times 0
    }

    It 'filters module names before repository lookup without warning' {
        $modulesPath = Join-Path $TestDrive 'Filtered'
        New-TestSaveLayout -Root $modulesPath -Name 'Managed.One' -Version '1.0.0'
        New-TestSaveLayout -Root $modulesPath -Name 'Managed.Two' -Version '1.0.0'
        New-TestSaveLayout -Root $modulesPath -Name 'Local.Build' -Version '1.0.0'

        Update-InstalledPSResource -Path $modulesPath -Name 'Managed.*' -Exclude '*.Two' `
            -Confirm:$false -WarningVariable warnings

        Should -Invoke -ModuleName Shmuelie.Utilities Find-PSResource -Times 1 -ParameterFilter {
            $Name -eq 'Managed.One'
        }
        Should -Invoke -ModuleName Shmuelie.Utilities Find-PSResource -Times 0 -ParameterFilter {
            $Name -in @('Managed.Two', 'Local.Build')
        }
        $warnings | Should -BeNullOrEmpty
    }

    It 'warns for an unavailable recorded repository and continues other resources' {
        $modulesPath = Join-Path $TestDrive 'UnavailableRepository'
        New-TestSaveLayout -Root $modulesPath -Name 'ModuleA' -Version '1.0.0' -Repository 'MissingRepo'
        New-TestSaveLayout -Root $modulesPath -Name 'ModuleB' -Version '1.0.0' -Repository 'RepoB'
        Mock -ModuleName Shmuelie.Utilities Find-PSResource {
            if ($Repository -eq 'MissingRepo') { throw 'repository is not registered' }
            [PSCustomObject]@{ Version = [version]'2.0.0' }
        }

        Update-InstalledPSResource -Path $modulesPath -Confirm:$false `
            -WarningVariable warnings -WarningAction SilentlyContinue

        $warnings | Should -HaveCount 1
        $warnings[0].Message | Should -Match 'MissingRepo'
        Should -Invoke -ModuleName Shmuelie.Utilities Save-PSResource -Times 0 -ParameterFilter {
            $Name -eq 'ModuleA'
        }
        Should -Invoke -ModuleName Shmuelie.Utilities Save-PSResource -Times 1 -ParameterFilter {
            $Name -eq 'ModuleB' -and $Repository -eq 'RepoB'
        }
    }

    It 'is a no-op for a missing path' {
        $modulesPath = Join-Path $TestDrive 'MissingPath'

        { Update-InstalledPSResource -Path $modulesPath -Confirm:$false } | Should -Not -Throw

        Should -Invoke -ModuleName Shmuelie.Utilities Find-PSResource -Times 0
        Should -Invoke -ModuleName Shmuelie.Utilities Save-PSResource -Times 0
    }

    It 'is a no-op for an empty path' {
        $modulesPath = Join-Path $TestDrive 'EmptyPath'
        New-Item -ItemType Directory -Path $modulesPath -Force | Out-Null

        { Update-InstalledPSResource -Path $modulesPath -Confirm:$false } | Should -Not -Throw

        Should -Invoke -ModuleName Shmuelie.Utilities Find-PSResource -Times 0
        Should -Invoke -ModuleName Shmuelie.Utilities Save-PSResource -Times 0
    }

    It 'recovers <Shape> prerelease metadata in a <Layout> layout' -ForEach @(
        $additionalDictionary = [System.Collections.Generic.Dictionary[string, string]]::new()
        $additionalDictionary.Add('IsPrerelease', 'true')
        $additionalDictionary.Add('NormalizedVersion', '1.0.0-beta.2')
        foreach ($shape in @(
            @{ Shape = 'Version string'; Metadata = @{ Version = '1.0.0-beta.2' } }
            @{ Shape = 'semantic Version object'; Metadata = @{ Version = [System.Management.Automation.SemanticVersion]'1.0.0-beta.2' } }
            @{ Shape = 'additional normalized version'; Metadata = @{
                Version = [version]'1.0.0'
                AdditionalMetadata = @{ IsPrerelease = 'true'; NormalizedVersion = '1.0.0-beta.2' }
            } }
            @{ Shape = 'object additional metadata'; Metadata = [PSCustomObject]@{
                Version = [version]'1.0.0'
                AdditionalMetadata = [PSCustomObject]@{ IsPrerelease = $true; NormalizedVersion = '1.0.0-beta.2' }
            } }
            @{ Shape = 'dictionary additional metadata'; Metadata = @{
                Version = [version]'1.0.0'
                AdditionalMetadata = $additionalDictionary
            } }
            @{ Shape = 'top-level normalized version'; Metadata = @{ NormalizedVersion = '1.0.0-beta.2' } }
            @{ Shape = 'normalized version without Version'; Metadata = @{
                AdditionalMetadata = @{ NormalizedVersion = '1.0.0-beta.2' }
            } }
            @{ Shape = 'split version and label'; Metadata = @{
                Version = [version]'1.0.0'; IsPrerelease = $true; Prerelease = 'beta.2'
            } }
            @{ Shape = 'split additional label'; Metadata = @{
                Version = [version]'1.0.0'; AdditionalMetadata = @{ IsPrerelease = 'true'; Prerelease = 'beta.2' }
            } }
            @{ Shape = 'invalid normalized version fallback'; Metadata = @{
                Version = '1.0.0-beta.2'; AdditionalMetadata = @{ NormalizedVersion = 'not-a-version' }
            } }
        )) {
            foreach ($layout in 'versioned', 'direct') {
                @{ Shape = $shape.Shape; Metadata = $shape.Metadata; Layout = $layout }
            }
        }
    ) {
        $modulesPath = Join-Path $TestDrive "MetadataShapes-$Shape-$Layout"
        New-TestSaveLayout -Root $modulesPath -Name 'ModuleA' -Metadata $Metadata -Direct:($Layout -eq 'direct')
        Mock -ModuleName Shmuelie.Utilities Find-PSResource {
            [PSCustomObject]@{ Version = '1.0.0-beta.10' }
        }

        Update-InstalledPSResource -Path $modulesPath -Confirm:$false

        Should -Invoke -ModuleName Shmuelie.Utilities Find-PSResource -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'ModuleA' -and $Repository -eq 'PSGallery' -and $Prerelease
        }
        Should -Invoke -ModuleName Shmuelie.Utilities Save-PSResource -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'ModuleA' -and $Version -ceq '1.0.0-beta.10' -and
            $Repository -eq 'PSGallery' -and $Path -eq (Resolve-Path $modulesPath).ProviderPath
        }
    }

    It 'preserves the exact selected remote version from <Shape>' -ForEach @(
        @{ Shape = 'Version string'; Remote = @{ Version = '1.0.0-Preview.10+build.7' } }
        @{ Shape = 'semantic Version'; Remote = @{ Version = [System.Management.Automation.SemanticVersion]'1.0.0-Preview.10+build.7' } }
        @{ Shape = 'normalized additional metadata'; Remote = @{
            Version = [version]'1.0.0'; IsPrerelease = $true
            AdditionalMetadata = @{ NormalizedVersion = '1.0.0-Preview.10+build.7' }
        } }
        @{ Shape = 'split version and prerelease'; Remote = @{
            Version = [version]'1.0.0'; IsPrerelease = $true; Prerelease = 'Preview.10+build.7'
        } }
        @{ Shape = 'top-level normalized version'; Remote = @{ NormalizedVersion = '1.0.0-Preview.10+build.7' } }
        @{ Shape = 'split additional prerelease'; Remote = @{
            Version = [version]'1.0.0'; AdditionalMetadata = @{ IsPrerelease = 'true'; Prerelease = 'Preview.10+build.7' }
        } }
    ) {
        $modulesPath = Join-Path $TestDrive "RemoteShapes-$Shape"
        New-TestSaveLayout -Root $modulesPath -Name 'ModuleA' -Metadata @{ Version = '1.0.0-Preview.2' }
        Mock -ModuleName Shmuelie.Utilities Find-PSResource { [PSCustomObject]$Remote }

        Update-InstalledPSResource -Path $modulesPath -Confirm:$false

        Should -Invoke -ModuleName Shmuelie.Utilities Save-PSResource -Times 1 -Exactly -ParameterFilter {
            $Version -ceq '1.0.0-Preview.10+build.7'
        }
    }

    It 'compares installed <Installed> to remote <Remote> semantically (update: <Update>)' -ForEach @(
        @{ Installed = '1.0.0-beta.2'; Remote = '1.0.0-beta.10'; Update = $true }
        @{ Installed = '1.0.0-beta.10'; Remote = '1.0.0-beta.2'; Update = $false }
        @{ Installed = '1.0.0-beta.10'; Remote = '1.0.0-beta.10'; Update = $false }
        @{ Installed = '1.0.0-beta.9999999999'; Remote = '1.0.0-beta.10000000000'; Update = $true }
        @{ Installed = '1.0.0-alpha'; Remote = '1.0.0-beta'; Update = $true }
        @{ Installed = '1.0.0-alpha'; Remote = '1.0.0-alpha.1'; Update = $true }
        @{ Installed = '1.0.0-alpha.1'; Remote = '1.0.0-alpha'; Update = $false }
        @{ Installed = '1.0.0-alpha.1'; Remote = '1.0.0-alpha.beta'; Update = $true }
        @{ Installed = '1.0.0-alpha.beta'; Remote = '1.0.0-alpha.1'; Update = $false }
        @{ Installed = '1.0.0-preview-feature.2'; Remote = '1.0.0-preview-feature.10'; Update = $true }
        @{ Installed = '1.0.0-RC.1'; Remote = '1.0.0-rc.1'; Update = $false }
        @{ Installed = '1.0.0-beta.2+build.1'; Remote = '1.0.0-beta.2+build.2'; Update = $false }
        @{ Installed = '1.0.0-rc.1'; Remote = '1.0.0'; Update = $true }
        @{ Installed = '2.0.0-beta.1'; Remote = '1.9.9'; Update = $false }
        @{ Installed = '1.0.0-rc.1'; Remote = '2.0.0-alpha.1'; Update = $true }
        @{ Installed = '1.0.0'; Remote = '1.0.0-rc.1'; Update = $false }
        @{ Installed = '1.0.0'; Remote = '2.0.0-beta.1'; Update = $false }
        @{ Installed = '1.0'; Remote = '1.0.0'; Update = $false }
        @{ Installed = '1.0.0.0'; Remote = '1.0.0'; Update = $false }
        @{ Installed = '1.0.0.1'; Remote = '1.0.0.2'; Update = $true }
        @{ Installed = '1.0.0.1-beta.2'; Remote = '1.0.0.1-beta.10'; Update = $true }
    ) {
        $modulesPath = Join-Path $TestDrive "VersionOrder-$Installed-$Remote"
        New-TestSaveLayout -Root $modulesPath -Name 'ModuleA' -Version ($Installed -split '[-+]')[0] `
            -Metadata @{ Version = $Installed }
        Mock -ModuleName Shmuelie.Utilities Find-PSResource { [PSCustomObject]@{ Version = $Remote } }

        Update-InstalledPSResource -Path $modulesPath -Confirm:$false

        $expectedPrerelease = ($Installed -split '\+', 2)[0] -match '-'
        Should -Invoke -ModuleName Shmuelie.Utilities Find-PSResource -Times 1 -Exactly -ParameterFilter {
            [bool]$Prerelease -eq $expectedPrerelease
        }
        Should -Invoke -ModuleName Shmuelie.Utilities Save-PSResource -Times ([int]$Update) -Exactly
        if ($Update) {
            Should -Invoke -ModuleName Shmuelie.Utilities Save-PSResource -Times 1 -Exactly -ParameterFilter {
                $Version -ceq $Remote
            }
        }
    }

    It 'selects the highest remote semantic version from unordered results: <Expected>' -ForEach @(
        @{ Versions = @('1.0.0-beta.2', '1.0.0-beta.10', '1.0.0-alpha'); Expected = '1.0.0-beta.10' }
        @{ Versions = @('1.0.0-beta.10', '1.0.0', '1.0.0-rc.1'); Expected = '1.0.0' }
        @{ Versions = @('1.0.0', '2.0.0-alpha.1', '1.0.0-rc.1'); Expected = '2.0.0-alpha.1' }
    ) {
        $modulesPath = Join-Path $TestDrive "RemoteOrder-$Expected"
        New-TestSaveLayout -Root $modulesPath -Name 'ModuleA' -Metadata @{ Version = '1.0.0-alpha' }
        Mock -ModuleName Shmuelie.Utilities Find-PSResource {
            foreach ($item in $Versions) { [PSCustomObject]@{ Version = $item } }
        }

        Update-InstalledPSResource -Path $modulesPath -Confirm:$false

        Should -Invoke -ModuleName Shmuelie.Utilities Save-PSResource -Times 1 -Exactly -ParameterFilter {
            $Version -ceq $Expected
        }
    }

    It 'keeps stable metadata stable for <Shape>, even if prereleases are returned' -ForEach @(
        @{ Shape = 'false string'; Metadata = @{
            Version = [version]'1.0.0'; AdditionalMetadata = @{ IsPrerelease = 'false'; NormalizedVersion = '1.0.0' }
        } }
        @{ Shape = 'false boolean'; Metadata = @{ Version = [version]'1.0.0'; IsPrerelease = $false } }
    ) {
        $modulesPath = Join-Path $TestDrive "StableChannel-$Shape"
        New-TestSaveLayout -Root $modulesPath -Name 'ModuleA' -Metadata $Metadata
        Mock -ModuleName Shmuelie.Utilities Find-PSResource {
            [PSCustomObject]@{ Version = '3.0.0-beta.1' }
            [PSCustomObject]@{ Version = [version]'2.0.0' }
        }

        Update-InstalledPSResource -Path $modulesPath -Confirm:$false

        Should -Invoke -ModuleName Shmuelie.Utilities Find-PSResource -Times 1 -Exactly -ParameterFilter {
            -not $PesterBoundParameters.ContainsKey('Prerelease')
        }
        Should -Invoke -ModuleName Shmuelie.Utilities Save-PSResource -Times 1 -Exactly -ParameterFilter {
            $Version -eq '2.0.0'
        }
    }

    It 'chooses installed semantic versions and their provenance across direct and versioned layouts: <DirectVersion>' -ForEach @(
        @{ DirectVersion = '1.0.0-beta.2'; VersionedVersion = '1.0.0-beta.10'; ExpectedRepository = 'VersionedRepo'; ExpectedPrerelease = $true }
        @{ DirectVersion = '1.0.0-beta.10'; VersionedVersion = '1.0.0-beta.2'; ExpectedRepository = 'DirectRepo'; ExpectedPrerelease = $true }
        @{ DirectVersion = '1.0.0'; VersionedVersion = '1.0.0-rc.1'; ExpectedRepository = 'DirectRepo'; ExpectedPrerelease = $false }
        @{ DirectVersion = '1.0.0-rc.1'; VersionedVersion = '1.0.0'; ExpectedRepository = 'VersionedRepo'; ExpectedPrerelease = $false }
    ) {
        $modulesPath = Join-Path $TestDrive "InstalledOrder-$DirectVersion-$VersionedVersion"
        New-TestSaveLayout -Root $modulesPath -Name 'ModuleA' -Direct `
            -Metadata @{ Version = $DirectVersion; Repository = 'DirectRepo' }
        New-TestSaveLayout -Root $modulesPath -Name 'ModuleA' `
            -Metadata @{ Version = $VersionedVersion; Repository = 'VersionedRepo' }

        Update-InstalledPSResource -Path $modulesPath -Confirm:$false

        Should -Invoke -ModuleName Shmuelie.Utilities Find-PSResource -Times 1 -Exactly -ParameterFilter {
            $Repository -eq $ExpectedRepository -and [bool]$Prerelease -eq $ExpectedPrerelease
        }
    }

    It 'inherits only repository provenance from an older prerelease, not its channel' {
        $modulesPath = Join-Path $TestDrive 'OlderPrereleaseProvenance'
        New-TestSaveLayout -Root $modulesPath -Name 'ModuleA' -Version '1.0.0' `
            -Metadata @{ Version = '1.0.0-beta.2'; Repository = 'RepoA' }
        New-TestSaveLayout -Root $modulesPath -Name 'ModuleA' -Version '1.5.0'

        Update-InstalledPSResource -Path $modulesPath -Confirm:$false

        Should -Invoke -ModuleName Shmuelie.Utilities Find-PSResource -Times 1 -Exactly -ParameterFilter {
            $Repository -eq 'RepoA' -and -not $Prerelease
        }
        Should -Invoke -ModuleName Shmuelie.Utilities Save-PSResource -Times 1 -Exactly -ParameterFilter {
            $Repository -eq 'RepoA' -and $Version -eq '2.0.0'
        }
    }

    It 'uses the highest older semantic version for missing provenance' {
        $modulesPath = Join-Path $TestDrive 'OlderSemanticProvenance'
        New-TestSaveLayout -Root $modulesPath -Name 'ModuleA' -Direct `
            -Metadata @{ Version = '1.0.0-beta.10'; Repository = 'LatestRepo' }
        New-TestSaveLayout -Root $modulesPath -Name 'ModuleA' `
            -Metadata @{ Version = '1.0.0-beta.2'; Repository = 'OlderRepo' }
        New-TestSaveLayout -Root $modulesPath -Name 'ModuleA' -Version '1.5.0'

        Update-InstalledPSResource -Path $modulesPath -Confirm:$false

        Should -Invoke -ModuleName Shmuelie.Utilities Find-PSResource -Times 1 -Exactly -ParameterFilter {
            $Repository -eq 'LatestRepo' -and -not $Prerelease
        }
    }

    It 'preserves prerelease tracking with repository override and confines saving to the selected path' {
        $modulesPath = Join-Path $TestDrive 'PrereleaseOverride'
        New-TestSaveLayout -Root $modulesPath -Name 'ModuleA' `
            -Metadata @{ Version = '1.0.0-beta.2'; Repository = 'RecordedRepo' }
        New-TestSaveLayout -Root (Join-Path $TestDrive 'OtherRoot') -Name 'OtherModule' `
            -Metadata @{ Version = '1.0.0-beta.2'; Repository = 'RecordedRepo' }
        Mock -ModuleName Shmuelie.Utilities Find-PSResource {
            [PSCustomObject]@{ Version = [version]'1.0.0'; Prerelease = 'beta.10'; IsPrerelease = $true }
        }

        Update-InstalledPSResource -Path $modulesPath -Repository 'OverrideRepo' -Confirm:$false

        Should -Invoke -ModuleName Shmuelie.Utilities Find-PSResource -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'ModuleA' -and $Repository -eq 'OverrideRepo' -and $Prerelease
        }
        Should -Invoke -ModuleName Shmuelie.Utilities Save-PSResource -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'ModuleA' -and $Repository -eq 'OverrideRepo' -and $Version -eq '1.0.0-beta.10' -and
            $Path -eq (Resolve-Path $modulesPath).ProviderPath -and
            $TrustRepository -and $IncludeXml -and $AcceptLicense -and $SkipDependencyCheck
        }
    }

    It 'resolves prerelease source-only provenance and queries that feed with prereleases' {
        $modulesPath = Join-Path $TestDrive 'PrereleaseSource'
        New-TestSaveLayout -Root $modulesPath -Name 'ModuleA' -Metadata @{
            Version = '1.0.0-beta.2'; RepositorySourceLocation = 'https://packages.example.test/v3/index.json/'
        }
        Mock -ModuleName Shmuelie.Utilities Get-PSResourceRepository {
            [PSCustomObject]@{ Name = 'SourceRepo'; Uri = [uri]'https://packages.example.test/v3/index.json' }
        }

        Update-InstalledPSResource -Path $modulesPath -Confirm:$false

        Should -Invoke -ModuleName Shmuelie.Utilities Find-PSResource -Times 1 -Exactly -ParameterFilter {
            $Repository -eq 'SourceRepo' -and $Prerelease
        }
        Should -Invoke -ModuleName Shmuelie.Utilities Save-PSResource -Times 1 -Exactly -ParameterFilter {
            $Repository -eq 'SourceRepo' -and $Version -eq '2.0.0'
        }
    }

    It 'retains prerelease metadata for a dynamic manifest in a <Layout> layout' -ForEach @(
        @{ Layout = 'versioned' }
        @{ Layout = 'direct' }
    ) {
        $modulesPath = Join-Path $TestDrive "DynamicPrerelease-$Layout"
        New-TestSaveLayout -Root $modulesPath -Name 'ModuleA' -Direct:($Layout -eq 'direct') `
            -Metadata @{ Version = '1.0.0-beta.2'; Repository = 'RepoA' }
        $manifestRoot = Join-Path $modulesPath 'ModuleA'
        if ($Layout -eq 'versioned') { $manifestRoot = Join-Path $manifestRoot '1.0.0' }
        Set-Content -LiteralPath (Join-Path $manifestRoot 'ModuleA.psd1') -Value @'
@{
    ModuleVersion = '1.0.0'
    FormatsToProcess = "$PSScriptRoot/ModuleA.format.ps1xml"
}
'@
        Mock -ModuleName Shmuelie.Utilities Find-PSResource {
            [PSCustomObject]@{ Version = '1.0.0-beta.10' }
        }

        Update-InstalledPSResource -Path $modulesPath -Confirm:$false

        Should -Invoke -ModuleName Shmuelie.Utilities Find-PSResource -Times 1 -Exactly -ParameterFilter {
            $Repository -eq 'RepoA' -and $Prerelease
        }
        Should -Invoke -ModuleName Shmuelie.Utilities Save-PSResource -Times 1 -Exactly -ParameterFilter {
            $Version -eq '1.0.0-beta.10'
        }
    }

    It 'uses a manifest version when metadata and a usable version directory are absent' {
        $modulesPath = Join-Path $TestDrive 'ManifestFallback'
        New-TestSaveLayout -Root $modulesPath -Name 'DirectModule' -Direct
        New-TestSaveLayout -Root $modulesPath -Name 'VersionedModule' -DirectoryName 'current'

        Update-InstalledPSResource -Path $modulesPath -Confirm:$false

        Should -Invoke -ModuleName Shmuelie.Utilities Save-PSResource -Times 2 -Exactly -ParameterFilter {
            $Version -eq '2.0.0' -and $Repository -eq 'PSGallery'
        }
    }

    It 'falls back to the versioned layout when metadata cannot be read' {
        $modulesPath = Join-Path $TestDrive 'CorruptMetadata'
        New-TestSaveLayout -Root $modulesPath -Name 'ModuleA'
        Set-Content -LiteralPath (Join-Path $modulesPath 'ModuleA' '1.0.0' 'PSGetModuleInfo.xml') -Value '<broken'

        Update-InstalledPSResource -Path $modulesPath -Confirm:$false

        Should -Invoke -ModuleName Shmuelie.Utilities Find-PSResource -Times 1 -Exactly -ParameterFilter {
            $Repository -eq 'PSGallery' -and -not $Prerelease
        }
        Should -Invoke -ModuleName Shmuelie.Utilities Save-PSResource -Times 1 -Exactly
    }

    It 'filters prerelease names before querying and leaves stable modules stable in a mixed root' {
        $modulesPath = Join-Path $TestDrive 'MixedChannels'
        foreach ($moduleName in 'Managed.Preview', 'Managed.Excluded', 'Other.Preview') {
            New-TestSaveLayout -Root $modulesPath -Name $moduleName -Metadata @{ Version = '1.0.0-beta.2' }
        }
        New-TestSaveLayout -Root $modulesPath -Name 'Managed.Stable'

        Update-InstalledPSResource -Path $modulesPath -Name 'Managed.*,NoMatch' -Exclude '*.Excluded,*.Local' -Confirm:$false

        Should -Invoke -ModuleName Shmuelie.Utilities Find-PSResource -Times 2 -Exactly
        Should -Invoke -ModuleName Shmuelie.Utilities Find-PSResource -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'Managed.Preview' -and $Prerelease
        }
        Should -Invoke -ModuleName Shmuelie.Utilities Find-PSResource -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'Managed.Stable' -and -not $Prerelease
        }
    }

    It 'queries prereleases under WhatIf without saving or changing the layout' {
        $modulesPath = Join-Path $TestDrive 'PrereleaseWhatIf'
        New-TestSaveLayout -Root $modulesPath -Name 'ModuleA' -Metadata @{ Version = '1.0.0-beta.2'; Repository = 'RepoA' }
        Mock -ModuleName Shmuelie.Utilities Find-PSResource {
            [PSCustomObject]@{ Version = '1.0.0-beta.10' }
        }

        Update-InstalledPSResource -Path $modulesPath -WhatIf

        Should -Invoke -ModuleName Shmuelie.Utilities Find-PSResource -Times 1 -Exactly -ParameterFilter {
            $Repository -eq 'RepoA' -and $Prerelease
        }
        Should -Invoke -ModuleName Shmuelie.Utilities Save-PSResource -Times 0
        Get-ChildItem -LiteralPath (Join-Path $modulesPath 'ModuleA') -Directory | Should -HaveCount 1
    }

    It 'does not save when the prerelease lookup returns no results' {
        $modulesPath = Join-Path $TestDrive 'MissingRemote'
        New-TestSaveLayout -Root $modulesPath -Name 'ModuleA' -Metadata @{ Version = '1.0.0-beta.2' }
        Mock -ModuleName Shmuelie.Utilities Find-PSResource {}

        Update-InstalledPSResource -Path $modulesPath -Confirm:$false

        Should -Invoke -ModuleName Shmuelie.Utilities Find-PSResource -Times 1 -Exactly -ParameterFilter { $Prerelease }
        Should -Invoke -ModuleName Shmuelie.Utilities Save-PSResource -Times 0
    }

    It 'warns and skips a <Layout> prerelease whose label cannot be recovered' -ForEach @(
        @{ Layout = 'versioned' }
        @{ Layout = 'direct' }
    ) {
        $modulesPath = Join-Path $TestDrive "MissingLabel-$Layout"
        New-TestSaveLayout -Root $modulesPath -Name 'ModuleA' -Direct:($Layout -eq 'direct') -Metadata @{
            Version = [version]'1.0.0'; AdditionalMetadata = @{ IsPrerelease = 'true' }
        }

        $warnings = @(Update-InstalledPSResource -Path $modulesPath -Confirm:$false -WarningAction Continue 3>&1)

        $warnings | Should -HaveCount 1
        $warnings[0].Message | Should -Match 'Could not determine module version'
        Should -Invoke -ModuleName Shmuelie.Utilities Find-PSResource -Times 0
        Should -Invoke -ModuleName Shmuelie.Utilities Save-PSResource -Times 0
    }

    It 'warns and skips an invalid remote version without blocking a valid result' {
        $modulesPath = Join-Path $TestDrive 'InvalidRemote'
        New-TestSaveLayout -Root $modulesPath -Name 'ModuleA' -Metadata @{ Version = '1.0.0-beta.2' }
        Mock -ModuleName Shmuelie.Utilities Find-PSResource {
            [PSCustomObject]@{ Version = 'not-a-version' }
            [PSCustomObject]@{ Version = '1.0.0-beta.10' }
        }

        Update-InstalledPSResource -Path $modulesPath -Confirm:$false -WarningVariable warnings -WarningAction SilentlyContinue

        $warnings | Should -HaveCount 1
        $warnings[0].Message | Should -Match 'Could not determine version'
        Should -Invoke -ModuleName Shmuelie.Utilities Save-PSResource -Times 1 -Exactly -ParameterFilter {
            $Version -eq '1.0.0-beta.10'
        }
    }
}
