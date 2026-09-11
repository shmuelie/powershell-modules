#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.2.0' }

BeforeDiscovery {
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules' 'Shmuelie.DotNet' 'Shmuelie.DotNet.psd1') -Force
}

BeforeAll {
    $script:repoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent
    $script:modulePath = Join-Path $script:repoRoot 'modules' 'Shmuelie.DotNet' 'Shmuelie.DotNet.psd1'
    Import-Module $script:modulePath
    $script:originalExitCode = $global:LASTEXITCODE
    & (Get-Module Shmuelie.DotNet) {
        function script:dotnet { }
    }
}

AfterAll {
    $global:LASTEXITCODE = $script:originalExitCode
    Remove-Module Shmuelie.DotNet -Force -ErrorAction SilentlyContinue
}

Describe 'Shmuelie.DotNet module contract' {
    It 'exports SDK installation and the four tool commands without dependencies or aliases' {
        $module = Get-Module Shmuelie.DotNet
        $expected = @('Get-DotNetTool', 'Install-DotNetSdk', 'Install-DotNetTool', 'Uninstall-DotNetTool', 'Update-DotNetTool')
        @($module.ExportedFunctions.Keys | Sort-Object) | Should -Be $expected
        $module.ExportedAliases.Count | Should -Be 0
        $module.RequiredModules.Count | Should -Be 0
        $manifest = Test-ModuleManifest $script:modulePath
        $module.Version | Should -Be $manifest.Version
        @($manifest.ExportedFunctions.Keys | Sort-Object) | Should -Be $expected
    }

    It 'provides comment-based help for <Command>' -ForEach @(
        @{ Command = 'Get-DotNetTool' }
        @{ Command = 'Install-DotNetSdk' }
        @{ Command = 'Install-DotNetTool' }
        @{ Command = 'Update-DotNetTool' }
        @{ Command = 'Uninstall-DotNetTool' }
    ) {
        $help = Get-Help "Shmuelie.DotNet\$Command" -Full
        $help.Synopsis | Should -Not -BeNullOrEmpty
        $help.examples.example | Should -Not -BeNullOrEmpty
    }

    It 'imports in isolation without invoking dotnet or loading Utilities' {
        $originalRoot = $env:SHMUELIE_DOTNET_TEST_ROOT
        try {
            $env:SHMUELIE_DOTNET_TEST_ROOT = $script:repoRoot
            $result = & pwsh -NoProfile -NonInteractive -Command {
                $ErrorActionPreference = 'Stop'
                function global:dotnet { throw 'Import must not invoke dotnet.' }
                Import-Module (Join-Path $env:SHMUELIE_DOTNET_TEST_ROOT 'modules' 'Shmuelie.DotNet' 'Shmuelie.DotNet.psd1') -WarningAction Stop
                if (Get-Module Shmuelie.Utilities) { throw 'Utilities was loaded.' }
                $PSModuleAutoLoadingPreference = 'None'
                if (Get-Command Invoke-InLocation -ErrorAction SilentlyContinue) { throw 'Private helper was exported.' }
                (Get-Module Shmuelie.DotNet).ExportedFunctions.Count
            }
            $LASTEXITCODE | Should -Be 0
            $result | Should -Be 5
        } finally {
            $env:SHMUELIE_DOTNET_TEST_ROOT = $originalRoot
        }
    }

    It 'preserves Utilities parameter sets, aliases, binding, output types, and ShouldProcess metadata' {
        $originalRoot = $env:SHMUELIE_DOTNET_TEST_ROOT
        try {
            $env:SHMUELIE_DOTNET_TEST_ROOT = $script:repoRoot
            $result = & pwsh -NoProfile -NonInteractive -Command {
                $ErrorActionPreference = 'Stop'
                function Get-Contract {
                    param($Command)
                    $binding = $Command.ScriptBlock.Attributes |
                        Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] }
                    [ordered]@{
                        DefaultParameterSet = $Command.DefaultParameterSet
                        OutputTypes = @($Command.OutputType.Name)
                        SupportsShouldProcess = $binding.SupportsShouldProcess
                        ConfirmImpact = [string]$binding.ConfirmImpact
                        ParameterSets = @(
                            $Command.ParameterSets | Sort-Object Name | ForEach-Object {
                                [ordered]@{
                                    Name = $_.Name
                                    IsDefault = $_.IsDefault
                                    Parameters = @(
                                        $_.Parameters | Sort-Object Name | ForEach-Object {
                                            [ordered]@{
                                                Name = $_.Name
                                                Type = $_.ParameterType.FullName
                                                Position = $_.Position
                                                Mandatory = $_.IsMandatory
                                                Pipeline = $_.ValueFromPipeline
                                                PipelineByPropertyName = $_.ValueFromPipelineByPropertyName
                                                RemainingArguments = $_.ValueFromRemainingArguments
                                                Aliases = @($_.Aliases)
                                            }
                                        }
                                    )
                                }
                            }
                        )
                    } | ConvertTo-Json -Depth 10 -Compress
                }
                $root = Join-Path $env:SHMUELIE_DOTNET_TEST_ROOT 'modules'
                $canonical = Import-Module (Join-Path $root 'Shmuelie.DotNet' 'Shmuelie.DotNet.psd1') -PassThru
                $legacy = Import-Module (Join-Path $root 'Shmuelie.Utilities' 'Shmuelie.Utilities.psd1') -PassThru -WarningAction Stop
                foreach ($name in @('Get-DotNetTool', 'Install-DotNetTool', 'Update-DotNetTool', 'Uninstall-DotNetTool')) {
                    if ((Get-Contract $canonical.ExportedFunctions[$name]) -cne (Get-Contract $legacy.ExportedFunctions[$name])) {
                        throw "Contract mismatch for $name"
                    }
                }
                'Compatible'
            }
            $LASTEXITCODE | Should -Be 0
            $result | Should -BeExactly 'Compatible'
        } finally {
            $env:SHMUELIE_DOTNET_TEST_ROOT = $originalRoot
        }
    }

    It 'builds a self-contained publishable module with private helpers' {
        $artifact = & (Join-Path $script:repoRoot 'build' 'Build-Module.ps1') -Module Shmuelie.DotNet -OutputPath $TestDrive
        foreach ($name in @('Shmuelie.DotNet.psd1', 'Shmuelie.DotNet.psm1', 'DotNetHelpers.ps1', 'SdkHelpers.ps1', 'PrivateHelpers.ps1', 'README.md', 'CHANGELOG.md')) {
            Join-Path $artifact.FullName $name | Should -Exist
        }
        $manifest = Test-ModuleManifest (Join-Path $artifact.FullName 'Shmuelie.DotNet.psd1')
        $manifest.ExportedFunctions.Count | Should -Be 5
        $manifest.RequiredModules.Count | Should -Be 0
    }
}

Describe 'Install-DotNetSdk' {
    InModuleScope Shmuelie.DotNet {
        BeforeEach {
            $script:sdkRoot = Join-Path $TestDrive ('SDK with spaces ' + [guid]::NewGuid().ToString('N'))
            $script:localAppData = Join-Path $TestDrive 'local'
            $script:platform = if ($IsWindows) { 'Windows' } else { 'Linux' }
            $script:processPath = 'original-process-path'
            $script:userPath = 'original-user-path'
            $script:invocations = [Collections.Generic.List[object]]::new()
            Push-Location $TestDrive
            Mock Get-DotNetSdkPlatform { $script:platform }
            Mock Get-DotNetSdkEnvironment {
                param($Name, $Target)
                if ($Name -eq 'LOCALAPPDATA') { return $script:localAppData }
                if ($Target -eq 'User') { return $script:userPath }
                $script:processPath
            }
            Mock Set-DotNetSdkEnvironment {}
            Mock Get-DotNetSdkHostArchitecture { 'x64' }
            Mock Assert-DotNetSdkCompatibility {}
            Mock Get-DotNetSdkInstallerFile {
                param($Name, $Directory)
                $file = Join-Path $Directory $Name
                Set-Content -LiteralPath $file -Value 'mock installer only'
                $file
            }
            Mock Test-DotNetSdkInstaller {}
            Mock Get-Command { @{ Source = (Join-Path $TestDrive 'synthetic-bash') } } -ParameterFilter { $Name -eq 'bash' }
            Mock Invoke-WebRequest { throw 'No real network operations permitted.' }
            Mock Invoke-DotNetSdkProcess {
                param($FilePath, $Arguments, $Environment)
                $script:invocations.Add(@{ FilePath = $FilePath; Arguments = $Arguments; Environment = $Environment })
                if ('-DryRun' -in $Arguments -or '--dry-run' -in $Arguments) {
                    return 'dotnet-install: Repeatable invocation: ./dotnet-install.sh --version "8.0.412" --architecture "x64"'
                }
                $versionFlag = if ('-Version' -in $Arguments) { '-Version' } else { '--version' }
                $dirFlag = if ('-InstallDir' -in $Arguments) { '-InstallDir' } else { '--install-dir' }
                $version = $Arguments[[array]::IndexOf($Arguments, $versionFlag) + 1]
                $directory = $Arguments[[array]::IndexOf($Arguments, $dirFlag) + 1]
                $null = New-Item -ItemType Directory -Path (Join-Path $directory 'sdk' $version) -Force
                Set-Content -LiteralPath (Join-Path $directory 'sdk' $version 'dotnet.dll') -Value 'synthetic SDK'
                $hostName = if ($script:platform -eq 'Windows') { 'dotnet.exe' } else { 'dotnet' }
                Set-Content -LiteralPath (Join-Path $directory $hostName) -Value 'synthetic host'
                'Installation finished successfully.'
            }
        }

        AfterEach {
            try {
                @(Get-ChildItem -LiteralPath $TestDrive -Directory -Filter '.dotnet-install-*' -Force) | Should -HaveCount 0
                Should -Invoke Invoke-WebRequest -Times 0 -Exactly
            } finally {
                Pop-Location
            }
        }

        It 'installs an exact SDK with typed output, discrete arguments and no PATH changes' {
            $result = Install-DotNetSdk -Version 8.0.412 -Architecture x64 -InstallDir $script:sdkRoot -Confirm:$false
            $result.PSTypeNames[0] | Should -Be 'DotNetSdkInstallResult'
            $result.RequestedVersion | Should -Be '8.0.412'
            $result.RequestedChannel | Should -BeNullOrEmpty
            $result.ResolvedVersion | Should -Be '8.0.412'
            $result.ResolvedChannel | Should -Be '8.0'
            $result.InstallDir | Should -Be $script:sdkRoot
            $result.Architecture | Should -Be 'x64'
            $result.Status | Should -Be 'Installed'
            $result.ProcessPathChanged | Should -BeFalse
            $result.UserPathChanged | Should -BeFalse
            $script:invocations | Should -HaveCount 1
            $arguments = $script:invocations[0].Arguments
            $arguments | Should -Contain $script:sdkRoot
            @($arguments | Where-Object { $_ -in '-NoPath', '--no-path' }) | Should -HaveCount 1
            $arguments | Should -Not -Contain '-Command'
            $script:invocations[0].Environment.TMPDIR | Should -BeLike "$TestDrive*"
            Should -Invoke Set-DotNetSdkEnvironment -Times 0 -Exactly
        }

        It 'skips a matching SDK without downloads or a second installer invocation' {
            $null = Install-DotNetSdk -Version 8.0.412 -Architecture x64 -InstallDir $script:sdkRoot -Confirm:$false
            $result = Install-DotNetSdk -Version 8.0.412 -Architecture x64 -InstallDir $script:sdkRoot -Confirm:$false
            $result.Status | Should -Be 'AlreadyInstalled'
            Should -Invoke Get-DotNetSdkInstallerFile -Times 1 -Exactly
            Should -Invoke Invoke-DotNetSdkProcess -Times 1 -Exactly
        }

        It 'passes discrete <Selection> installer arguments on <Platform>' -ForEach @(
            @{ Platform = 'Linux'; Selection = 'Version' }
            @{ Platform = 'macOS'; Selection = 'Version' }
            @{ Platform = 'Linux'; Selection = 'Channel' }
            @{ Platform = 'macOS'; Selection = 'Channel' }
        ) {
            $script:platform = $Platform
            $parameters = if ($Selection -eq 'Version') { @{ Version = '8.0.412' } } else { @{ Channel = '8.0'; Quality = 'GA' } }
            $result = Install-DotNetSdk @parameters -Architecture x64 -InstallDir $script:sdkRoot -Confirm:$false
            $result.Status | Should -Be 'Installed'
            $result.ResolvedVersion | Should -Be '8.0.412'
            $script:invocations | Should -HaveCount $(if ($Selection -eq 'Version') { 1 } else { 2 })
            foreach ($invocation in $script:invocations) {
                $invocation.FilePath | Should -Be (Join-Path $TestDrive 'synthetic-bash')
                $invocation.Arguments[0] | Should -Be (Join-Path $invocation.Environment.TMPDIR 'dotnet-install.sh')
                $invocation.Arguments[1..7] | Should -Be @(
                    '--architecture', 'x64', '--install-dir', $script:sdkRoot,
                    '--no-path', '--zip-path', (Join-Path $invocation.Environment.TMPDIR 'sdk.tar.gz')
                )
            }
            $script:invocations[-1].Arguments[8..9] | Should -Be @('--version', '8.0.412')
            if ($Selection -eq 'Channel') {
                $script:invocations[0].Arguments[8..12] | Should -Be @('--channel', '8.0', '--dry-run', '--quality', 'GA')
            }
        }

        It 'preserves other SDK versions in the installation directory' {
            $null = Install-DotNetSdk -Version 8.0.412 -Architecture x64 -InstallDir $script:sdkRoot -Confirm:$false
            $result = Install-DotNetSdk -Version 9.0.303 -Architecture x64 -InstallDir $script:sdkRoot -Confirm:$false
            $result.Status | Should -Be 'Installed'
            Join-Path $script:sdkRoot 'sdk' '8.0.412' 'dotnet.dll' | Should -Exist
        }

        It 'preserves newer non-versioned files when installing an older SDK alongside it' {
            $null = Install-DotNetSdk -Version 9.0.303 -Architecture x64 -InstallDir $script:sdkRoot -Confirm:$false
            $null = Install-DotNetSdk -Version 8.0.412 -Architecture x64 -InstallDir $script:sdkRoot -Confirm:$false
            @($script:invocations[1].Arguments | Where-Object { $_ -in '-SkipNonVersionedFiles', '--skip-non-versioned-files' }) | Should -HaveCount 1
        }

        It 'preserves the host across feature bands even when the requested SDK number is higher' {
            $null = Install-DotNetSdk -Version 8.0.120 -Architecture x64 -InstallDir $script:sdkRoot -Confirm:$false
            $runtime = Join-Path $script:sdkRoot 'host' 'fxr' '8.0.20'
            $null = New-Item -ItemType Directory -Path $runtime -Force
            $null = Install-DotNetSdk -Version 8.0.400 -Architecture x64 -InstallDir $script:sdkRoot -Confirm:$false
            @($script:invocations[1].Arguments | Where-Object { $_ -in '-SkipNonVersionedFiles', '--skip-non-versioned-files' }) | Should -HaveCount 1
            Should -Invoke Assert-DotNetSdkCompatibility -Times 1 -Exactly -ParameterFilter { $Version -eq '8.0.400' }
        }

        It 'preserves a runtime-only host and verifies SDK compatibility' {
            $null = New-Item -ItemType Directory -Path (Join-Path $script:sdkRoot 'host' 'fxr' '8.0.20') -Force
            $hostName = if ($script:platform -eq 'Windows') { 'dotnet.exe' } else { 'dotnet' }
            Set-Content -LiteralPath (Join-Path $script:sdkRoot $hostName) -Value 'runtime-only host'
            $result = Install-DotNetSdk -Version 8.0.400 -Architecture x64 -InstallDir $script:sdkRoot -Confirm:$false
            $result.Status | Should -Be 'Installed'
            @($script:invocations[0].Arguments | Where-Object { $_ -in '-SkipNonVersionedFiles', '--skip-non-versioned-files' }) | Should -HaveCount 1
            Should -Invoke Assert-DotNetSdkCompatibility -Times 1 -Exactly
        }

        It 'checks an older host with a newer SDK instead of silently assuming compatibility' {
            $null = Install-DotNetSdk -Version 8.0.100 -Architecture x64 -InstallDir $script:sdkRoot -Confirm:$false
            $result = Install-DotNetSdk -Version 10.0.100 -Architecture x64 -InstallDir $script:sdkRoot -Confirm:$false
            $result.Status | Should -Be 'Installed'
            @($script:invocations[1].Arguments | Where-Object { $_ -in '-SkipNonVersionedFiles', '--skip-non-versioned-files' }) | Should -HaveCount 1
            Should -Invoke Assert-DotNetSdkCompatibility -Times 1 -Exactly -ParameterFilter { $Version -eq '10.0.100' }
        }

        It 'reports incompatible hosts without success or PATH writes, including subsequent calls' {
            $null = Install-DotNetSdk -Version 8.0.100 -Architecture x64 -InstallDir $script:sdkRoot -Confirm:$false
            Mock Assert-DotNetSdkCompatibility { throw 'host incompatible; use a separate InstallDir' } -ParameterFilter { $Version -eq '10.0.100' }
            { Install-DotNetSdk -Version 10.0.100 -Architecture x64 -InstallDir $script:sdkRoot -AddToProcessPath -Confirm:$false } | Should -Throw '*host incompatible*'
            { Install-DotNetSdk -Version 10.0.100 -Architecture x64 -InstallDir $script:sdkRoot -AddToProcessPath -Confirm:$false } | Should -Throw '*host incompatible*'
            Should -Invoke Set-DotNetSdkEnvironment -Times 0 -Exactly
        }

        It 'resolves channel <Channel> with quality <Quality> and pins the installation' -ForEach @(
            @{ Channel = '8.0'; Quality = 'GA' }
            @{ Channel = '8.0.4xx'; Quality = 'preview' }
            @{ Channel = '10.0'; Quality = 'daily' }
            @{ Channel = 'LTS'; Quality = $null }
            @{ Channel = 'STS'; Quality = $null }
        ) {
            $parameters = @{ Channel = $Channel; Architecture = 'x64'; InstallDir = $script:sdkRoot; Confirm = $false }
            if ($Quality) { $parameters.Quality = $Quality }
            $result = Install-DotNetSdk @parameters
            $result.RequestedChannel | Should -Be $Channel
            $result.Quality | Should -Be ([string]$Quality)
            $result.ResolvedVersion | Should -Be '8.0.412'
            $script:invocations | Should -HaveCount 2
            $script:invocations[0].Arguments | Should -Contain $Channel
            $script:invocations[1].Arguments | Should -Contain '8.0.412'
            @($script:invocations[1].Arguments | Where-Object { $_ -in '-Channel', '--channel', '-Quality', '--quality' }) | Should -HaveCount 0
        }

        It 'resolves channels again but avoids reinstalling their matching SDK' {
            $null = Install-DotNetSdk -Version 8.0.412 -Architecture x64 -InstallDir $script:sdkRoot -Confirm:$false
            $result = Install-DotNetSdk -Channel 8.0 -Architecture x64 -InstallDir $script:sdkRoot -Confirm:$false
            $result.Status | Should -Be 'AlreadyInstalled'
            $script:invocations | Should -HaveCount 2
        }

        It 'previews all opt-in operations without downloading, installing or changing PATH' {
            $script:platform = 'Windows'
            $result = Install-DotNetSdk -Channel LTS -Architecture x64 -InstallDir $script:sdkRoot -AddToUserPath -WhatIf
            $result.Status | Should -Be 'Skipped'
            $result.ResolvedVersion | Should -BeNullOrEmpty
            $result.ProcessPathChanged | Should -BeFalse
            $result.UserPathChanged | Should -BeFalse
            $script:sdkRoot | Should -Not -Exist
            Should -Invoke Get-DotNetSdkInstallerFile -Times 0 -Exactly
            Should -Invoke Invoke-DotNetSdkProcess -Times 0 -Exactly
            Should -Invoke Set-DotNetSdkEnvironment -Times 0 -Exactly
        }

        It 'uses the official Windows default without honoring ambient installer overrides' {
            $script:platform = 'Windows'
            $result = Install-DotNetSdk -Version 8.0.412 -Architecture amd64 -WhatIf
            $result.InstallDir | Should -Be (Join-Path $script:localAppData 'Microsoft' 'dotnet')
            $result.Architecture | Should -Be 'x64'
        }

        It 'uses the official Unix default on <Platform>' -ForEach @(@{ Platform = 'Linux' }, @{ Platform = 'macOS' }) {
            $script:platform = $Platform
            $result = Install-DotNetSdk -Version 8.0.412 -Architecture x64 -WhatIf
            $result.InstallDir | Should -Be (Join-Path $HOME '.dotnet')
            Should -Invoke Get-DotNetSdkInstallerFile -Times 0 -Exactly
        }

        It 'uses OS architecture for auto selection' {
            $result = Install-DotNetSdk -Version 8.0.412 -InstallDir $script:sdkRoot -WhatIf
            $result.Architecture | Should -Be ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant())
        }

        It 'rejects <Description> before any mutation' -ForEach @(
            @{ Description = 'Version plus Channel'; Parameters = @{ Version = '8.0.412'; Channel = '8.0' } }
            @{ Description = 'Version plus Quality'; Parameters = @{ Version = '8.0.412'; Quality = 'GA' } }
            @{ Description = 'LTS quality'; Parameters = @{ Channel = 'LTS'; Quality = 'GA' } }
            @{ Description = 'implicit LTS quality'; Parameters = @{ Quality = 'preview' } }
            @{ Description = 'pre-5 quality'; Parameters = @{ Channel = '3.1'; Quality = 'preview' } }
            @{ Description = 'pre-5 feature band'; Parameters = @{ Channel = '3.1.1xx' } }
            @{ Description = 'version command injection'; Parameters = @{ Version = '8.0.412;echo bad' } }
            @{ Description = 'version newline'; Parameters = @{ Version = "8.0.412`n" } }
            @{ Description = 'latest as exact version'; Parameters = @{ Version = 'latest' } }
            @{ Description = 'channel URL'; Parameters = @{ Channel = 'https://example.com' } }
            @{ Description = 'unknown quality'; Parameters = @{ Channel = '8.0'; Quality = 'evil' } }
            @{ Description = 'unknown architecture'; Parameters = @{ Architecture = 'x64;echo bad' } }
        ) {
            { Install-DotNetSdk @Parameters -InstallDir $script:sdkRoot -Confirm:$false } | Should -Throw
            Should -Invoke Get-DotNetSdkInstallerFile -Times 0 -Exactly
            Should -Invoke Invoke-DotNetSdkProcess -Times 0 -Exactly
            Should -Invoke Set-DotNetSdkEnvironment -Times 0 -Exactly
        }

        It 'rejects invalid install directory <BadPath>' -ForEach @(
            @{ BadPath = ' ' }, @{ BadPath = 'sdk*' }, @{ BadPath = "sdk`nother" }, @{ BadPath = 'sdk"other' }, @{ BadPath = 'Env:PATH' }
        ) {
            { Install-DotNetSdk -Version 8.0.412 -InstallDir $BadPath -Confirm:$false } | Should -Throw
            Should -Invoke Get-DotNetSdkInstallerFile -Times 0 -Exactly
        }

        It 'rejects a file as the installation directory' {
            Set-Content -LiteralPath $script:sdkRoot -Value 'not a directory'
            { Install-DotNetSdk -Version 8.0.412 -InstallDir $script:sdkRoot -Confirm:$false } | Should -Throw '*file*'
            Should -Invoke Get-DotNetSdkInstallerFile -Times 0 -Exactly
        }

        It 'fails without mutation for user PATH on <Platform>, even with WhatIf' -ForEach @(
            @{ Platform = 'Linux' }, @{ Platform = 'macOS' }
        ) {
            $script:platform = $Platform
            { Install-DotNetSdk -Version 8.0.412 -InstallDir $script:sdkRoot -AddToUserPath -AddToProcessPath -WhatIf } |
                Should -Throw '*only on Windows*'
            Should -Invoke Get-DotNetSdkInstallerFile -Times 0 -Exactly
            Should -Invoke Invoke-DotNetSdkProcess -Times 0 -Exactly
            Should -Invoke Set-DotNetSdkEnvironment -Times 0 -Exactly
        }

        It 'changes only process PATH when requested' {
            $result = Install-DotNetSdk -Version 8.0.412 -Architecture x64 -InstallDir $script:sdkRoot -AddToProcessPath -Confirm:$false
            $result.ProcessPathChanged | Should -BeTrue
            $result.UserPathChanged | Should -BeFalse
            Should -Invoke Set-DotNetSdkEnvironment -Times 1 -Exactly -ParameterFilter { $Target -eq 'Process' -and $Value.EndsWith('original-process-path') }
            Should -Invoke Set-DotNetSdkEnvironment -Times 0 -Exactly -ParameterFilter { $Target -eq 'User' }
        }

        It 'independently adds user and process PATH for an already installed SDK' {
            $script:platform = 'Windows'
            $null = Install-DotNetSdk -Version 8.0.412 -Architecture x64 -InstallDir $script:sdkRoot -Confirm:$false
            $result = Install-DotNetSdk -Version 8.0.412 -Architecture x64 -InstallDir $script:sdkRoot -AddToUserPath -Confirm:$false
            $result.Status | Should -Be 'AlreadyInstalled'
            $result.UserPathChanged | Should -BeTrue
            $result.ProcessPathChanged | Should -BeTrue
            Should -Invoke Set-DotNetSdkEnvironment -Times 1 -Exactly -ParameterFilter { $Target -eq 'User' -and $Value -eq "$script:sdkRoot;original-user-path" }
            Should -Invoke Set-DotNetSdkEnvironment -Times 1 -Exactly -ParameterFilter { $Target -eq 'Process' -and $Value -eq "$script:sdkRoot;original-process-path" }
        }

        It 'does not duplicate or report changes to Windows case-insensitive PATH entries' {
            $script:platform = 'Windows'
            $script:processPath = "$($script:sdkRoot.ToUpperInvariant())\;keep"
            $script:userPath = "`"$script:sdkRoot`";keep"
            $result = Install-DotNetSdk -Version 8.0.412 -Architecture x64 -InstallDir $script:sdkRoot -AddToUserPath -AddToProcessPath -Confirm:$false
            $result.ProcessPathChanged | Should -BeFalse
            $result.UserPathChanged | Should -BeFalse
            Should -Invoke Set-DotNetSdkEnvironment -Times 0 -Exactly
        }

        It 'cleans staging and throws on <Failure>' -ForEach @(
            @{ Failure = 'download' }
            @{ Failure = 'signature' }
            @{ Failure = 'installer' }
            @{ Failure = 'missing installed SDK' }
            @{ Failure = 'malformed resolution' }
        ) {
            switch ($Failure) {
                'download' { Mock Get-DotNetSdkInstallerFile { throw 'download failed' } }
                'signature' { Mock Test-DotNetSdkInstaller { throw 'signature failed' } }
                'installer' { Mock Invoke-DotNetSdkProcess { throw 'installer failed (exit 1)' } }
                'missing installed SDK' { Mock Invoke-DotNetSdkProcess { 'success without installing' } }
                'malformed resolution' { Mock Invoke-DotNetSdkProcess { 'Repeatable invocation: --version "malicious;command"' } }
            }
            $parameters = if ($Failure -eq 'malformed resolution') { @{ Channel = '8.0' } } else { @{ Version = '8.0.412' } }
            { Install-DotNetSdk @parameters -Architecture x64 -InstallDir $script:sdkRoot -AddToProcessPath -Confirm:$false } | Should -Throw
            Should -Invoke Set-DotNetSdkEnvironment -Times 0 -Exactly
        }

        It 'surfaces persistent PATH failures without process PATH mutation or success output' {
            $script:platform = 'Windows'
            Mock Set-DotNetSdkEnvironment { throw 'persistent PATH denied' } -ParameterFilter { $Target -eq 'User' }
            { Install-DotNetSdk -Version 8.0.412 -Architecture x64 -InstallDir $script:sdkRoot -AddToUserPath -Confirm:$false } |
                Should -Throw '*persistent PATH denied*'
            Should -Invoke Set-DotNetSdkEnvironment -Times 0 -Exactly -ParameterFilter { $Target -eq 'Process' }
        }

        It 'rejects an existing host with a different architecture before downloading' {
            $null = New-Item -ItemType Directory -Path $script:sdkRoot
            $name = if ($script:platform -eq 'Windows') { 'dotnet.exe' } else { 'dotnet' }
            Set-Content -LiteralPath (Join-Path $script:sdkRoot $name) -Value 'different architecture'
            Mock Get-DotNetSdkHostArchitecture { 'arm64' }
            { Install-DotNetSdk -Version 8.0.412 -Architecture x64 -InstallDir $script:sdkRoot -Confirm:$false } | Should -Throw '*different dotnet architecture*'
            Should -Invoke Get-DotNetSdkInstallerFile -Times 0 -Exactly
        }
    }
}

Describe 'SDK environment failure propagation under Continue' {
    It 'terminates on a real .NET environment <Operation> error without success or later PATH writes' -ForEach @(
        @{ Operation = 'Read' }, @{ Operation = 'Write' }
    ) {
        $directory = Join-Path $TestDrive $Operation
        $null = New-Item -ItemType Directory -Path (Join-Path $directory 'sdk' '8.0.412') -Force
        Set-Content -LiteralPath (Join-Path $directory 'sdk' '8.0.412' 'dotnet.dll') -Value 'synthetic SDK'
        Set-Content -LiteralPath (Join-Path $directory 'dotnet.exe') -Value 'synthetic Windows host'
        $shell = [PowerShell]::Create()
        try {
            # A separate runspace has no enclosing Pester try/catch, which would
            # otherwise promote statement-terminating method errors itself.
            $null = $shell.AddScript({
                param($ModulePath, $Directory, $Operation)
                $ErrorActionPreference = 'Continue'
                $global:targets = [Collections.Generic.List[string]]::new()
                $module = Import-Module $ModulePath -PassThru -Force
                & $module {
                    param($Operation)
                    $script:operation = $Operation
                    $script:realGetter = ${function:Get-DotNetSdkEnvironment}
                    $script:realSetter = ${function:Set-DotNetSdkEnvironment}
                    function script:Get-DotNetSdkPlatform { 'Windows' }
                    function script:Get-DotNetSdkHostArchitecture { 'x64' }
                    function script:Assert-DotNetSdkCompatibility {}
                    function script:Get-DotNetSdkInstallerFile { throw 'No downloads permitted.' }
                    function script:Invoke-DotNetSdkProcess { throw 'No processes permitted.' }
                    function script:Get-DotNetSdkEnvironment {
                        param($Name, $Target)
                        if ($script:operation -eq 'Read') {
                            & $script:realGetter -Name 'INVALID_TEST_NAME' -Target ([Enum]::ToObject([EnvironmentVariableTarget], 99))
                        } else { 'existing-path' }
                    }
                    function script:Set-DotNetSdkEnvironment {
                        param($Name, $Value, $Target)
                        $global:targets.Add($Target)
                        # Invalid name fails in .NET validation before any mutation.
                        & $script:realSetter -Name 'INVALID=TEST_NAME' -Value 'unused' -Target Process
                    }
                } $Operation
                Install-DotNetSdk -Version 8.0.412 -Architecture x64 -InstallDir $Directory -AddToUserPath -Confirm:$false
            }.ToString()).AddArgument($script:modulePath).AddArgument($directory).AddArgument($Operation)
            $output = [Collections.Generic.List[psobject]]::new()
            $invocationError = $null
            try {
                $shell.Invoke[psobject]($null, $output)
            } catch [System.Management.Automation.MethodInvocationException] {
                # Catch only the hosting API failure, outside the isolated caller.
                $invocationError = $_
            }
            $output | Should -HaveCount 0
            ($shell.Streams.Error.Count -gt 0 -or $null -ne $invocationError) | Should -BeTrue
            $writes = @($shell.Runspace.SessionStateProxy.GetVariable('targets'))
            if ($Operation -eq 'Write') { $writes | Should -Be @('User') }
            else { $writes | Should -HaveCount 0 }
        } finally {
            $shell.Dispose()
        }
    }
}

Describe 'SDK host compatibility verification' {
    InModuleScope Shmuelie.DotNet {
        BeforeEach {
            Push-Location $TestDrive
            Mock Invoke-DotNetSdkProcess { '10.0.100' }
        }
        AfterEach {
            try {
                @(Get-ChildItem -LiteralPath $TestDrive -Directory -Filter '.dotnet-install-*' -Force) | Should -HaveCount 0
            } finally { Pop-Location }
        }

        It 'runs the exact SDK with the selected host, isolated CLI state and no SDK resolution' {
            $directory = Join-Path $TestDrive 'sdk'
            $hostPath = Join-Path $directory 'dotnet'
            Assert-DotNetSdkCompatibility -HostPath $hostPath -InstallDir $directory -Version 10.0.100
            Should -Invoke Invoke-DotNetSdkProcess -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq $hostPath -and $Arguments[0] -eq 'exec' -and
                $Arguments[1] -eq (Join-Path $directory 'sdk' '10.0.100' 'dotnet.dll') -and
                $Arguments[2] -eq '--version' -and
                $Environment.DOTNET_CLI_HOME.StartsWith($TestDrive) -and
                $Environment.DOTNET_CLI_TELEMETRY_OPTOUT -eq '1' -and
                $Environment.DOTNET_MULTILEVEL_LOOKUP -eq '0'
            }
        }

        It 'rejects a different SDK version and cleans its CLI scratch' {
            Mock Invoke-DotNetSdkProcess { '8.0.120' }
            { Assert-DotNetSdkCompatibility -HostPath 'synthetic-host' -InstallDir $TestDrive -Version 10.0.100 } | Should -Throw '*did not run SDK*'
        }

        It 'propagates host/runtime launch failure and cleans its CLI scratch' {
            Mock Invoke-DotNetSdkProcess { throw 'SDK process failed (exit 1): incompatible host/runtime' }
            { Assert-DotNetSdkCompatibility -HostPath 'synthetic-host' -InstallDir $TestDrive -Version 10.0.100 } | Should -Throw '*incompatible host/runtime*'
        }
    }
}

Describe 'SDK download and PATH helpers' {
    InModuleScope Shmuelie.DotNet {
        It 'compares Unix PATH entries case-sensitively while preserving all entries' {
            Get-DotNetSdkPathUpdate -Path '/SDK:/bin::/other' -InstallDir '/sdk' -Platform Linux | Should -Be '/sdk:/SDK:/bin::/other'
            Get-DotNetSdkPathUpdate -Path '/sdk/:/bin' -InstallDir '/sdk' -Platform macOS | Should -Be '/sdk/:/bin'
            Get-DotNetSdkPathUpdate -Path '' -InstallDir '/sdk' -Platform Linux | Should -Be '/sdk'
        }

        It 'downloads only the canonical Microsoft URL and redirect' {
            Mock Invoke-WebRequest {
                param($Uri, $OutFile)
                if ($Uri.Host -eq 'dot.net') {
                    return @{ StatusCode = 301; Headers = @{ Location = 'https://builds.dotnet.microsoft.com/dotnet/scripts/v1/dotnet-install.sh' } }
                }
                Set-Content -LiteralPath $OutFile -Value 'mock content'
                @{ StatusCode = 200 }
            }
            $path = Get-DotNetSdkInstallerFile -Name dotnet-install.sh -Directory $TestDrive
            $path | Should -Exist
            Should -Invoke Invoke-WebRequest -Times 2 -Exactly -ParameterFilter { $MaximumRedirection -eq 0 -and $SkipHttpErrorCheck }
        }

        It 'rejects an untrusted redirect before contacting it' {
            Mock Invoke-WebRequest { @{ StatusCode = 302; Headers = @{ Location = 'https://example.com/dotnet-install.sh' } } }
            { Get-DotNetSdkInstallerFile -Name dotnet-install.sh -Directory $TestDrive } | Should -Throw '*Untrusted installer URL*'
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly
        }

        It 'rejects HTTP failures instead of treating the response as an installer' {
            Mock Invoke-WebRequest { @{ StatusCode = 404; Headers = @{} } }
            { Get-DotNetSdkInstallerFile -Name dotnet-install.ps1 -Directory $TestDrive } | Should -Throw '*HTTP 404*'
        }

        It 'handles the explicit zero-redirect error and preserves all other request errors' {
            Mock Invoke-WebRequest {
                @{ StatusCode = 302; Headers = @{ Location = 'https://builds.dotnet.microsoft.com/dotnet/scripts/v1/dotnet-install.sh' } }
                Write-Error -ErrorId 'MaximumRedirectExceeded,Microsoft.PowerShell.Commands.InvokeWebRequestCommand' -Message 'Redirect intentionally disabled'
            } -ParameterFilter { $Uri.Host -eq 'dot.net' }
            Mock Invoke-WebRequest { @{ StatusCode = 200 } } -ParameterFilter { $Uri.Host -eq 'builds.dotnet.microsoft.com' }
            { Get-DotNetSdkInstallerFile -Name dotnet-install.sh -Directory $TestDrive } | Should -Not -Throw
            Mock Invoke-WebRequest { Write-Error -ErrorId 'NetworkFailure' -Message 'connection failed' } -ParameterFilter { $Uri.AbsolutePath.EndsWith('dotnet-install.ps1') }
            { Get-DotNetSdkInstallerFile -Name dotnet-install.ps1 -Directory $TestDrive } | Should -Throw '*connection failed*'
        }

        It 'validates available Windows Authenticode signatures' -Skip:(-not $IsWindows) {
            Mock Get-AuthenticodeSignature { @{ Status = 'Valid' } }
            { Test-DotNetSdkInstaller -Installer 'synthetic.ps1' -Platform Windows -Directory $TestDrive } | Should -Not -Throw
            Should -Invoke Get-AuthenticodeSignature -Times 1 -Exactly
        }

        It 'rejects invalid Windows signatures' -Skip:(-not $IsWindows) {
            Mock Get-AuthenticodeSignature { @{ Status = 'HashMismatch' } }
            { Test-DotNetSdkInstaller -Installer 'synthetic.ps1' -Platform Windows -Directory $TestDrive } | Should -Throw '*Authenticode*'
        }

        It 'verifies Unix scripts using the documented signature and an isolated GPG keyring' -Skip:$IsWindows {
            Mock Get-Command { @{ Source = '/usr/bin/gpg' } } -ParameterFilter { $Name -eq 'gpg' }
            Mock Get-DotNetSdkInstallerFile { param($Name, $Directory) Join-Path $Directory $Name }
            Mock Invoke-DotNetSdkProcess {}
            Test-DotNetSdkInstaller -Installer (Join-Path $TestDrive 'dotnet-install.sh') -Platform Linux -Directory $TestDrive
            Should -Invoke Get-DotNetSdkInstallerFile -Times 1 -Exactly -ParameterFilter { $Name -eq 'dotnet-install.asc' }
            Should -Invoke Get-DotNetSdkInstallerFile -Times 1 -Exactly -ParameterFilter { $Name -eq 'dotnet-install.sig' }
            Should -Invoke Invoke-DotNetSdkProcess -Times 1 -Exactly -ParameterFilter { '--import' -in $Arguments -and '--homedir' -in $Arguments -and '--no-autostart' -in $Arguments }
            Should -Invoke Invoke-DotNetSdkProcess -Times 1 -Exactly -ParameterFilter { '--verify' -in $Arguments -and (Join-Path $TestDrive 'dotnet-install.sig') -in $Arguments }
        }

        It 'rejects batch shims without starting a process' {
            { Invoke-DotNetSdkProcess -FilePath 'evil.cmd' -Arguments @('data') } | Should -Throw '*batch shims*'
        }
    }
}

Describe 'SDK host architecture detection' {
    InModuleScope Shmuelie.DotNet {
        It 'recognizes <Format> <Architecture> without executing the host' -ForEach @(
            @{ Format = 'PE'; Machine = 0x8664; Architecture = 'x64' }
            @{ Format = 'PE'; Machine = 0x14c; Architecture = 'x86' }
            @{ Format = 'PE'; Machine = 0xaa64; Architecture = 'arm64' }
            @{ Format = 'ELF'; Machine = 62; Architecture = 'x64' }
            @{ Format = 'ELF'; Machine = 183; Architecture = 'arm64' }
            @{ Format = 'ELF'; Machine = 21; Architecture = 'ppc64le' }
            @{ Format = 'ELF-BE'; Machine = 22; Architecture = 's390x' }
            @{ Format = 'MachO'; Machine = 0x1000007; Architecture = 'x64' }
            @{ Format = 'MachO'; Machine = 0x100000c; Architecture = 'arm64' }
        ) {
            $path = Join-Path $TestDrive "$Format-$Architecture"
            $stream = [IO.File]::Create($path)
            $writer = [IO.BinaryWriter]::new($stream)
            try {
                switch ($Format) {
                    'PE' {
                        $writer.Write([uint32]0x5a4d)
                        $stream.Position = 0x3c
                        $writer.Write([uint32]0x40)
                        $writer.Write([uint32]0x4550)
                        $writer.Write([uint16]$Machine)
                    }
                    { $_ -like 'ELF*' } {
                        $writer.Write([uint32]0x464c457f)
                        $stream.Position = 5
                        $writer.Write([byte]$(if ($Format -eq 'ELF-BE') { 2 } else { 1 }))
                        $stream.Position = 18
                        if ($Format -eq 'ELF-BE') { $writer.Write([byte]0); $writer.Write([byte]$Machine) }
                        else { $writer.Write([uint16]$Machine) }
                    }
                    'MachO' {
                        $writer.Write(0xfeedfacfu)
                        $writer.Write([uint32]$Machine)
                    }
                }
            } finally {
                $writer.Dispose()
            }
            Get-DotNetSdkHostArchitecture -Path $path | Should -Be $Architecture
            Remove-Item -LiteralPath $path -ErrorAction Stop
        }

        It 'fails for a malformed host and closes its file handle' {
            $path = Join-Path $TestDrive 'invalid-host'
            Set-Content -LiteralPath $path -Value 'not a native host'
            { Get-DotNetSdkHostArchitecture -Path $path } | Should -Throw
            { Remove-Item -LiteralPath $path -ErrorAction Stop } | Should -Not -Throw
        }
    }
}

Describe 'SDK native process lifecycle' {
    InModuleScope Shmuelie.DotNet {
        BeforeEach {
            $script:fakeProcess = [pscustomobject]@{
                StartInfo = $null
                HasExited = $false
                ExitCode = 0
                Timeout = $false
                FailStart = $false
                Killed = $false
                Disposed = $false
                StandardInput = [pscustomobject]@{}
                StandardOutput = [pscustomobject]@{ Value = 'mock stdout' }
                StandardError = [pscustomobject]@{ Value = 'mock stderr' }
            }
            $script:fakeProcess | Add-Member ScriptMethod Start {
                if ($this.FailStart) { throw 'start failed' }
                return $true
            }
            $script:fakeProcess | Add-Member ScriptMethod WaitForExit {
                param($TimeoutMilliseconds)
                if ($this.Timeout -and $TimeoutMilliseconds) { return $false }
                $this.HasExited = $true
                if ($TimeoutMilliseconds) { return $true }
            }
            $script:fakeProcess | Add-Member ScriptMethod Kill { param($Tree) $this.Killed = $Tree; $this.HasExited = $true }
            $script:fakeProcess | Add-Member ScriptMethod Dispose { $this.Disposed = $true }
            $script:fakeProcess.StandardInput | Add-Member ScriptMethod Close {}
            foreach ($reader in @($script:fakeProcess.StandardOutput, $script:fakeProcess.StandardError)) {
                $reader | Add-Member ScriptMethod ReadToEndAsync { [Threading.Tasks.Task]::FromResult[string]($this.Value) }
            }
            Mock New-DotNetSdkProcess { $script:fakeProcess }
        }

        It 'uses ArgumentList and child-only environment without a shell' {
            Invoke-DotNetSdkProcess -FilePath 'synthetic-executable' -Arguments @('file with spaces', 'literal&data') -Environment @{ TEST_VALUE = 'child only' } |
                Should -Be 'mock stdout'
            @($script:fakeProcess.StartInfo.ArgumentList) | Should -Be @('file with spaces', 'literal&data')
            $script:fakeProcess.StartInfo.UseShellExecute | Should -BeFalse
            $script:fakeProcess.StartInfo.Environment['TEST_VALUE'] | Should -Be 'child only'
            $script:fakeProcess.Disposed | Should -BeTrue
            $script:fakeProcess.Killed | Should -BeFalse
        }

        It 'throws on a nonzero exit instead of returning output as success' {
            $script:fakeProcess.ExitCode = 17
            { Invoke-DotNetSdkProcess -FilePath 'synthetic-executable' -Arguments @('argument') } | Should -Throw '*exit 17*mock stderr*'
            $script:fakeProcess.Disposed | Should -BeTrue
        }

        It 'terminates the owned process tree on timeout and disposes it' {
            $script:fakeProcess.Timeout = $true
            { Invoke-DotNetSdkProcess -FilePath 'synthetic-executable' -Arguments @('argument') -TimeoutSeconds 1 } | Should -Throw '*timed out*'
            $script:fakeProcess.Killed | Should -BeTrue
            $script:fakeProcess.Disposed | Should -BeTrue
        }

        It 'disposes failed starts without trying to kill a process that never started' {
            $script:fakeProcess.FailStart = $true
            { Invoke-DotNetSdkProcess -FilePath 'synthetic-executable' -Arguments @('argument') } | Should -Throw '*start failed*'
            $script:fakeProcess.Killed | Should -BeFalse
            $script:fakeProcess.Disposed | Should -BeTrue
        }
    }
}

Describe 'Shmuelie.DotNet tool commands' {
    BeforeEach {
        Mock -ModuleName Shmuelie.DotNet dotnet {
            $global:LASTEXITCODE = 0
        }
    }

    Context 'Get-DotNetTool' {
        BeforeEach {
            Mock -ModuleName Shmuelie.DotNet dotnet {
                $global:LASTEXITCODE = 0
                @(
                    'Package Id        Version      Commands'
                    '---------------------------------------'
                    'dotnet-ef         8.0.7        dotnet-ef'
                    'dotnet-outdated   4.6.4        dotnet-outdated'
                )
            }
        }

        It 'parses package ids, versions, commands, and the existing type name' {
            $tools = @(Shmuelie.DotNet\Get-DotNetTool)
            $tools | Should -HaveCount 2
            $tools[0].PSTypeNames[0] | Should -BeExactly 'DotNetTool'
            $tools[0].PackageId | Should -BeExactly 'dotnet-ef'
            $tools[0].Version | Should -BeExactly '8.0.7'
            $tools[0].Commands | Should -BeExactly 'dotnet-ef'
            $tools[0].Global | Should -BeTrue
            $tools[1].PackageId | Should -BeExactly 'dotnet-outdated'
            $tools[1].Version | Should -BeExactly '4.6.4'
            @($tools[0].PSObject.Properties.Name) | Should -Be @('PackageId', 'Version', 'Commands', 'Global')
        }

        It 'filters tools by package id wildcards' {
            $tools = @(Shmuelie.DotNet\Get-DotNetTool 'dotnet-e*')
            $tools | Should -HaveCount 1
            $tools[0].PackageId | Should -BeExactly 'dotnet-ef'
        }

        It 'returns no objects when a filter matches nothing' {
            @(Shmuelie.DotNet\Get-DotNetTool 'missing-*') | Should -HaveCount 0
        }

        It 'preserves <Scope> list arguments and scope output' -ForEach @(
            @{ Scope = 'global'; Local = $false; Expected = '-g' }
            @{ Scope = 'local'; Local = $true; Expected = '--local' }
        ) {
            $tools = @(Shmuelie.DotNet\Get-DotNetTool -Local:$Local)
            $tools[0].Global | Should -Be (-not $Local)
            Should -Invoke -ModuleName Shmuelie.DotNet dotnet -Times 1 -Exactly -ParameterFilter {
                $args.Count -eq 3 -and $args[0] -eq 'tool' -and $args[1] -eq 'list' -and $args[2] -eq $Expected
            }
        }

        It 'ignores empty lists and malformed rows' {
            Mock -ModuleName Shmuelie.DotNet dotnet {
                'Package Id        Version      Commands'
                '---------------------------------------'
                ''
                'not a tool row'
            }
            @(Shmuelie.DotNet\Get-DotNetTool) | Should -HaveCount 0
        }

        It 'preserves home-directory discovery and restores the caller location' {
            Mock -ModuleName Shmuelie.DotNet dotnet {
                (Get-Location).Path | Should -Be $HOME
            }
            Push-Location $TestDrive
            try {
                Shmuelie.DotNet\Get-DotNetTool | Out-Null
                (Get-Location).Path | Should -Be $TestDrive
                Should -Invoke -ModuleName Shmuelie.DotNet dotnet -Times 1 -Exactly
            } finally {
                Pop-Location
            }
        }

        It 'restores the caller location after a terminating native invocation error' {
            Mock -ModuleName Shmuelie.DotNet dotnet { throw 'dotnet unavailable' }
            Push-Location $TestDrive
            try {
                { Shmuelie.DotNet\Get-DotNetTool } | Should -Throw '*dotnet unavailable*'
                (Get-Location).Path | Should -Be $TestDrive
            } finally {
                Pop-Location
            }
        }

        It 'restores the caller location when downstream stops early' {
            Push-Location $TestDrive
            try {
                Shmuelie.DotNet\Get-DotNetTool | Select-Object -First 1 | Out-Null
                (Get-Location).Path | Should -Be $TestDrive
            } finally {
                Pop-Location
            }
        }
    }

    Context 'Update-DotNetTool' {
        BeforeEach {
            Mock -ModuleName Shmuelie.DotNet dotnet {
                $global:LASTEXITCODE = 0
                "Tool 'dotnet-ef' was successfully updated from version '8.0.7' to version '8.0.8'."
            }
        }

        It 'updates <Scope> tools by name with the original typed output' -ForEach @(
            @{ Scope = 'global'; Local = $false; Expected = '-g' }
            @{ Scope = 'local'; Local = $true; Expected = '--local' }
        ) {
            $result = Shmuelie.DotNet\Update-DotNetTool dotnet-ef -Local:$Local -Confirm:$false
            $result.PSTypeNames[0] | Should -BeExactly 'DotNetToolUpdateResult'
            $result.PackageId | Should -BeExactly 'dotnet-ef'
            $result.Version | Should -BeExactly '8.0.8'
            $result.Updated | Should -BeTrue
            @($result.PSObject.Properties.Name) | Should -Be @('PackageId', 'Version', 'Updated')
            Should -Invoke -ModuleName Shmuelie.DotNet dotnet -Times 1 -Exactly -ParameterFilter {
                ($args -join '|') -eq "tool|update|dotnet-ef|$Expected"
            }
        }

        It 'binds each pipeline object and selects its own global/local scope' {
            $tools = @(
                [pscustomobject]@{ PackageId = 'global-tool'; Global = $true; Version = '1.0.0' }
                [pscustomobject]@{ PackageId = 'local-tool'; Global = $false; Version = '1.0.0' }
            )
            $results = @($tools | Shmuelie.DotNet\Update-DotNetTool -Confirm:$false)
            $results | Should -HaveCount 2
            $results.PackageId | Should -Be @('global-tool', 'local-tool')
            Should -Invoke -ModuleName Shmuelie.DotNet dotnet -Times 1 -Exactly -ParameterFilter {
                ($args -join '|') -eq 'tool|update|global-tool|-g'
            }
            Should -Invoke -ModuleName Shmuelie.DotNet dotnet -Times 1 -Exactly -ParameterFilter {
                ($args -join '|') -eq 'tool|update|local-tool|--local'
            }
        }

        It 'updates from the caller location rather than the discovery location' {
            Mock -ModuleName Shmuelie.DotNet dotnet {
                (Get-Location).Path | Should -Be $TestDrive
            }
            Push-Location $TestDrive
            try {
                Shmuelie.DotNet\Update-DotNetTool dotnet-ef -Local -Confirm:$false | Out-Null
                Should -Invoke -ModuleName Shmuelie.DotNet dotnet -Times 1 -Exactly
            } finally {
                Pop-Location
            }
        }

        It 'retains Updated false when the existing version is reinstalled' {
            Mock -ModuleName Shmuelie.DotNet dotnet {
                "Tool 'dotnet-ef' was successfully reinstalled (version '8.0.8')."
            }
            $result = Shmuelie.DotNet\Update-DotNetTool dotnet-ef -Confirm:$false
            $result.Updated | Should -BeFalse
        }

        It 'parses a trailing version without changing the result shape' {
            Mock -ModuleName Shmuelie.DotNet dotnet { "Installed version '8.0.9'." }
            $result = Shmuelie.DotNet\Update-DotNetTool dotnet-ef -Confirm:$false
            $result.Version | Should -BeExactly '8.0.9'
            $result.Updated | Should -BeFalse
        }

        It 'does not execute updates or produce results under WhatIf by name' {
            @(Shmuelie.DotNet\Update-DotNetTool dotnet-ef -Local -WhatIf) | Should -HaveCount 0
            Should -Invoke -ModuleName Shmuelie.DotNet dotnet -Times 0 -Exactly
        }

        It 'does not execute updates or produce results under WhatIf by object' {
            $tool = [pscustomobject]@{ PackageId = 'dotnet-ef'; Global = $true; Version = '8.0.7' }
            @($tool | Shmuelie.DotNet\Update-DotNetTool -WhatIf) | Should -HaveCount 0
            Should -Invoke -ModuleName Shmuelie.DotNet dotnet -Times 0 -Exactly
        }

        It 'propagates terminating invocation failures rather than fabricating output' {
            Mock -ModuleName Shmuelie.DotNet dotnet { throw 'dotnet unavailable' }
            { Shmuelie.DotNet\Update-DotNetTool dotnet-ef -Confirm:$false } | Should -Throw '*dotnet unavailable*'
        }
    }

    Context 'Install-DotNetTool' {
        BeforeEach {
            Mock -ModuleName Shmuelie.DotNet Get-DotNetTool { }
        }

        It 'installs missing global tools without writing success-stream objects' {
            @(Shmuelie.DotNet\Install-DotNetTool dotnet-ef -Confirm:$false) | Should -HaveCount 0
            Should -Invoke -ModuleName Shmuelie.DotNet Get-DotNetTool -Times 1 -Exactly -ParameterFilter { $Name -eq 'dotnet-ef' }
            Should -Invoke -ModuleName Shmuelie.DotNet dotnet -Times 1 -Exactly -ParameterFilter {
                ($args -join '|') -eq 'tool|install|-g|dotnet-ef'
            }
        }

        It 'skips installation when discovery finds the tool' {
            Mock -ModuleName Shmuelie.DotNet Get-DotNetTool {
                [pscustomobject]@{ PackageId = 'dotnet-ef'; Version = '8.0.7'; Global = $true }
            }
            @(Shmuelie.DotNet\Install-DotNetTool dotnet-ef -Confirm:$false) | Should -HaveCount 0
            Should -Invoke -ModuleName Shmuelie.DotNet dotnet -Times 0 -Exactly
        }

        It 'does not discover or install tools under WhatIf' {
            @(Shmuelie.DotNet\Install-DotNetTool dotnet-ef -WhatIf) | Should -HaveCount 0
            Should -Invoke -ModuleName Shmuelie.DotNet Get-DotNetTool -Times 0 -Exactly
            Should -Invoke -ModuleName Shmuelie.DotNet dotnet -Times 0 -Exactly
        }

        It 'preserves failed installation error text and respects ErrorAction' {
            Mock -ModuleName Shmuelie.DotNet dotnet {
                $global:LASTEXITCODE = 1
                'Native installation failure'
            }
            { Shmuelie.DotNet\Install-DotNetTool dotnet-ef -Confirm:$false -ErrorAction Stop } |
                Should -Throw 'Failed to install tool: dotnet-ef'
        }

        It 'rejects an empty package name before invoking dotnet' {
            { Shmuelie.DotNet\Install-DotNetTool -Name '' -Confirm:$false } | Should -Throw
            Should -Invoke -ModuleName Shmuelie.DotNet dotnet -Times 0 -Exactly
        }
    }

    Context 'Uninstall-DotNetTool' {
        It 'uninstalls global tools by name without success-stream output' {
            @(Shmuelie.DotNet\Uninstall-DotNetTool dotnet-ef -Confirm:$false) | Should -HaveCount 0
            Should -Invoke -ModuleName Shmuelie.DotNet dotnet -Times 1 -Exactly -ParameterFilter {
                ($args -join '|') -eq 'tool|uninstall|-g|dotnet-ef'
            }
        }

        It 'uninstalls every pipeline package with the existing global-only contract' {
            $tools = @(
                [pscustomobject]@{ PackageId = 'first-tool'; Global = $true }
                [pscustomobject]@{ PackageId = 'second-tool'; Global = $true }
            )
            @($tools | Shmuelie.DotNet\Uninstall-DotNetTool -Confirm:$false) | Should -HaveCount 0
            Should -Invoke -ModuleName Shmuelie.DotNet dotnet -Times 1 -Exactly -ParameterFilter {
                ($args -join '|') -eq 'tool|uninstall|-g|first-tool'
            }
            Should -Invoke -ModuleName Shmuelie.DotNet dotnet -Times 1 -Exactly -ParameterFilter {
                ($args -join '|') -eq 'tool|uninstall|-g|second-tool'
            }
        }

        It 'does not execute uninstall under WhatIf by name' {
            @(Shmuelie.DotNet\Uninstall-DotNetTool dotnet-ef -WhatIf) | Should -HaveCount 0
            Should -Invoke -ModuleName Shmuelie.DotNet dotnet -Times 0 -Exactly
        }

        It 'does not execute uninstall under WhatIf by object' {
            $tool = [pscustomobject]@{ PackageId = 'dotnet-ef'; Global = $true }
            @($tool | Shmuelie.DotNet\Uninstall-DotNetTool -WhatIf) | Should -HaveCount 0
            Should -Invoke -ModuleName Shmuelie.DotNet dotnet -Times 0 -Exactly
        }

        It 'preserves failed uninstall error text and respects ErrorAction' {
            Mock -ModuleName Shmuelie.DotNet dotnet {
                $global:LASTEXITCODE = 1
                'Native uninstall failure'
            }
            { Shmuelie.DotNet\Uninstall-DotNetTool dotnet-ef -Confirm:$false -ErrorAction Stop } |
                Should -Throw 'Failed to uninstall tool: dotnet-ef'
        }
    }
}
