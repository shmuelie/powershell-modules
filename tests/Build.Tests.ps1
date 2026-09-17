#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.2.0' }
<#
.SYNOPSIS
    Validates that Build-Module.ps1 can be called multiple times in the same
    PowerShell process without hitting DLL-lock errors on the stage directory,
    treats source/output paths literally, and cleans temporary validation views.

    Regression test for GitHub issue #154: a second Build-Module call would fail
    with "access denied" trying to delete the stage directory because the binary
    module DLL was held in the parent process's non-collectible ALC.  The fix
    uses a short-lived child pwsh process for staged-module validation so that
    every DLL handle is released on child exit.
#>

BeforeAll {
    $script:repoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent
    $script:buildScript = Join-Path $script:repoRoot 'build' 'Build-Module.ps1'
    $script:tempRoot = [System.IO.Path]::GetTempPath()
}

Describe 'Build-Module literal paths' -Tag 'LiteralPaths' {
    BeforeAll {
        $script:caseRoots = [System.Collections.Generic.List[string]]::new()

        function New-LiteralBuildFixture {
            param(
                [string]$RepositoryName = 'repo-[ab]',
                [string]$Module = 'Shmuelie.Dsc'
            )

            $repository = Join-Path $script:caseRoot $RepositoryName
            $build = Join-Path $repository 'build'
            $source = Join-Path $repository 'modules' $Module
            $null = [System.IO.Directory]::CreateDirectory($build)
            $null = [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($source))
            Copy-Item -LiteralPath $script:buildScript -Destination (Join-Path $build 'Build-Module.ps1')
            if ($Module -eq 'Shmuelie.Dsc') {
                Copy-Item -LiteralPath (Join-Path $script:repoRoot 'modules' $Module) -Destination $source -Recurse
            } else {
                $null = [System.IO.Directory]::CreateDirectory($source)
                Set-Content -LiteralPath (Join-Path $source "$Module.psd1") -Value "@{ RootModule = '$Module.psm1'; ModuleVersion = '0.1.0'; FunctionsToExport = @() }"
                Set-Content -LiteralPath (Join-Path $source "$Module.psm1") -Value '# Isolated build fixture.'
                Set-Content -LiteralPath (Join-Path $source 'README.md') -Value 'Fixture'
                Set-Content -LiteralPath (Join-Path $source 'CHANGELOG.md') -Value 'Fixture'
            }
            Add-Content -LiteralPath (Join-Path $source "$Module.psm1") -Value @'
Set-Content -LiteralPath (Join-Path $PSScriptRoot 'imported.txt') -Value $PSScriptRoot
$ExecutionContext.SessionState.Module.OnRemove = {
    Set-Content -LiteralPath (Join-Path $PSScriptRoot 'removed.txt') -Value $PSScriptRoot
}
'@
            Set-Content -LiteralPath (Join-Path $source 'helper-[ab].ps1') -Value '# Literal script fixture.'
            Set-Content -LiteralPath (Join-Path $source 'fixture-[ab].format.ps1xml') -Value '<Configuration><ViewDefinitions /></Configuration>'
            $null = [System.IO.Directory]::CreateDirectory((Join-Path $source 'Classes' 'nested-[ab]'))
            Set-Content -LiteralPath (Join-Path $source 'Classes' 'nested-[ab]' 'class-[ab].ps1') -Value '# Literal class fixture.'
            [pscustomobject]@{
                Repository = $repository
                Build = Join-Path $build 'Build-Module.ps1'
                Source = $source
                Manifest = Join-Path $source "$Module.psd1"
                Loader = Join-Path $source "$Module.psm1"
            }
        }

        function New-BuildSentinel {
            param([string]$Directory)
            $null = [System.IO.Directory]::CreateDirectory($Directory)
            $file = Join-Path $Directory 'keep.txt'
            Set-Content -LiteralPath $file -Value $Directory
            Get-FileHash -LiteralPath $file
        }
    }

    BeforeEach {
        $script:caseRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:caseRoots.Add($script:caseRoot)
        $script:validationTemp = Join-Path $script:caseRoot 'temp'
        $null = [System.IO.Directory]::CreateDirectory($script:validationTemp)
        $script:savedEnvironment = @{}
        foreach ($name in 'TEMP', 'TMP', 'TMPDIR', 'PSMOD_VALIDATE_MANIFEST') {
            $script:savedEnvironment[$name] = [System.Environment]::GetEnvironmentVariable($name)
            $value = if ($name -eq 'PSMOD_VALIDATE_MANIFEST') { 'caller-owned-value' } else { $script:validationTemp }
            [System.Environment]::SetEnvironmentVariable($name, $value)
        }
    }

    AfterEach {
        try {
            [System.Environment]::GetEnvironmentVariable('PSMOD_VALIDATE_MANIFEST') | Should -Be 'caller-owned-value'
            @(Get-ChildItem -LiteralPath $script:validationTemp -Force) | Should -BeNullOrEmpty
        } finally {
            foreach ($name in $script:savedEnvironment.Keys) {
                [System.Environment]::SetEnvironmentVariable($name, $script:savedEnvironment[$name])
            }
        }
    }

    AfterAll {
        foreach ($root in $script:caseRoots) {
            if (Test-Path -LiteralPath $root) {
                Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop
            }
            Test-Path -LiteralPath $root | Should -BeFalse
        }
    }

    It 'builds and rebuilds literal <RepositoryName> / <OutputName> without touching neighbors' -ForEach @(
        @{ RepositoryName = 'repo'; OutputName = 'output' }
        @{ RepositoryName = 'repo'; OutputName = 'output-[ab]' }
        @{ RepositoryName = 'repo-[ab]'; OutputName = 'output' }
        @{ RepositoryName = 'repo-[ab]'; OutputName = 'output-[ab]' }
        @{ RepositoryName = 'repo-`literal'; OutputName = 'output-`literal' }
    ) {
        $fixture = New-LiteralBuildFixture -RepositoryName $RepositoryName
        $output = Join-Path $script:caseRoot $OutputName
        $stage = Join-Path $output 'Shmuelie.Dsc' '0.1.0'
        $sentinels = @(
            New-BuildSentinel (Join-Path $script:caseRoot 'output-a' 'Shmuelie.Dsc' '0.1.0')
            New-BuildSentinel (Join-Path $script:caseRoot 'output-b' 'Shmuelie.Dsc' '0.1.0')
            New-BuildSentinel (Join-Path $script:caseRoot 'repo-a' 'modules' 'Shmuelie.Dsc')
            New-BuildSentinel (Join-Path $script:caseRoot 'repo-b' 'modules' 'Shmuelie.Dsc')
            New-BuildSentinel (Join-Path $output 'Shmuelie.Dsc' '9.9.9')
            New-BuildSentinel (Join-Path $output 'Other.Module' '0.1.0')
        )
        $sourceHashes = @(Get-ChildItem -LiteralPath $fixture.Source -File -Recurse | ForEach-Object { Get-FileHash -LiteralPath $_.FullName })

        foreach ($iteration in 1, 2) {
            # Exercise normalization as well as literal resolution of the output root.
            $result = @(& $fixture.Build -Module Shmuelie.Dsc -OutputPath (Join-Path $output '..' $OutputName))
            $result.Count | Should -Be 1
            $result[0] | Should -BeOfType ([System.IO.DirectoryInfo])
            $result[0].FullName | Should -BeExactly $stage
            foreach ($file in 'imported.txt', 'removed.txt') {
                (Get-Content -LiteralPath (Join-Path $stage $file) -Raw).Trim() | Should -BeExactly $stage
            }
            foreach ($relative in 'helper-[ab].ps1', 'fixture-[ab].format.ps1xml', (Join-Path 'Classes' 'nested-[ab]' 'class-[ab].ps1')) {
                (Get-FileHash -LiteralPath (Join-Path $stage $relative)).Hash |
                    Should -Be (Get-FileHash -LiteralPath (Join-Path $fixture.Source $relative)).Hash
            }
            Test-Path -LiteralPath (Join-Path $stage 'Classes' 'Classes') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $stage 'stale.txt') | Should -BeFalse
            foreach ($sentinel in $sentinels + $sourceHashes) {
                (Get-FileHash -LiteralPath $sentinel.Path).Hash | Should -Be $sentinel.Hash
            }
            Test-Path -LiteralPath (Join-Path $fixture.Source 'imported.txt') | Should -BeFalse
            if ($iteration -eq 1) { Set-Content -LiteralPath (Join-Path $stage 'stale.txt') -Value 'replace on rebuild' }
        }
    }

    It 'preserves the existing stage when source framework validation rejects <Field>' -ForEach @(
        @{ Field = 'FileList'; Value = 'missing-file.txt' }
        @{ Field = 'RequiredModules'; Value = 'Issue257MissingDependency' }
    ) {
        $fixture = New-LiteralBuildFixture
        $output = Join-Path $script:caseRoot 'output-[ab]'
        $sentinel = New-BuildSentinel (Join-Path $output 'Shmuelie.Dsc' '0.1.0')
        Set-Content -LiteralPath $fixture.Manifest -Value "@{ RootModule = 'Shmuelie.Dsc.psm1'; ModuleVersion = '0.1.0'; $Field = @('$Value') }"

        { & $fixture.Build -Module Shmuelie.Dsc -OutputPath $output } | Should -Throw "*$Value*"
        (Get-FileHash -LiteralPath $sentinel.Path).Hash | Should -Be $sentinel.Hash
    }

    It 'retains final framework checks for files that are not staged' {
        $fixture = New-LiteralBuildFixture
        Set-Content -LiteralPath (Join-Path $fixture.Source 'not-staged.txt') -Value 'source-only fixture'
        Set-Content -LiteralPath $fixture.Manifest -Value "@{ RootModule = 'Shmuelie.Dsc.psm1'; ModuleVersion = '0.1.0'; FileList = @('not-staged.txt') }"
        $output = Join-Path $script:caseRoot 'output-[ab]'

        { & $fixture.Build -Module Shmuelie.Dsc -OutputPath $output } |
            Should -Throw '*Staged module validation failed*not-staged.txt*'
        Test-Path -LiteralPath (Join-Path $output 'Shmuelie.Dsc' '0.1.0' 'imported.txt') | Should -BeFalse
    }

    It 'propagates actual staged module <Operation> errors and cleans validation views' -ForEach @(
        @{ Operation = 'import'; Code = "throw 'fixture import failure'" }
        @{ Operation = 'removal'; Code = '$ExecutionContext.SessionState.Module.OnRemove = { throw ''fixture removal failure'' }' }
    ) {
        $fixture = New-LiteralBuildFixture
        Add-Content -LiteralPath $fixture.Loader -Value $Code
        $output = Join-Path $script:caseRoot 'output-[ab]'

        { & $fixture.Build -Module Shmuelie.Dsc -OutputPath $output } |
            Should -Throw "*Staged module validation failed*fixture $Operation failure*"
    }

    It 'rejects a non-filesystem output without staging' {
        $fixture = New-LiteralBuildFixture
        { & $fixture.Build -Module Shmuelie.Dsc -OutputPath 'Env:\Issue257Output' } |
            Should -Throw '*OutputPath must refer to the filesystem*'
    }

    It 'rejects an existing stage file instead of deleting it' {
        $fixture = New-LiteralBuildFixture
        $output = Join-Path $script:caseRoot 'output-[ab]'
        $null = [System.IO.Directory]::CreateDirectory((Join-Path $output 'Shmuelie.Dsc'))
        $stage = Join-Path $output 'Shmuelie.Dsc' '0.1.0'
        Set-Content -LiteralPath $stage -Value 'not a build directory'
        $hash = (Get-FileHash -LiteralPath $stage).Hash
        { & $fixture.Build -Module Shmuelie.Dsc -OutputPath $output } | Should -Throw '*ordinary filesystem directory*'
        (Get-FileHash -LiteralPath $stage).Hash | Should -Be $hash
    }

    It 'resolves a relative bracketed output from the caller location' {
        $fixture = New-LiteralBuildFixture
        Push-Location -LiteralPath $script:caseRoot
        try {
            $artifact = & $fixture.Build -Module Shmuelie.Dsc -OutputPath (Join-Path '.' 'output-[ab]')
            $artifact.FullName | Should -BeExactly (Join-Path $script:caseRoot 'output-[ab]' 'Shmuelie.Dsc' '0.1.0')
        } finally {
            Pop-Location
        }
    }

    It 'retains available required modules in framework validation and actual staged import' {
        $fixture = New-LiteralBuildFixture
        $dependencyRoot = Join-Path $script:caseRoot 'dependencies'
        $dependency = Join-Path $dependencyRoot 'Issue257FixtureDependency'
        $null = [System.IO.Directory]::CreateDirectory($dependency)
        Set-Content -LiteralPath (Join-Path $dependency 'Issue257FixtureDependency.psd1') -Value "@{ RootModule = 'Issue257FixtureDependency.psm1'; ModuleVersion = '1.2.3' }"
        Set-Content -LiteralPath (Join-Path $dependency 'Issue257FixtureDependency.psm1') -Value '# Inert dependency fixture.'
        Set-Content -LiteralPath $fixture.Manifest -Value "@{ RootModule = 'Shmuelie.Dsc.psm1'; ModuleVersion = '0.1.0'; RequiredModules = @(@{ ModuleName = 'Issue257FixtureDependency'; RequiredVersion = '1.2.3' }) }"
        Add-Content -LiteralPath $fixture.Loader -Value @'
if ((Get-Module -Name Issue257FixtureDependency).Version -ne [version]'1.2.3') {
    throw 'The actual artifact did not load its required dependency.'
}
'@
        $previous = $env:PSModulePath
        try {
            $env:PSModulePath = $dependencyRoot + [System.IO.Path]::PathSeparator + $previous
            $artifact = & $fixture.Build -Module Shmuelie.Dsc -OutputPath (Join-Path $script:caseRoot 'output-[ab]')
            Test-Path -LiteralPath (Join-Path $artifact.FullName 'removed.txt') | Should -BeTrue
        } finally {
            $env:PSModulePath = $previous
        }
    }

    It 'does not follow a linked <Location> directory' -ForEach @(
        @{ Location = 'source' }
        @{ Location = 'stage' }
    ) {
        $fixture = New-LiteralBuildFixture
        $output = Join-Path $script:caseRoot 'output-[ab]'
        $target = Join-Path $script:caseRoot 'owned-link-target'
        $sentinel = New-BuildSentinel $target
        $link = if ($Location -eq 'source') {
            Join-Path $fixture.Source 'linked-content'
        } else {
            $null = [System.IO.Directory]::CreateDirectory((Join-Path $output 'Shmuelie.Dsc'))
            Join-Path $output 'Shmuelie.Dsc' '0.1.0'
        }
        $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
        New-Item -Path $link -ItemType $linkType -Target $target -ErrorAction Stop | Out-Null
        try {
            $message = if ($Location -eq 'source') { '*linked item*' } else { '*ordinary filesystem directory*' }
            { & $fixture.Build -Module Shmuelie.Dsc -OutputPath $output } | Should -Throw $message
            (Get-FileHash -LiteralPath $sentinel.Path).Hash | Should -Be $sentinel.Hash
        } finally {
            Remove-Item -LiteralPath $link -Force -ErrorAction Stop
        }
    }

    It 'requires a wildcard-free temporary directory only for affected paths = <Affected>' -ForEach @(
        @{ Affected = $false }
        @{ Affected = $true }
    ) {
        $repositoryName = if ($Affected) { 'repo-[ab]' } else { 'repo' }
        $fixture = New-LiteralBuildFixture -RepositoryName $repositoryName
        $output = Join-Path $script:caseRoot 'output'
        $sentinel = New-BuildSentinel (Join-Path $output 'Shmuelie.Dsc' '0.1.0')
        $temp = Join-Path $script:caseRoot 'temp-[ab]'
        $null = [System.IO.Directory]::CreateDirectory($temp)
        foreach ($name in 'TEMP', 'TMP', 'TMPDIR') {
            [System.Environment]::SetEnvironmentVariable($name, $temp)
        }
        if ($Affected) {
            { & $fixture.Build -Module Shmuelie.Dsc -OutputPath $output } | Should -Throw '*temporary directory without wildcard or escape characters*'
            (Get-FileHash -LiteralPath $sentinel.Path).Hash | Should -Be $sentinel.Hash
        } else {
            $artifact = & $fixture.Build -Module Shmuelie.Dsc -OutputPath $output
            Test-Path -LiteralPath (Join-Path $artifact.FullName 'removed.txt') | Should -BeTrue
        }
        @(Get-ChildItem -LiteralPath $temp -Force) | Should -BeNullOrEmpty
    }

    It 'rebuilds an isolated binary fixture without locking the literal stage or deleting predictor neighbors' {
        $fixture = New-LiteralBuildFixture -Module Shmuelie.Git
        $binaryOutput = Join-Path $script:caseRoot 'output-[ab]'
        $binaryProject = Join-Path $fixture.Source 'Predictor' 'WorktreePredictor.csproj'
        $binarySeed = Join-Path $script:caseRoot 'Fixture.dll'
        Add-Type -OutputAssembly $binarySeed -TypeDefinition @'
using System.Management.Automation;
[Cmdlet(VerbsCommon.Get, "Issue257Fixture")]
public sealed class Issue257FixtureCommand : PSCmdlet { }
'@
        Add-Content -LiteralPath $fixture.Loader -Value @'
$script:binaryFixture = Import-Module -Name (Join-Path $PSScriptRoot 'bin' 'WorktreePredictor.dll') -Force -PassThru -ErrorAction Stop
Set-Content -LiteralPath (Join-Path $PSScriptRoot 'binary-path.txt') -Value $script:binaryFixture.Path
$ExecutionContext.SessionState.Module.OnRemove = {
    Remove-Module -ModuleInfo $script:binaryFixture -Force -ErrorAction Stop
}
'@
        $binaryCalls = [System.Collections.Generic.List[string]]::new()
        function dotnet {
            if ($args[0] -ne 'build' -or $args[1] -ne $binaryProject -or
                $args[2] -ne '--configuration' -or $args[3] -ne 'Release' -or
                $args[4] -ne '--output' -or $args[5] -ne (Join-Path $binaryOutput '.predictor-build') -or
                $args[6] -ne '--nologo' -or $args.Count -ne 7) {
                throw "Unexpected fixture build arguments: $args"
            }
            $null = [System.IO.Directory]::CreateDirectory($args[5])
            Copy-Item -LiteralPath $binarySeed -Destination (Join-Path $args[5] 'WorktreePredictor.dll')
            $binaryCalls.Add($args[1])
            $global:LASTEXITCODE = 0
        }
        $function:dotnet = ${function:dotnet}.GetNewClosure()
        $sentinels = @(
            New-BuildSentinel (Join-Path $script:caseRoot 'output-a' '.predictor-build')
            New-BuildSentinel (Join-Path $script:caseRoot 'output-b' '.predictor-build')
            New-BuildSentinel (Join-Path $script:caseRoot 'output-a' 'Shmuelie.Git' '0.1.0')
            New-BuildSentinel (Join-Path $script:caseRoot 'output-b' 'Shmuelie.Git' '0.1.0')
        )
        $null = New-BuildSentinel (Join-Path $binaryOutput '.predictor-build')
        foreach ($iteration in 1, 2) {
            $artifact = & $fixture.Build -Module Shmuelie.Git -OutputPath $binaryOutput
            (Get-Content -LiteralPath (Join-Path $artifact.FullName 'binary-path.txt') -Raw).Trim() |
                Should -BeExactly (Join-Path $artifact.FullName 'bin' 'WorktreePredictor.dll')
            Test-Path -LiteralPath (Join-Path $binaryOutput '.predictor-build') | Should -BeFalse
            foreach ($sentinel in $sentinels) {
                (Get-FileHash -LiteralPath $sentinel.Path).Hash | Should -Be $sentinel.Hash
            }
        }
        $binaryCalls.Count | Should -Be 2
    }

    It 'stages fake Windows build outputs literally with dependency mismatch = <Mismatch>' -ForEach @(
        @{ Mismatch = $false }
        @{ Mismatch = $true }
    ) {
        $fixture = New-LiteralBuildFixture -Module Shmuelie.Windows
        $windowsOutput = Join-Path $script:caseRoot 'output-[ab]'
        $windowsMismatch = $Mismatch
        $windowsProjects = @{
            (Join-Path $fixture.Source 'Cmdlets' 'Shmuelie.Windows.Cmdlets.csproj') = @{
                Operation = 'build'; Directory = '.windows-cmdlets-build'
                Files = @('Shmuelie.Windows.Cmdlets.dll')
            }
            (Join-Path $fixture.Source 'Cmdlets.AppInstaller' 'Shmuelie.Windows.AppInstaller.csproj') = @{
                Operation = 'publish'; Directory = '.windows-appinstaller-build'
                Files = @('Shmuelie.Windows.AppInstaller.dll', 'Microsoft.Windows.SDK.NET.dll', 'WinRT.Runtime.dll')
            }
            (Join-Path $fixture.Source 'Cmdlets.AppInstall' 'Shmuelie.Windows.AppInstall.csproj') = @{
                Operation = 'publish'; Directory = '.windows-appinstall-build'
                Files = @('Shmuelie.Windows.AppInstall.dll', 'Microsoft.Windows.SDK.NET.dll', 'WinRT.Runtime.dll', (Join-Path 'en-US' 'help-[ab].xml'))
            }
        }
        $windowsCalls = [System.Collections.Generic.List[string]]::new()
        function dotnet {
            $project = $windowsProjects[$args[1]]
            if (-not $project -or $args[0] -ne $project.Operation -or
                $args[2] -ne '--configuration' -or $args[3] -ne 'Release' -or
                $args[4] -ne '--output' -or $args[5] -ne (Join-Path $windowsOutput $project.Directory) -or
                -not $args[6].StartsWith("-bl:$windowsOutput") -or $args[7] -ne '--nologo' -or $args.Count -ne 8) {
                throw "Unexpected fixture build arguments: $args"
            }
            foreach ($file in $project.Files) {
                $destination = Join-Path $args[5] $file
                $null = [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($destination))
                $content = if ($windowsMismatch -and $project.Directory -eq '.windows-appinstall-build' -and $file -eq 'WinRT.Runtime.dll') {
                    'mismatched dependency fixture'
                } else { "fixture $file" }
                Set-Content -LiteralPath $destination -Value $content
            }
            $windowsCalls.Add($args[1])
            $global:LASTEXITCODE = 0
        }
        $function:dotnet = ${function:dotnet}.GetNewClosure()
        $sentinels = @(
            foreach ($neighbor in 'output-a', 'output-b') {
                foreach ($directory in '.windows-cmdlets-build', '.windows-appinstaller-build', '.windows-appinstall-build', (Join-Path 'Shmuelie.Windows' '0.1.0')) {
                    New-BuildSentinel (Join-Path $script:caseRoot $neighbor $directory)
                }
            }
        )
        foreach ($directory in '.windows-cmdlets-build', '.windows-appinstaller-build', '.windows-appinstall-build') {
            $null = New-BuildSentinel (Join-Path $windowsOutput $directory)
        }
        if ($Mismatch) {
            { & $fixture.Build -Module Shmuelie.Windows -OutputPath $windowsOutput } |
                Should -Throw '*different copies of WinRT.Runtime.dll*'
            $windowsCalls.Count | Should -Be 3
        } else {
            foreach ($iteration in 1, 2) {
                $artifact = & $fixture.Build -Module Shmuelie.Windows -OutputPath $windowsOutput
                foreach ($file in $windowsProjects.Values.Files) {
                    (Get-Content -LiteralPath (Join-Path $artifact.FullName 'bin' $file) -Raw).Trim() | Should -Be "fixture $file"
                }
                Test-Path -LiteralPath (Join-Path $artifact.FullName 'bin' 'en-US' 'en-US') | Should -BeFalse
                foreach ($directory in '.windows-cmdlets-build', '.windows-appinstaller-build', '.windows-appinstall-build') {
                    Test-Path -LiteralPath (Join-Path $windowsOutput $directory) | Should -BeFalse
                }
            }
            $windowsCalls.Count | Should -Be 6
        }
        foreach ($sentinel in $sentinels) {
            (Get-FileHash -LiteralPath $sentinel.Path).Hash | Should -Be $sentinel.Hash
        }
    }
}

Describe 'Build-Module repeat invocations' {
    BeforeAll {
        $script:artifacts = Join-Path $TestDrive 'artifacts'
    }

    AfterAll {
        Remove-Item $script:artifacts -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'builds Shmuelie.Git twice in the same process without DLL lock errors' {
        # Snapshot any pre-existing psmod-validate-* dirs so we can detect leaks.
        $dirsBefore = @(Get-ChildItem $script:tempRoot -Filter 'psmod-validate-*' -Directory -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty FullName)

        # First build: compiles and validates WorktreePredictor.dll in a child process.
        { & $script:buildScript -Module Shmuelie.Git -OutputPath $script:artifacts } |
            Should -Not -Throw

        # Second build must delete the previous stage dir (containing the DLL)
        # without an access-denied error.
        { & $script:buildScript -Module Shmuelie.Git -OutputPath $script:artifacts } |
            Should -Not -Throw

        # Child-process validation must not leave psmod-validate-* directories behind.
        $dirsAfter = @(Get-ChildItem $script:tempRoot -Filter 'psmod-validate-*' -Directory -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty FullName)
        @($dirsAfter | Where-Object { $_ -notin $dirsBefore }) |
            Should -BeNullOrEmpty -Because 'child-process validation leaves no psmod-validate-* temp directories'
    }

    It 'builds Shmuelie.Windows twice in the same process without DLL lock errors' -Skip:(-not $IsWindows) {
        $dirsBefore = @(Get-ChildItem $script:tempRoot -Filter 'psmod-validate-*' -Directory -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty FullName)

        # Same scenario for the Windows binary cmdlet DLLs.
        { & $script:buildScript -Module Shmuelie.Windows -OutputPath $script:artifacts } |
            Should -Not -Throw
        { & $script:buildScript -Module Shmuelie.Windows -OutputPath $script:artifacts } |
            Should -Not -Throw

        $dirsAfter = @(Get-ChildItem $script:tempRoot -Filter 'psmod-validate-*' -Directory -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty FullName)
        @($dirsAfter | Where-Object { $_ -notin $dirsBefore }) |
            Should -BeNullOrEmpty -Because 'child-process validation leaves no psmod-validate-* temp directories'
    }
}