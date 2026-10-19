#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.2.0' }

BeforeAll {
    $repoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent
    $script:ModuleManifest = [System.IO.Path]::Combine($repoRoot, 'modules', 'Shmuelie.VisualStudio', 'Shmuelie.VisualStudio.psd1')
    Import-Module $script:ModuleManifest -Force -ErrorAction Stop

    function New-VsTestInstallation {
        param([string]$Root, [string]$Name = 'VS fixture', [string]$Version = '17.10.123.4', [int]$Year = 2022)
        $installationPath = Join-Path $Root $Name
        $tools = New-Item -ItemType Directory -Path (Join-Path $installationPath 'Common7/Tools') -Force
        $bat = Join-Path $tools.FullName 'VsDevCmd.bat'
        Set-Content -LiteralPath $bat -Value '@exit /b 99' -Encoding ascii
        [pscustomobject]@{
            Year = $Year
            Version = $Version
            InstallationPath = $installationPath
            ScriptPath = $bat
        }
    }

    function Invoke-VsTestChild {
        param([string[]]$Arguments, [hashtable]$Environment = @{}, [string]$WorkingDirectory = $TestDrive)
        $process = [Diagnostics.Process]::new()
        $started = $false
        try {
            $start = [Diagnostics.ProcessStartInfo]::new()
            $start.FileName = Join-Path $PSHOME 'pwsh.exe'
            $start.UseShellExecute = $false
            $start.RedirectStandardOutput = $true
            $start.RedirectStandardError = $true
            $start.WorkingDirectory = $WorkingDirectory
            foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
            foreach ($key in $Environment.Keys) {
                if ($null -eq $Environment[$key]) { $null = $start.Environment.Remove($key) }
                else { $start.Environment[$key] = [string]$Environment[$key] }
            }
            $process.StartInfo = $start
            if (-not $process.Start()) { throw 'Synthetic child did not start.' }
            $started = $true
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(20000)) { throw 'Synthetic child exceeded 20 seconds.' }
            [pscustomobject]@{
                ExitCode = $process.ExitCode
                Output = $stdout.GetAwaiter().GetResult()
                Error = $stderr.GetAwaiter().GetResult()
            }
        } finally {
            if ($started -and -not $process.HasExited) {
                $process.Kill($true)
                $process.WaitForExit()
            }
            $process.Dispose()
        }
    }

    # A real ShouldProcess prompt with a deterministic "No", not a mocked
    # initializer or a substituted ShouldProcess implementation.
    if (-not ('VsTestDecliningHost' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Globalization;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Management.Automation;
using System.Management.Automation.Host;
public sealed class VsTestDecliningHost : PSHost {
    public readonly VsTestDecliningUI Interface = new VsTestDecliningUI();
    public override Guid InstanceId { get; } = Guid.NewGuid();
    public override string Name => "issue361 declining fixture";
    public override Version Version => new Version(1,0);
    public override PSHostUserInterface UI => Interface;
    public override CultureInfo CurrentCulture => CultureInfo.InvariantCulture;
    public override CultureInfo CurrentUICulture => CultureInfo.InvariantCulture;
    public override void SetShouldExit(int code) {}
    public override void EnterNestedPrompt() { throw new Exception("Unexpected nested prompt"); }
    public override void ExitNestedPrompt() {}
    public override void NotifyBeginApplication() {}
    public override void NotifyEndApplication() {}
}
public sealed class VsTestDecliningUI : PSHostUserInterface {
    public int Prompts;
    public override PSHostRawUserInterface RawUI => null;
    public override int PromptForChoice(string caption, string message, Collection<ChoiceDescription> choices, int defaultChoice) {
        Prompts++;
        for (int i=0; i<choices.Count; i++) {
            if (choices[i].Label.Replace("&", "") == "No") return i;
        }
        throw new Exception("No decline option");
    }
    public override string ReadLine() { throw new Exception("Unexpected input"); }
    public override System.Security.SecureString ReadLineAsSecureString() { throw new Exception("Unexpected input"); }
    public override void Write(string value) {}
    public override void Write(ConsoleColor foreground, ConsoleColor background, string value) {}
    public override void WriteLine(string value) {}
    public override void WriteErrorLine(string value) {}
    public override void WriteDebugLine(string value) {}
    public override void WriteVerboseLine(string value) {}
    public override void WriteWarningLine(string value) {}
    public override void WriteProgress(long source, ProgressRecord record) {}
    public override Dictionary<string, PSObject> Prompt(string caption, string message, Collection<FieldDescription> fields) { throw new Exception("Unexpected input"); }
    public override PSCredential PromptForCredential(string caption, string message, string user, string target) { throw new Exception("Unexpected credential"); }
    public override PSCredential PromptForCredential(string caption, string message, string user, string target, PSCredentialTypes types, PSCredentialUIOptions options) { throw new Exception("Unexpected credential"); }
}
'@
    }
}

AfterAll {
    Remove-Module Shmuelie.VisualStudio -Force -ErrorAction SilentlyContinue
}

Describe 'Shmuelie.VisualStudio module' {
    It 'exports the expected functions and no aliases' {
        $data = Import-PowerShellDataFile $script:ModuleManifest
        $expected = @('Get-InstalledVsVersion', 'Resolve-MSBuild', 'Set-VS2017', 'Set-VS2019', 'Set-VS2022', 'Set-VS2026', 'Start-DevShell') | Sort-Object
        ($data.FunctionsToExport | Sort-Object) | Should -Be $expected
        ((Get-Module Shmuelie.VisualStudio).ExportedFunctions.Keys | Sort-Object) | Should -Be $expected
        $data.AliasesToExport.Count | Should -Be 0
        (Get-Module Shmuelie.VisualStudio).ExportedAliases.Count | Should -Be 0
        @($data.RequiredModules) | Should -Not -Contain 'PSVSEnv'
    }

    Describe 'Resolve-MSBuild' {
        BeforeAll {
            if (-not $TestDrive -or -not (Test-Path -LiteralPath $TestDrive -PathType Container -ErrorAction Stop)) {
                throw 'Pester TestDrive is required for synthetic Visual Studio paths.'
            }
            InModuleScope Shmuelie.VisualStudio -Parameters @{ FixtureRoot = $TestDrive } {
                param($FixtureRoot)
                $script:MSBuildFixtureRoot = $FixtureRoot
            }
        }

        BeforeEach {
            InModuleScope Shmuelie.VisualStudio {
                $script:MSBuildInstances = @(
                    [pscustomobject]@{ installationVersion = '17.9.12345.1'; installationPath = (Join-Path $script:MSBuildFixtureRoot 'VS Old') },
                    [pscustomobject]@{ installationVersion = '18.0.100.1'; installationPath = (Join-Path $script:MSBuildFixtureRoot 'Build Tools') },
                    [pscustomobject]@{ installationVersion = '17.10.12345.2'; installationPath = (Join-Path $script:MSBuildFixtureRoot 'VS New') }
                )
                Mock Test-IsWindowsPlatform { $true }
                Mock Get-MSBuildDefaultArchitecture { 'x64' }
                Mock Invoke-VsWhere { $script:MSBuildInstances }
                Mock Test-Path { $true }
                Mock Invoke-MSBuildVsWhere { throw 'Unexpected native discovery' }
                Mock Get-InstalledVsVersion { throw 'Unexpected Set-VS provider discovery' }
                Mock Invoke-DevShellProcess { throw 'Unexpected developer shell' }
                Mock Start-Process { throw 'Unexpected process launch' }
            }
        }

        It 'returns one typed result from the newest installation without changing the environment' {
            InModuleScope Shmuelie.VisualStudio {
                $originalPath = $env:PATH
                $originalLocation = (Get-Location).Path
                $results = @(Resolve-MSBuild)

                $results | Should -HaveCount 1
                $result = $results[0]
                $result.PSTypeNames | Should -Contain 'MSBuildInstallation'
                $result.Path | Should -Be (Join-Path $script:MSBuildInstances[1].installationPath 'MSBuild' 'Current' 'Bin' 'amd64' 'MSBuild.exe')
                $result.VisualStudioVersion | Should -BeOfType ([version])
                $result.VisualStudioVersion | Should -Be ([version]'18.0.100.1')
                $result.VisualStudioYear | Should -Be 2026
                $result.InstallationPath | Should -Be $script:MSBuildInstances[1].installationPath
                $result.Architecture | Should -Be 'x64'
                $env:PATH | Should -Be $originalPath
                (Get-Location).Path | Should -Be $originalLocation
                Should -Invoke Invoke-VsWhere -Times 1 -Exactly -ParameterFilter { $MSBuild }
                Should -Invoke Get-InstalledVsVersion -Times 0
                Should -Invoke Start-Process -Times 0
                Should -Invoke Invoke-DevShellProcess -Times 0
            }
        }

        It 'filters version <Filter> numerically' -ForEach @(
            @{ Filter = '2022'; Expected = '17.10.12345.2' }
            @{ Filter = '17'; Expected = '17.10.12345.2' }
            @{ Filter = '17.9'; Expected = '17.9.12345.1' }
            @{ Filter = '17.09'; Expected = '17.9.12345.1' }
            @{ Filter = '17.10.12345'; Expected = '17.10.12345.2' }
            @{ Filter = '17.10.12345.2'; Expected = '17.10.12345.2' }
            @{ Filter = '2026'; Expected = '18.0.100.1' }
            @{ Filter = '18.0'; Expected = '18.0.100.1' }
        ) {
            InModuleScope Shmuelie.VisualStudio -Parameters @{ Filter = $Filter; Expected = $Expected } {
                param($Filter, $Expected)
                (Resolve-MSBuild -Version $Filter).VisualStudioVersion | Should -Be ([version]$Expected)
            }
        }

        It 'resolves architecture <Arch> without fallback' -ForEach @(
            @{ Arch = 'x86'; Folder = ''; Expected = 'x86' }
            @{ Arch = 'x64'; Folder = 'amd64'; Expected = 'x64' }
            @{ Arch = 'amd64'; Folder = 'amd64'; Expected = 'x64' }
            @{ Arch = 'ARM64'; Folder = 'arm64'; Expected = 'arm64' }
        ) {
            InModuleScope Shmuelie.VisualStudio -Parameters @{ Arch = $Arch; Folder = $Folder; Expected = $Expected } {
                param($Arch, $Folder, $Expected)
                $bin = Join-Path $script:MSBuildInstances[1].installationPath 'MSBuild' 'Current' 'Bin'
                if ($Folder) { $bin = Join-Path $bin $Folder }

                $result = Resolve-MSBuild -Arch $Arch

                $result.Path | Should -Be (Join-Path $bin 'MSBuild.exe')
                $result.Architecture | Should -Be $Expected
                Should -Invoke Get-MSBuildDefaultArchitecture -Times 0
                Should -Invoke Test-Path -Times 1 -Exactly -ParameterFilter { $PathType -eq 'Leaf' }
            }
        }

        It 'uses the native OS architecture when none is requested' {
            InModuleScope Shmuelie.VisualStudio {
                Mock Get-MSBuildDefaultArchitecture { 'arm64' }
                (Resolve-MSBuild).Architecture | Should -Be 'arm64'
            }
        }

        It 'returns just a string with PathOnly' {
            InModuleScope Shmuelie.VisualStudio {
                $result = @(Resolve-MSBuild -PathOnly)
                $result | Should -HaveCount 1
                $result[0] | Should -BeOfType ([string])
                $result[0] | Should -Be (Resolve-MSBuild).Path
            }
        }

        It 'skips newer installations without the requested executable' {
            InModuleScope Shmuelie.VisualStudio {
                Mock Test-Path { $LiteralPath -notlike '*Build Tools*' }
                (Resolve-MSBuild).VisualStudioVersion | Should -Be ([version]'17.10.12345.2')
            }
        }

        It 'breaks equal version ties by installation path' {
            InModuleScope Shmuelie.VisualStudio {
                $script:MSBuildInstances = @(
                    [pscustomobject]@{ installationVersion = '18.0.100.1'; installationPath = (Join-Path $script:MSBuildFixtureRoot 'Z') },
                    [pscustomobject]@{ installationVersion = '18.0.100.1'; installationPath = (Join-Path $script:MSBuildFixtureRoot 'A') }
                )
                (Resolve-MSBuild).InstallationPath | Should -Be $script:MSBuildInstances[1].installationPath
            }
        }

        It 'uses the Visual Studio 2017 toolset layout for <Arch>' -ForEach @(
            @{ Arch = 'x86'; Folder = '' }
            @{ Arch = 'x64'; Folder = 'amd64' }
        ) {
            InModuleScope Shmuelie.VisualStudio -Parameters @{ Arch = $Arch; Folder = $Folder } {
                param($Arch, $Folder)
                $script:MSBuildInstances = @(
                    [pscustomobject]@{ installationVersion = '15.9.100.1'; installationPath = (Join-Path $script:MSBuildFixtureRoot 'VS2017') }
                )
                $bin = Join-Path $script:MSBuildInstances[0].installationPath 'MSBuild' '15.0' 'Bin'
                if ($Folder) { $bin = Join-Path $bin $Folder }
                (Resolve-MSBuild -Version 2017 -Architecture $Arch).Path | Should -Be (Join-Path $bin 'MSBuild.exe')
            }
        }

        It 'does not invent a year for an unknown future Visual Studio major' {
            InModuleScope Shmuelie.VisualStudio {
                $script:MSBuildInstances = @(
                    [pscustomobject]@{ installationVersion = '19.0.100.1'; installationPath = (Join-Path $script:MSBuildFixtureRoot 'Future') }
                )
                $result = Resolve-MSBuild
                $result.VisualStudioVersion | Should -Be ([version]'19.0.100.1')
                $result.VisualStudioYear | Should -BeNullOrEmpty
            }
        }

        It 'reports a clear error when no installation exists' {
            InModuleScope Shmuelie.VisualStudio {
                Mock Invoke-VsWhere { @() }
                { Resolve-MSBuild } | Should -Throw "*No compatible Visual Studio MSBuild.exe*architecture 'x64'*"
            }
        }

        It 'reports the requested version and architecture when none match' {
            InModuleScope Shmuelie.VisualStudio {
                { Resolve-MSBuild -Version 2019 -Architecture x86 } | Should -Throw "*Visual Studio '2019'*architecture 'x86'*"
            }
        }

        It 'does not choose an executable of a different architecture' {
            InModuleScope Shmuelie.VisualStudio {
                Mock Test-Path { $LiteralPath -notlike '*arm64*' }
                { Resolve-MSBuild -Architecture arm64 } | Should -Throw "*No compatible Visual Studio MSBuild.exe*architecture 'arm64'*"
            }
        }

        It 'does not treat a directory named MSBuild.exe as an executable' {
            InModuleScope Shmuelie.VisualStudio {
                Mock Test-Path { $PathType -ne 'Leaf' }
                { Resolve-MSBuild } | Should -Throw '*No compatible Visual Studio MSBuild.exe*'
            }
        }

        It 'propagates filesystem discovery failures instead of trying another installation' {
            InModuleScope Shmuelie.VisualStudio {
                Mock Test-Path { throw 'Access denied fixture' }
                { Resolve-MSBuild } | Should -Throw '*Access denied fixture*'
                Should -Invoke Test-Path -Times 1 -Exactly
            }
        }

        It 'propagates vswhere failures without a success-shaped result' {
            InModuleScope Shmuelie.VisualStudio {
                Mock Invoke-VsWhere { throw 'Discovery failed fixture' }
                { Resolve-MSBuild } | Should -Throw '*Discovery failed fixture*'
                Should -Invoke Test-Path -Times 0
            }
        }

        It 'rejects invalid version <Filter> before discovery' -ForEach @(
            @{ Filter = 'latest' }, @{ Filter = '[17,18)' }, @{ Filter = '2025' }, @{ Filter = '17.*' }, @{ Filter = '14' }
            @{ Filter = '17.999999999999999999999999' }, @{ Filter = '' }
        ) {
            InModuleScope Shmuelie.VisualStudio -Parameters @{ Filter = $Filter } {
                param($Filter)
                { Resolve-MSBuild -Version $Filter } | Should -Throw
                Should -Invoke Invoke-VsWhere -Times 0
            }
        }

        It 'rejects an unsupported executable architecture before discovery' {
            InModuleScope Shmuelie.VisualStudio {
                { Resolve-MSBuild -Architecture sparc } | Should -Throw
                Should -Invoke Invoke-VsWhere -Times 0
            }
        }

        It 'throws off Windows before inspecting the OS architecture or installations' {
            InModuleScope Shmuelie.VisualStudio {
                Mock Test-IsWindowsPlatform { $false }
                { Resolve-MSBuild } | Should -Throw '*Resolve-MSBuild is only supported on Windows.*'
                Should -Invoke Get-MSBuildDefaultArchitecture -Times 0
                Should -Invoke Invoke-VsWhere -Times 0
                Should -Invoke Test-Path -Times 0
            }
        }
    }

    Describe 'MSBuild vswhere discovery' {
        BeforeEach {
            InModuleScope Shmuelie.VisualStudio {
                Mock Get-VsInstallerPath { (Get-Location).Path }
                Mock Test-Path { $true }
                Mock Invoke-MSBuildVsWhere { '[]' }
            }
        }

        It 'uses the existing installer path helper and parses metadata' {
            InModuleScope Shmuelie.VisualStudio {
                Mock Invoke-MSBuildVsWhere {
                    ConvertTo-Json -InputObject @(
                        @{ installationVersion = '18.0.100.1'; installationPath = (Get-Location).Path }
                    )
                }
                $result = @(Invoke-VsWhere -MSBuild)
                $result | Should -HaveCount 1
                $result[0].installationVersion | Should -Be '18.0.100.1'
                Should -Invoke Get-VsInstallerPath -Times 1 -Exactly
                Should -Invoke Invoke-MSBuildVsWhere -Times 1 -Exactly -ParameterFilter {
                    $Path -eq (Join-Path (Get-Location).Path 'vswhere.exe')
                }
            }
        }

        It 'returns no instances for valid empty discovery' {
            InModuleScope Shmuelie.VisualStudio {
                @(Invoke-VsWhere -MSBuild) | Should -HaveCount 0
            }
        }

        It 'reports a missing installer directory' {
            InModuleScope Shmuelie.VisualStudio {
                Mock Get-VsInstallerPath { $null }
                { Invoke-VsWhere -MSBuild } | Should -Throw '*vswhere.exe was not found*'
                Should -Invoke Invoke-MSBuildVsWhere -Times 0
            }
        }

        It 'reports a missing vswhere executable' {
            InModuleScope Shmuelie.VisualStudio {
                Mock Test-Path { $false }
                { Invoke-VsWhere -MSBuild } | Should -Throw '*vswhere.exe was not found*'
                Should -Invoke Invoke-MSBuildVsWhere -Times 0
            }
        }

        It 'rejects an invalid installation version even with an absolute path' {
            InModuleScope Shmuelie.VisualStudio {
                Mock Invoke-MSBuildVsWhere {
                    ConvertTo-Json -InputObject @(
                        @{ installationVersion = 'invalid'; installationPath = (Get-Location).Path }
                    )
                }
                { Invoke-VsWhere -MSBuild } | Should -Throw '*invalid installation metadata*'
            }
        }

        It 'rejects invalid discovery output <Json>' -ForEach @(
            @{ Json = '' }
            @{ Json = 'invalid json' }
            @{ Json = 'null' }
            @{ Json = '{}' }
            @{ Json = '[{}]' }
            @{ Json = '[{"installationPath":"relative","installationVersion":"18.0"}]' }
        ) {
            InModuleScope Shmuelie.VisualStudio -Parameters @{ Json = $Json } {
                param($Json)
                Mock Invoke-MSBuildVsWhere { $Json }
                { Invoke-VsWhere -MSBuild } | Should -Throw
            }
        }
    }

    Describe 'MSBuild native discovery arguments' {
        BeforeAll {
            InModuleScope Shmuelie.VisualStudio {
                function script:Invoke-VsWhereFixture {
                    [CmdletBinding()]
                    param($products, $requires, $format, [switch]$utf8)
                    throw 'Fixture must be mocked; no native process is allowed.'
                }
            }
        }

        BeforeEach {
            $script:SavedLastExitCode = $global:LASTEXITCODE
            InModuleScope Shmuelie.VisualStudio {
                Mock Invoke-VsWhereFixture { $global:LASTEXITCODE = 0; '[]' }
            }
        }

        AfterEach {
            $global:LASTEXITCODE = $script:SavedLastExitCode
        }

        AfterAll {
            InModuleScope Shmuelie.VisualStudio {
                Remove-Item Function:\Invoke-VsWhereFixture -ErrorAction Stop
            }
        }

        It 'requests all products with MSBuild without opting into preview or incomplete installations' {
            InModuleScope Shmuelie.VisualStudio {
                Invoke-MSBuildVsWhere -Path Invoke-VsWhereFixture | Should -Be '[]'
                Should -Invoke Invoke-VsWhereFixture -Times 1 -Exactly -ParameterFilter {
                    $products -eq '*' -and $requires -eq 'Microsoft.Component.MSBuild' -and $format -eq 'json' -and $utf8
                }
            }
        }

        It 'reports the exit code and diagnostics when vswhere fails' {
            InModuleScope Shmuelie.VisualStudio {
                Mock Invoke-VsWhereFixture { $global:LASTEXITCODE = 5; 'Fixture failure' }
                { Invoke-MSBuildVsWhere -Path Invoke-VsWhereFixture } | Should -Throw '*exited with code 5*Fixture failure*'
            }
        }
    }
}

Describe 'Get-InstalledVsVersion' {
    BeforeAll {
        $script:DiscoveryFixtures = @(
            New-VsTestInstallation $TestDrive '2017' '15.9.100.1' 2017
            New-VsTestInstallation $TestDrive '2019' '16.11.100.1' 2019
            New-VsTestInstallation $TestDrive '2022 old' '17.9.100.1' 2022
            New-VsTestInstallation $TestDrive '2022 Z edition' '17.10.100.1' 2022
            New-VsTestInstallation $TestDrive '2022 A build tools' '17.10.100.1' 2022
            New-VsTestInstallation $TestDrive '2026' '18.0.100.1' 2026
        )
        InModuleScope Shmuelie.VisualStudio -Parameters @{ Fixtures = $script:DiscoveryFixtures } {
            param($Fixtures)
            $script:DeveloperInstances = @($Fixtures | ForEach-Object {
                [pscustomobject]@{
                    installationPath = $_.InstallationPath
                    installationVersion = $_.Version
                    isComplete = $true
                    isLaunchable = $true
                    isPrerelease = $false
                }
            })
        }
    }
    BeforeEach {
        InModuleScope Shmuelie.VisualStudio {
            Mock Test-IsWindowsPlatform { $true }
            Mock Invoke-VsWhere { $script:DeveloperInstances }
            Mock Invoke-DeveloperVsWhere { throw 'Unexpected native developer discovery.' }
            Mock Invoke-MSBuildVsWhere { throw 'Unexpected native MSBuild discovery.' }
            Mock Invoke-VsEnvironmentCapture { throw 'Unexpected initialization.' }
            Mock Invoke-DevShellProcess { throw 'Unexpected interactive child.' }
            Mock Get-Command { throw 'Provider lookup is forbidden.' } -ParameterFilter { $Name -like 'Set-VS*' }
        }
    }
    Context 'when the platform is Windows' {
        It 'returns sorted unique integer years without provider lookup' {
            InModuleScope Shmuelie.VisualStudio {
                $years = @(Get-InstalledVsVersion)
                $years | Should -Be @(2017, 2019, 2022, 2026)
                foreach ($year in $years) { $year | Should -BeOfType ([int]) }
                Should -Invoke Invoke-VsWhere -Times 1 -Exactly -ParameterFilter { -not $MSBuild }
                Should -Invoke Get-Command -Times 0 -ParameterFilter { $Name -like 'Set-VS*' }
                Should -Invoke Invoke-VsEnvironmentCapture -Times 0
                Should -Invoke Invoke-DevShellProcess -Times 0
            }
        }

        It 'retains exact installation metadata and orders numeric versions with stable edition ties' {
            InModuleScope Shmuelie.VisualStudio {
                $results = @(Get-VsDeveloperInstallation -Year 2022)
                $results | Should -HaveCount 3
                $results.Version | Should -Be @('17.10.100.1', '17.10.100.1', '17.9.100.1')
                $results[0].InstallationPath | Should -Be $script:DeveloperInstances[4].installationPath
                $results[1].InstallationPath | Should -Be $script:DeveloperInstances[3].installationPath
                $results[0].ScriptPath | Should -Be (Join-Path $results[0].InstallationPath 'Common7/Tools/VsDevCmd.bat')
                $results[0].Version | Should -BeOfType ([string])
                $results[0].Year | Should -Be 2022
            }
        }

        It 'excludes ineligible installations for reason <Reason>' -ForEach @(
            @{ Reason = 'incomplete'; Field = 'isComplete'; Value = $false }
            @{ Reason = 'unlaunchable'; Field = 'isLaunchable'; Value = $false }
            @{ Reason = 'preview'; Field = 'isPrerelease'; Value = $true }
            @{ Reason = 'missing eligibility'; Field = 'isComplete'; Value = $null }
        ) {
            InModuleScope Shmuelie.VisualStudio -Parameters @{ Field = $Field; Value = $Value } {
                param($Field, $Value)
                $instance = $script:DeveloperInstances[0].PSObject.Copy()
                $instance.$Field = $Value
                Mock Invoke-VsWhere { @($instance) }
                @(Get-InstalledVsVersion) | Should -HaveCount 0
            }
        }

        It 'skips missing scripts and unsupported years rather than inventing support' {
            InModuleScope Shmuelie.VisualStudio {
                Mock Test-Path { $false }
                @(Get-InstalledVsVersion) | Should -HaveCount 0
                $instance = $script:DeveloperInstances[0].PSObject.Copy()
                $instance.installationVersion = '19.0.100.1'
                Mock Invoke-VsWhere { @($instance) }
                Mock Test-Path { throw 'Unsupported year must not inspect a script.' }
                @(Get-InstalledVsVersion) | Should -HaveCount 0
            }
        }

        It 'rejects malformed installation metadata <Case>' -ForEach @(
            @{ Case = 'invalid version'; Field = 'installationVersion'; Value = 'invalid' }
            @{ Case = 'relative path'; Field = 'installationPath'; Value = 'relative' }
            @{ Case = 'missing path'; Field = 'installationPath'; Value = $null }
        ) {
            InModuleScope Shmuelie.VisualStudio -Parameters @{ Field = $Field; Value = $Value } {
                param($Field, $Value)
                $instance = $script:DeveloperInstances[0].PSObject.Copy()
                $instance.$Field = $Value
                Mock Invoke-VsWhere { @($instance) }
                { Get-InstalledVsVersion } | Should -Throw '*invalid installation metadata*'
            }
        }

        It 'returns nothing only for successful empty discovery' {
            InModuleScope Shmuelie.VisualStudio {
                Mock Invoke-VsWhere { @() }
                @(Get-InstalledVsVersion) | Should -HaveCount 0
            }
        }

        It 'propagates discovery and filesystem failures' {
            InModuleScope Shmuelie.VisualStudio {
                Mock Invoke-VsWhere { throw 'Discovery fixture failure' }
                { Get-InstalledVsVersion } | Should -Throw '*Discovery fixture failure*'
                Mock Invoke-VsWhere { $script:DeveloperInstances }
                Mock Test-Path { throw 'Filesystem fixture failure' }
                { Get-InstalledVsVersion } | Should -Throw '*Filesystem fixture failure*'
            }
        }
    }

    Context 'when the platform is not Windows' {
        It 'throws before attempting discovery' {
            InModuleScope Shmuelie.VisualStudio {
                Mock Test-IsWindowsPlatform { $false }
                Mock Invoke-VsWhere { throw 'vswhere side effect' }

                { Get-InstalledVsVersion } | Should -Throw '*Get-InstalledVsVersion is only supported on Windows.*'
                Should -Invoke Invoke-VsWhere -Times 0
            }
        }
    }
}

Describe 'Start-DevShell' {
    BeforeAll {
        $script:StartFixtures = @(
            New-VsTestInstallation $TestDrive 'Latest exact instance' '18.2.100.1' 2026
            New-VsTestInstallation $TestDrive 'Chosen instance' '17.10.100.1' 2022
            New-VsTestInstallation $TestDrive 'Older edition' '17.9.100.1' 2022
        )
        InModuleScope Shmuelie.VisualStudio -Parameters @{ Fixtures = $script:StartFixtures } {
            param($Fixtures)
            $script:StartInstallations = $Fixtures
        }
    }

        Describe 'Set-VS current-session commands' {
            BeforeAll {
                $script:YearFixture = New-VsTestInstallation $TestDrive
                InModuleScope Shmuelie.VisualStudio -Parameters @{ Fixture = $script:YearFixture } {
                    param($Fixture)
                    $script:YearInstallation = $Fixture
                }
            }
            BeforeEach {
                InModuleScope Shmuelie.VisualStudio {
                    Mock Test-IsWindowsPlatform { $true }
                    Mock Get-VsDeveloperInstallation { $script:YearInstallation }
                    Mock Invoke-VsWhere { throw 'Unexpected native discovery.' }
                    Mock Invoke-VsEnvironmentCapture { throw 'Unexpected native initialization.' }
                    Mock Initialize-VsDeveloperEnvironment {}
                    Mock Invoke-DevShellProcess { throw 'Set-VS must not launch an interactive shell.' }
                }
            }

            It 'initializes year <Year> with compatible x86 defaults and no interactive shell' -ForEach @(
                @{ Year = 2017 }, @{ Year = 2019 }, @{ Year = 2022 }, @{ Year = 2026 }
            ) {
                InModuleScope Shmuelie.VisualStudio -Parameters @{ Year = $Year } {
                    param($Year)
                    $requestedYear = $Year
                    & "Set-VS$Year" -Confirm:$false
                    Should -Invoke Get-VsDeveloperInstallation -Times 1 -Exactly -ParameterFilter { $Year -eq $requestedYear }
                    Should -Invoke Initialize-VsDeveloperEnvironment -Times 1 -Exactly -ParameterFilter {
                        $Installation.InstallationPath -eq $script:YearInstallation.InstallationPath -and
                        $Architecture -eq 'x86' -and $HostArchitecture -eq 'x86'
                    }
                    Should -Invoke Invoke-DevShellProcess -Times 0
                }
            }

            It 'preserves both parameter names and aliases for year <Year>' -ForEach @(
                @{ Year = 2017 }, @{ Year = 2019 }, @{ Year = 2022 }, @{ Year = 2026 }
            ) {
                InModuleScope Shmuelie.VisualStudio -Parameters @{ Year = $Year } {
                    param($Year)
                    $command = Get-Command "Set-VS$Year"
                    $command.Parameters.Architecture.Aliases | Should -Contain 'Arch'
                    $command.Parameters.HostArchitecture.Aliases | Should -Contain 'HostArch'
                    $command.Parameters.Keys | Should -Contain 'WhatIf'
                    $command.Parameters.Keys | Should -Contain 'Confirm'
                    & "Set-VS$Year" -Architecture arm -HostArchitecture amd64 -Confirm:$false
                    & "Set-VS$Year" -Arch arm64 -HostArch x86 -Confirm:$false
                    Should -Invoke Initialize-VsDeveloperEnvironment -Times 1 -Exactly -ParameterFilter {
                        $Architecture -eq 'arm' -and $HostArchitecture -eq 'amd64'
                    }
                    Should -Invoke Initialize-VsDeveloperEnvironment -Times 1 -Exactly -ParameterFilter {
                        $Architecture -eq 'arm64' -and $HostArchitecture -eq 'x86'
                    }
                }
            }

            It 'accepts target <Target> and host <HostArch> independently' -ForEach @(
                @{ Target = 'x86'; HostArch = 'x86' }
                @{ Target = 'amd64'; HostArch = 'amd64' }
                @{ Target = 'arm'; HostArch = 'x86' }
                @{ Target = 'arm64'; HostArch = 'arm64' }
                @{ Target = 'arm64'; HostArch = 'amd64' }
            ) {
                InModuleScope Shmuelie.VisualStudio -Parameters @{ Target = $Target; RequestedHost = $HostArch } {
                    param($Target, $RequestedHost)
                    Set-VS2022 -Architecture $Target -HostArchitecture $RequestedHost
                    Should -Invoke Initialize-VsDeveloperEnvironment -Times 1 -Exactly -ParameterFilter {
                        $Architecture -eq $Target -and $HostArchitecture -eq $RequestedHost
                    }
                }
            }

            It 'rejects invalid architecture <Case> for every wrapper before discovery' -ForEach @(
                @{ Case = 'target'; Arguments = @{ Architecture = 'sparc' } }
                @{ Case = 'host'; Arguments = @{ HostArchitecture = 'arm' } }
            ) {
                InModuleScope Shmuelie.VisualStudio -Parameters @{ Arguments = $Arguments } {
                    param($Arguments)
                    foreach ($year in @(2017, 2019, 2022, 2026)) {
                        { & "Set-VS$year" @Arguments } | Should -Throw
                    }
                    Should -Invoke Get-VsDeveloperInstallation -Times 0
                    Should -Invoke Initialize-VsDeveloperEnvironment -Times 0
                }
            }

            It 'does not initialize any year under WhatIf' {
                InModuleScope Shmuelie.VisualStudio {
                    foreach ($year in @(2017, 2019, 2022, 2026)) { & "Set-VS$year" -WhatIf }
                    Should -Invoke Initialize-VsDeveloperEnvironment -Times 0
                    Should -Invoke Invoke-VsEnvironmentCapture -Times 0
                    Should -Invoke Invoke-DevShellProcess -Times 0
                }
            }

            It 'reports missing installations and native failures without falling back' {
                InModuleScope Shmuelie.VisualStudio {
                    Mock Get-VsDeveloperInstallation { @() }
                    { Set-VS2019 } | Should -Throw '*No complete, launchable Visual Studio 2019*'
                    Should -Invoke Initialize-VsDeveloperEnvironment -Times 0
                    Mock Get-VsDeveloperInstallation { $script:YearInstallation }
                    Mock Initialize-VsDeveloperEnvironment { throw 'Unsupported target host combination fixture' }
                    { Set-VS2022 -Arch arm64 -HostArch x86 } | Should -Throw '*Unsupported target host combination fixture*'
                    Should -Invoke Initialize-VsDeveloperEnvironment -Times 1 -Exactly
                }
            }

            It 'rejects every year off Windows before discovery' {
                InModuleScope Shmuelie.VisualStudio {
                    Mock Test-IsWindowsPlatform { $false }
                    foreach ($year in @(2017, 2019, 2022, 2026)) {
                        { & "Set-VS$year" } | Should -Throw "*Set-VS$year is only supported on Windows.*"
                    }
                    Should -Invoke Get-VsDeveloperInstallation -Times 0
                    Should -Invoke Initialize-VsDeveloperEnvironment -Times 0
                }
            }
        }

        Describe 'Visual Studio confirmation gates' {
            It 'declined Confirm for <Command> performs zero initialization and process launches' -ForEach @(
                @{ Command = 'Set-VS2022' }
                @{ Command = 'Start-DevShell' }
            ) {
                $fixture = New-VsTestInstallation $TestDrive
                $hostFixture = [VsTestDecliningHost]::new()
                $runspace = [runspacefactory]::CreateRunspace($hostFixture)
                $pipeline = [powershell]::Create()
                try {
                    $runspace.Open()
                    $pipeline.Runspace = $runspace
                    $null = $pipeline.AddScript({
                        param($manifest, $installation, $command)
                        $module = Import-Module $manifest -Force -PassThru
                        & $module {
                            param($installation)
                            $script:ConfirmationInstallation = $installation
                            function script:Get-VsDeveloperInstallation { param($Year) $script:ConfirmationInstallation }
                            function script:Test-IsWindowsPlatform { $true }
                            function script:Get-VsCleanChildEnvironment { throw 'Declined launch built a child environment.' }
                            function script:Initialize-VsDeveloperEnvironment { throw 'Declined request initialized.' }
                            function script:Invoke-DevShellProcess { throw 'Declined request launched.' }
                            function script:Invoke-VsWhere { throw 'Unexpected discovery.' }
                        } $installation
                        & $command -Confirm
                    }).AddArgument($script:ModuleManifest).AddArgument($fixture).AddArgument($Command)
                    @($pipeline.Invoke()) | Should -HaveCount 0
                    $pipeline.HadErrors | Should -BeFalse -Because ($pipeline.Streams.Error -join '; ')
                    $hostFixture.Interface.Prompts | Should -Be 1
                } finally {
                    $pipeline.Dispose()
                    $runspace.Dispose()
                }
            }
        }

        Describe 'Visual Studio environment identity' {
            BeforeAll { $script:IdentityInstallation = New-VsTestInstallation $TestDrive }

            It 'recognizes an uninitialized environment without treating unrelated state as a toolset' {
                InModuleScope Shmuelie.VisualStudio -Parameters @{ Installation = $script:IdentityInstallation } {
                    param($Installation)
                    Test-VsEnvironmentIdentity $Installation amd64 x86 @{ PATH = 'unrelated'; CUSTOM = 'retained' } | Should -BeFalse
                }
            }

            It 'accepts exact identity including normalized x64 markers and path separators' {
                InModuleScope Shmuelie.VisualStudio -Parameters @{ Installation = $script:IdentityInstallation } {
                    param($Installation)
                    foreach ($activeArchitecture in @('amd64', 'x64')) {
                        $environment = @{
                            VSCMD_VER = '17.0.0'
                            VSINSTALLDIR = $Installation.InstallationPath.ToUpperInvariant() + [IO.Path]::DirectorySeparatorChar
                            VSCMD_ARG_TGT_ARCH = $activeArchitecture
                            VSCMD_ARG_HOST_ARCH = $activeArchitecture
                        }
                        Test-VsEnvironmentIdentity $Installation amd64 amd64 $environment | Should -BeTrue
                    }
                }
            }

            It 'rejects conflicting or incomplete identity <Case>' -ForEach @(
                @{ Case = 'wrong instance'; Field = 'VSINSTALLDIR'; Value = 'C:\different fixture' }
                @{ Case = 'relative instance'; Field = 'VSINSTALLDIR'; Value = 'relative' }
                @{ Case = 'wrong major'; Field = 'VSCMD_VER'; Value = '16.11.1' }
                @{ Case = 'malformed version'; Field = 'VSCMD_VER'; Value = 'bad' }
                @{ Case = 'missing version'; Field = 'VSCMD_VER'; Value = $null }
                @{ Case = 'wrong target'; Field = 'VSCMD_ARG_TGT_ARCH'; Value = 'arm64' }
                @{ Case = 'wrong host'; Field = 'VSCMD_ARG_HOST_ARCH'; Value = 'amd64' }
                @{ Case = 'missing target'; Field = 'VSCMD_ARG_TGT_ARCH'; Value = $null }
                @{ Case = 'missing host'; Field = 'VSCMD_ARG_HOST_ARCH'; Value = $null }
            ) {
                InModuleScope Shmuelie.VisualStudio -Parameters @{ Installation = $script:IdentityInstallation; Field = $Field; Value = $Value } {
                    param($Installation, $Field, $Value)
                    $environment = @{
                        VSCMD_VER = '17.10.0'
                        VSINSTALLDIR = $Installation.InstallationPath
                        VSCMD_ARG_TGT_ARCH = 'amd64'
                        VSCMD_ARG_HOST_ARCH = 'x86'
                    }
                    $environment[$Field] = $Value
                    { Test-VsEnvironmentIdentity $Installation amd64 x86 $environment } | Should -Throw '*fresh Start-DevShell*'
                }
            }
        }

        Describe 'Visual Studio environment application' {
            BeforeAll { $script:ApplyInstallation = New-VsTestInstallation $TestDrive }
            BeforeEach {
                InModuleScope Shmuelie.VisualStudio {
                    $script:SavedApplyEnvironment = Get-VsEnvironmentSnapshot
                    $script:SavedApplyOriginals = Get-Variable VsEnvironmentOriginals -Scope Script -ValueOnly -ErrorAction SilentlyContinue
                    # Remove only identity markers during these controlled process tests.
                    foreach ($name in @('VSCMD_VER', 'VSINSTALLDIR', 'VSCMD_ARG_TGT_ARCH', 'VSCMD_ARG_HOST_ARCH')) {
                        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
                    }
                    Mock Invoke-VsEnvironmentCapture { throw 'Native initializer must be explicitly scripted.' }
                    Mock Invoke-VsWhere { throw 'Unexpected discovery.' }
                    Mock Invoke-DevShellProcess { throw 'Unexpected interactive child.' }
                }
            }
            AfterEach {
                InModuleScope Shmuelie.VisualStudio {
                    foreach ($name in @([Environment]::GetEnvironmentVariables('Process').Keys) + @($script:SavedApplyEnvironment.Keys) | Sort-Object -Unique) {
                        [Environment]::SetEnvironmentVariable($name, $script:SavedApplyEnvironment[$name], 'Process')
                    }
                    $script:VsEnvironmentOriginals = $script:SavedApplyOriginals
                }
            }

            It 'applies the validated environment losslessly and repeats as a no-op' {
                InModuleScope Shmuelie.VisualStudio -Parameters @{ Installation = $script:ApplyInstallation } {
                    param($Installation)
                    $location = (Get-Location).Path
                    $modulePath = $env:PSModulePath
                    $script:CapturedFixture = Get-VsEnvironmentSnapshot
                    $script:CapturedFixture.VSCMD_VER = '17.10.123.4'
                    $script:CapturedFixture.VSINSTALLDIR = $Installation.InstallationPath
                    $script:CapturedFixture.VSCMD_ARG_TGT_ARCH = 'amd64'
                    $script:CapturedFixture.VSCMD_ARG_HOST_ARCH = 'x86'
                    $script:CapturedFixture.PATH = 'C:\synthetic tools;C:\clean'
                    $script:CapturedFixture.SHMUELIE_TEST_LOSSLESS = " left=right==`nsecond`r`nUnicode Ω 日本語 "
                    $script:CapturedFixture.PSModulePath = 'must not replace module search path'
                    $script:CapturedFixture.SHMUELIE_VS_CAPTURE = 'must not leak transport'
                    $unrelated = $env:TEMP
                    Mock Invoke-VsEnvironmentCapture { $script:CapturedFixture }
                    Initialize-VsDeveloperEnvironment $Installation amd64 x86
                    $env:PATH | Should -BeExactly 'C:\synthetic tools;C:\clean'
                    $env:SHMUELIE_TEST_LOSSLESS | Should -BeExactly " left=right==`nsecond`r`nUnicode Ω 日本語 "
                    $env:VSINSTALLDIR | Should -BeExactly $Installation.InstallationPath
                    $env:VSCMD_ARG_HOST_ARCH | Should -Be 'x86'
                    $env:PSModulePath | Should -BeExactly $modulePath
                    $env:SHMUELIE_VS_CAPTURE | Should -BeExactly $script:SavedApplyEnvironment.SHMUELIE_VS_CAPTURE
                    $env:TEMP | Should -BeExactly $unrelated
                    (Get-Location).Path | Should -Be $location
                    Initialize-VsDeveloperEnvironment $Installation amd64 x86
                    Should -Invoke Invoke-VsEnvironmentCapture -Times 1 -Exactly
                }
            }

            It 'rejects conflicting parent state before invoking the initializer' {
                InModuleScope Shmuelie.VisualStudio -Parameters @{ Installation = $script:ApplyInstallation } {
                    param($Installation)
                    $env:VSCMD_VER = '16.11.0'
                    $before = Get-VsEnvironmentSnapshot
                    { Initialize-VsDeveloperEnvironment $Installation amd64 x86 } | Should -Throw '*fresh Start-DevShell*'
                    Should -Invoke Invoke-VsEnvironmentCapture -Times 0
                    foreach ($key in $before.Keys) {
                        [Environment]::GetEnvironmentVariable($key, 'Process') | Should -BeExactly $before[$key]
                    }
                }
            }

            It 'leaves every environment entry unchanged when capture fails' {
                InModuleScope Shmuelie.VisualStudio -Parameters @{ Installation = $script:ApplyInstallation } {
                    param($Installation)
                    $before = Get-VsEnvironmentSnapshot
                    Mock Invoke-VsEnvironmentCapture { throw 'Native exit 42 fixture' }
                    { Initialize-VsDeveloperEnvironment $Installation amd64 x86 } | Should -Throw '*Native exit 42 fixture*'
                    $after = Get-VsEnvironmentSnapshot
                    $after.Count | Should -Be $before.Count
                    foreach ($key in $before.Keys) { $after[$key] | Should -BeExactly $before[$key] }
                }
            }

            It 'rejects a capture with no identity markers before applying any values' {
                InModuleScope Shmuelie.VisualStudio -Parameters @{ Installation = $script:ApplyInstallation } {
                    param($Installation)
                    $before = Get-VsEnvironmentSnapshot
                    Mock Invoke-VsEnvironmentCapture { @{ SHMUELIE_TEST_PARTIAL = 'must not appear' } }
                    { Initialize-VsDeveloperEnvironment $Installation amd64 x86 } |
                        Should -Throw '*did not establish the requested environment*'
                    $after = Get-VsEnvironmentSnapshot
                    $after.Count | Should -Be $before.Count
                    foreach ($key in $before.Keys) { $after[$key] | Should -BeExactly $before[$key] }
                }
            }

            It 'rejects invalid captured identity <Case> before applying any values' -ForEach @(
                @{ Case = 'absent'; Field = 'VSCMD_VER'; Value = $null }
                @{ Case = 'wrong version'; Field = 'VSCMD_VER'; Value = '18.1' }
                @{ Case = 'wrong instance'; Field = 'VSINSTALLDIR'; Value = 'C:\wrong fixture' }
                @{ Case = 'wrong target'; Field = 'VSCMD_ARG_TGT_ARCH'; Value = 'arm' }
                @{ Case = 'wrong host'; Field = 'VSCMD_ARG_HOST_ARCH'; Value = 'amd64' }
            ) {
                InModuleScope Shmuelie.VisualStudio -Parameters @{ Installation = $script:ApplyInstallation; Field = $Field; Value = $Value } {
                    param($Installation, $Field, $Value)
                    $before = Get-VsEnvironmentSnapshot
                    $captured = @{
                        VSCMD_VER = '17.10.1'; VSINSTALLDIR = $Installation.InstallationPath
                        VSCMD_ARG_TGT_ARCH = 'amd64'; VSCMD_ARG_HOST_ARCH = 'x86'
                        SHMUELIE_TEST_PARTIAL = 'must not appear'; PATH = 'must not appear'
                    }
                    $captured[$Field] = $Value
                    Mock Invoke-VsEnvironmentCapture { $captured }
                    { Initialize-VsDeveloperEnvironment $Installation amd64 x86 } | Should -Throw
                    $after = Get-VsEnvironmentSnapshot
                    $after.Count | Should -Be $before.Count
                    foreach ($key in $before.Keys) { $after[$key] | Should -BeExactly $before[$key] }
                    $after.ContainsKey('SHMUELIE_TEST_PARTIAL') | Should -BeFalse
                }
            }
        }
    BeforeEach {
        InModuleScope Shmuelie.VisualStudio {
            Mock Test-IsWindowsPlatform { $true }
            Mock Get-VsDeveloperInstallation { $script:StartInstallations }
            Mock Invoke-VsWhere { throw 'Unexpected rediscovery.' }
            Mock Invoke-DeveloperVsWhere { throw 'Unexpected native discovery.' }
            Mock Get-InstalledVsVersion { throw 'Start must select an exact installation once.' }
            Mock Invoke-VsEnvironmentCapture { throw 'Parent must not initialize.' }
            Mock Get-CleanLoginPath { 'C:\clean;C:\installer' }
            Mock Get-VsCleanChildEnvironment { @{ PATH = 'C:\clean;C:\installer'; VSCMD_VER = $null } }
            $script:SeenLaunch = $null
            Mock Invoke-DevShellProcess {
                $script:SeenLaunch = @{ Environment = $Environment; Arguments = $ArgumentList; Directory = $WorkingDirectory }
            }
        }
    }
    Context 'when the platform is Windows' {
        It 'launches the chosen exact instance once with defaults and unchanged parent state' {
            InModuleScope Shmuelie.VisualStudio {
                $before = Get-VsEnvironmentSnapshot
                $location = (Get-Location).Path
                Start-DevShell -Version 2022
                $script:SeenLaunch.Environment.VSDEV_VERSION | Should -Be '2022'
                $script:SeenLaunch.Environment.VSDEV_ARCH | Should -Be 'amd64'
                $script:SeenLaunch.Environment.VSDEV_HOSTARCH | Should -Be 'amd64'
                $script:SeenLaunch.Environment.PATH | Should -Be 'C:\clean;C:\installer'
                $script:SeenLaunch.Directory | Should -Be $location
                $arguments = $script:SeenLaunch.Arguments
                $arguments | Should -Contain '-NoExit'
                $arguments | Should -Not -Contain '-NoProfile'
                $bootstrap = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($arguments[-1]))
                $data = [regex]::Match($bootstrap, "FromBase64String\('([^']+)'\)").Groups[1].Value
                $request = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($data)) | ConvertFrom-Json
                $request.Installation.InstallationPath | Should -Be $script:StartInstallations[1].InstallationPath
                $request.Installation.Version | Should -Be '17.10.100.1'
                $request.WorkingDirectory | Should -Be $location
                $request.ModuleManifest | Should -Be (Join-Path (Get-Module Shmuelie.VisualStudio).ModuleBase 'Shmuelie.VisualStudio.psd1')
            }
        }

        It 'does not mutate any parent environment entry during launch' {
            InModuleScope Shmuelie.VisualStudio {
                $before = Get-VsEnvironmentSnapshot
                $location = (Get-Location).Path
                Start-DevShell -Version 2022
                $after = Get-VsEnvironmentSnapshot
                $after.Count | Should -Be $before.Count
                foreach ($key in $before.Keys) { $after[$key] | Should -BeExactly $before[$key] }
                (Get-Location).Path | Should -Be $location
                Should -Invoke Get-VsDeveloperInstallation -Times 1 -Exactly
                Should -Invoke Invoke-DevShellProcess -Times 1 -Exactly
                Should -Invoke Invoke-VsEnvironmentCapture -Times 0
                Should -Invoke Invoke-VsWhere -Times 0
            }
        }

        It 'defaults to the latest installed version' {
            InModuleScope Shmuelie.VisualStudio {
                Start-DevShell
                $script:SeenLaunch.Environment.VSDEV_VERSION | Should -Be '2026'
            }
        }

        It 'passes distinct target and host choices without substitution' {
            InModuleScope Shmuelie.VisualStudio {
                Start-DevShell 2022 -Arch arm -HostArch x86
                $script:SeenLaunch.Environment.VSDEV_ARCH | Should -Be 'arm'
                $script:SeenLaunch.Environment.VSDEV_HOSTARCH | Should -Be 'x86'
            }
        }

        It 'rejects unavailable and empty selections without launching or choosing another version' {
            InModuleScope Shmuelie.VisualStudio {
                { Start-DevShell 2019 } | Should -Throw '*2019 is not available*2026, 2022*'
                Mock Get-VsDeveloperInstallation { @() }
                { Start-DevShell } | Should -Throw '*No complete, launchable*'
                Should -Invoke Invoke-DevShellProcess -Times 0
                Should -Invoke Get-VsCleanChildEnvironment -Times 0
            }
        }

        It 'rejects invalid architecture <Case> before discovery' -ForEach @(
            @{ Case = 'target'; Arguments = @{ Arch = 'sparc' } }
            @{ Case = 'host'; Arguments = @{ HostArch = 'arm' } }
        ) {
            InModuleScope Shmuelie.VisualStudio -Parameters @{ Arguments = $Arguments } {
                param($Arguments)
                { Start-DevShell @Arguments } | Should -Throw
                Should -Invoke Get-VsDeveloperInstallation -Times 0
                Should -Invoke Invoke-DevShellProcess -Times 0
            }
        }

        It 'rejects non-filesystem working directories' {
            InModuleScope Shmuelie.VisualStudio {
                Push-Location Env:\
                try {
                    { Start-DevShell 2022 } | Should -Throw '*filesystem working directory*'
                    Should -Invoke Invoke-DevShellProcess -Times 0
                } finally { Pop-Location }
            }
        }

        It 'does not launch a child process under WhatIf' {
            InModuleScope Shmuelie.VisualStudio {
                Start-DevShell -Version 2022 -WhatIf
                Should -Invoke Invoke-DevShellProcess -Times 0
                Should -Invoke Get-VsCleanChildEnvironment -Times 0
                Should -Invoke Invoke-VsEnvironmentCapture -Times 0
            }
        }

        It 'propagates process failures without changing parent state' {
            InModuleScope Shmuelie.VisualStudio {
                $before = Get-VsEnvironmentSnapshot
                Mock Invoke-DevShellProcess { throw 'Child exited with code 7 fixture' }
                { Start-DevShell 2022 } | Should -Throw '*code 7 fixture*'
                foreach ($key in $before.Keys) {
                    [Environment]::GetEnvironmentVariable($key, 'Process') | Should -BeExactly $before[$key]
                }
            }
        }

        It 'completes supported installed years by prefix without provider lookup' {
            InModuleScope Shmuelie.VisualStudio {
                Mock Get-InstalledVsVersion { 2017; 2019; 2022; 2026 }
                $attribute = (Get-Command Start-DevShell).Parameters.Version.Attributes |
                    Where-Object { $_ -is [System.Management.Automation.ArgumentCompleterAttribute] }
                @(& $attribute.ScriptBlock 'Start-DevShell' 'Version' '202' $null @{}) | Should -Be @('2022', '2026')
            }
        }
    }

    Context 'when the platform is not Windows' {
        It 'throws before launching pwsh' {
            InModuleScope Shmuelie.VisualStudio {
                Mock Test-IsWindowsPlatform { $false }
                { Start-DevShell } | Should -Throw '*Start-DevShell is only supported on Windows.*'
                Should -Invoke Get-VsDeveloperInstallation -Times 0
                Should -Invoke Invoke-DevShellProcess -Times 0
            }
        }
    }

}

Describe 'Developer bootstrap with controlled synthetic profiles' -Skip:(-not $IsWindows) {
    It 'runs profiles before bootstrap for <Scenario> with bounded native fixtures' -ForEach @(
        @{ Scenario = 'uninitialized'; ProfileMode = 'none'; NativeExit = 0; ExpectedExit = 0 }
        @{ Scenario = 'matching profile'; ProfileMode = 'matching'; NativeExit = 0; ExpectedExit = 0 }
        @{ Scenario = 'conflicting architecture profile'; ProfileMode = 'conflict'; NativeExit = 0; ExpectedExit = 1 }
        @{ Scenario = 'conflicting instance profile'; ProfileMode = 'instance'; NativeExit = 0; ExpectedExit = 1 }
        @{ Scenario = 'native initialization failure'; ProfileMode = 'none'; NativeExit = 42; ExpectedExit = 1 }
    ) {
        $root = New-Item -ItemType Directory -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $staged = New-Item -ItemType Directory -Path (Join-Path $root.FullName 'Staged module')
        Copy-Item -Path (Join-Path (Split-Path $script:ModuleManifest) '*.ps*1') -Destination $staged.FullName
        $selected = New-VsTestInstallation $root.FullName 'Selected exact instance'
        $other = New-VsTestInstallation $root.FullName 'Other same-year instance'
        foreach ($installation in @($selected, $other)) {
            Set-Content -LiteralPath $installation.ScriptPath -Encoding ascii -Value @(
                '@echo off'
                ('if {0} NEQ 0 (echo synthetic bootstrap failure 1>&2 & exit /b {0})' -f $NativeExit)
                'set /a SHMUELIE_TEST_INITIALIZATIONS+=1'
                'set "VSCMD_VER=17.10.123.4"'
                ('set "VSINSTALLDIR={0}"' -f $installation.InstallationPath)
                # cmd batch parameters split unquoted equals signs; this is
                # the same -arch=value spelling consumed by official VsDevCmd.
                'set "VSCMD_ARG_TGT_ARCH=%3"'
                'set "VSCMD_ARG_HOST_ARCH=%5"'
                'exit /b 0'
            )
        }
        $installationForProfile = if ($ProfileMode -eq 'instance') { $other } else { $selected }
        $fixtureData = $installationForProfile | ConvertTo-Json -Compress
        $override = @'

$script:SyntheticInstallation = '__FIXTURE__' | ConvertFrom-Json
function Get-VsDeveloperInstallation {
    param($Year)
    $script:SyntheticInstallation
}
function Invoke-VsWhere { throw 'Synthetic bootstrap must never use installed Visual Studio.' }
function Invoke-DeveloperVsWhere { throw 'Synthetic bootstrap must never launch vswhere.' }
'@
        Add-Content -LiteralPath (Join-Path $staged.FullName 'Shmuelie.VisualStudio.psm1') -Value (
            $override.Replace('__FIXTURE__', $fixtureData.Replace("'", "''"))
        )
        $profiles = @()
        foreach ($name in @('AllUsersAllHosts', 'AllUsersCurrentHost', 'CurrentUserAllHosts', 'CurrentUserCurrentHost')) {
            $path = Join-Path $root.FullName ($name + '.ps1')
            Set-Content -LiteralPath $path -Value ('$script:ProfileEvents += ''' + $name + '''')
            $profiles += $path
        }
        if ($ProfileMode -in @('matching', 'instance')) {
            Add-Content -LiteralPath $profiles[-1] -Value 'Shmuelie.VisualStudio\Set-VS2022 -Architecture $env:VSDEV_ARCH -HostArchitecture $env:VSDEV_HOSTARCH -Confirm:$false'
        } elseif ($ProfileMode -eq 'conflict') {
            Add-Content -LiteralPath $profiles[-1] -Value 'Shmuelie.VisualStudio\Set-VS2022 -Arch x86 -HostArch x86 -Confirm:$false'
        }
        # Profiles may legitimately change location; bootstrap must restore the
        # caller's requested directory after every synthetic profile completed.
        Add-Content -LiteralPath $profiles[-1] -Value 'Set-Location -LiteralPath $env:SHMUELIE_TEST_PROFILE_DIRECTORY'
        $driverPath = Join-Path $root.FullName 'synthetic-profile-driver.ps1'
        # These are actual controlled scripts, NOT the user's normal profiles.
        # -NoProfile is a test safety boundary. The public launch-argument test
        # separately verifies that production does not suppress normal profiles.
        Set-Content -LiteralPath $driverPath -Value @'
param($RequestJson)
$ErrorActionPreference = 'Stop'
$request = $RequestJson | ConvertFrom-Json
$module = Import-Module $request.Manifest -PassThru -Force -ErrorAction Stop
$arguments = & $module {
    param($installation, $directory)
    Get-VsDevShellArguments -Installation $installation -Architecture arm64 -HostArchitecture amd64 -WorkingDirectory $directory
} $request.Installation $request.Directory
$bootstrap = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($arguments[-1]))
$script:ProfileEvents = @()
foreach ($profilePath in $request.Profiles) { . $profilePath }
& ([scriptblock]::Create($bootstrap))
$script:ProfileEvents += 'interactive boundary'
@{
    Events = $script:ProfileEvents
    Count = $env:SHMUELIE_TEST_INITIALIZATIONS
    Installation = $env:VSINSTALLDIR
    Target = $env:VSCMD_ARG_TGT_ARCH
    HostArchitecture = $env:VSCMD_ARG_HOST_ARCH
    Directory = (Get-Location).Path
    VersionHandoff = $env:VSDEV_VERSION
} | ConvertTo-Json -Compress
'@
        $request = @{
            Manifest = Join-Path $staged.FullName 'Shmuelie.VisualStudio.psd1'
            Installation = $selected
            Directory = $root.FullName
            Profiles = $profiles
        } | ConvertTo-Json -Depth 5 -Compress
        $before = [Environment]::GetEnvironmentVariables('Process')
        $result = Invoke-VsTestChild -Arguments @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $driverPath, $request) -Environment @{
            VSCMD_VER = $null; VSINSTALLDIR = $null
            VSCMD_ARG_TGT_ARCH = $null; VSCMD_ARG_HOST_ARCH = $null
            SHMUELIE_TEST_INITIALIZATIONS = $null
            SHMUELIE_TEST_PROFILE_DIRECTORY = $staged.FullName
            VSDEV_VERSION = '2022'; VSDEV_ARCH = 'arm64'; VSDEV_HOSTARCH = 'amd64'
        } -WorkingDirectory $root.FullName
        $result.ExitCode | Should -Be $ExpectedExit -Because $result.Error
        if ($ExpectedExit -eq 0) {
            $data = $result.Output | ConvertFrom-Json
            $data.Events | Should -Be @('AllUsersAllHosts', 'AllUsersCurrentHost', 'CurrentUserAllHosts', 'CurrentUserCurrentHost', 'interactive boundary')
            $data.Count | Should -Be '1'
            $data.Installation | Should -BeExactly $selected.InstallationPath
            $data.Target | Should -Be 'arm64'
            $data.HostArchitecture | Should -Be 'amd64'
            $data.Directory | Should -BeExactly $root.FullName
            $data.VersionHandoff | Should -Be '2022'
            $result.Error | Should -BeNullOrEmpty
        } else {
            $result.Output | Should -Not -Match 'interactive boundary'
            $result.Error | Should -Match 'Cannot initialize Visual Studio developer shell'
            if ($NativeExit) { $result.Error | Should -Match 'code 42.*synthetic bootstrap failure' }
            else { $result.Error | Should -Match 'fresh Start-DevShell' }
        }
        $after = [Environment]::GetEnvironmentVariables('Process')
        $after.Count | Should -Be $before.Count
        foreach ($key in $before.Keys) { $after[$key] | Should -BeExactly $before[$key] }
    }

    It 'transports executable-looking request fields as data instead of interpolated source' {
        $fixture = New-VsTestInstallation $TestDrive "quoted ' instance Ω"
        $directory = "C:\literal ' ; Write-Error injected; Ω"
        $arguments = & (Get-Module Shmuelie.VisualStudio) {
            param($installation, $directory)
            Get-VsDevShellArguments $installation arm64 x86 $directory
        } $fixture $directory
        $arguments | Should -Be @('-NoLogo', '-NoExit', '-EncodedCommand', $arguments[-1])
        $bootstrap = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($arguments[-1]))
        $bootstrap | Should -Not -Match 'Write-Error injected'
        $encodedData = [regex]::Match($bootstrap, "FromBase64String\('([^']+)'\)").Groups[1].Value
        $request = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encodedData)) | ConvertFrom-Json
        $request.Installation.InstallationPath | Should -BeExactly $fixture.InstallationPath
        $request.Installation.ScriptPath | Should -BeExactly $fixture.ScriptPath
        $request.WorkingDirectory | Should -BeExactly $directory
        $request.Architecture | Should -Be 'arm64'
        $request.HostArchitecture | Should -Be 'x86'
        $request.ModuleManifest | Should -BeExactly $script:ModuleManifest
    }
}

Describe 'Environment application rollback fault injection' -Skip:(-not $IsWindows) {
    It 'rolls back already-applied entries when a later process environment write fails' {
        $driver = Join-Path $TestDrive 'rollback isolated adapter.ps1'
        # Pester cannot mock a static .NET call. Resolve the short Environment
        # type to a deterministic adapter BEFORE importing a fresh module, only
        # in this bounded child. System.Environment and the parent are untouched.
        Set-Content -LiteralPath $driver -Value @'
param($Manifest)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @"
using System;
using System.Collections;
using System.Collections.Generic;
public static class VsRollbackEnvironment {
    public static readonly Hashtable Values = new Hashtable(StringComparer.OrdinalIgnoreCase) {
        { "A_FIXTURE_CHANGED", "original" }, { "B_FIXTURE_FAILURE", "original failure" }
    };
    public static readonly List<string> Writes = new List<string>();
    public static IDictionary GetEnvironmentVariables(string target) { return Values; }
    public static void SetEnvironmentVariable(string key, string value, string target) {
        Writes.Add(key + ":" + value);
        if (key == "B_FIXTURE_FAILURE" && value == "changed failure")
            throw new InvalidOperationException("synthetic transient process write failure");
        if (value == null) Values.Remove(key); else Values[key] = value;
    }
}
"@
$accelerators = [psobject].Assembly.GetType('System.Management.Automation.TypeAccelerators')
$accelerators::Add('Environment', [VsRollbackEnvironment])
try {
    $module = Import-Module $Manifest -PassThru -Force
    & $module {
        function script:Invoke-VsEnvironmentCapture {
            @{
                A_FIXTURE_CHANGED = 'changed'; B_FIXTURE_FAILURE = 'changed failure'
                VSCMD_VER = '17.10.1'; VSINSTALLDIR = 'C:\synthetic fixture'
                VSCMD_ARG_TGT_ARCH = 'amd64'; VSCMD_ARG_HOST_ARCH = 'x86'
            }
        }
    }
    $failure = $null
    try {
        & $module {
            Initialize-VsDeveloperEnvironment -Installation @{
                Version = '17.10.1'; InstallationPath = 'C:\synthetic fixture'
            } -Architecture amd64 -HostArchitecture x86
        }
    } catch { $failure = "$_" }
    @{ Failure = $failure; Values = [VsRollbackEnvironment]::Values; Writes = [VsRollbackEnvironment]::Writes } |
        ConvertTo-Json -Depth 5 -Compress
} finally {
    $null = $accelerators::Remove('Environment')
}
'@
        $result = Invoke-VsTestChild -Arguments @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $driver, $script:ModuleManifest)
        $result.ExitCode | Should -Be 0 -Because $result.Error
        $data = $result.Output | ConvertFrom-Json -AsHashtable
        $data.Failure | Should -Match 'synthetic transient process write failure'
        $data.Values.Count | Should -Be 2
        $data.Values.A_FIXTURE_CHANGED | Should -BeExactly 'original'
        $data.Values.B_FIXTURE_FAILURE | Should -BeExactly 'original failure'
        $data.Writes[0] | Should -BeExactly 'A_FIXTURE_CHANGED:changed'
        $data.Writes[1] | Should -BeExactly 'B_FIXTURE_FAILURE:changed failure'
        $data.Writes | Should -Contain 'A_FIXTURE_CHANGED:original'
        $data.Writes | Should -Contain 'B_FIXTURE_FAILURE:original failure'
    }
}

Describe 'Native nested-shell process contract' -Skip:(-not $IsWindows) {
    It 'inherits the console transports arguments and environment and waits for exit <ExitCode>' -ForEach @(
        @{ ExitCode = 0 }, @{ ExitCode = 7 }
    ) {
        $root = New-Item -ItemType Directory -Path (Join-Path $TestDrive "process $ExitCode")
        $inner = Join-Path $root.FullName 'child arguments.ps1'
        Set-Content -LiteralPath $inner -Value @'
param([string]$Value)
@{
    Value = $Value
    Override = $env:SHMUELIE_TEST_PROCESS_OVERRIDE
    Removed = $env:SHMUELIE_TEST_PROCESS_REMOVE
    Directory = (Get-Location).Path
} | ConvertTo-Json -Compress
exit ([int]$env:SHMUELIE_TEST_PROCESS_EXIT)
'@
        $outer = Join-Path $root.FullName 'outer bounded driver.ps1'
        Set-Content -LiteralPath $outer -Value @'
param($Manifest, $Inner, $Directory, $ExitCode)
$ErrorActionPreference = 'Stop'
$module = Import-Module $Manifest -PassThru -ErrorAction Stop
try {
    & $module {
        param($inner, $directory, $exitCode)
        Invoke-DevShellProcess -Environment @{
            SHMUELIE_TEST_PROCESS_OVERRIDE = 'child only'
            SHMUELIE_TEST_PROCESS_REMOVE = $null
            SHMUELIE_TEST_PROCESS_EXIT = $exitCode
        } -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $inner, " spaces = 'quotes' Ω`nsecond ") -WorkingDirectory $directory
    } $Inner $Directory $ExitCode
    'AFTER CHILD'
} catch {
    [Console]::Error.WriteLine($_)
    exit 9
}
'@
        $result = Invoke-VsTestChild -Arguments @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $outer,
            $script:ModuleManifest, $inner, $root.FullName, "$ExitCode"
        ) -Environment @{ SHMUELIE_TEST_PROCESS_REMOVE = 'inherited must disappear' } -WorkingDirectory $root.FullName
        $lines = @($result.Output.Trim() -split '\r?\n')
        $data = $lines[0] | ConvertFrom-Json
        $data.Value | Should -BeExactly " spaces = 'quotes' Ω`nsecond "
        $data.Override | Should -BeExactly 'child only'
        $data.Removed | Should -BeNullOrEmpty
        $data.Directory | Should -BeExactly $root.FullName
        if ($ExitCode -eq 0) {
            $result.ExitCode | Should -Be 0 -Because $result.Error
            $lines | Should -HaveCount 2
            $lines[1] | Should -Be 'AFTER CHILD'
        } else {
            $result.ExitCode | Should -Be 9
            $result.Error | Should -Match 'developer shell exited with code 7'
            $lines | Should -HaveCount 1
        }
    }
}

Describe 'Developer vswhere boundaries' {
        BeforeAll {
            InModuleScope Shmuelie.VisualStudio {
                function script:Invoke-DeveloperWhereFixture {
                    [CmdletBinding()]
                    param($products, $format, [switch]$utf8)
                    throw 'Fixture must be mocked.'
                }
            }
        }
        BeforeEach {
            $script:SavedDiscoveryExitCode = $global:LASTEXITCODE
            InModuleScope Shmuelie.VisualStudio {
                Mock Get-VsInstallerPath { (Get-Location).Path }
                Mock Test-Path { $true }
                Mock Invoke-MSBuildVsWhere { throw 'MSBuild filter must not be used.' }
                Mock Invoke-DeveloperWhereFixture { $global:LASTEXITCODE = 0; '[]' }
            }
        }
        AfterEach { $global:LASTEXITCODE = $script:SavedDiscoveryExitCode }
        AfterAll {
            InModuleScope Shmuelie.VisualStudio {
                Remove-Item Function:\Invoke-DeveloperWhereFixture -ErrorAction Stop
            }
        }

        It 'requests all release products without requiring the MSBuild component' {
            InModuleScope Shmuelie.VisualStudio {
                Invoke-DeveloperVsWhere -Path Invoke-DeveloperWhereFixture | Should -Be '[]'
                Should -Invoke Invoke-DeveloperWhereFixture -Times 1 -Exactly -ParameterFilter {
                    $products -eq '*' -and $format -eq 'json' -and $utf8
                }
                Mock Invoke-DeveloperWhereFixture { $global:LASTEXITCODE = 5; 'synthetic discovery failure' }
                { Invoke-DeveloperVsWhere -Path Invoke-DeveloperWhereFixture } | Should -Throw '*code 5*synthetic discovery failure*'
            }
        }

        It 'distinguishes successful empty developer discovery from missing installer and native failures' {
            InModuleScope Shmuelie.VisualStudio {
                Mock Invoke-DeveloperVsWhere { '[]' }
                @(Invoke-VsWhere) | Should -HaveCount 0
                Mock Get-VsInstallerPath { $null }
                { Invoke-VsWhere } | Should -Throw '*vswhere.exe was not found*'
                Mock Get-VsInstallerPath { (Get-Location).Path }
                Mock Test-Path { $false }
                { Invoke-VsWhere } | Should -Throw '*vswhere.exe was not found*'
                Mock Test-Path { $true }
                Mock Invoke-DeveloperVsWhere { throw 'Native discovery exit 5 fixture' }
                { Invoke-VsWhere } | Should -Throw '*Native discovery exit 5 fixture*'
            }
        }

        It 'rejects malformed developer JSON <Case>' -ForEach @(
            @{ Case = 'empty'; Json = '' }
            @{ Case = 'invalid'; Json = 'invalid json' }
            @{ Case = 'null'; Json = 'null' }
            @{ Case = 'object'; Json = '{}' }
        ) {
            InModuleScope Shmuelie.VisualStudio -Parameters @{ Json = $Json } {
                param($Json)
                Mock Invoke-DeveloperVsWhere { $Json }
                { Invoke-VsWhere } | Should -Throw
            }
        }
    }

    Describe 'Synthetic native VsDevCmd capture' -Skip:(-not $IsWindows) {
        BeforeAll { $script:NativeInstallation = New-VsTestInstallation $TestDrive 'Native space fixture' }
        BeforeEach {
            $script:NativeLosslessBefore = $env:SHMUELIE_TEST_NATIVE_LOSSLESS
        }
        AfterEach {
            [Environment]::SetEnvironmentVariable('SHMUELIE_TEST_NATIVE_LOSSLESS', $script:NativeLosslessBefore, 'Process')
        }

        It 'captures a synthetic batch environment with spaces equals newlines and Unicode without mutating its parent' {
            $fixture = $script:NativeInstallation
            Set-Content -LiteralPath $fixture.ScriptPath -Encoding ascii -Value @(
                '@echo off'
                'if not "%1"=="-no_logo" exit /b 81'
                'if not "%2"=="-arch" exit /b 82'
                'if not "%3"=="arm64" exit /b 83'
                'if not "%4"=="-host_arch" exit /b 84'
                'if not "%5"=="amd64" exit /b 85'
                'set "VSCMD_VER=17.10.123.4"'
                ('set "VSINSTALLDIR={0}"' -f $fixture.InstallationPath)
                'set "VSCMD_ARG_TGT_ARCH=arm64"'
                'set "VSCMD_ARG_HOST_ARCH=x64"'
                'set "SHMUELIE_TEST_BATCH_VALUE=left=right== with spaces"'
                'exit /b 0'
            )
            $env:SHMUELIE_TEST_NATIVE_LOSSLESS = " left==right`nsecond`r`nΩ 日本語 "
            InModuleScope Shmuelie.VisualStudio -Parameters @{ Installation = $fixture } {
                param($Installation)
                $before = Get-VsEnvironmentSnapshot
                $location = (Get-Location).Path
                $result = Invoke-VsEnvironmentCapture $Installation arm64 amd64
                $result.SHMUELIE_TEST_BATCH_VALUE | Should -BeExactly 'left=right== with spaces'
                $result.SHMUELIE_TEST_NATIVE_LOSSLESS | Should -BeExactly " left==right`nsecond`r`nΩ 日本語 "
                $result.VSINSTALLDIR | Should -BeExactly $Installation.InstallationPath
                $result.VSCMD_ARG_TGT_ARCH | Should -Be 'arm64'
                $result.VSCMD_ARG_HOST_ARCH | Should -Be 'x64'
                $result.ContainsKey('SHMUELIE_VS_CAPTURE') | Should -BeFalse
                $after = Get-VsEnvironmentSnapshot
                $after.Count | Should -Be $before.Count
                foreach ($key in $before.Keys) { $after[$key] | Should -BeExactly $before[$key] }
                (Get-Location).Path | Should -Be $location
            }
        }

        It 'reports native failure code and diagnostics and does not accept partial output' {
            Set-Content -LiteralPath $script:NativeInstallation.ScriptPath -Encoding ascii -Value @(
                '@echo off', 'echo synthetic diagnostic 1>&2', 'set "SHMUELIE_TEST_PARTIAL=must not escape"', 'exit /b 42'
            )
            InModuleScope Shmuelie.VisualStudio -Parameters @{ Installation = $script:NativeInstallation } {
                param($Installation)
                $before = Get-VsEnvironmentSnapshot
                { Invoke-VsEnvironmentCapture $Installation x86 x86 } | Should -Throw '*code 42*synthetic diagnostic*'
                foreach ($key in $before.Keys) {
                    [Environment]::GetEnvironmentVariable($key, 'Process') | Should -BeExactly $before[$key]
                }
                $env:SHMUELIE_TEST_PARTIAL | Should -BeNullOrEmpty
            }
        }

        It 'rejects a successful native exit that did not produce an environment' {
            Set-Content -LiteralPath $script:NativeInstallation.ScriptPath -Encoding ascii -Value '@exit 0'
            InModuleScope Shmuelie.VisualStudio -Parameters @{ Installation = $script:NativeInstallation } {
                param($Installation)
                { Invoke-VsEnvironmentCapture $Installation x86 x86 } | Should -Throw '*returned no environment*'
            }
        }

        It 'rejects unsafe script path <Case> before executing a batch file' -ForEach @(
            @{ Case = 'percent expansion'; Suffix = '%expanded%' }
            @{ Case = 'delayed expansion'; Suffix = '!expanded!' }
            @{ Case = 'command separator'; Suffix = '&echo unexpected' }
            @{ Case = 'pipe'; Suffix = '|echo unexpected' }
            @{ Case = 'caret'; Suffix = '^escaped' }
            @{ Case = 'quote'; Suffix = '"quoted' }
            @{ Case = 'newline'; Suffix = "`nnew" }
            @{ Case = 'relative'; Suffix = $null }
        ) {
            $unsafe = $script:NativeInstallation.PSObject.Copy()
            $unsafe.ScriptPath = if ($Suffix) { Join-Path $TestDrive ("unsafe" + $Suffix + '.bat') } else { 'relative.bat' }
            InModuleScope Shmuelie.VisualStudio -Parameters @{ Installation = $unsafe } {
                param($Installation)
                Mock Test-Path { throw 'Unsafe path reached filesystem validation.' }
                { Invoke-VsEnvironmentCapture $Installation amd64 amd64 } | Should -Throw '*Cannot safely initialize Visual Studio*'
                Should -Invoke Test-Path -Times 0
            }
        }

        It 'rejects a missing initialization script without executing a native process' {
            $missing = $script:NativeInstallation.PSObject.Copy()
            $missing.ScriptPath = Join-Path $TestDrive 'missing.bat'
            InModuleScope Shmuelie.VisualStudio -Parameters @{ Installation = $missing } {
                param($Installation)
                { Invoke-VsEnvironmentCapture $Installation x86 x86 } | Should -Throw '*Cannot safely initialize Visual Studio*'
            }
        }
    }

    Describe 'Clean nested developer shell environment' {
        It 'restores original toolset values and clean PATH without altering parent variables' {
            InModuleScope Shmuelie.VisualStudio {
                $savedOriginals = Get-Variable VsEnvironmentOriginals -Scope Script -ValueOnly -ErrorAction SilentlyContinue
                $before = Get-VsEnvironmentSnapshot
                try {
                    $script:VsEnvironmentOriginals = @{
                        INCLUDE = 'original include'
                        LIB = $null
                        SHMUELIE_TEST_CUSTOM_TOOLSET = 'original custom'
                    }
                    Mock Get-VsEnvironmentSnapshot {
                        @{
                            PATH = 'loaded toolset'
                            VSCMD_VER = '17.10'
                            VSINSTALLDIR = 'C:\loaded fixture'
                            VCToolsInstallDir = 'C:\loaded tools'
                            WindowsSdkDir = 'C:\loaded SDK'
                            DevEnvDir = 'C:\loaded IDE'
                            __DOTNET_ADD_64BIT = '1'
                            INCLUDE = 'loaded include'
                            LIB = 'loaded lib'
                            SHMUELIE_TEST_UNRELATED = 'unrelated'
                        }
                    }
                    Mock Get-CleanLoginPath { 'C:\clean;C:\installer' }
                    $result = Get-VsCleanChildEnvironment
                    $result.PATH | Should -BeExactly 'C:\clean;C:\installer'
                    $result.INCLUDE | Should -BeExactly 'original include'
                    $result.ContainsKey('LIB') | Should -BeTrue
                    $result.LIB | Should -BeNullOrEmpty
                    $result.SHMUELIE_TEST_CUSTOM_TOOLSET | Should -BeExactly 'original custom'
                    $result.ContainsKey('SHMUELIE_TEST_UNRELATED') | Should -BeFalse
                    foreach ($name in @('VSCMD_VER', 'VSINSTALLDIR', 'VCToolsInstallDir', 'WindowsSdkDir', 'DevEnvDir', '__DOTNET_ADD_64BIT')) {
                        $result.ContainsKey($name) | Should -BeTrue
                        $configured = [Environment]::GetEnvironmentVariable($name, 'User')
                        if ($null -eq $configured) { $configured = [Environment]::GetEnvironmentVariable($name, 'Machine') }
                        $result[$name] | Should -BeExactly $configured
                    }
                    foreach ($key in $before.Keys) {
                        [Environment]::GetEnvironmentVariable($key, 'Process') | Should -BeExactly $before[$key]
                    }
                    Should -Invoke Get-CleanLoginPath -Times 1 -Exactly
                } finally {
                    $script:VsEnvironmentOriginals = $savedOriginals
                }
            }
        }
    }
