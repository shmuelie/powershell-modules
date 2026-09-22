#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.2.0' }

BeforeAll {
    $repoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent
    Import-Module ([System.IO.Path]::Combine($repoRoot, 'modules', 'Shmuelie.Git', 'Shmuelie.Git.psd1')) -Force

    # Run a git command and throw on failure. $ErrorActionPreference does not turn
    # a native non-zero exit into a terminating error, so setup failures would
    # otherwise surface as a confusing later assertion rather than at the source.
    # Pass all tokens as a single array so leading switches (e.g. -C) are not
    # mistaken for parameters of this function.
    function Invoke-Git {
        param([Parameter(Mandatory, Position = 0)][string[]]$Arguments)
        $commonConfig = @(
            '-c', 'user.name=Test User',
            '-c', 'user.email=test@example.com',
            '-c', 'init.defaultBranch=main',
            '-c', 'protocol.file.allow=always',
            '-c', 'commit.gpgsign=false',
            '-c', 'tag.gpgsign=false'
        )
        $output = & git @commonConfig @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "git $($Arguments -join ' ') failed (exit $LASTEXITCODE): $output"
        }
        $output
    }

    # Neutralize ambient/global git config so the repo behaves identically on any
    # contributor's machine and on CI: a global status.showUntrackedFiles=no,
    # core.autocrlf, GPG signing, or inherited hooks would otherwise perturb the
    # status output the tests assert on.
    function Set-TestRepoConfig {
        param([Parameter(Mandatory)][string]$Path)
        Invoke-Git @('-C', $Path, 'config', 'user.email', 'test@example.com')
        Invoke-Git @('-C', $Path, 'config', 'user.name', 'Test User')
        Invoke-Git @('-C', $Path, 'config', 'commit.gpgsign', 'false')
        Invoke-Git @('-C', $Path, 'config', 'tag.gpgsign', 'false')
        Invoke-Git @('-C', $Path, 'config', 'core.autocrlf', 'false')
        Invoke-Git @('-C', $Path, 'config', 'core.hooksPath', (Join-Path $Path '.no-such-hooks'))
        Invoke-Git @('-C', $Path, 'config', 'status.showUntrackedFiles', 'normal')
    }

    # Create an isolated git repository with a deterministic default branch, no
    # inherited template hooks, and a single initial commit. Returns the path.
    function New-TestRepo {
        param(
            [Parameter(Mandatory)][string]$Path,
            [switch]$NoCommit
        )
        New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
        Invoke-Git @('-C', $Path, '-c', 'init.templateDir=', 'init', '-b', 'main', '--quiet')
        Set-TestRepoConfig $Path
        if (-not $NoCommit) {
            Set-Content -LiteralPath (Join-Path $Path 'README.md') -Value 'initial'
            Invoke-Git @('-C', $Path, 'add', 'README.md')
            Invoke-Git @('-C', $Path, 'commit', '-m', 'init', '--quiet')
        }
        $Path
    }

    function Get-TestGitDir {
        param([Parameter(Mandatory)][string]$Path)
        $gitDir = Invoke-Git @('-C', $Path, 'rev-parse', '--git-dir')
        if ([System.IO.Path]::IsPathRooted($gitDir)) {
            $gitDir
        } else {
            Join-Path $Path $gitDir
        }
    }

    function ConvertTo-NativeTestPath {
        param([Parameter(Mandatory)][string]$Path)

        if ([System.IO.Path]::DirectorySeparatorChar -eq '\') {
            return $Path -replace '/', '\'
        }

        [System.IO.Path]::GetFullPath($Path)
    }

    function Invoke-TestCommit {
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][string]$Message
        )

        Invoke-Git @(
            '-C', $Path,
            '-c', 'user.name=Test User',
            '-c', 'user.email=test@example.com',
            'commit', '-m', $Message, '--quiet'
        )
    }
}

Describe 'Worktree predictor literal arguments' -Tag 'PredictorLiteralArguments' {
    BeforeAll {
        $predictionRoot = (New-Item -ItemType Directory -Path (
            Join-Path $TestDrive "predictor-literals-$([guid]::NewGuid().ToString('N'))"
        ) -ErrorAction Stop).FullName
        $predictionSource = Join-Path $repoRoot 'modules' 'Shmuelie.Git' 'Predictor'
        Copy-Item -LiteralPath @(
            Join-Path $predictionSource 'WorktreePredictor.cs'
            Join-Path $predictionSource 'WorktreePredictor.csproj'
        ) -Destination $predictionRoot -ErrorAction Stop
        $predictionBin = Join-Path $predictionRoot 'bin'
        $dotnet = (Get-Command dotnet -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        $previousBuildLogPath = $env:MSBUILDDEBUGPATH
        try {
            $env:MSBUILDDEBUGPATH = Join-Path $predictionRoot 'build-logs'
            $buildOutput = & $dotnet build (Join-Path $predictionRoot 'WorktreePredictor.csproj') `
                -c Release -o $predictionBin --nologo -v q --disable-build-servers -p:UseSharedCompilation=false 2>&1
            $buildExitCode = $LASTEXITCODE
        } finally {
            $env:MSBUILDDEBUGPATH = $previousBuildLogPath
        }
        if ($buildExitCode -ne 0) {
            throw "Predictor source build failed (exit $buildExitCode): $($buildOutput -join [Environment]::NewLine)"
        }
        $predictionPwsh = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    }

    AfterAll {
        if ($predictionRoot -and (Test-Path -LiteralPath $predictionRoot)) {
            if ((Split-Path $predictionRoot -Parent) -cne $TestDrive) {
                throw 'Refusing cleanup outside the owned prediction TestDrive.'
            }
            Remove-Item -LiteralPath $predictionRoot -Recurse -Force -ErrorAction Stop
        }
    }

    It 'parses real cached-branch predictions as unchanged literal arguments without executing them' {
        $output = & $predictionPwsh -NoProfile -NonInteractive -File (
            Join-Path $PSScriptRoot 'fixtures' 'Test-WorktreePrediction.ps1'
        ) -AssemblyPath (Join-Path $predictionBin 'WorktreePredictor.dll') 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Isolated prediction test failed (exit $LASTEXITCODE): $($output -join [Environment]::NewLine)"
        }
        $result = ($output -join "`n") | ConvertFrom-Json
        $result.Failed | Should -Be 0
        $result.LiteralCases | Should -Be 175
        $result.CompatibilityCases | Should -Be 17
        $result.Passed | Should -Be 192
    }
}

Describe 'Worktree predictor event ownership' -Tag 'PredictorEventOwnership' {
    BeforeAll {
        $lifecycleRoot = (New-Item -ItemType Directory -Path (
            Join-Path $TestDrive "predictor-lifetime-$([guid]::NewGuid().ToString('N'))"
        ) -ErrorAction Stop).FullName
        $lifecycleChild = Join-Path $lifecycleRoot 'lifecycle.ps1'
        $lifecycleSource = Join-Path $repoRoot 'modules' 'Shmuelie.Git'
        $lifecyclePwsh = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        Set-Content -LiteralPath $lifecycleChild -Encoding utf8 -Value @'
param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$Mode,
    [Parameter(Mandatory)][string]$PriorState,
    [switch]$AlreadyRemoved
)
$ErrorActionPreference = 'Stop'
$originalLocation = Get-Location
$timer = [Timers.Timer]::new()
$module = $null
$externalBinary = $null
$externalJobs = @()
$externalSubscribers = @()

function Assert-LifecycleState([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-ExternalState {
    $subscribers = @(Get-EventSubscriber -Force)
    foreach ($expected in $externalSubscribers) {
        Assert-LifecycleState ([bool]($subscribers | Where-Object {
            [object]::ReferenceEquals($_, $expected)
        })) "Removed unrelated subscriber $($expected.SubscriptionId)."
    }
    $jobs = @(Get-Job)
    foreach ($expected in $externalJobs) {
        Assert-LifecycleState ([bool]($jobs | Where-Object {
            [object]::ReferenceEquals($_, $expected)
        })) "Removed unrelated job $($expected.Id)."
    }
}

try {
    Assert-LifecycleState (-not (Test-Path -LiteralPath $Root)) 'Scenario directory must be new.'
    $null = New-Item -ItemType Directory -Path $Root -ErrorAction Stop
    Set-Location -LiteralPath $Root -ErrorAction Stop
    Assert-LifecycleState ((Get-Location).ProviderPath -ceq $Root) 'Scenario location guard failed.'
    $staged = (New-Item -ItemType Directory -Path (Join-Path $Root 'Shmuelie.Git') -ErrorAction Stop).FullName
    Get-ChildItem -LiteralPath $Source -File | Copy-Item -Destination $staged -ErrorAction Stop
    Copy-Item -LiteralPath (Join-Path $Source 'Classes') -Destination $staged -Recurse -ErrorAction Stop
    $manifest = Join-Path $staged 'Shmuelie.Git.psd1'

    # This double exercises the real loader without starting Git on idle.
    $predictorSource = @"
using System;
using System.Collections.Generic;
using System.Management.Automation;
using System.Management.Automation.Subsystem;
using System.Management.Automation.Subsystem.Prediction;
using System.Threading;
namespace WorktreePredictor {
    public sealed class WorktreeCommandPredictor : ICommandPredictor {
        public static readonly Guid PredictorId = new Guid("a1b2c3d4-e5f6-7890-abcd-ef1234567890");
        public static int Imports;
        public static int Removals;
        public static int Updates;
        public static void UpdateWorkingDirectory(string path) { Updates++; }
        public Guid Id => PredictorId;
        public string Name => "Worktree";
        public string Description => "No-Git lifecycle test predictor";
        public SuggestionPackage GetSuggestion(PredictionClient client, PredictionContext context, CancellationToken token) => default;
        public bool CanAcceptFeedback(PredictionClient client, PredictorFeedbackKind feedback) => false;
        public void OnSuggestionDisplayed(PredictionClient client, uint session, int countOrIndex) { }
        public void OnSuggestionAccepted(PredictionClient client, uint session, string text) { }
        public void OnCommandLineAccepted(PredictionClient client, IReadOnlyList<string> history) { }
        public void OnCommandLineExecuted(PredictionClient client, string commandLine, bool success) { }
    }
    public sealed class Init : IModuleAssemblyInitializer, IModuleAssemblyCleanup {
        public void OnImport() {
            SubsystemManager.RegisterSubsystem(SubsystemKind.CommandPredictor, new WorktreeCommandPredictor());
            WorktreeCommandPredictor.Imports++;
        }
        public void OnRemove(PSModuleInfo module) {
            SubsystemManager.UnregisterSubsystem(SubsystemKind.CommandPredictor, WorktreeCommandPredictor.PredictorId);
            WorktreeCommandPredictor.Removals++;
        }
    }
}
"@
    if ($Mode -eq 'SourceWithType') {
        Add-Type -TypeDefinition $predictorSource
    } elseif ($Mode -in @('Bundled', 'Preloaded')) {
        $bin = (New-Item -ItemType Directory -Path (Join-Path $staged 'bin') -ErrorAction Stop).FullName
        $binaryPath = Join-Path $bin 'WorktreePredictor.dll'
        Add-Type -TypeDefinition $predictorSource -OutputAssembly $binaryPath
        if ($Mode -eq 'Preloaded') {
            $externalBinary = Import-Module $binaryPath -PassThru -ErrorAction Stop
        }
    }

    if ($PriorState -in @('Actionless', 'Mixed')) {
        $null = Register-ObjectEvent -InputObject $timer -EventName Elapsed -SourceIdentifier 'Fixture.Actionless.One'
        $null = Register-ObjectEvent -InputObject $timer -EventName Disposed -SourceIdentifier 'Fixture.Actionless.Two'
        $null = Register-ObjectEvent -InputObject $timer -EventName Elapsed -SourceIdentifier 'Fixture.Actionless.Three'
    }
    if ($PriorState -in @('Jobs', 'Mixed')) {
        $job = Start-Job -ScriptBlock { 'unrelated completed job' }
        $externalJobs += $job
        $null = Wait-Job -Job $job -Timeout 30
        Assert-LifecycleState ($job.State -eq 'Completed') 'Unrelated fixture job did not complete.'
    }
    if ($PriorState -eq 'Mixed') {
        $externalJobs += Register-EngineEvent -SourceIdentifier PowerShell.OnIdle -Action { }
        $externalJobs += Register-ObjectEvent -InputObject $timer -EventName Elapsed -SourceIdentifier 'Fixture.Action' -Action { }
    }
    $externalSubscribers = @(Get-EventSubscriber -Force)
    $externalIds = @($externalSubscribers | Select-Object -ExpandProperty SubscriptionId)
    $externalJobIds = @($externalJobs | Select-Object -ExpandProperty Id)
    $expectedOwnCount = if ($Mode -eq 'SourceWithoutPredictor') { 0 } else { 1 }
    $divergentIdsObserved = $false

    foreach ($cycle in 1..3) {
        foreach ($import in 1..2) {
            $module = Import-Module $manifest -Force -PassThru -ErrorAction Stop
            Assert-ExternalState
            $ownedSubscribers = @(Get-EventSubscriber -Force | Where-Object SubscriptionId -NotIn $externalIds)
            $ownedJobs = @(Get-Job | Where-Object Id -NotIn $externalJobIds)
            Assert-LifecycleState ($ownedSubscribers.Count -eq $expectedOwnCount) "Unexpected owned subscriber count after import: $($ownedSubscribers.Count)."
            Assert-LifecycleState ($ownedJobs.Count -eq $expectedOwnCount) "Unexpected owned job count after import: $($ownedJobs.Count)."
            if ($expectedOwnCount -eq 1) {
                Assert-LifecycleState ([object]::ReferenceEquals($ownedSubscribers[0].Action, $ownedJobs[0])) 'Owned job/subscriber association differs.'
                if ($ownedSubscribers[0].SubscriptionId -ne $ownedJobs[0].Id) { $divergentIdsObserved = $true }
            }
            if ($Mode -in @('Bundled', 'Preloaded')) {
                Assert-LifecycleState ((Get-PSSubsystem -Kind CommandPredictor).Implementations.Name -contains 'Worktree') 'Predictor must be registered while the module is loaded.'
            }
        }
        if ($AlreadyRemoved -and $ownedSubscribers.Count -gt 0) {
            Unregister-Event -SubscriptionId $ownedSubscribers[0].SubscriptionId
            Remove-Job -Job $ownedJobs[0] -Force
        }
        Remove-Module $module -Force -ErrorAction Stop
        $module = $null
        Assert-ExternalState
        Assert-LifecycleState (@(Get-EventSubscriber -Force | Where-Object SubscriptionId -NotIn $externalIds).Count -eq 0) 'Module subscriber leaked after removal.'
        Assert-LifecycleState (@(Get-Job | Where-Object Id -NotIn $externalJobIds).Count -eq 0) 'Module action job leaked after removal.'
        if ($Mode -eq 'Preloaded') {
            Assert-LifecycleState ([bool](Get-Module WorktreePredictor)) 'Caller-owned binary module was removed.'
            Assert-LifecycleState ((Get-PSSubsystem -Kind CommandPredictor).Implementations.Name -contains 'Worktree') 'Caller-owned predictor was unregistered.'
            Assert-LifecycleState ([WorktreePredictor.WorktreeCommandPredictor]::Removals -eq 0) 'Caller-owned binary cleanup ran.'
        } elseif ($Mode -eq 'Bundled') {
            Assert-LifecycleState (-not (Get-Module WorktreePredictor)) 'Loader-owned binary module leaked.'
            Assert-LifecycleState ((Get-PSSubsystem -Kind CommandPredictor).Implementations.Name -notcontains 'Worktree') 'Loader-owned predictor registration leaked.'
        }
    }
    if ($expectedOwnCount -eq 1) {
        Assert-LifecycleState $divergentIdsObserved 'Fixture did not exercise divergent counters.'
        Assert-LifecycleState ([WorktreePredictor.WorktreeCommandPredictor]::Updates -ge 6) 'Predictor update wiring did not run on import.'
    }
    [pscustomobject]@{
        Mode = $Mode
        PriorState = $PriorState
        Cycles = 3
        ForceImports = 6
        DivergentIdsObserved = $divergentIdsObserved
        ExternalSubscribersPreserved = $externalSubscribers.Count
        ExternalJobsPreserved = $externalJobs.Count
    } | ConvertTo-Json -Compress
} finally {
    if ($module) { Remove-Module $module -Force -ErrorAction SilentlyContinue }
    Get-EventSubscriber -Force | ForEach-Object { Unregister-Event -SubscriptionId $_.SubscriptionId -ErrorAction SilentlyContinue }
    Get-Job | Remove-Job -Force -ErrorAction SilentlyContinue
    if ($externalBinary) { Remove-Module $externalBinary -Force -ErrorAction SilentlyContinue }
    $timer.Dispose()
    Set-Location -LiteralPath $originalLocation.ProviderPath -ErrorAction Stop
}
'@
    }

    AfterAll {
        if ($lifecycleRoot -and (Test-Path -LiteralPath $lifecycleRoot)) {
            if ((Split-Path $lifecycleRoot -Parent) -cne $TestDrive) {
                throw 'Refusing cleanup outside the owned lifecycle TestDrive.'
            }
            Remove-Item -LiteralPath $lifecycleRoot -Recurse -Force -ErrorAction Stop
        }
    }

    It 'preserves subscriber, job and binary ownership for <Mode> with <PriorState> state (AlreadyRemoved=<AlreadyRemoved>)' -ForEach @(
        @{ Mode = 'SourceWithType'; PriorState = 'Actionless'; AlreadyRemoved = $false }
        @{ Mode = 'SourceWithType'; PriorState = 'Jobs'; AlreadyRemoved = $false }
        @{ Mode = 'SourceWithType'; PriorState = 'Mixed'; AlreadyRemoved = $false }
        @{ Mode = 'SourceWithType'; PriorState = 'Mixed'; AlreadyRemoved = $true }
        @{ Mode = 'SourceWithoutPredictor'; PriorState = 'Mixed'; AlreadyRemoved = $false }
        @{ Mode = 'Bundled'; PriorState = 'Mixed'; AlreadyRemoved = $false }
        @{ Mode = 'Preloaded'; PriorState = 'Mixed'; AlreadyRemoved = $false }
    ) {
        $scenarioRoot = Join-Path $lifecycleRoot ([guid]::NewGuid().ToString('N'))
        $arguments = @(
            '-NoProfile', '-NonInteractive', '-File', $lifecycleChild,
            '-Source', $lifecycleSource, '-Root', $scenarioRoot,
            '-Mode', $Mode, '-PriorState', $PriorState
        )
        if ($AlreadyRemoved) { $arguments += '-AlreadyRemoved' }
        $output = & $lifecyclePwsh @arguments 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Isolated lifecycle test failed (exit $LASTEXITCODE): $($output -join [Environment]::NewLine)"
        }
        $result = ($output -join "`n") | ConvertFrom-Json
        $result.Cycles | Should -Be 3
        $result.ForceImports | Should -Be 6
        if ($Mode -ne 'SourceWithoutPredictor') {
            $result.DivergentIdsObserved | Should -BeTrue
        }
    }
}

Describe 'Restore-GitStash' {
    BeforeAll {
        $restoreLocation = Get-Location
        $restoreRoot = Join-Path $TestDrive 'restore-stash'
        if (Test-Path -LiteralPath $restoreRoot) { throw "Fixture already exists: $restoreRoot" }
        $null = New-Item -ItemType Directory -Path $restoreRoot -ErrorAction Stop
        $restoreEnvironment = @{}
        foreach ($key in @(
            'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_SYSTEM', 'GIT_CONFIG_NOSYSTEM',
            'GIT_CONFIG_COUNT', 'GIT_CONFIG_PARAMETERS', 'GIT_DIR', 'GIT_WORK_TREE',
            'GIT_COMMON_DIR', 'GIT_INDEX_FILE', 'GIT_OBJECT_DIRECTORY',
            'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_NAMESPACE', 'GIT_CEILING_DIRECTORIES',
            'GIT_DEFAULT_HASH', 'GIT_DEFAULT_REF_FORMAT', 'GIT_AUTHOR_DATE', 'GIT_COMMITTER_DATE'
        )) {
            $restoreEnvironment[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
            Remove-Item -LiteralPath "Env:$key" -ErrorAction Ignore
        }
        $env:GIT_CONFIG_GLOBAL = Join-Path $restoreRoot 'no-global-config'
        $env:GIT_CONFIG_SYSTEM = Join-Path $restoreRoot 'no-system-config'
        $env:GIT_CONFIG_NOSYSTEM = '1'
        $env:GIT_CONFIG_COUNT = '0'

        function Assert-RestoreTestPath {
            param([Parameter(Mandatory)][string]$Path)
            $root = [IO.Path]::GetFullPath((Join-Path $TestDrive 'restore-stash'))
            $full = [IO.Path]::GetFullPath($Path)
            if ($root -ne $restoreRoot -or
                -not $full.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::Ordinal) -or
                -not (Test-Path -LiteralPath $full -PathType Container)) {
                throw "Not an owned restore fixture: $Path"
            }
            $item = Get-Item -LiteralPath $full
            while ($item.FullName -ne $root) {
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked fixture: $Path" }
                $item = $item.Parent
            }
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked fixture root: $root" }
        }

        function Invoke-RestoreTestGit {
            param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$Arguments, [switch]$Initialize)
            Assert-RestoreTestPath $Path
            if (-not $Initialize) {
                # All fixtures own their .git directory; never follow an external worktree gitdir.
                $gitDir = Get-Item -LiteralPath (Join-Path $Path '.git') -Force -ErrorAction Stop
                if (-not $gitDir.PSIsContainer -or $gitDir.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    throw "Not an owned git directory: $Path"
                }
            }
            Invoke-Git (@('-C', $Path) + $Arguments)
        }

        function New-RestoreTestRepo {
            param([string]$Name = 'r')
            $path = Join-Path $restoreRoot $Name
            if (Test-Path -LiteralPath $path) { throw "Fixture already exists: $path" }
            $null = New-Item -ItemType Directory -Path $path -ErrorAction Stop
            Invoke-RestoreTestGit $path @('-c', 'init.templateDir=', 'init', '-b', 'main', '--quiet') -Initialize
            Invoke-RestoreTestGit $path @('config', 'core.autocrlf', 'false')
            Invoke-RestoreTestGit $path @('config', 'user.name', 'Test User')
            Invoke-RestoreTestGit $path @('config', 'user.email', 'test@example.com')
            foreach ($name in @('tracked.txt', 'other.txt', 'keep.txt')) {
                Set-Content -LiteralPath (Join-Path $path $name) -Value 'initial'
            }
            Invoke-RestoreTestGit $path @('add', '--', 'tracked.txt', 'other.txt', 'keep.txt')
            Invoke-RestoreTestGit $path @('commit', '--quiet', '-m', 'initial')
            $path
        }

        function Add-RestoreTestStash {
            param([Parameter(Mandatory)][string]$Path, [string]$Value = 'stashed', [string]$File = 'tracked.txt')
            Assert-RestoreTestPath $Path
            Set-Content -LiteralPath (Join-Path $Path $File) -Value $Value
            Invoke-RestoreTestGit $Path @('stash', 'push', '--quiet', '-m', $Value)
            Invoke-RestoreTestGit $Path @('rev-parse', 'refs/stash')
        }

        function Get-RestoreTestState {
            param([Parameter(Mandatory)][string]$Path)
            Assert-RestoreTestPath $Path
            [ordered]@{
                Head = Invoke-RestoreTestGit $Path @('rev-parse', 'HEAD')
                Stashes = @(Invoke-RestoreTestGit $Path @('stash', 'list', '--format=%gd %H %gs'))
                Index = @(Invoke-RestoreTestGit $Path @('ls-files', '--stage'))
                Files = @(Get-ChildItem -LiteralPath $Path -File | Sort-Object Name | ForEach-Object {
                    "$($_.Name):$([Convert]::ToBase64String([IO.File]::ReadAllBytes($_.FullName)))"
                })
            } | ConvertTo-Json -Depth 5 -Compress
        }

        function Clear-RestoreTestFixtures {
            if ($restoreRoot -ne (Join-Path $TestDrive 'restore-stash')) { throw 'Invalid cleanup root.' }
            Set-Location -LiteralPath $TestDrive -ErrorAction Stop
            foreach ($item in Get-ChildItem -LiteralPath $restoreRoot -Force -ErrorAction Stop) {
                if (-not $item.PSIsContainer) { throw "Unexpected fixture file: $($item.FullName)" }
                Assert-RestoreTestPath $item.FullName
                # Pester 5.9 shares TestDrive across Describe blocks; remove our read-only Git objects explicitly.
                Get-ChildItem -LiteralPath $item.FullName -Recurse -Force -File -ErrorAction Stop |
                    ForEach-Object { $_.IsReadOnly = $false }
                Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
            }
        }
    }

    BeforeEach {
        Set-Location -LiteralPath $restoreRoot -ErrorAction Stop
    }

    AfterEach {
        Clear-RestoreTestFixtures
    }

    AfterAll {
        try {
            Clear-RestoreTestFixtures
            Remove-Item -LiteralPath $restoreRoot -Force -ErrorAction Stop
        } finally {
            foreach ($key in $restoreEnvironment.Keys) {
                if ($null -eq $restoreEnvironment[$key]) {
                    Remove-Item -LiteralPath "Env:$key" -ErrorAction Ignore
                } else {
                    [Environment]::SetEnvironmentVariable($key, $restoreEnvironment[$key], 'Process')
                }
            }
            Set-Location -LiteralPath $restoreLocation.Path -ErrorAction Stop
        }
    }

    It 'exports the command with help, standard path aliases and ShouldProcess' {
        $command = Get-Command Restore-GitStash -Module Shmuelie.Git
        $command.Parameters['Path'].Aliases | Should -Contain 'RepositoryPath'
        $command.Parameters['Path'].Aliases | Should -Contain 'RepoPath'
        $command.Parameters.Keys | Should -Contain 'WhatIf'
        $command.Parameters.Keys | Should -Contain 'Confirm'
        (Get-Help Restore-GitStash).Description.Text | Should -Not -BeNullOrEmpty
    }

    It 'passes only discrete native pop arguments for <Selector>' -ForEach @(
        @{ Selector = 'default'; Options = @{}; Expected = 'stash@{0}' }
        @{ Selector = 'explicit'; Options = @{ Stash = 'stash@{12}' }; Expected = 'stash@{12}' }
        @{ Selector = 'maximum index'; Options = @{ Stash = 'stash@{2147483647}' }; Expected = 'stash@{2147483647}' }
    ) {
        InModuleScope Shmuelie.Git -Parameters @{ Options = $Options; Expected = $Expected } {
            Mock Resolve-GitRepositoryPath { 'resolved repo & ; [literal]' }
            Mock Invoke-Git { [pscustomobject]@{ ExitCode = 0 } }
            Restore-GitStash -Path 'input repo' @Options -Confirm:$false | Should -BeNullOrEmpty
            Should -Invoke Invoke-Git -Exactly -Times 1 -ParameterFilter {
                $Path -ceq 'resolved repo & ; [literal]' -and
                ($Arguments -join '|') -ceq "stash|pop|--|$Expected"
            }
        }
    }

    It 'rejects unsafe, ambiguous or out-of-range selectors: <Label>' -ForEach @(
        @{ Label = 'null'; Value = $null }, @{ Label = 'empty'; Value = '' },
        @{ Label = 'option'; Value = '--index' }, @{ Label = 'config'; Value = '-c' },
        @{ Label = 'number'; Value = '0' }, @{ Label = 'object ID'; Value = ('a' * 40) },
        @{ Label = 'ref'; Value = 'refs/stash' }, @{ Label = 'revision'; Value = 'stash@{0}^' },
        @{ Label = 'date'; Value = 'stash@{yesterday}' }, @{ Label = 'wildcard'; Value = 'stash@{*}' },
        @{ Label = 'leading zero'; Value = 'stash@{01}' }, @{ Label = 'negative'; Value = 'stash@{-1}' },
        @{ Label = 'case'; Value = 'STASH@{0}' }, @{ Label = 'overflow'; Value = 'stash@{2147483648}' },
        @{ Label = 'large overflow'; Value = 'stash@{99999999999999999999}' },
        @{ Label = 'newline'; Value = "stash@{0}`n" }, @{ Label = 'NUL'; Value = "stash@{0}`0" },
        @{ Label = 'shell'; Value = 'stash@{0};echo injected' }
    ) {
        InModuleScope Shmuelie.Git -Parameters @{ Value = $Value } {
            Mock Resolve-GitRepositoryPath { throw 'Must not discover a repository.' }
            Mock Invoke-Git { throw 'Must not invoke Git.' }
            { Restore-GitStash -Stash $Value -Confirm:$false } | Should -Throw
            Should -Invoke Resolve-GitRepositoryPath -Exactly -Times 0
            Should -Invoke Invoke-Git -Exactly -Times 0
        }
    }

    It 'does not retry native failure with apply or drop or emit a success diagnostic' {
        InModuleScope Shmuelie.Git {
            Mock Resolve-GitRepositoryPath { 'fixture' }
            Mock Invoke-Git { Write-Error 'Native failure.' }
            Mock Write-Verbose {}
            Restore-GitStash -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable failures | Should -BeNullOrEmpty
            $failures | Should -Not -BeNullOrEmpty
            Should -Invoke Invoke-Git -Exactly -Times 1
            Should -Invoke Write-Verbose -Exactly -Times 0
        }
    }

    Context 'isolated native working trees' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
        BeforeEach {
            $restoreRepo = New-RestoreTestRepo -Name 'r &;[x]'
            Assert-RestoreTestPath $restoreRepo
        }

        It 'pops the newest stash by default, preserving other stashes and unrelated dirty files' {
            $older = Add-RestoreTestStash $restoreRepo -Value 'older' -File 'other.txt'
            $null = Add-RestoreTestStash $restoreRepo
            Set-Content -LiteralPath (Join-Path $restoreRepo 'keep.txt') -Value 'keep staged'
            Invoke-RestoreTestGit $restoreRepo @('add', '--', 'keep.txt')
            Set-Content -LiteralPath (Join-Path $restoreRepo 'keep.txt') -Value 'keep unstaged'
            Set-Content -LiteralPath (Join-Path $restoreRepo 'untracked.txt') -Value 'keep untracked'
            Set-Location -LiteralPath $restoreRepo -ErrorAction Stop
            $global:LASTEXITCODE = 73
            Restore-GitStash -Confirm:$false | Should -BeNullOrEmpty
            $global:LASTEXITCODE | Should -Be 73
            (Get-Location).Path | Should -BeExactly $restoreRepo
            Get-Content -LiteralPath (Join-Path $restoreRepo 'tracked.txt') | Should -BeExactly 'stashed'
            Get-Content -LiteralPath (Join-Path $restoreRepo 'other.txt') | Should -BeExactly 'initial'
            Get-Content -LiteralPath (Join-Path $restoreRepo 'keep.txt') | Should -BeExactly 'keep unstaged'
            Get-Content -LiteralPath (Join-Path $restoreRepo 'untracked.txt') | Should -BeExactly 'keep untracked'
            Invoke-RestoreTestGit $restoreRepo @('show', ':keep.txt') | Should -BeExactly 'keep staged'
            Invoke-RestoreTestGit $restoreRepo @('stash', 'list', '--format=%H') | Should -BeExactly $older
        }

        It 'pops an exact older entry without applying or dropping the newest entry' {
            $null = Add-RestoreTestStash $restoreRepo -Value 'older' -File 'other.txt'
            $newest = Add-RestoreTestStash $restoreRepo
            Restore-GitStash -Path $restoreRepo -Stash 'stash@{1}' -Confirm:$false | Should -BeNullOrEmpty
            Get-Content -LiteralPath (Join-Path $restoreRepo 'other.txt') | Should -BeExactly 'older'
            Get-Content -LiteralPath (Join-Path $restoreRepo 'tracked.txt') | Should -BeExactly 'initial'
            Invoke-RestoreTestGit $restoreRepo @('stash', 'list', '--format=%H') | Should -BeExactly $newest
        }

        It 'restores untracked files without reinstating the saved staged state' {
            Set-Content -LiteralPath (Join-Path $restoreRepo 'tracked.txt') -Value 'saved staged'
            Invoke-RestoreTestGit $restoreRepo @('add', '--', 'tracked.txt')
            Set-Content -LiteralPath (Join-Path $restoreRepo 'new.txt') -Value 'saved untracked'
            Invoke-RestoreTestGit $restoreRepo @('stash', 'push', '--quiet', '--include-untracked')
            Restore-GitStash -Path $restoreRepo -Confirm:$false
            Get-Content -LiteralPath (Join-Path $restoreRepo 'tracked.txt') | Should -BeExactly 'saved staged'
            Get-Content -LiteralPath (Join-Path $restoreRepo 'new.txt') | Should -BeExactly 'saved untracked'
            Invoke-RestoreTestGit $restoreRepo @('diff', '--cached', '--name-only') | Should -BeNullOrEmpty
            Invoke-RestoreTestGit $restoreRepo @('stash', 'list') | Should -BeNullOrEmpty
        }

        It 'targets only the selected repository through <Mode>' -ForEach @(
            @{ Mode = 'Path' }, @{ Mode = 'RepositoryPath' }, @{ Mode = 'RepoPath' },
            @{ Mode = 'pipeline string' }, @{ Mode = 'pipeline Path' },
            @{ Mode = 'pipeline RepositoryPath' }, @{ Mode = 'pipeline RepoPath' },
            @{ Mode = 'relative literal subdirectory' }
        ) {
            $otherRepo = New-RestoreTestRepo -Name 'untouched'
            $null = Add-RestoreTestStash $otherRepo -Value 'do not restore'
            $otherState = Get-RestoreTestState $otherRepo
            $null = Add-RestoreTestStash $restoreRepo
            Set-Location -LiteralPath $otherRepo -ErrorAction Stop
            if ($Mode -eq 'pipeline string') {
                $restoreRepo | Restore-GitStash -Confirm:$false
            } elseif ($Mode.StartsWith('pipeline ')) {
                [pscustomobject]@{ $Mode.Substring(9) = $restoreRepo } | Restore-GitStash -Confirm:$false
            } elseif ($Mode -eq 'relative literal subdirectory') {
                $null = New-Item -ItemType Directory -Path (Join-Path $restoreRepo 'nested [literal]') -ErrorAction Stop
                $relative = Join-Path '..' (Split-Path $restoreRepo -Leaf) 'nested [literal]'
                Restore-GitStash -Path $relative -Confirm:$false
            } else {
                $parameters = @{ $Mode = $restoreRepo }
                Restore-GitStash @parameters -Confirm:$false
            }
            (Get-Location).Path | Should -BeExactly $otherRepo
            Get-Content -LiteralPath (Join-Path $restoreRepo 'tracked.txt') | Should -BeExactly 'stashed'
            Invoke-RestoreTestGit $restoreRepo @('stash', 'list') | Should -BeNullOrEmpty
            Get-RestoreTestState $otherRepo | Should -BeExactly $otherState
        }

        It 'preserves files, index and stash entries with WhatIf' {
            $null = Add-RestoreTestStash $restoreRepo
            Set-Content -LiteralPath (Join-Path $restoreRepo 'keep.txt') -Value 'staged'
            Invoke-RestoreTestGit $restoreRepo @('add', '--', 'keep.txt')
            Set-Content -LiteralPath (Join-Path $restoreRepo 'keep.txt') -Value 'unstaged'
            Set-Content -LiteralPath (Join-Path $restoreRepo 'new.txt') -Value 'untracked'
            $before = Get-RestoreTestState $restoreRepo
            Restore-GitStash -Path $restoreRepo -WhatIf | Should -BeNullOrEmpty
            Get-RestoreTestState $restoreRepo | Should -BeExactly $before
        }

        It 'honors native confirmation answer <Answer>' -ForEach @(
            @{ Answer = 'n'; Restored = $false }
            @{ Answer = 'y'; Restored = $true }
        ) {
            $null = Add-RestoreTestStash $restoreRepo
            Set-Content -LiteralPath (Join-Path $restoreRepo 'keep.txt') -Value 'staged'
            Invoke-RestoreTestGit $restoreRepo @('add', '--', 'keep.txt')
            Set-Content -LiteralPath (Join-Path $restoreRepo 'keep.txt') -Value 'unstaged'
            $before = Get-RestoreTestState $restoreRepo
            $manifest = Join-Path $repoRoot 'modules' 'Shmuelie.Git' 'Shmuelie.Git.psd1'
            $childScript = @'
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath '__PATH__'
Import-Module '__MANIFEST__'
Restore-GitStash -Confirm
'COMPLETE'
'@.Replace('__PATH__', $restoreRepo.Replace("'", "''")).Replace('__MANIFEST__', $manifest.Replace("'", "''"))
            Assert-RestoreTestPath $restoreRepo
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript))
            $output = $Answer | & (Get-Process -Id $PID).Path -NoLogo -NoProfile -EncodedCommand $encoded -OutputFormat Text 2>&1
            $LASTEXITCODE | Should -Be 0
            ($output -join "`n") | Should -Match 'COMPLETE'
            if ($Restored) {
                Get-Content -LiteralPath (Join-Path $restoreRepo 'tracked.txt') | Should -BeExactly 'stashed'
                Invoke-RestoreTestGit $restoreRepo @('stash', 'list') | Should -BeNullOrEmpty
            } else {
                Get-RestoreTestState $restoreRepo | Should -BeExactly $before
            }
            Get-Content -LiteralPath (Join-Path $restoreRepo 'keep.txt') | Should -BeExactly 'unstaged'
            Invoke-RestoreTestGit $restoreRepo @('show', ':keep.txt') | Should -BeExactly 'staged'
        }

        It 'rejects implicit GitStash object selection and permits an explicit reflog selector' {
            $older = Add-RestoreTestStash $restoreRepo -Value 'older' -File 'other.txt'
            $newest = Add-RestoreTestStash $restoreRepo
            $saved = [pscustomobject]@{ PSTypeName = 'GitStash'; ObjectId = $older; RepositoryPath = $restoreRepo; Subject = 'older' }
            $before = Get-RestoreTestState $restoreRepo
            $saved | Restore-GitStash -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable failures | Should -BeNullOrEmpty
            $failures | Should -HaveCount 1
            $failures[0].FullyQualifiedErrorId | Should -BeLike 'GitStashSelectorRequired,*'
            { $saved | Restore-GitStash -Confirm:$false -ErrorAction Stop } | Should -Throw -ErrorId 'GitStashSelectorRequired,*'
            Get-RestoreTestState $restoreRepo | Should -BeExactly $before
            $saved | Restore-GitStash -Stash 'stash@{1}' -Confirm:$false
            Get-Content -LiteralPath (Join-Path $restoreRepo 'other.txt') | Should -BeExactly 'older'
            Invoke-RestoreTestGit $restoreRepo @('stash', 'list', '--format=%H') | Should -BeExactly $newest
        }

        It 'surfaces no-stash and missing-entry failures without modifying state: <Mode>' -ForEach @(
            @{ Mode = 'no stash'; Options = @{} }
            @{ Mode = 'missing selector'; Options = @{ Stash = 'stash@{10}' } }
        ) {
            if ($Mode -eq 'missing selector') { $null = Add-RestoreTestStash $restoreRepo }
            Set-Content -LiteralPath (Join-Path $restoreRepo 'keep.txt') -Value 'keep dirty'
            $before = Get-RestoreTestState $restoreRepo
            Restore-GitStash -Path $restoreRepo @Options -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable failures |
                Should -BeNullOrEmpty
            $failures | Should -HaveCount 1
            $failures[0].FullyQualifiedErrorId | Should -BeLike 'GitCommandFailed,*'
            $failures[0].TargetObject.ExitCode | Should -Not -Be 0
            $failures[0].TargetObject.StandardError | Should -Not -BeNullOrEmpty
            { Restore-GitStash -Path $restoreRepo @Options -Confirm:$false -ErrorAction Stop } |
                Should -Throw -ErrorId 'GitCommandFailed,*'
            Get-RestoreTestState $restoreRepo | Should -BeExactly $before
        }

        It 'preserves the stash and dirty files when Git refuses to overwrite local changes' {
            $null = Add-RestoreTestStash $restoreRepo
            Set-Content -LiteralPath (Join-Path $restoreRepo 'tracked.txt') -Value 'keep dirty'
            $before = Get-RestoreTestState $restoreRepo
            Restore-GitStash -Path $restoreRepo -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable failures | Should -BeNullOrEmpty
            $failures | Should -HaveCount 1
            $failures[0].TargetObject.ExitCode | Should -Not -Be 0
            $failures[0].TargetObject.StandardError | Should -Match 'would be overwritten'
            Get-RestoreTestState $restoreRepo | Should -BeExactly $before
        }

        It 'surfaces a real conflict and preserves the stash, conflict markers and unrelated dirty files' {
            $stashId = Add-RestoreTestStash $restoreRepo
            Set-Content -LiteralPath (Join-Path $restoreRepo 'tracked.txt') -Value 'competing commit'
            Invoke-RestoreTestGit $restoreRepo @('add', '--', 'tracked.txt')
            Invoke-RestoreTestGit $restoreRepo @('commit', '--quiet', '-m', 'competing')
            Set-Content -LiteralPath (Join-Path $restoreRepo 'keep.txt') -Value 'keep dirty'
            Restore-GitStash -Path $restoreRepo -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable failures | Should -BeNullOrEmpty
            $failures | Should -HaveCount 1
            $failures[0].FullyQualifiedErrorId | Should -BeLike 'GitCommandFailed,*'
            $failures[0].TargetObject.ExitCode | Should -Not -Be 0
            $failures[0].TargetObject.StandardOutput | Should -Match 'CONFLICT'
            Invoke-RestoreTestGit $restoreRepo @('stash', 'list', '--format=%H') | Should -BeExactly $stashId
            @(Invoke-RestoreTestGit $restoreRepo @('ls-files', '--unmerged')) | Should -HaveCount 3
            Get-Content -LiteralPath (Join-Path $restoreRepo 'tracked.txt') -Raw | Should -Match '<<<<<<<'
            Get-Content -LiteralPath (Join-Path $restoreRepo 'keep.txt') | Should -BeExactly 'keep dirty'
        }

        It 'rejects invalid paths without falling back to the current repository' {
            $null = Add-RestoreTestStash $restoreRepo
            $before = Get-RestoreTestState $restoreRepo
            Set-Location -LiteralPath $restoreRepo -ErrorAction Stop
            foreach ($path in @($null, '', ' ', (Join-Path $restoreRoot 'missing'), $restoreRoot, (Join-Path $restoreRepo 'tracked.txt'))) {
                { Restore-GitStash -Path $path -Confirm:$false -ErrorAction Stop } | Should -Throw
                Get-RestoreTestState $restoreRepo | Should -BeExactly $before
            }
        }

        It 'rejects a bare repository' {
            $bare = Join-Path $restoreRoot 'bare'
            $null = New-Item -ItemType Directory -Path $bare -ErrorAction Stop
            Invoke-RestoreTestGit $bare @('-c', 'init.templateDir=', 'init', '--bare', '--quiet') -Initialize
            { Restore-GitStash -Path $bare -Confirm:$false -ErrorAction Stop } | Should -Throw
        }
    }
}

Describe 'Restore-Items' {
    BeforeAll {
        $restoreFixtureRoot = Join-Path $TestDrive 'restore-items'
        $restoreModuleManifest = Join-Path $repoRoot 'modules/Shmuelie.Git/Shmuelie.Git.psd1'

        function Assert-RestoreFixturePath {
            param([Parameter(Mandatory)][string]$Path)

            if ([IO.Path]::GetRelativePath($TestDrive, $restoreFixtureRoot) -cne 'restore-items') {
                throw 'The restore fixture must be the owned restore-items directory under TestDrive.'
            }
            $relative = [IO.Path]::GetRelativePath($restoreFixtureRoot, [IO.Path]::GetFullPath($Path))
            if ([IO.Path]::IsPathRooted($relative) -or $relative -eq '..' -or
                $relative.StartsWith("..$([IO.Path]::DirectorySeparatorChar)")) {
                throw "Refusing access outside the owned restore fixture: '$Path'."
            }
            # Do not follow a link out of the owned fixture, including on cleanup.
            $ancestor = [IO.Path]::GetFullPath($Path)
            while ($ancestor -and $ancestor -ne (Split-Path $restoreFixtureRoot -Parent)) {
                if (Test-Path -LiteralPath $ancestor) {
                    $item = Get-Item -LiteralPath $ancestor -Force -ErrorAction Stop
                    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                        throw "Refusing a linked restore fixture path: '$ancestor'."
                    }
                }
                $ancestor = Split-Path $ancestor -Parent
            }
        }

        function Invoke-RestoreFixtureGit {
            param(
                [Parameter(Mandatory, Position = 0)][string[]]$Arguments,
                [string]$Path = $restoreRepo,
                [switch]$Initialize
            )

            Assert-RestoreFixturePath $Path
            if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
                throw "Missing restore fixture directory: '$Path'."
            }
            if (-not $Initialize -and -not (Test-Path -LiteralPath (Join-Path $Path '.git') -PathType Container)) {
                throw "Missing owned restore fixture repository: '$Path'."
            }
            $result = & (Get-Module Shmuelie.Git) {
                param($Tokens)
                Invoke-GitProcess -Arguments $Tokens
            } (@('-C', $Path, '--literal-pathspecs') + $Arguments)
            if ($result.ExitCode -ne 0) {
                throw "Restore fixture git failed ($($result.ExitCode)): $($result.StandardError)"
            }
            $result.StandardOutput.TrimEnd()
        }

        function Set-RestoreFixtureFile {
            param([Parameter(Mandatory)][string]$Name, [string]$Content)

            $file = Join-Path $restoreRepo $Name
            Assert-RestoreFixturePath $file
            $null = [IO.Directory]::CreateDirectory((Split-Path $file -Parent))
            [IO.File]::WriteAllText($file, $Content, [Text.UTF8Encoding]::new($false))
        }

        function Get-RestoreFixtureSnapshot {
            Assert-RestoreFixturePath $restoreRepo
            $files = [ordered]@{}
            foreach ($file in Get-ChildItem -LiteralPath $restoreRepo -File -Force -Recurse |
                Where-Object { -not $_.FullName.StartsWith((Join-Path $restoreRepo '.git') + [IO.Path]::DirectorySeparatorChar) } |
                Sort-Object FullName) {
                Assert-RestoreFixturePath $file.FullName
                $files[[IO.Path]::GetRelativePath($restoreRepo, $file.FullName)] =
                    [Convert]::ToBase64String([IO.File]::ReadAllBytes($file.FullName))
            }
            [ordered]@{
                Head = Invoke-RestoreFixtureGit @('rev-parse', 'HEAD')
                Index = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $restoreRepo '.git/index')))
                Files = $files
            } | ConvertTo-Json -Depth 5 -Compress
        }

        if (-not ('RestoreItemsConfirmationHost' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Management.Automation;
using System.Management.Automation.Host;
using System.Security;

public sealed class RestoreItemsConfirmationHost : PSHost
{
    public readonly RestoreItemsConfirmationUI PromptUI = new RestoreItemsConfirmationUI();
    public override Guid InstanceId { get; } = Guid.NewGuid();
    public override string Name => "RestoreItemsConfirmationHost";
    public override Version Version => new Version(1, 0);
    public override PSHostUserInterface UI => PromptUI;
    public override CultureInfo CurrentCulture => CultureInfo.InvariantCulture;
    public override CultureInfo CurrentUICulture => CultureInfo.InvariantCulture;
    public override void SetShouldExit(int exitCode) { }
    public override void EnterNestedPrompt() => throw new NotSupportedException();
    public override void ExitNestedPrompt() => throw new NotSupportedException();
    public override void NotifyBeginApplication() { }
    public override void NotifyEndApplication() { }
}

public sealed class RestoreItemsConfirmationUI : PSHostUserInterface
{
    public int PromptCount;
    public override PSHostRawUserInterface RawUI => null;
    public override int PromptForChoice(string caption, string message, Collection<ChoiceDescription> choices, int defaultChoice)
    {
        PromptCount++;
        for (int i = 0; i < choices.Count; i++)
            if (choices[i].Label.Replace("&", "") == "No") return i;
        throw new InvalidOperationException("Expected a No confirmation choice.");
    }
    public override string ReadLine() => throw new NotSupportedException();
    public override SecureString ReadLineAsSecureString() => throw new NotSupportedException();
    public override Dictionary<string, PSObject> Prompt(string caption, string message, Collection<FieldDescription> descriptions) => throw new NotSupportedException();
    public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName) => throw new NotSupportedException();
    public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName, PSCredentialTypes types, PSCredentialUIOptions options) => throw new NotSupportedException();
    public override void Write(string value) { }
    public override void Write(ConsoleColor foreground, ConsoleColor background, string value) { }
    public override void WriteLine(string value) { }
    public override void WriteErrorLine(string value) { }
    public override void WriteDebugLine(string value) { }
    public override void WriteVerboseLine(string value) { }
    public override void WriteWarningLine(string value) { }
    public override void WriteProgress(long sourceId, ProgressRecord record) { }
}
'@
        }
    }

    BeforeEach {
        $restoreEnvironment = @{}
        $restoreLocationPushed = $false
        $restoreRootCreated = $false
        # Fail before any mutation if location setup fails. Never fall back to
        # the task worktree when creating a repository or restoring a file.
        Push-Location -LiteralPath $TestDrive -ErrorAction Stop
        $restoreLocationPushed = $true
        Assert-RestoreFixturePath $restoreFixtureRoot
        $null = New-Item -ItemType Directory -Path $restoreFixtureRoot -ErrorAction Stop
        $restoreRootCreated = $true
        foreach ($entry in Get-ChildItem Env: | Where-Object Name -Like 'GIT_*') {
            $restoreEnvironment[$entry.Name] = $entry.Value
            [Environment]::SetEnvironmentVariable($entry.Name, $null, 'Process')
        }
        $env:GIT_CONFIG_GLOBAL = Join-Path $restoreFixtureRoot 'no-global'
        $env:GIT_CONFIG_SYSTEM = Join-Path $restoreFixtureRoot 'no-system'
        $env:GIT_CONFIG_NOSYSTEM = '1'
        $env:GIT_CONFIG_COUNT = '0'
        $env:GIT_CEILING_DIRECTORIES = $TestDrive
        $env:GIT_AUTHOR_DATE = '2025-01-01T00:00:00Z'
        $env:GIT_COMMITTER_DATE = $env:GIT_AUTHOR_DATE
        $restoreRepo = Join-Path $restoreFixtureRoot 'repo [literal]'
        Assert-RestoreFixturePath $restoreRepo
        $null = New-Item -ItemType Directory -Path $restoreRepo -ErrorAction Stop
        $null = Invoke-RestoreFixtureGit @('-c', 'init.templateDir=', 'init', '--quiet', '-b', 'main') -Initialize
        foreach ($config in @(
            @('user.name', 'Restore Test'), @('user.email', 'test@example.com'),
            @('commit.gpgsign', 'false'), @('tag.gpgsign', 'false'), @('core.autocrlf', 'false'),
            @('core.hooksPath', (Join-Path $restoreFixtureRoot 'no-hooks')),
            @('core.fsmonitor', 'false'), @('core.untrackedCache', 'false'),
            @('core.ignoreCase', 'false'), @('core.sparseCheckout', 'false')
        )) {
            $null = Invoke-RestoreFixtureGit (@('config', '--local') + $config)
        }
        $restoreNames = @(
            'alpha.txt', 'beta.txt', 'space name.txt', '[literal].txt', 'l.txt',
            '--source=HEAD~1', 'semi; $(echo injected).txt', 'sub/item.txt',
            "caf$([char]0xe9)-$([char]0x65e5).txt"
        )
        foreach ($name in $restoreNames) { Set-RestoreFixtureFile $name 'base' }
        $null = Invoke-RestoreFixtureGit (@('add', '--') + $restoreNames)
        $null = Invoke-RestoreFixtureGit @('commit', '--quiet', '-m', 'base')
        $null = Invoke-RestoreFixtureGit @('tag', 'restore-base')
        $restoreBaseTree = Invoke-RestoreFixtureGit @('rev-parse', 'HEAD^{tree}')
        foreach ($name in $restoreNames) { Set-RestoreFixtureFile $name 'head' }
        $null = Invoke-RestoreFixtureGit (@('add', '--') + $restoreNames)
        $null = Invoke-RestoreFixtureGit @('commit', '--quiet', '-m', 'head')
        foreach ($name in $restoreNames) { Set-RestoreFixtureFile $name 'staged' }
        $null = Invoke-RestoreFixtureGit (@('add', '--') + $restoreNames)
        foreach ($name in $restoreNames) { Set-RestoreFixtureFile $name 'unstaged' }
        $restoreIndexTree = Invoke-RestoreFixtureGit @('write-tree')
        $restoreHead = Invoke-RestoreFixtureGit @('rev-parse', 'HEAD')
    }

    AfterEach {
        try {
            if ($restoreLocationPushed) { Pop-Location -ErrorAction Stop }
            if ($restoreRootCreated) {
                Assert-RestoreFixturePath $restoreFixtureRoot
                foreach ($item in Get-ChildItem -LiteralPath $restoreFixtureRoot -Force -Recurse -ErrorAction Stop) {
                    Assert-RestoreFixturePath $item.FullName
                    if (-not $item.PSIsContainer) { $item.IsReadOnly = $false }
                }
                Remove-Item -LiteralPath $restoreFixtureRoot -Force -Recurse -ErrorAction Stop
            }
        } finally {
            if ($restoreRootCreated) {
                foreach ($entry in Get-ChildItem Env: | Where-Object Name -Like 'GIT_*') {
                    [Environment]::SetEnvironmentVariable($entry.Name, $null, 'Process')
                }
                foreach ($key in $restoreEnvironment.Keys) {
                    [Environment]::SetEnvironmentVariable($key, $restoreEnvironment[$key], 'Process')
                }
            }
        }
    }

    It 'exports an approved high-impact command with required files, path aliases, help and no Force' {
        $command = Get-Command Restore-Items -Module Shmuelie.Git
        (Get-Verb Restore).Verb | Should -BeExactly $command.Verb
        $binding = $command.ScriptBlock.Attributes |
            Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] }
        $binding.SupportsShouldProcess | Should -BeTrue
        $binding.ConfirmImpact | Should -Be 'High'
        $command.Parameters.Path.Aliases | Should -Be @('RepositoryPath', 'RepoPath')
        $command.Parameters.ContainsKey('Force') | Should -BeFalse
        $parameter = $command.Parameters.Files.Attributes |
            Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] }
        $parameter.Mandatory | Should -BeTrue
        $parameter.Position | Should -Be 0
        (Import-PowerShellDataFile $restoreModuleManifest).FunctionsToExport | Should -Contain 'Restore-Items'
        (Get-Help Restore-Items).Description.Text | Should -Match 'index'
    }

    It 'restores only unstaged content by default, preserving all staged changes and HEAD' {
        Restore-Items 'alpha.txt' -Path $restoreRepo -Confirm:$false -ErrorAction Stop | Should -BeNullOrEmpty
        [IO.File]::ReadAllText((Join-Path $restoreRepo 'alpha.txt')) | Should -BeExactly 'staged'
        [IO.File]::ReadAllText((Join-Path $restoreRepo 'beta.txt')) | Should -BeExactly 'unstaged'
        Invoke-RestoreFixtureGit @('write-tree') | Should -BeExactly $restoreIndexTree
        Invoke-RestoreFixtureGit @('rev-parse', 'HEAD') | Should -BeExactly $restoreHead
    }

    It 'restores both index and working tree from HEAD only with IncludeIndex' {
        Restore-Items 'alpha.txt' -Path $restoreRepo -IncludeIndex -Confirm:$false -ErrorAction Stop
        [IO.File]::ReadAllText((Join-Path $restoreRepo 'alpha.txt')) | Should -BeExactly 'head'
        Invoke-RestoreFixtureGit @('show', ':alpha.txt') | Should -BeExactly 'head'
        Invoke-RestoreFixtureGit @('show', ':beta.txt') | Should -BeExactly 'staged'
        [IO.File]::ReadAllText((Join-Path $restoreRepo 'beta.txt')) | Should -BeExactly 'unstaged'
        Invoke-RestoreFixtureGit @('rev-parse', 'HEAD') | Should -BeExactly $restoreHead
    }

    It 'uses an explicit <SourceKind> source with IncludeIndex=<Index>' -ForEach @(
        @{ SourceKind = 'revision'; Index = $false }, @{ SourceKind = 'revision'; Index = $true },
        @{ SourceKind = 'tag'; Index = $false }, @{ SourceKind = 'tree'; Index = $true }
    ) {
        $source = switch ($SourceKind) { revision { 'HEAD~1' } tag { 'restore-base' } tree { $restoreBaseTree } }
        Restore-Items 'alpha.txt' -Path $restoreRepo -Source $source -IncludeIndex:$Index -Confirm:$false -ErrorAction Stop
        [IO.File]::ReadAllText((Join-Path $restoreRepo 'alpha.txt')) | Should -BeExactly 'base'
        Invoke-RestoreFixtureGit @('show', ':alpha.txt') | Should -BeExactly $(if ($Index) { 'base' } else { 'staged' })
        if (-not $Index) { Invoke-RestoreFixtureGit @('write-tree') | Should -BeExactly $restoreIndexTree }
        Invoke-RestoreFixtureGit @('rev-parse', 'HEAD') | Should -BeExactly $restoreHead
    }

    It 'restores multiple literal Unicode, space, bracket, dash and shell-metacharacter filenames' {
        $selected = @($restoreNames | Where-Object { $_ -notin @('alpha.txt', 'beta.txt', 'l.txt', 'sub/item.txt') })
        Restore-Items -Files $selected -Path $restoreRepo -Confirm:$false -ErrorAction Stop
        foreach ($name in $selected) {
            [IO.File]::ReadAllText((Join-Path $restoreRepo $name)) | Should -BeExactly 'staged'
        }
        [IO.File]::ReadAllText((Join-Path $restoreRepo 'l.txt')) | Should -BeExactly 'unstaged'
        [IO.File]::ReadAllText((Join-Path $restoreRepo 'alpha.txt')) | Should -BeExactly 'unstaged'
        Invoke-RestoreFixtureGit @('write-tree') | Should -BeExactly $restoreIndexTree
    }

    It 'restores an actual colon-prefixed filename on supporting platforms' -Skip:($PSVersionTable.Platform -eq 'Win32NT') {
        Set-RestoreFixtureFile ':literal.txt' 'staged-colon'
        $null = Invoke-RestoreFixtureGit @('add', '--', ':literal.txt')
        Set-RestoreFixtureFile ':literal.txt' 'unstaged-colon'
        Restore-Items ':literal.txt' -Path $restoreRepo -Confirm:$false -ErrorAction Stop
        [IO.File]::ReadAllText((Join-Path $restoreRepo ':literal.txt')) | Should -BeExactly 'staged-colon'
        [IO.File]::ReadAllText((Join-Path $restoreRepo 'alpha.txt')) | Should -BeExactly 'unstaged'
    }

    It 'does not broaden literal operand <Operand> to a pattern or option' -ForEach @(
        @{ Operand = '*' }, @{ Operand = ':' }, @{ Operand = ':(top)*' },
        @{ Operand = ':(exclude)alpha.txt' }, @{ Operand = '--staged' },
        @{ Operand = '--pathspec-from-file=alpha.txt' }
    ) {
        $before = Get-RestoreFixtureSnapshot
        { Restore-Items -Files $Operand -Path $restoreRepo -Confirm:$false -ErrorAction Stop } | Should -Throw
        Get-RestoreFixtureSnapshot | Should -BeExactly $before
    }

    It 'passes colon, pathspec-like and option-like strings as individual literal operands to the shared helper' {
        $before = Get-RestoreFixtureSnapshot
        InModuleScope Shmuelie.Git -Parameters @{ Fixture = $restoreRepo } {
            param($Fixture)
            $names = @('space name.txt', ':literal.txt', 'a:b', ':(top)*', '--staged', '[x].txt')
            Mock Invoke-Git {
                param($Path)
                [PSCustomObject]@{ RepositoryPath = $Path; StandardOutput = ''; ExitCode = 0 }
            }
            Restore-Items -Files $names -Path $Fixture -Confirm:$false -ErrorAction Stop
            Should -Invoke Invoke-Git -Times 1 -Exactly -ParameterFilter {
                $Arguments[1] -eq 'restore' -and
                ($Arguments -join "`n") -ceq (@(
                    '--literal-pathspecs', 'restore', '--worktree', '--no-recurse-submodules', '--'
                ) + $names -join "`n") -and
                $Path -ceq $Fixture -and
                $Environment.GIT_LITERAL_PATHSPECS -eq '1' -and
                $null -eq $Environment.GIT_GLOB_PATHSPECS -and
                $null -eq $Environment.GIT_NOGLOB_PATHSPECS -and
                $null -eq $Environment.GIT_ICASE_PATHSPECS
            }
            Should -Invoke Invoke-Git -Times 2 -Exactly
        }
        Get-RestoreFixtureSnapshot | Should -BeExactly $before
    }

    It 'overrides ambient pathspec expansion only in the child Git process' {
        $env:GIT_GLOB_PATHSPECS = '1'
        $env:GIT_NOGLOB_PATHSPECS = '1'
        $env:GIT_ICASE_PATHSPECS = '1'
        $env:GIT_LITERAL_PATHSPECS = '0'
        Restore-Items '[literal].txt' -Path $restoreRepo -Confirm:$false -ErrorAction Stop
        [IO.File]::ReadAllText((Join-Path $restoreRepo '[literal].txt')) | Should -BeExactly 'staged'
        [IO.File]::ReadAllText((Join-Path $restoreRepo 'l.txt')) | Should -BeExactly 'unstaged'
        $env:GIT_GLOB_PATHSPECS | Should -BeExactly '1'
        $env:GIT_NOGLOB_PATHSPECS | Should -BeExactly '1'
        $env:GIT_ICASE_PATHSPECS | Should -BeExactly '1'
        $env:GIT_LITERAL_PATHSPECS | Should -BeExactly '0'
    }

    It 'uses repository aliases and relative, absolute or omitted paths without changing cwd' {
        $location = (Get-Location).ProviderPath
        Restore-Items 'alpha.txt' -RepositoryPath ([IO.Path]::GetRelativePath($location, $restoreRepo)) -Confirm:$false -ErrorAction Stop
        (Get-Location).ProviderPath | Should -BeExactly $location
        Restore-Items (Join-Path $restoreRepo 'beta.txt') -RepoPath $restoreRepo -Confirm:$false -ErrorAction Stop
        $subdirectory = Join-Path $restoreRepo 'sub'
        Assert-RestoreFixturePath $subdirectory
        Push-Location -LiteralPath $subdirectory -ErrorAction Stop
        try {
            Restore-Items 'item.txt' -Confirm:$false -ErrorAction Stop
            (Get-Location).ProviderPath | Should -BeExactly $subdirectory
            Restore-Items '../space name.txt' -Path . -Confirm:$false -ErrorAction Stop
        } finally {
            Pop-Location
        }
        foreach ($name in @('alpha.txt', 'beta.txt', 'sub/item.txt', 'space name.txt')) {
            [IO.File]::ReadAllText((Join-Path $restoreRepo $name)) | Should -BeExactly 'staged'
        }
        (Get-Location).ProviderPath | Should -BeExactly $location
    }

    It 'limits explicit dot selection to the repository subdirectory' {
        Restore-Items '.' -Path (Join-Path $restoreRepo 'sub') -Confirm:$false -ErrorAction Stop
        [IO.File]::ReadAllText((Join-Path $restoreRepo 'sub/item.txt')) | Should -BeExactly 'staged'
        [IO.File]::ReadAllText((Join-Path $restoreRepo 'alpha.txt')) | Should -BeExactly 'unstaged'
    }

    It 'restores deleted tracked files, but does not clean untracked files' {
        $deleted = Join-Path $restoreRepo 'alpha.txt'
        Assert-RestoreFixturePath $deleted
        Remove-Item -LiteralPath $deleted -ErrorAction Stop
        Set-RestoreFixtureFile 'untracked.txt' 'keep'
        Restore-Items '.' -Path $restoreRepo -Confirm:$false -ErrorAction Stop
        [IO.File]::ReadAllText($deleted) | Should -BeExactly 'staged'
        [IO.File]::ReadAllText((Join-Path $restoreRepo 'untracked.txt')) | Should -BeExactly 'keep'
    }

    It 'removes a selected staged addition absent from HEAD with IncludeIndex' {
        Set-RestoreFixtureFile 'added.txt' 'new'
        $null = Invoke-RestoreFixtureGit @('add', '--', 'added.txt')
        Restore-Items 'added.txt' -Path $restoreRepo -IncludeIndex -Confirm:$false -ErrorAction Stop
        Test-Path -LiteralPath (Join-Path $restoreRepo 'added.txt') | Should -BeFalse
        Invoke-RestoreFixtureGit @('ls-files', '--', 'added.txt') | Should -BeNullOrEmpty
    }

    It 'does not mutate files, HEAD, index bytes or cwd under WhatIf with IncludeIndex=<Index>' -ForEach @(
        @{ Index = $false }, @{ Index = $true }
    ) {
        $before = Get-RestoreFixtureSnapshot
        $location = (Get-Location).ProviderPath
        Restore-Items 'alpha.txt', 'space name.txt' -Path $restoreRepo -Source HEAD~1 -IncludeIndex:$Index -WhatIf -ErrorAction Stop
        Get-RestoreFixtureSnapshot | Should -BeExactly $before
        (Get-Location).ProviderPath | Should -BeExactly $location
    }

    It 'leaves the entire fixture unchanged when high-impact confirmation is declined' {
        Assert-RestoreFixturePath $restoreRepo
        $before = Get-RestoreFixtureSnapshot
        $confirmationHost = [RestoreItemsConfirmationHost]::new()
        $runspace = [runspacefactory]::CreateRunspace($confirmationHost)
        $pipeline = [powershell]::Create()
        try {
            $runspace.Open()
            $pipeline.Runspace = $runspace
            $null = $pipeline.AddScript({
                param($Manifest, $Directory)
                $ErrorActionPreference = 'Stop'
                Set-Location -LiteralPath $Directory
                Import-Module $Manifest -Force
                Restore-Items 'alpha.txt' -Path $Directory -IncludeIndex -Confirm -ErrorAction Stop
                (Get-Location).ProviderPath
            }).AddArgument($restoreModuleManifest).AddArgument($restoreRepo)
            $output = $pipeline.Invoke()
            $pipeline.HadErrors | Should -BeFalse -Because ($pipeline.Streams.Error -join '; ')
            $confirmationHost.PromptUI.PromptCount | Should -Be 1
            $output | Should -Be @($restoreRepo)
        } finally {
            $pipeline.Dispose()
            $runspace.Dispose()
        }
        Get-RestoreFixtureSnapshot | Should -BeExactly $before
    }

    It 'rejects invalid file arrays without restoring anything' -ForEach @(
        @{ Values = @() }, @{ Values = @('') }, @{ Values = @('alpha.txt', ' ') },
        @{ Values = @("alpha.txt`n") }, @{ Values = @("alpha$([char]0).txt") }
    ) {
        $before = Get-RestoreFixtureSnapshot
        { Restore-Items -Files $Values -Path $restoreRepo -Confirm:$false -ErrorAction Stop } | Should -Throw
        Get-RestoreFixtureSnapshot | Should -BeExactly $before
    }

    It 'rejects invalid or option-like source <SourceValue> without falling back' -ForEach @(
        @{ SourceValue = 'does-not-exist'; Index = $false },
        @{ SourceValue = 'does-not-exist'; Index = $true },
        @{ SourceValue = 'HEAD:alpha.txt'; Index = $false },
        @{ SourceValue = '--staged'; Index = $false },
        @{ SourceValue = "HEAD`n"; Index = $false },
        @{ SourceValue = ''; Index = $false }
    ) {
        $before = Get-RestoreFixtureSnapshot
        { Restore-Items 'alpha.txt' -Path $restoreRepo -Source $SourceValue -IncludeIndex:$Index -Confirm:$false -ErrorAction Stop } |
            Should -Throw
        Get-RestoreFixtureSnapshot | Should -BeExactly $before
    }

    It 'surfaces native missing-path errors and preserves cwd' {
        $before = Get-RestoreFixtureSnapshot
        $location = (Get-Location).ProviderPath
        $errors = @()
        Restore-Items 'missing.txt' -Path $restoreRepo -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable +errors |
            Should -BeNullOrEmpty
        $nativeError = $errors | Where-Object FullyQualifiedErrorId -Like 'GitCommandFailed*' | Select-Object -Last 1
        $nativeError | Should -Not -BeNullOrEmpty
        $nativeError.TargetObject.ExitCode | Should -Not -Be 0
        $nativeError.TargetObject.StandardError | Should -Match 'pathspec'
        $nativeError.TargetObject.RepositoryPath | Should -BeExactly $restoreRepo
        { Restore-Items 'missing.txt' -Path $restoreRepo -Confirm:$false -ErrorAction Stop } | Should -Throw
        Get-RestoreFixtureSnapshot | Should -BeExactly $before
        (Get-Location).ProviderPath | Should -BeExactly $location
    }

    It 'rejects missing, file, non-repository and bare repository Path values' {
        $bare = Join-Path $restoreFixtureRoot 'bare'
        Assert-RestoreFixturePath $bare
        $null = New-Item -ItemType Directory -Path $bare -ErrorAction Stop
        $null = Invoke-RestoreFixtureGit @('-c', 'init.templateDir=', 'init', '--bare', '--quiet') -Path $bare -Initialize
        $before = Get-RestoreFixtureSnapshot
        foreach ($path in @((Join-Path $restoreFixtureRoot 'missing'), (Join-Path $restoreRepo 'alpha.txt'), $restoreFixtureRoot, $bare)) {
            Assert-RestoreFixturePath $path
            { Restore-Items 'alpha.txt' -Path $path -Confirm:$false -ErrorAction Stop } | Should -Throw
        }
        Get-RestoreFixtureSnapshot | Should -BeExactly $before
    }

    It 'refuses a file operand outside the working tree' {
        $outside = Join-Path $restoreFixtureRoot 'outside.txt'
        Assert-RestoreFixturePath $outside
        [IO.File]::WriteAllText($outside, 'keep')
        $before = Get-RestoreFixtureSnapshot
        { Restore-Items $outside -Path $restoreRepo -Confirm:$false -ErrorAction Stop } | Should -Throw
        [IO.File]::ReadAllText($outside) | Should -BeExactly 'keep'
        Get-RestoreFixtureSnapshot | Should -BeExactly $before
    }

    It 'surfaces index lock failures rather than repairing them' {
        $lock = Join-Path $restoreRepo '.git/index.lock'
        Assert-RestoreFixturePath $lock
        [IO.File]::WriteAllText($lock, 'owned lock')
        $before = Get-RestoreFixtureSnapshot
        { Restore-Items 'alpha.txt' -Path $restoreRepo -IncludeIndex -Confirm:$false -ErrorAction Stop } | Should -Throw '*index.lock*'
        [IO.File]::ReadAllText($lock) | Should -BeExactly 'owned lock'
        Get-RestoreFixtureSnapshot | Should -BeExactly $before
    }

    It 'refuses selected unmerged entries without repairing them in <Mode> mode' -ForEach @(
        @{ Mode = 'default' }, @{ Mode = 'source' }, @{ Mode = 'index' }
    ) {
        $stages = foreach ($stage in 1..3) {
            $blob = Invoke-RestoreFixtureGit @('rev-parse', 'HEAD:alpha.txt')
            "100644 $blob $stage`talpha.txt"
        }
        # Write LF-delimited index records directly: Windows pipeline CRLF would
        # put a carriage return in each filename. No merge or branch switch needed.
        $null = Invoke-RestoreFixtureGit @('update-index', '--force-remove', '--', 'alpha.txt')
        Assert-RestoreFixturePath $restoreRepo
        $gitExecutable = Get-Command $(if ($IsWindows) { 'git.exe' } else { 'git' }) -CommandType Application |
            Select-Object -First 1
        $start = [Diagnostics.ProcessStartInfo]::new($gitExecutable.Source)
        $start.WorkingDirectory = $restoreRepo
        $start.UseShellExecute = $false
        $start.RedirectStandardInput = $true
        $start.RedirectStandardError = $true
        foreach ($token in @('-C', $restoreRepo, 'update-index', '--index-info')) { $start.ArgumentList.Add($token) }
        $process = [Diagnostics.Process]::Start($start)
        try {
            $process.StandardInput.Write(($stages -join "`n") + "`n")
            $process.StandardInput.Close()
            $errorText = $process.StandardError.ReadToEnd()
            $process.WaitForExit()
            if ($process.ExitCode -ne 0) { throw "Creating owned unmerged index entries failed: $errorText" }
        } finally {
            $process.Dispose()
        }
        ((Invoke-RestoreFixtureGit @('ls-files', '--unmerged', '--', 'alpha.txt')) -split "`n").Count | Should -Be 3
        $before = Get-RestoreFixtureSnapshot
        $options = switch ($Mode) { source { @{ Source = 'HEAD' } } index { @{ IncludeIndex = $true } } default { @{} } }
        { Restore-Items 'alpha.txt', 'beta.txt' -Path $restoreRepo @options -Confirm:$false -ErrorAction Stop } |
            Should -Throw '*unmerged*'
        Get-RestoreFixtureSnapshot | Should -BeExactly $before
        # An unrelated conflict must not prevent a literal selection elsewhere.
        Restore-Items 'beta.txt' -Path $restoreRepo -Confirm:$false -ErrorAction Stop
        [IO.File]::ReadAllText((Join-Path $restoreRepo 'beta.txt')) | Should -BeExactly 'staged'
        Invoke-RestoreFixtureGit @('ls-files', '--unmerged', '--', 'alpha.txt') | Should -Not -BeNullOrEmpty
    }

    It 'uses the index without HEAD in an unborn repository' {
        $null = Invoke-RestoreFixtureGit @('symbolic-ref', 'HEAD', 'refs/heads/unborn')
        Restore-Items 'alpha.txt' -Path $restoreRepo -Confirm:$false -ErrorAction Stop
        [IO.File]::ReadAllText((Join-Path $restoreRepo 'alpha.txt')) | Should -BeExactly 'staged'
        { Restore-Items 'alpha.txt' -Path $restoreRepo -IncludeIndex -Confirm:$false -ErrorAction Stop } | Should -Throw
    }
}

Describe 'Save-GitStash' {
    BeforeAll {
        $stashTestRoot = (New-Item -ItemType Directory -Path (
            Join-Path $TestDrive "stash-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
        ) -ErrorAction Stop).FullName
        $stashEnvironment = @{}
        foreach ($key in @(
            'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_SYSTEM', 'GIT_CONFIG_NOSYSTEM',
            'GIT_CONFIG_COUNT', 'GIT_CONFIG_PARAMETERS', 'GIT_DIR', 'GIT_WORK_TREE',
            'GIT_COMMON_DIR', 'GIT_INDEX_FILE', 'GIT_OBJECT_DIRECTORY',
            'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_AUTHOR_DATE', 'GIT_COMMITTER_DATE',
            'GIT_CEILING_DIRECTORIES'
        )) {
            $stashEnvironment[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
            Remove-Item "Env:$key" -ErrorAction Ignore
        }
        $env:GIT_CONFIG_GLOBAL = Join-Path $stashTestRoot 'no-global-config'
        $env:GIT_CONFIG_SYSTEM = Join-Path $stashTestRoot 'no-system-config'
        $env:GIT_CONFIG_NOSYSTEM = '1'
        $env:GIT_CONFIG_COUNT = '0'
        $env:GIT_CEILING_DIRECTORIES = $TestDrive

        if (-not ('GitStashConfirmationHost' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Management.Automation;
using System.Management.Automation.Host;
using System.Security;

public sealed class GitStashConfirmationHost : PSHost
{
    public readonly GitStashConfirmationUI PromptUI = new GitStashConfirmationUI();
    public override Guid InstanceId { get; } = Guid.NewGuid();
    public override string Name => "GitStashConfirmationHost";
    public override Version Version => new Version(1, 0);
    public override PSHostUserInterface UI => PromptUI;
    public override CultureInfo CurrentCulture => CultureInfo.InvariantCulture;
    public override CultureInfo CurrentUICulture => CultureInfo.InvariantCulture;
    public override void SetShouldExit(int exitCode) { }
    public override void EnterNestedPrompt() => throw new NotSupportedException();
    public override void ExitNestedPrompt() => throw new NotSupportedException();
    public override void NotifyBeginApplication() { }
    public override void NotifyEndApplication() { }
}

public sealed class GitStashConfirmationUI : PSHostUserInterface
{
    public int PromptCount;
    public string TargetMessage;
    public override PSHostRawUserInterface RawUI => null;
    public override int PromptForChoice(string caption, string message, Collection<ChoiceDescription> choices, int defaultChoice)
    {
        PromptCount++;
        TargetMessage = message;
        for (int i = 0; i < choices.Count; i++)
            if (choices[i].Label == "&No") return i;
        throw new InvalidOperationException("Expected a No confirmation choice.");
    }
    public override string ReadLine() => throw new NotSupportedException();
    public override SecureString ReadLineAsSecureString() => throw new NotSupportedException();
    public override Dictionary<string, PSObject> Prompt(string caption, string message, Collection<FieldDescription> descriptions) => throw new NotSupportedException();
    public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName) => throw new NotSupportedException();
    public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName, PSCredentialTypes types, PSCredentialUIOptions options) => throw new NotSupportedException();
    public override void Write(string value) { }
    public override void Write(ConsoleColor foreground, ConsoleColor background, string value) { }
    public override void WriteLine(string value) { }
    public override void WriteErrorLine(string value) { }
    public override void WriteDebugLine(string value) { }
    public override void WriteVerboseLine(string value) { }
    public override void WriteWarningLine(string value) { }
    public override void WriteProgress(long sourceId, ProgressRecord record) { }
}
'@
        }
    }

    BeforeEach {
        $stashLocationPushed = $false
        Push-Location -LiteralPath $stashTestRoot -ErrorAction Stop
        $stashLocationPushed = $true
        (Get-Location).ProviderPath | Should -BeExactly $stashTestRoot
        $stashRepo = New-TestRepo -Path (Join-Path $stashTestRoot "repo $([guid]::NewGuid().ToString('N').Substring(0, 8))")
        Set-Content -LiteralPath (Join-Path $stashRepo '.gitignore') -Value 'ignored.txt'
        Invoke-Git @('-C', $stashRepo, 'add', '.gitignore')
        Invoke-TestCommit -Path $stashRepo -Message 'ignore fixture'
        Set-Content -LiteralPath (Join-Path $stashRepo 'README.md') -Value 'staged'
        Invoke-Git @('-C', $stashRepo, 'add', 'README.md')
        Set-Content -LiteralPath (Join-Path $stashRepo 'README.md') -Value 'unstaged'
        Set-Content -LiteralPath (Join-Path $stashRepo 'loose.txt') -Value 'untracked'
        Set-Content -LiteralPath (Join-Path $stashRepo 'ignored.txt') -Value 'ignored'
    }

    AfterEach {
        if ($stashLocationPushed) { Pop-Location }
    }

    AfterAll {
        foreach ($key in $stashEnvironment.Keys) {
            if ($null -eq $stashEnvironment[$key]) {
                Remove-Item "Env:$key" -ErrorAction Ignore
            } else {
                [Environment]::SetEnvironmentVariable($key, $stashEnvironment[$key], 'Process')
            }
        }
        if ($stashTestRoot -and (Test-Path -LiteralPath $stashTestRoot)) {
            (Split-Path $stashTestRoot -Parent) | Should -BeExactly $TestDrive
            # Pester 5 shares TestDrive across Describes and its wildcard cleanup
            # can leave literal bracket paths and read-only git objects behind.
            Get-ChildItem -LiteralPath $stashTestRoot -Recurse -Force -File -ErrorAction Stop |
                ForEach-Object { $_.IsReadOnly = $false }
            Remove-Item -LiteralPath $stashTestRoot -Recurse -Force -ErrorAction Stop
        }
    }

    It 'exports the approved command and documents its output and standard pipeline metadata' {
        $module = Get-Module Shmuelie.Git
        $command = Get-Command Save-GitStash -Module Shmuelie.Git
        $module.ExportedFunctions.Keys | Should -Contain 'Save-GitStash'
        $module.ExportedFunctions.Keys | Should -Not -Contain 'Backup-Changes'
        $module.ExportedAliases.Count | Should -Be 0
        $command.OutputType.Name | Should -Contain 'GitStash'
        $command.Parameters.Keys | Should -Contain 'WhatIf'
        $command.Parameters.Keys | Should -Contain 'Confirm'
        $command.Parameters.Path.Aliases | Should -Be @('RepositoryPath', 'RepoPath')
        $attribute = $command.Parameters.Path.Attributes |
            Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] }
        $attribute.ValueFromPipeline | Should -BeTrue
        $attribute.ValueFromPipelineByPropertyName | Should -BeTrue
        (Get-Help Save-GitStash).Description.Text | Should -Not -BeNullOrEmpty
    }

    It 'saves <Mode> changes with KeepIndex=<Keep>, retaining every uncaptured file' -ForEach @(
        @{ Mode = 'tracked'; Keep = $false; Flags = @{}; Extra = @() }
        @{ Mode = 'tracked'; Keep = $true; Flags = @{ KeepIndex = $true }; Extra = @() }
        @{ Mode = 'untracked'; Keep = $false; Flags = @{ IncludeUntracked = $true }; Extra = @('loose.txt') }
        @{ Mode = 'untracked'; Keep = $true; Flags = @{ IncludeUntracked = $true; KeepIndex = $true }; Extra = @('loose.txt') }
        @{ Mode = 'all'; Keep = $false; Flags = @{ All = $true }; Extra = @('ignored.txt', 'loose.txt') }
        @{ Mode = 'all'; Keep = $true; Flags = @{ All = $true; KeepIndex = $true }; Extra = @('ignored.txt', 'loose.txt') }
    ) {
        $head = Invoke-Git @('-C', $stashRepo, 'rev-parse', 'HEAD')
        $results = @(Save-GitStash -Path $stashRepo @Flags -Confirm:$false -ErrorAction Stop)
        $results | Should -HaveCount 1
        $stash = $results[0]
        $stash.PSTypeNames[0] | Should -BeExactly 'GitStash'
        @($stash.PSObject.Properties.Name) | Should -Be @('ObjectId', 'RepositoryPath', 'Subject')
        $stash.RepositoryPath | Should -BeExactly $stashRepo
        $stash.ObjectId | Should -Match '^(?:[0-9a-f]{40}|[0-9a-f]{64})$'
        $stash.ObjectId | Should -BeExactly (Invoke-Git @('-C', $stashRepo, 'rev-parse', 'refs/stash'))
        $stash.Subject | Should -BeExactly (Invoke-Git @('-C', $stashRepo, 'show', '-s', '--format=%s', $stash.ObjectId))
        Invoke-Git @('-C', $stashRepo, 'show', "$($stash.ObjectId):README.md") | Should -BeExactly 'unstaged'
        Invoke-Git @('-C', $stashRepo, 'show', "$($stash.ObjectId)^2:README.md") | Should -BeExactly 'staged'
        Invoke-Git @('-C', $stashRepo, 'rev-parse', "$($stash.ObjectId)^1") | Should -BeExactly $head
        Invoke-Git @('-C', $stashRepo, 'rev-parse', 'HEAD') | Should -BeExactly $head
        Invoke-Git @('-C', $stashRepo, 'rev-list', '--count', '--walk-reflogs', 'refs/stash') | Should -Be '1'

        $expected = if ($Keep) { 'staged' } else { 'initial' }
        (Get-Content -LiteralPath (Join-Path $stashRepo 'README.md') -Raw).Trim() | Should -BeExactly $expected
        Invoke-Git @('-C', $stashRepo, 'show', ':README.md') | Should -BeExactly $expected
        @(Invoke-Git @('-C', $stashRepo, 'diff', '--name-only')) | Should -HaveCount 0
        $stagedPaths = @(Invoke-Git @('-C', $stashRepo, 'diff', '--cached', '--name-only'))
        if ($Keep) { $stagedPaths | Should -Be @('README.md') }
        else { $stagedPaths | Should -HaveCount 0 }
        foreach ($file in @('loose.txt', 'ignored.txt')) {
            $filePath = Join-Path $stashRepo $file
            if ($file -in $Extra) {
                Test-Path -LiteralPath $filePath | Should -BeFalse
                $value = if ($file -eq 'loose.txt') { 'untracked' } else { 'ignored' }
                Invoke-Git @('-C', $stashRepo, 'show', "$($stash.ObjectId)^3:$file") | Should -BeExactly $value
            } else {
                $value = if ($file -eq 'loose.txt') { 'untracked' } else { 'ignored' }
                (Get-Content -LiteralPath $filePath -Raw).Trim() | Should -BeExactly $value
            }
        }
        $parents = (Invoke-Git @('-C', $stashRepo, 'rev-list', '--parents', '-n', '1', $stash.ObjectId)) -split ' '
        $parents.Count | Should -Be $(if ($Extra.Count) { 4 } else { 3 })
    }

    It 'keeps a stable commit identity when later saves move the stack' {
        $first = Save-GitStash -Path $stashRepo -Message first -Confirm:$false
        Set-Content -LiteralPath (Join-Path $stashRepo 'README.md') -Value 'second change'
        $second = Save-GitStash -Path $stashRepo -Message second -Confirm:$false
        $first.ObjectId | Should -Not -Be $second.ObjectId
        Invoke-Git @('-C', $stashRepo, 'rev-parse', 'stash@{1}') | Should -BeExactly $first.ObjectId
        Invoke-Git @('-C', $stashRepo, 'show', "$($first.ObjectId):README.md") | Should -BeExactly 'unstaged'
        Invoke-Git @('-C', $stashRepo, 'show', "$($second.ObjectId):README.md") | Should -BeExactly 'second change'
    }

    It 'passes the <Case> message literally rather than evaluating text or options' -ForEach @(
        @{ Case = 'quoted and executable-looking'; Text = 'a "quote" and ''single'' & | ; $(throw "executed") <> ` %PATH% ! ^' }
        @{ Case = 'option-looking'; Text = '--all --keep-index' }
        @{ Case = 'padded'; Text = '  keep  spaces  ' }
        @{ Case = 'multiline Unicode'; Text = "first $([char]0xe9)`n`nsecond`tline" }
        @{ Case = 'trailing backslashes'; Text = 'path ends\\' }
    ) {
        $stash = Save-GitStash -Path $stashRepo -Message $Text -Confirm:$false -ErrorAction Stop
        $stored = InModuleScope Shmuelie.Git -Parameters @{ Repo = $stashRepo; Oid = $stash.ObjectId } {
            param($Repo, $Oid)
            (Invoke-Git -Path $Repo -Arguments @('cat-file', 'commit', $Oid)).StandardOutput
        }
        ($stored -split "`n`n", 2)[1] | Should -BeExactly "On main: $Text"
        Test-Path -LiteralPath (Join-Path $stashRepo 'loose.txt') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $stashRepo 'ignored.txt') | Should -BeTrue
        Invoke-Git @('-C', $stashRepo, 'show', ':README.md') | Should -BeExactly 'initial'
    }

    It 'uses the default git message for <Case>' -ForEach @(
        @{ Case = 'null'; Text = $null }
        @{ Case = 'empty text'; Text = '' }
        @{ Case = 'whitespace'; Text = " `t`r`n " }
    ) {
        $stash = Save-GitStash -Path $stashRepo -Message $Text -Confirm:$false -ErrorAction Stop
        $stash.Subject | Should -Match '^WIP on main: [0-9a-f]+ ignore fixture$'
    }

    It 'returns nothing when only uncaptured files remain and there is no existing stash' {
        Invoke-Git @('-C', $stashRepo, 'restore', '--staged', '--worktree', '--', '.')
        @(Save-GitStash -Path $stashRepo -Confirm:$false -ErrorAction Stop) | Should -HaveCount 0
        @(Invoke-Git @('-C', $stashRepo, 'for-each-ref', '--format=%(objectname)', 'refs/stash')) | Should -HaveCount 0
        Test-Path -LiteralPath (Join-Path $stashRepo 'loose.txt') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $stashRepo 'ignored.txt') | Should -BeTrue
    }

    It 'never returns an old stash as if a no-op had created it' {
        $stash = Save-GitStash -Path $stashRepo -All -Confirm:$false
        @(Save-GitStash -Path $stashRepo -All -Confirm:$false -ErrorAction Stop) | Should -HaveCount 0
        Invoke-Git @('-C', $stashRepo, 'rev-parse', 'refs/stash') | Should -BeExactly $stash.ObjectId
        Invoke-Git @('-C', $stashRepo, 'rev-list', '--count', '--walk-reflogs', 'refs/stash') | Should -Be '1'
    }

    It 'can save only <Mode> files when tracked changes are absent' -ForEach @(
        @{ Mode = 'untracked'; Flags = @{ IncludeUntracked = $true }; Files = @('loose.txt') }
        @{ Mode = 'ignored'; Flags = @{ All = $true }; Files = @('ignored.txt') }
    ) {
        Invoke-Git @('-C', $stashRepo, 'restore', '--staged', '--worktree', '--', '.')
        if ($Mode -eq 'ignored') { Remove-Item -LiteralPath (Join-Path $stashRepo 'loose.txt') }
        $stash = Save-GitStash -Path $stashRepo @Flags -Confirm:$false -ErrorAction Stop
        $stash.ObjectId | Should -Not -BeNullOrEmpty
        Invoke-Git @('-C', $stashRepo, 'ls-tree', '-r', '--name-only', "$($stash.ObjectId)^3") | Should -Be $Files
    }

    It 'rejects conflicting inclusion switches and NUL messages before running git' {
        InModuleScope Shmuelie.Git -Parameters @{ Repo = $stashRepo } {
            param($Repo)
            Mock Invoke-Git { throw 'Git must not run for invalid options.' }
            { Save-GitStash -Path $Repo -All -IncludeUntracked -Confirm:$false } |
                Should -Throw -ErrorId 'GitStashOptionsConflict,Save-GitStash' -ExpectedMessage '*either -All or -IncludeUntracked*'
            { Save-GitStash -Path $Repo -Message "invalid`0message" -Confirm:$false } |
                Should -Throw -ExpectedMessage '*NUL*'
            Should -Invoke Invoke-Git -Times 0
        }
    }

    It 'treats explicitly false switches as disabled' {
        $stash = Save-GitStash -Path $stashRepo -All:$false -IncludeUntracked:$false -KeepIndex:$false -Confirm:$false
        $stash.ObjectId | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $stashRepo 'loose.txt') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $stashRepo 'ignored.txt') | Should -BeTrue
        Invoke-Git @('-C', $stashRepo, 'show', ':README.md') | Should -BeExactly 'initial'
    }

    It 'does not change any stash, file or index when <Mode>' -ForEach @(
        @{ Mode = 'WhatIf is set' }
        @{ Mode = 'confirmation is declined' }
    ) {
        $beforeStatus = Invoke-Git @('-C', $stashRepo, 'status', '--porcelain=v1', '--ignored')
        $indexPath = Join-Path (Get-TestGitDir $stashRepo) 'index'
        $beforeIndex = (Get-FileHash -LiteralPath $indexPath).Hash
        $beforeLocation = (Get-Location).ProviderPath
        if ($Mode -eq 'WhatIf is set') {
            @(Save-GitStash -Path $stashRepo -All -WhatIf -Confirm:$false -ErrorAction Stop) | Should -HaveCount 0
        } else {
            $hostStub = [GitStashConfirmationHost]::new()
            $runspace = [runspacefactory]::CreateRunspace($hostStub)
            $powershell = [powershell]::Create()
            try {
                $runspace.Open()
                $powershell.Runspace = $runspace
                $null = $powershell.AddScript({
                    param($root, $path)
                    $ErrorActionPreference = 'Stop'
                    Import-Module (Join-Path $root 'modules' 'Shmuelie.Git' 'Shmuelie.Git.psd1')
                    try { Save-GitStash -Path $path -All -Confirm }
                    finally { Remove-Module Shmuelie.Git }
                }.ToString()).AddArgument($repoRoot).AddArgument($stashRepo)
                @($powershell.Invoke()) | Should -HaveCount 0
                $powershell.HadErrors | Should -BeFalse -Because ($powershell.Streams.Error -join "`n")
                $hostStub.PromptUI.PromptCount | Should -Be 1
                $hostStub.PromptUI.TargetMessage | Should -BeLike "*$stashRepo*"
                $hostStub.PromptUI.TargetMessage | Should -BeLike '*tracked, untracked and ignored*'
            } finally {
                $powershell.Dispose()
                $runspace.Dispose()
            }
        }
        (Get-FileHash -LiteralPath $indexPath).Hash | Should -BeExactly $beforeIndex
        (Get-Location).ProviderPath | Should -BeExactly $beforeLocation
        @(Invoke-Git @('-C', $stashRepo, 'for-each-ref', '--format=%(objectname)', 'refs/stash')) | Should -HaveCount 0
        Invoke-Git @('-C', $stashRepo, 'status', '--porcelain=v1', '--ignored') | Should -Be $beforeStatus
        (Get-Content -LiteralPath (Join-Path $stashRepo 'README.md') -Raw).Trim() | Should -BeExactly 'unstaged'
        (Get-Content -LiteralPath (Join-Path $stashRepo 'loose.txt') -Raw).Trim() | Should -BeExactly 'untracked'
        (Get-Content -LiteralPath (Join-Path $stashRepo 'ignored.txt') -Raw).Trim() | Should -BeExactly 'ignored'
    }

    It 'targets pipeline <Property> without changing the caller location or LASTEXITCODE' -ForEach @(
        @{ Property = 'string' }
        @{ Property = 'Path' }
        @{ Property = 'RepositoryPath' }
        @{ Property = 'RepoPath' }
    ) {
        $inputPath = if ($Property -eq 'string') { $stashRepo }
            else { [PSCustomObject]@{ $Property = $stashRepo } }
        Push-Location -LiteralPath $stashTestRoot -ErrorAction Stop
        try {
            $LASTEXITCODE = 37
            $stash = $inputPath | Save-GitStash -Confirm:$false -ErrorAction Stop
            $LASTEXITCODE | Should -Be 37
            $stash.RepositoryPath | Should -BeExactly $stashRepo
            (Get-Location).ProviderPath | Should -BeExactly $stashTestRoot
        } finally {
            Pop-Location
        }
    }

    It 'resolves relative literal aliases and defaults to a subdirectory while stashing the entire tree' -ForEach @(
        @{ Mode = 'RepositoryPath' }
        @{ Mode = 'RepoPath' }
        @{ Mode = 'current directory' }
    ) {
        $renamed = Join-Path $stashTestRoot "literal [stash] & ($Mode)"
        Rename-Item -LiteralPath $stashRepo -NewName (Split-Path $renamed -Leaf) -ErrorAction Stop
        $stashRepo = $renamed
        $subdirectory = New-Item -ItemType Directory -Path (Join-Path $stashRepo 'subdirectory') -ErrorAction Stop
        $location = if ($Mode -eq 'current directory') { $subdirectory.FullName } else { $stashTestRoot }
        Push-Location -LiteralPath $location -ErrorAction Stop
        try {
            $parameters = @{ Confirm = $false; ErrorAction = 'Stop' }
            if ($Mode -ne 'current directory') {
                $parameters[$Mode] = Join-Path (Split-Path $stashRepo -Leaf) 'subdirectory'
            }
            $stash = Save-GitStash @parameters
            $stash.RepositoryPath | Should -BeExactly $subdirectory.FullName
            (Get-Location).ProviderPath | Should -BeExactly $location
            Invoke-Git @('-C', $stashRepo, 'show', "$($stash.ObjectId):README.md") | Should -BeExactly 'unstaged'
            Invoke-Git @('-C', $stashRepo, 'show', ':README.md') | Should -BeExactly 'initial'
        } finally {
            Pop-Location
        }
    }

    It 'continues pipeline processing after a no-op repository' {
        $clean = New-TestRepo -Path (Join-Path $stashTestRoot 'clean stash repo')
        $results = @($clean, $stashRepo | Save-GitStash -Confirm:$false -ErrorAction Stop)
        $results | Should -HaveCount 1
        $results[0].RepositoryPath | Should -BeExactly $stashRepo
    }

    It 'supports linked worktrees without stashing changes from another worktree' {
        $linked = Join-Path $stashTestRoot 'linked stash worktree'
        Invoke-Git @('-C', $stashRepo, 'worktree', 'add', '--detach', '--quiet', $linked)
        Set-Content -LiteralPath (Join-Path $linked 'README.md') -Value 'linked changes'
        $stash = Save-GitStash -Path $linked -Confirm:$false -ErrorAction Stop
        $stash.RepositoryPath | Should -BeExactly $linked
        Invoke-Git @('-C', $linked, 'show', "$($stash.ObjectId):README.md") | Should -BeExactly 'linked changes'
        (Get-Content -LiteralPath (Join-Path $linked 'README.md') -Raw).Trim() | Should -BeExactly 'initial'
        (Get-Content -LiteralPath (Join-Path $stashRepo 'README.md') -Raw).Trim() | Should -BeExactly 'unstaged'
        Invoke-Git @('-C', $stashRepo, 'show', ':README.md') | Should -BeExactly 'staged'
    }

    It 'leaves nested repository work untouched with <Mode>' -ForEach @(
        @{ Mode = 'IncludeUntracked'; Flags = @{ IncludeUntracked = $true } }
        @{ Mode = 'All'; Flags = @{ All = $true } }
    ) {
        $nested = New-TestRepo -Path (Join-Path $stashRepo 'nested repo')
        Set-Content -LiteralPath (Join-Path $nested 'README.md') -Value 'nested work'
        $stash = Save-GitStash -Path $stashRepo @Flags -Confirm:$false -ErrorAction Stop
        $stash.ObjectId | Should -Not -BeNullOrEmpty
        (Get-Content -LiteralPath (Join-Path $nested 'README.md') -Raw).Trim() | Should -BeExactly 'nested work'
        @(Invoke-Git @('-C', $nested, 'for-each-ref', '--format=%(objectname)', 'refs/stash')) | Should -HaveCount 0
        @(Invoke-Git @('-C', $stashRepo, 'ls-tree', '-r', '--name-only', "$($stash.ObjectId)^3")) |
            Should -Not -Contain 'nested repo/README.md'
    }

    It 'reports native lock failures without emitting success or altering the working tree' {
        $beforeLocation = (Get-Location).ProviderPath
        $indexPath = Join-Path (Get-TestGitDir $stashRepo) 'index'
        $beforeIndex = (Get-FileHash -LiteralPath $indexPath).Hash
        Set-Content -LiteralPath "$indexPath.lock" -Value 'held by test'
        @(Save-GitStash -Path $stashRepo -All -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable failures) |
            Should -HaveCount 0
        $failures | Should -HaveCount 1
        $failures[0].FullyQualifiedErrorId | Should -Match '^GitCommandFailed'
        $failures[0].TargetObject.ExitCode | Should -Not -Be 0
        $failures[0].TargetObject.RepositoryPath | Should -BeExactly $stashRepo
        { Save-GitStash -Path $stashRepo -Confirm:$false -ErrorAction Stop } | Should -Throw -ExpectedMessage '*git failed*'
        (Get-FileHash -LiteralPath $indexPath).Hash | Should -BeExactly $beforeIndex
        (Get-Location).ProviderPath | Should -BeExactly $beforeLocation
        (Get-Content -LiteralPath (Join-Path $stashRepo 'README.md') -Raw).Trim() | Should -BeExactly 'unstaged'
        Test-Path -LiteralPath (Join-Path $stashRepo 'loose.txt') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $stashRepo 'ignored.txt') | Should -BeTrue
        @(Invoke-Git @('-C', $stashRepo, 'for-each-ref', '--format=%(objectname)', 'refs/stash')) | Should -HaveCount 0
    }

    It 'rejects missing paths, nonrepositories, files, bare repositories and unborn histories' {
        { Save-GitStash -Path (Join-Path $stashTestRoot 'missing') -Confirm:$false -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*repository path not found*'
        { Save-GitStash -Path $stashTestRoot -Confirm:$false -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*not inside a git working tree*'
        { Save-GitStash -Path (Join-Path $stashRepo 'README.md') -Confirm:$false -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*must be a FileSystem directory*'
        $bare = Join-Path $stashTestRoot 'bare stash.git'
        Invoke-Git @('init', '--bare', '--quiet', $bare)
        { Save-GitStash -Path $bare -Confirm:$false -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*not inside a git working tree*'
        $unborn = New-TestRepo -Path (Join-Path $stashTestRoot 'unborn stash') -NoCommit
        { Save-GitStash -Path $unborn -Confirm:$false -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*git failed*'
    }

    It 'surfaces reference-read failures <When> without returning a stash' -ForEach @(
        @{ When = 'before push'; FailAt = 1; Pushes = 0 }
        @{ When = 'after push'; FailAt = 2; Pushes = 1 }
    ) {
        InModuleScope Shmuelie.Git -Parameters @{ Repo = $stashRepo; FailAt = $FailAt; Pushes = $Pushes } {
            param($Repo, $FailAt, $Pushes)
            $script:stashRefReads = 0
            Mock Resolve-GitRepositoryPath { $Repo }
            Mock Invoke-GitProcess {
                if ($Arguments -contains 'for-each-ref') {
                    $script:stashRefReads++
                    if ($script:stashRefReads -eq $FailAt) {
                        return [PSCustomObject]@{ ExitCode = 128; StandardOutput = ''; StandardError = 'ref read failed'; Output = @() }
                    }
                }
                [PSCustomObject]@{ ExitCode = 0; StandardOutput = ''; StandardError = ''; Output = @() }
            }
            @(Save-GitStash -Path $Repo -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable failures) |
                Should -HaveCount 0
            $failures | Should -HaveCount 1
            $failures[0].FullyQualifiedErrorId | Should -Match '^GitCommandFailed'
            $failures[0].Exception.Message | Should -BeLike '*ref read failed*'
            Should -Invoke Invoke-GitProcess -Times $Pushes -ParameterFilter { $Arguments -contains 'push' }
        }
    }
}

Describe 'Set-Config' {
    BeforeAll {
        function Read-TestConfig {
            param([string]$Path, [string]$Location = 'local', [string]$Property = 'example.value')
            InModuleScope Shmuelie.Git -Parameters @{ Path = $Path; Location = $Location; Property = $Property } {
                param($Path, $Location, $Property)
                $result = Invoke-GitProcess -Arguments @('-C', $Path, 'config', "--$Location", '--null', '--get-all', '--', $Property)
                if ($result.ExitCode -ne 0) { throw $result.StandardError }
                $result.StandardOutput
            }
        }

        if (-not ('SetConfigConfirmationHost' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Management.Automation;
using System.Management.Automation.Host;
using System.Security;

public sealed class SetConfigConfirmationHost : PSHost
{
    public readonly SetConfigConfirmationUI PromptUI = new SetConfigConfirmationUI();
    public override Guid InstanceId { get; } = Guid.NewGuid();
    public override string Name => "SetConfigConfirmationHost";
    public override Version Version => new Version(1, 0);
    public override PSHostUserInterface UI => PromptUI;
    public override CultureInfo CurrentCulture => CultureInfo.InvariantCulture;
    public override CultureInfo CurrentUICulture => CultureInfo.InvariantCulture;
    public override void SetShouldExit(int exitCode) { }
    public override void EnterNestedPrompt() => throw new NotSupportedException();
    public override void ExitNestedPrompt() => throw new NotSupportedException();
    public override void NotifyBeginApplication() { }
    public override void NotifyEndApplication() { }
}

public sealed class SetConfigConfirmationUI : PSHostUserInterface
{
    public int Choice;
    public int PromptCount;
    public override PSHostRawUserInterface RawUI => null;
    public override int PromptForChoice(string caption, string message, Collection<ChoiceDescription> choices, int defaultChoice)
    {
        PromptCount++;
        return Choice;
    }
    public override string ReadLine() => throw new NotSupportedException();
    public override SecureString ReadLineAsSecureString() => throw new NotSupportedException();
    public override Dictionary<string, PSObject> Prompt(string caption, string message, Collection<FieldDescription> descriptions) => throw new NotSupportedException();
    public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName) => throw new NotSupportedException();
    public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName, PSCredentialTypes types, PSCredentialUIOptions options) => throw new NotSupportedException();
    public override void Write(string value) { }
    public override void Write(ConsoleColor foreground, ConsoleColor background, string value) { }
    public override void WriteLine(string value) { }
    public override void WriteErrorLine(string value) { }
    public override void WriteDebugLine(string value) { }
    public override void WriteVerboseLine(string value) { }
    public override void WriteWarningLine(string value) { }
    public override void WriteProgress(long sourceId, ProgressRecord record) { }
}
'@
        }
    }

    BeforeEach {
        $ErrorActionPreference = 'Stop'
        Push-Location -LiteralPath $TestDrive -ErrorAction Stop
        $configEnvironment = @{}
        foreach ($entry in Get-ChildItem Env: | Where-Object Name -Like 'GIT_*') {
            $configEnvironment[$entry.Name] = $entry.Value
            [Environment]::SetEnvironmentVariable($entry.Name, $null, 'Process')
        }
        foreach ($environmentKey in 'HOME', 'USERPROFILE', 'XDG_CONFIG_HOME') {
            $configEnvironment[$environmentKey] = [Environment]::GetEnvironmentVariable($environmentKey, 'Process')
        }
        $configSandbox = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $configHome = New-Item -ItemType Directory -Path (Join-Path $configSandbox 'home')
        $env:HOME = $configHome.FullName
        $env:USERPROFILE = $configHome.FullName
        $env:XDG_CONFIG_HOME = $configHome.FullName
        $env:GIT_CONFIG_GLOBAL = Join-Path $configHome.FullName 'global.gitconfig'
        $env:GIT_CONFIG_SYSTEM = Join-Path $configHome.FullName 'system.gitconfig'
        $env:GIT_CONFIG_COUNT = '0'
        foreach ($file in $env:GIT_CONFIG_GLOBAL, $env:GIT_CONFIG_SYSTEM) {
            Set-Content -LiteralPath $file -Value "[sentinel]`n`tvalue = original"
        }
        $configRepo = New-TestRepo -Path (Join-Path $configSandbox "repo [literal] & 'quoted'") -NoCommit
        $configFiles = @{
            local = Join-Path $configRepo '.git' 'config'
            global = $env:GIT_CONFIG_GLOBAL
            system = $env:GIT_CONFIG_SYSTEM
        }
        $configBefore = @{}
        foreach ($configLocation in $configFiles.Keys) {
            $configBefore[$configLocation] = [IO.File]::ReadAllText($configFiles[$configLocation])
        }
    }

    AfterEach {
        foreach ($entry in Get-ChildItem Env: | Where-Object Name -Like 'GIT_*') {
            [Environment]::SetEnvironmentVariable($entry.Name, $null, 'Process')
        }
        foreach ($environmentKey in $configEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($environmentKey, $configEnvironment[$environmentKey], 'Process')
        }
        Pop-Location
    }

    It 'exports ShouldProcess, void output, literal value and path metadata with help' {
        $command = Get-Command Set-Config -Module Shmuelie.Git
        $command.Parameters.Keys | Should -Contain 'WhatIf'
        $command.Parameters.Keys | Should -Contain 'Confirm'
        $command.OutputType.Name | Should -Contain 'System.Void'
        $command.Parameters.Path.Aliases | Should -Be @('RepositoryPath', 'RepoPath', 'Repository')
        $pathMetadata = $command.Parameters.Path.Attributes |
            Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] }
        $pathMetadata.ValueFromPipeline | Should -Contain $true
        $pathMetadata.ValueFromPipelineByPropertyName | Should -Contain $true
        $command.Parameters.Value.Attributes.TypeId.Name | Should -Contain 'AllowEmptyStringAttribute'
        ($command.Parameters.Location.Attributes |
            Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }).ValidValues |
            Should -Be @('local', 'global', 'system')
        (Get-Help Set-Config).Synopsis | Should -BeLike '*git configuration value*'
    }

    It 'sets and replaces a <Scope> value without changing other scopes or keys' -ForEach @(
        @{ Scope = 'local' }; @{ Scope = 'global' }; @{ Scope = 'system' }
    ) {
        @(Set-Config example.value first -Path $configRepo -Location $Scope -Confirm:$false) | Should -HaveCount 0
        Set-Config example.value second -Path $configRepo -Location $Scope.ToUpperInvariant() -Confirm:$false
        Read-TestConfig -Path $configRepo -Location $Scope | Should -BeExactly "second`0"
        foreach ($other in $configFiles.Keys | Where-Object { $_ -ne $Scope }) {
            [IO.File]::ReadAllText($configFiles[$other]) | Should -BeExactly $configBefore[$other]
        }
        $preserved = if ($Scope -eq 'local') { 'user.name' } else { 'sentinel.value' }
        $expected = if ($Scope -eq 'local') { "Test User`0" } else { "original`0" }
        Read-TestConfig -Path $configRepo -Location $Scope -Property $preserved | Should -BeExactly $expected
    }

    It 'round-trips the literal <Label> value and subsection key' -ForEach @(
        @{ Label = 'empty'; Value = '' }
        @{ Label = 'whitespace'; Value = '  leading and trailing  ' }
        @{ Label = 'quotes'; Value = 'both "double" and ''single'' quotes \' }
        @{ Label = 'shell characters'; Value = '$(throw "evaluated"); & | < > %PATH% ! ` [*] # ;' }
        @{ Label = 'leading dashes'; Value = '--unset-all' }
        @{ Label = 'separator'; Value = '--' }
        @{ Label = 'newlines and Unicode'; Value = "line`t1`nline2 $([char]0x96ea)`n" }
    ) {
        $key = 'example. subsection "quoted"; $literal & | % ! .value'
        Set-Config -Property $key -Value $Value -Path $configRepo -Confirm:$false
        Read-TestConfig -Path $configRepo -Property $key | Should -BeExactly "$Value`0"
    }

    It 'defaults to local and the current directory without changing location or LASTEXITCODE' {
        $subdirectory = New-Item -ItemType Directory -Path (Join-Path $configRepo 'nested')
        Push-Location -LiteralPath $subdirectory.FullName
        try {
            $global:LASTEXITCODE = 73
            Set-Config example.value current -Confirm:$false
            $LASTEXITCODE | Should -Be 73
            (Get-Location).ProviderPath | Should -BeExactly $subdirectory.FullName
            Read-TestConfig -Path $configRepo | Should -BeExactly "current`0"
        } finally { Pop-Location }
    }

    It 'accepts relative literal paths and the <Alias> alias' -ForEach @(
        @{ Alias = 'Path' }; @{ Alias = 'RepositoryPath' }; @{ Alias = 'RepoPath' }; @{ Alias = 'Repository' }
    ) {
        Push-Location -LiteralPath $configSandbox
        try {
            $options = @{ $Alias = (Split-Path $configRepo -Leaf) }
            Set-Config example.value relative @options -Confirm:$false
            (Get-Location).ProviderPath | Should -BeExactly $configSandbox
            Read-TestConfig -Path $configRepo | Should -BeExactly "relative`0"
        } finally { Pop-Location }
    }

    It 'accepts a bare repository for local configuration' {
        $bare = Join-Path $configSandbox 'bare.git'
        Invoke-Git @('-c', 'init.templateDir=', 'init', '--bare', '--quiet', $bare)
        Set-Config example.value bare -Path $bare -Confirm:$false
        Read-TestConfig -Path $bare | Should -BeExactly "bare`0"
    }

    It 'runs <Scope> configuration outside any repository, with or without an explicit path' -ForEach @(
        @{ Scope = 'global' }; @{ Scope = 'system' }
    ) {
        Push-Location -LiteralPath $configHome.FullName
        try {
            Set-Config example.value implicit -Location $Scope -Confirm:$false
            Read-TestConfig -Path $configHome.FullName -Location $Scope | Should -BeExactly "implicit`0"
            Set-Config example.value explicit -Location $Scope -Path $configHome.FullName -Confirm:$false
            Read-TestConfig -Path $configHome.FullName -Location $Scope | Should -BeExactly "explicit`0"
        } finally { Pop-Location }
    }

    It 'requires a repository for local configuration and keeps the shared runner default strict' {
        { Set-Config example.value unused -Path $configHome.FullName -ErrorAction Stop } |
            Should -Throw '*not inside a git working tree*'
        InModuleScope Shmuelie.Git -Parameters @{ Directory = $configHome.FullName } {
            param($Directory)
            { Invoke-Git -Path $Directory -Arguments @('config', '--global', '--get', 'sentinel.value') -ErrorAction Stop } |
                Should -Throw '*not inside a git working tree*'
        }
    }

    It 'rejects invalid paths for <Scope> without falling back to the current directory' -ForEach @(
        @{ Scope = 'local' }; @{ Scope = 'global' }; @{ Scope = 'system' }
    ) {
        { Set-Config example.value unused -Location $Scope -Path (Join-Path $configSandbox 'missing') -ErrorAction Stop } |
            Should -Throw '*path not found*'
        { Set-Config example.value unused -Location $Scope -Path $configFiles.local -ErrorAction Stop } |
            Should -Throw '*must be a FileSystem directory*'
        { Set-Config example.value unused -Location $Scope -Path 'Env:' -ErrorAction Stop } |
            Should -Throw '*must be a FileSystem directory*'
        { Set-Config example.value unused -Location $Scope -Path '' -ErrorAction Stop } | Should -Throw
        foreach ($configLocation in $configFiles.Keys) {
            [IO.File]::ReadAllText($configFiles[$configLocation]) | Should -BeExactly $configBefore[$configLocation]
        }
    }

    It 'rejects an invalid location, empty key or NUL before invoking git' {
        InModuleScope Shmuelie.Git {
            Mock Invoke-Git {}
            Mock Resolve-GitRepositoryPath {}
            { Set-Config example.value unused -Location worktree } | Should -Throw
            { Set-Config -Property '' -Value unused } | Should -Throw
            { Set-Config -Property "example.`0value" -Value unused } | Should -Throw '*NUL*'
            { Set-Config -Property example.value -Value "invalid`0value" } | Should -Throw '*NUL*'
            Should -Invoke Invoke-Git -Times 0 -Exactly
            Should -Invoke Resolve-GitRepositoryPath -Times 0 -Exactly
        }
    }

    It 'reports invalid key <Key> through git rather than interpreting it as an option' -ForEach @(
        @{ Key = 'notakey' }; @{ Key = '--global' }
        @{ Key = 'example.invalid_key' }; @{ Key = 'example.' }
    ) {
        Set-Config -Property $Key -Value unused -Path $configRepo -ErrorAction SilentlyContinue -ErrorVariable failures |
            Should -BeNullOrEmpty
        $failures | Should -HaveCount 1
        $failures[0].FullyQualifiedErrorId | Should -Match '^GitCommandFailed'
        $failures[0].TargetObject.ExitCode | Should -Not -Be 0
        $failures[0].TargetObject.StandardError | Should -Not -BeNullOrEmpty
        [IO.File]::ReadAllText($configFiles.local) | Should -BeExactly $configBefore.local
    }

    It 'preserves a leading-dash section name when git permits it' {
        Set-Config -Property '-example.value' -Value '--literal' -Path $configRepo -Confirm:$false
        Read-TestConfig -Path $configRepo -Property '-example.value' | Should -BeExactly "--literal`0"
    }

    It 'does not overwrite multiple existing values or conceal the native failure' {
        Invoke-Git @('-C', $configRepo, 'config', '--local', '--add', 'example.value', 'first')
        Invoke-Git @('-C', $configRepo, 'config', '--local', '--add', 'example.value', 'second')
        { Set-Config example.value replacement -Path $configRepo -ErrorAction Stop } |
            Should -Throw '*git failed*'
        Read-TestConfig -Path $configRepo | Should -BeExactly "first`0second`0"
    }

    It 'reports a <Scope> write failure through the shared helper without success output' -ForEach @(
        @{ Scope = 'local' }; @{ Scope = 'global' }; @{ Scope = 'system' }
    ) {
        Set-Content -LiteralPath "$($configFiles[$Scope]).lock" -Value 'locked'
        Set-Config example.value unused -Path $configRepo -Location $Scope -ErrorAction SilentlyContinue -ErrorVariable failures |
            Should -BeNullOrEmpty
        $failures | Should -HaveCount 1
        $failures[0].FullyQualifiedErrorId | Should -Match '^GitCommandFailed'
        $failures[0].Exception.Message | Should -Match 'lock'
        $failures[0].TargetObject.StandardError | Should -Not -BeNullOrEmpty
        { Set-Config example.value unused -Path $configRepo -Location $Scope -ErrorAction Stop } |
            Should -Throw '*lock*'
        [IO.File]::ReadAllText($configFiles[$Scope]) | Should -BeExactly $configBefore[$Scope]
    }

    It 'passes exactly two operands after the separator to the private shared runner' {
        InModuleScope Shmuelie.Git -Parameters @{ Repo = $configRepo } {
            param($Repo)
            Mock Invoke-Git {}
            Set-Config -Property 'example.literal "key".value' -Value '--literal "value"' -Path $Repo -Confirm:$false
            Should -Invoke Invoke-Git -Times 1 -Exactly -ParameterFilter {
                $Arguments.Count -eq 5 -and $Arguments[0] -ceq 'config' -and $Arguments[1] -ceq '--local' -and
                $Arguments[2] -ceq '--' -and $Arguments[3] -ceq 'example.literal "key".value' -and
                $Arguments[4] -ceq '--literal "value"' -and $Path -ceq $Repo -and -not $AllowNonRepository
            }
        }
    }

    It 'preserves arbitrary native exit codes and stderr in the shared error record' {
        InModuleScope Shmuelie.Git -Parameters @{ Repo = $configRepo } {
            param($Repo)
            Mock Resolve-GitRepositoryPath { $Repo }
            Mock Invoke-GitProcess {
                [PSCustomObject]@{ ExitCode = 42; StandardOutput = ''; StandardError = 'deliberate native failure'; Output = @() }
            }
            Set-Config example.value unused -Path $Repo -ErrorAction SilentlyContinue -ErrorVariable failures |
                Should -BeNullOrEmpty
            $failures | Should -HaveCount 1
            $failures[0].FullyQualifiedErrorId | Should -Match '^GitCommandFailed'
            $failures[0].TargetObject.ExitCode | Should -Be 42
            $failures[0].TargetObject.StandardError | Should -BeExactly 'deliberate native failure'
            $failures[0].TargetObject.RepositoryPath | Should -BeExactly $Repo
            Should -Invoke Invoke-GitProcess -Times 1 -Exactly
        }
    }

    It 'WhatIf does not create an absent <Scope> configuration file' -ForEach @(
        @{ Scope = 'global' }; @{ Scope = 'system' }
    ) {
        Remove-Item -LiteralPath $configFiles[$Scope]
        Set-Config example.value unused -Location $Scope -Path $configHome.FullName -WhatIf
        Test-Path -LiteralPath $configFiles[$Scope] | Should -BeFalse
        Set-Config example.value created -Location $Scope -Path $configHome.FullName -Confirm:$false
        Read-TestConfig -Path $configHome.FullName -Location $Scope | Should -BeExactly "created`0"
    }

    It 'WhatIf leaves <Scope> configuration unchanged and never invokes the writer' -ForEach @(
        @{ Scope = 'local' }; @{ Scope = 'global' }; @{ Scope = 'system' }
    ) {
        InModuleScope Shmuelie.Git -Parameters @{ Repo = $configRepo; Scope = $Scope } {
            param($Repo, $Scope)
            Mock Invoke-Git {}
            @(Set-Config example.value unused -Path $Repo -Location $Scope -WhatIf) | Should -HaveCount 0
            Should -Invoke Invoke-Git -Times 0 -Exactly
        }
        Set-Config example.value unused -Path $configRepo -Location $Scope -WhatIf
        foreach ($configLocation in $configFiles.Keys) {
            [IO.File]::ReadAllText($configFiles[$configLocation]) | Should -BeExactly $configBefore[$configLocation]
        }
    }

    It 'prompts independently for each piped path in <Scope> scope and honors <Mode>' -ForEach @(
        foreach ($scope in 'local', 'global', 'system') {
            @{ Scope = $scope; Mode = 'confirm yes'; Choice = 0; ExpectedPrompts = 2; Writes = $true; Options = @{ Confirm = $true } }
            @{ Scope = $scope; Mode = 'confirm no'; Choice = 2; ExpectedPrompts = 2; Writes = $false; Options = @{ Confirm = $true } }
            @{ Scope = $scope; Mode = 'confirm false'; Choice = 2; ExpectedPrompts = 0; Writes = $true; Options = @{ Confirm = $false } }
            @{ Scope = $scope; Mode = 'ambient WhatIf'; Choice = 0; ExpectedPrompts = 0; Writes = $false; Options = @{} }
        }
    ) {
        $hostStub = [SetConfigConfirmationHost]::new()
        $hostStub.PromptUI.Choice = $Choice
        $runspace = [runspacefactory]::CreateRunspace($hostStub)
        $powershell = [powershell]::Create()
        try {
            $runspace.Open()
            $powershell.Runspace = $runspace
            $null = $powershell.AddScript({
                param($root, $path, $scope, $mode, $options)
                $ErrorActionPreference = 'Stop'
                Import-Module (Join-Path $root 'modules' 'Shmuelie.Git' 'Shmuelie.Git.psd1')
                if ($mode -eq 'ambient WhatIf') { $WhatIfPreference = $true }
                $ConfirmPreference = 'Low'
                @($path, [PSCustomObject]@{ RepositoryPath = $path }) |
                    Set-Config -Property example.value -Value approved -Location $scope @options
            }.ToString()).AddArgument($repoRoot).AddArgument($configRepo).AddArgument($Scope).AddArgument($Mode).AddArgument($Options)
            @($powershell.Invoke()) | Should -HaveCount 0
            $powershell.HadErrors | Should -BeFalse -Because ($powershell.Streams.Error -join "`n")
            $hostStub.PromptUI.PromptCount | Should -Be $ExpectedPrompts
            if ($Writes) {
                Read-TestConfig -Path $configRepo -Location $Scope | Should -BeExactly "approved`0"
            } else {
                [IO.File]::ReadAllText($configFiles[$Scope]) | Should -BeExactly $configBefore[$Scope]
            }
        } finally {
            $powershell.Dispose()
            $runspace.Dispose()
        }
    }

    It 'preserves newline and backslash characters in Unix paths' -Skip:$IsWindows {
        $path = New-TestRepo -Path (Join-Path $configSandbox "config`nrepo\literal") -NoCommit
        Set-Config example.value literal -Path $path -Confirm:$false
        Read-TestConfig -Path $path | Should -BeExactly "literal`0"
    }
}

Describe 'Remove-Branch' {
    BeforeAll {
        $branchEnvironment = @{}
        # Pester 5 shares TestDrive across Describe blocks.
        $branchFixtureRoot = Join-Path $TestDrive 'remove-branch'
        $null = New-Item -ItemType Directory -Path $branchFixtureRoot -ErrorAction Stop
        foreach ($key in @(
            'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_SYSTEM', 'GIT_CONFIG_NOSYSTEM',
            'GIT_CONFIG_COUNT', 'GIT_CONFIG_PARAMETERS', 'GIT_DIR', 'GIT_WORK_TREE',
            'GIT_COMMON_DIR', 'GIT_INDEX_FILE', 'GIT_OBJECT_DIRECTORY',
            'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_NAMESPACE'
        )) {
            $branchEnvironment[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
            Remove-Item "Env:$key" -ErrorAction Ignore
        }
        $env:GIT_CONFIG_GLOBAL = Join-Path $branchFixtureRoot 'no-global-config'
        $env:GIT_CONFIG_SYSTEM = Join-Path $branchFixtureRoot 'no-system-config'
        $env:GIT_CONFIG_NOSYSTEM = '1'
        $env:GIT_CONFIG_COUNT = '0'
        $seed = New-TestRepo -Path (Join-Path $branchFixtureRoot 'seed')
        $branchOrigin = Join-Path $branchFixtureRoot 'origin.git'
        $branchRepo = Join-Path $branchFixtureRoot 'branch repo [literal]'
        Invoke-Git @('clone', '--bare', '--quiet', '--', $seed, $branchOrigin)
        Invoke-Git @('clone', '--quiet', '--', $branchOrigin, $branchRepo)
        Set-TestRepoConfig $branchRepo
        $initialCommit = Invoke-Git @('-C', $branchRepo, 'rev-parse', 'HEAD')

        function Get-TestBranchNames {
            param([string]$Path)
            Invoke-Git @('-C', $Path, 'for-each-ref', '--format=%(refname)', 'refs/heads/')
        }

        if (-not ('BranchRemovalConfirmationHost' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Management.Automation;
using System.Management.Automation.Host;
using System.Security;

public sealed class BranchRemovalConfirmationHost : PSHost
{
    public readonly BranchRemovalConfirmationUI PromptUI = new BranchRemovalConfirmationUI();
    public override Guid InstanceId { get; } = Guid.NewGuid();
    public override string Name => "BranchRemovalConfirmationHost";
    public override Version Version => new Version(1, 0);
    public override PSHostUserInterface UI => PromptUI;
    public override CultureInfo CurrentCulture => CultureInfo.InvariantCulture;
    public override CultureInfo CurrentUICulture => CultureInfo.InvariantCulture;
    public override void SetShouldExit(int exitCode) { }
    public override void EnterNestedPrompt() => throw new NotSupportedException();
    public override void ExitNestedPrompt() => throw new NotSupportedException();
    public override void NotifyBeginApplication() { }
    public override void NotifyEndApplication() { }
}

public sealed class BranchRemovalConfirmationUI : PSHostUserInterface
{
    public int PromptCount;
    public readonly List<string> Messages = new List<string>();
    public override PSHostRawUserInterface RawUI => null;
    public override int PromptForChoice(string caption, string message, Collection<ChoiceDescription> choices, int defaultChoice)
    {
        PromptCount++;
        Messages.Add(message);
        return 2; // No: refuse each high-impact operation.
    }
    public override string ReadLine() => throw new NotSupportedException();
    public override SecureString ReadLineAsSecureString() => throw new NotSupportedException();
    public override Dictionary<string, PSObject> Prompt(string caption, string message, Collection<FieldDescription> descriptions) => throw new NotSupportedException();
    public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName) => throw new NotSupportedException();
    public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName, PSCredentialTypes types, PSCredentialUIOptions options) => throw new NotSupportedException();
    public override void Write(string value) => Messages.Add(value);
    public override void Write(ConsoleColor foreground, ConsoleColor background, string value) => Messages.Add(value);
    public override void WriteLine(string value) => Messages.Add(value);
    public override void WriteErrorLine(string value) => Messages.Add(value);
    public override void WriteDebugLine(string value) => Messages.Add(value);
    public override void WriteVerboseLine(string value) => Messages.Add(value);
    public override void WriteWarningLine(string value) => Messages.Add(value);
    public override void WriteProgress(long sourceId, ProgressRecord record) { }
}
'@
        }
    }

    BeforeEach {
        $branchName = 'remove-' + [guid]::NewGuid().ToString('N')
        Invoke-Git @('-C', $branchRepo, 'branch', $branchName, $initialCommit)
        Invoke-Git @('-C', $branchRepo, 'push', '--quiet', '--', 'origin', "refs/heads/$branchName")
    }

    AfterAll {
        try {
            if ($branchFixtureRoot) {
                $relativeRoot = [IO.Path]::GetRelativePath($TestDrive, $branchFixtureRoot)
                if ($relativeRoot -cne 'remove-branch') {
                    throw "Refusing to clean a fixture outside its owned TestDrive directory: '$branchFixtureRoot'."
                }
                if (Test-Path -LiteralPath $branchFixtureRoot) {
                    # Pester 5's directory deletion can fail on read-only Git objects.
                    Remove-Item -LiteralPath $branchFixtureRoot -Recurse -Force -ErrorAction Stop
                }
            }
        } finally {
            foreach ($key in $branchEnvironment.Keys) {
                if ($null -eq $branchEnvironment[$key]) {
                    Remove-Item "Env:$key" -ErrorAction Ignore
                } else {
                    [Environment]::SetEnvironmentVariable($key, $branchEnvironment[$key], 'Process')
                }
            }
        }
    }

    It 'exports an approved high-impact command with standard path aliases and help' {
        $command = Get-Command Remove-Branch -Module Shmuelie.Git
        (Get-Verb Remove).Verb | Should -BeExactly $command.Verb
        $binding = $command.ScriptBlock.Attributes |
            Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] }
        $binding.SupportsShouldProcess | Should -BeTrue
        $binding.ConfirmImpact | Should -Be 'High'
        $command.Parameters.Path.Aliases | Should -Be @('RepositoryPath', 'RepoPath')
        $command.Parameters.Name.Aliases | Should -Be @('BranchName', 'Branch')
        (Get-Module Shmuelie.Git).ExportedAliases.Count | Should -Be 0
        (Get-Help Remove-Branch).Description.Text | Should -Not -BeNullOrEmpty
    }

    It 'deletes only the merged local branch with <InputKind> input' -ForEach @(
        @{ InputKind = 'name' }, @{ InputKind = 'reference' }, @{ InputKind = 'pipeline' },
        @{ InputKind = 'properties' }, @{ InputKind = 'aliases' }
    ) {
        $result = switch ($InputKind) {
            name { Remove-Branch $branchName -Path $branchRepo -Confirm:$false -ErrorAction Stop }
            reference { Remove-Branch "refs/heads/$branchName" -Path $branchRepo -Confirm:$false -ErrorAction Stop }
            pipeline { $branchName | Remove-Branch -Path $branchRepo -Confirm:$false -ErrorAction Stop }
            properties {
                [PSCustomObject]@{ Name = $branchName; Path = $branchRepo } |
                    Remove-Branch -Confirm:$false -ErrorAction Stop
            }
            aliases {
                [PSCustomObject]@{ BranchName = $branchName; RepositoryPath = $branchRepo } |
                    Remove-Branch -Confirm:$false -ErrorAction Stop
            }
        }
        $result | Should -BeNullOrEmpty
        Get-TestBranchNames $branchRepo | Should -Not -Contain "refs/heads/$branchName"
        Get-TestBranchNames $branchRepo | Should -Contain 'refs/heads/main'
        Get-TestBranchNames $branchOrigin | Should -Contain "refs/heads/$branchName"
    }

    It 'uses literal, relative, current and bare repository paths without changing location' {
        $location = (Get-Location).ProviderPath
        $subdirectory = New-Item -ItemType Directory -Path (Join-Path $branchRepo $branchName)
        Push-Location -LiteralPath $subdirectory.FullName
        try {
            Remove-Branch $branchName -RepoPath .. -Confirm:$false -ErrorAction Stop
            Invoke-Git @('-C', $branchRepo, 'branch', $branchName, $initialCommit)
            Remove-Branch $branchName -Confirm:$false -ErrorAction Stop
            (Get-Location).ProviderPath | Should -BeExactly $subdirectory.FullName
        } finally {
            Pop-Location
        }
        (Get-Location).ProviderPath | Should -BeExactly $location
        Remove-Branch $branchName -Path $branchOrigin -Confirm:$false -ErrorAction Stop
        Get-TestBranchNames $branchOrigin | Should -Not -Contain "refs/heads/$branchName"
    }

    It 'leaves both repositories untouched for <Mode> WhatIf' -ForEach @(
        @{ Mode = 'local'; Options = @{} }
        @{ Mode = 'forced local'; Options = @{ Force = $true } }
        @{ Mode = 'remote'; Options = @{ Remote = $true } }
    ) {
        $beforeLocal = Invoke-Git @('-C', $branchRepo, 'show-ref')
        $beforeRemote = Invoke-Git @('-C', $branchOrigin, 'show-ref')
        Remove-Branch $branchName -Path $branchRepo @Options -WhatIf -ErrorAction Stop |
            Should -BeNullOrEmpty
        Invoke-Git @('-C', $branchRepo, 'show-ref') | Should -Be $beforeLocal
        Invoke-Git @('-C', $branchOrigin, 'show-ref') | Should -Be $beforeRemote
    }

    It 'honors declined <Mode> confirmation including the implicit High prompt' -ForEach @(
        @{ Mode = 'local'; Options = @{} }
        @{ Mode = 'forced local'; Options = @{ Force = $true } }
        @{ Mode = 'remote'; Options = @{ Remote = $true } }
        @{ Mode = 'explicit'; Options = @{ Confirm = $true } }
    ) {
        $hostStub = [BranchRemovalConfirmationHost]::new()
        $runspace = [runspacefactory]::CreateRunspace($hostStub)
        $powershell = [powershell]::Create()
        try {
            $runspace.Open()
            $powershell.Runspace = $runspace
            $null = $powershell.AddScript({
                param($moduleRoot, $path, $name, $options)
                $ErrorActionPreference = 'Stop'
                $ConfirmPreference = 'High'
                Import-Module (Join-Path $moduleRoot 'modules' 'Shmuelie.Git' 'Shmuelie.Git.psd1')
                try {
                    Remove-Branch -Name $name -Path $path @options
                } finally {
                    Remove-Module Shmuelie.Git
                }
            }.ToString()).AddArgument($repoRoot).AddArgument($branchRepo).AddArgument($branchName).AddArgument($Options)
            @($powershell.Invoke()) | Should -HaveCount 0
            $powershell.HadErrors | Should -BeFalse -Because ($powershell.Streams.Error -join "`n")
            $hostStub.PromptUI.PromptCount | Should -Be 1
            ($hostStub.PromptUI.Messages -join "`n") | Should -BeLike "*refs/heads/$branchName*"
            if ($Options.Remote) {
                ($hostStub.PromptUI.Messages -join "`n") | Should -BeLike "*remote 'origin'*"
            }
        } finally {
            $powershell.Dispose()
            $runspace.Dispose()
        }
        Get-TestBranchNames $branchRepo | Should -Contain "refs/heads/$branchName"
        Get-TestBranchNames $branchOrigin | Should -Contain "refs/heads/$branchName"
    }

    It 'refuses unmerged local deletion and requires explicit Force' {
        Invoke-Git @('-C', $branchRepo, 'switch', '--quiet', $branchName)
        try {
            Invoke-Git @('-C', $branchRepo, 'commit', '--allow-empty', '--quiet', '-m', 'unmerged work')
        } finally {
            Invoke-Git @('-C', $branchRepo, 'switch', '--quiet', 'main')
        }
        Remove-Branch $branchName -Path $branchRepo -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable failures |
            Should -BeNullOrEmpty
        $failures | Should -HaveCount 1
        $failures[0].FullyQualifiedErrorId | Should -BeLike 'GitCommandFailed*'
        $failures[0].TargetObject.ExitCode | Should -Not -Be 0
        $failures[0].TargetObject.StandardError | Should -Match 'not fully merged'
        Get-TestBranchNames $branchRepo | Should -Contain "refs/heads/$branchName"
        Remove-Branch $branchName -Path $branchRepo -Force -Confirm:$false -ErrorAction Stop
        Get-TestBranchNames $branchRepo | Should -Not -Contain "refs/heads/$branchName"
    }

    It 'refuses deletion of a branch in the <Location> worktree with Force=<UseForce>' -ForEach @(
        @{ Location = 'current'; UseForce = $false }, @{ Location = 'current'; UseForce = $true }
        @{ Location = 'linked'; UseForce = $false }, @{ Location = 'linked'; UseForce = $true }
    ) {
        $targetName = 'main'
        if ($Location -eq 'linked') {
            $targetName = $branchName
            Invoke-Git @('-C', $branchRepo, 'worktree', 'add', '--quiet', (Join-Path $branchFixtureRoot $branchName), $branchName)
        }
        { Remove-Branch $targetName -Path $branchRepo -Force:$UseForce -Confirm:$false -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*git failed*'
        Get-TestBranchNames $branchRepo | Should -Contain "refs/heads/$targetName"
    }

    It 'rejects invalid or option-like branch <InvalidName> before any deletion' -ForEach @(
        @{ InvalidName = '--all' }, @{ InvalidName = '-D' }, @{ InvalidName = 'refs/heads/-D' }
        @{ InvalidName = 'refs/heads/' }, @{ InvalidName = 'refs/tags/main' }
        @{ InvalidName = 'refs/remotes/origin/main' }, @{ InvalidName = 'HEAD' }
        @{ InvalidName = 'refs/heads/HEAD' }, @{ InvalidName = '@{-1}' }
        @{ InvalidName = 'main~1' }, @{ InvalidName = 'main:other' }, @{ InvalidName = 'feature/*' }
        @{ InvalidName = 'main..other' }, @{ InvalidName = 'white space' }, @{ InvalidName = "line`nbreak" }
        @{ InvalidName = "nul`0name" }
    ) {
        $beforeLocal = Invoke-Git @('-C', $branchRepo, 'show-ref')
        $beforeRemote = Invoke-Git @('-C', $branchOrigin, 'show-ref')
        foreach ($options in @(@{}, @{ Remote = $true })) {
            { Remove-Branch $InvalidName -Path $branchRepo @options -Confirm:$false -ErrorAction Stop } |
                Should -Throw
        }
        Invoke-Git @('-C', $branchRepo, 'show-ref') | Should -Be $beforeLocal
        Invoke-Git @('-C', $branchOrigin, 'show-ref') | Should -Be $beforeRemote
    }

    It 'preserves literal metacharacters and Unicode in valid branch names' {
        $literalName = 'feature/a&b;echo${literal}' + "'-" + [char]0xe9
        Invoke-Git @('-C', $branchRepo, 'branch', $literalName)
        Invoke-Git @('-C', $branchRepo, 'push', '--quiet', '--', 'origin', "refs/heads/$literalName")
        Remove-Branch $literalName -Path $branchRepo -Remote -Confirm:$false -ErrorAction Stop
        Get-TestBranchNames $branchRepo | Should -Contain "refs/heads/$literalName"
        Get-TestBranchNames $branchOrigin | Should -Not -Contain "refs/heads/$literalName"
        Remove-Branch $literalName -Path $branchRepo -Confirm:$false -ErrorAction Stop
        Get-TestBranchNames $branchRepo | Should -Not -Contain "refs/heads/$literalName"
    }

    It 'deletes only the explicit remote branch even with same-named tags and push defaults' {
        Invoke-Git @('-C', $branchRepo, 'tag', $branchName)
        Invoke-Git @('-C', $branchRepo, 'push', '--quiet', '--', 'origin', "refs/tags/$branchName")
        Invoke-Git @('-C', $branchRepo, 'tag', '-a', "$branchName-local-tag", '-m', 'local only')
        Invoke-Git @('-C', $branchRepo, 'config', 'remote.origin.mirror', 'true')
        Invoke-Git @('-C', $branchRepo, 'config', 'push.followTags', 'true')
        Invoke-Git @('-C', $branchRepo, 'config', 'remote.origin.push', 'refs/heads/*:refs/heads/*')
        $beforeRemote = @(Invoke-Git @('-C', $branchOrigin, 'show-ref'))
        try {
            Remove-Branch "refs/heads/$branchName" -Path $branchRepo -Remote -Confirm:$false -ErrorAction Stop |
                Should -BeNullOrEmpty
        } finally {
            Invoke-Git @('-C', $branchRepo, 'config', '--unset', 'remote.origin.mirror')
            Invoke-Git @('-C', $branchRepo, 'config', '--unset', 'push.followTags')
            Invoke-Git @('-C', $branchRepo, 'config', '--unset', 'remote.origin.push')
        }
        $expected = @($beforeRemote | Where-Object { -not $_.EndsWith(" refs/heads/$branchName") })
        Invoke-Git @('-C', $branchOrigin, 'show-ref') | Should -Be $expected
        Get-TestBranchNames $branchRepo | Should -Contain "refs/heads/$branchName"
    }

    It 'selects a named configured remote and respects its push URL rather than its fetch URL' {
        $pushTarget = Join-Path $branchFixtureRoot "$branchName.git"
        Invoke-Git @('clone', '--bare', '--quiet', '--', $branchOrigin, $pushTarget)
        Invoke-Git @('-C', $branchRepo, 'remote', 'add', $branchName, $branchOrigin)
        Invoke-Git @('-C', $branchRepo, 'remote', 'set-url', '--push', $branchName, $pushTarget)
        Remove-Branch $branchName -Path $branchRepo -Remote -RemoteName $branchName -Confirm:$false -ErrorAction Stop
        Get-TestBranchNames $pushTarget | Should -Not -Contain "refs/heads/$branchName"
        Get-TestBranchNames $branchOrigin | Should -Contain "refs/heads/$branchName"
        Get-TestBranchNames $branchRepo | Should -Contain "refs/heads/$branchName"
    }

    It 'does not infer a remote from an upstream or strip a remote prefix' {
        $prefixedName = "origin/$branchName"
        Invoke-Git @('-C', $branchRepo, 'branch', '--set-upstream-to', "origin/$branchName", $branchName)
        Invoke-Git @('-C', $branchRepo, 'branch', $prefixedName)
        Invoke-Git @('-C', $branchRepo, 'push', '--quiet', '--', 'origin', "refs/heads/$prefixedName")
        Remove-Branch $prefixedName -Path $branchRepo -Remote -Confirm:$false -ErrorAction Stop
        Get-TestBranchNames $branchOrigin | Should -Not -Contain "refs/heads/$prefixedName"
        Get-TestBranchNames $branchOrigin | Should -Contain "refs/heads/$branchName"
        Remove-Branch $branchName -Path $branchRepo -Confirm:$false -ErrorAction Stop
        Get-TestBranchNames $branchOrigin | Should -Contain "refs/heads/$branchName"
    }

    It 'rejects unknown, option-like and URL/path remote arguments' -ForEach @(
        @{ InvalidRemote = 'missing' }, @{ InvalidRemote = '--all' }, @{ InvalidRemote = 'ORIGIN' },
        @{ InvalidRemote = 'https://example.invalid/repo.git' }
    ) {
        { Remove-Branch $branchName -Path $branchRepo -Remote -RemoteName $InvalidRemote -Confirm:$false -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*Configured remote*was not found*'
        { Remove-Branch $branchName -Path $branchRepo -Remote -RemoteName $branchOrigin -Confirm:$false -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*Configured remote*was not found*'
        Get-TestBranchNames $branchOrigin | Should -Contain "refs/heads/$branchName"
    }

    It 'rejects Force with remote deletion and an explicitly disabled Remote switch' {
        { Remove-Branch $branchName -Path $branchRepo -Remote -Force -Confirm:$false -ErrorAction Stop } |
            Should -Throw
        { Remove-Branch $branchName -Path $branchRepo -Remote:$false -RemoteName origin -Confirm:$false -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*requires -Remote*'
        Get-TestBranchNames $branchRepo | Should -Contain "refs/heads/$branchName"
        Get-TestBranchNames $branchOrigin | Should -Contain "refs/heads/$branchName"
    }

    It 'reports a nonexistent local branch with a structured native error and no output' {
        Remove-Branch "$branchName-missing" -Path $branchRepo -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable failures |
            Should -BeNullOrEmpty
        $failures | Should -HaveCount 1
        $failures[0].FullyQualifiedErrorId | Should -BeLike 'GitCommandFailed*'
        $failures[0].TargetObject.RepositoryPath | Should -BeExactly $branchRepo
        $failures[0].TargetObject.ExitCode | Should -Not -Be 0
        $failures[0].TargetObject.StandardError | Should -Not -BeNullOrEmpty
    }

    It 'leaves refs unchanged when Git accepts deletion of an already absent remote branch' {
        $beforeRemote = Invoke-Git @('-C', $branchOrigin, 'show-ref')
        Remove-Branch "$branchName-missing" -Path $branchRepo -Remote -Confirm:$false -ErrorAction Stop |
            Should -BeNullOrEmpty
        Invoke-Git @('-C', $branchOrigin, 'show-ref') | Should -Be $beforeRemote
    }

    It 'propagates remote rejection and unavailable-remote errors without local deletion' {
        Invoke-Git @('-C', $branchOrigin, 'config', 'receive.denyDeletes', 'true')
        try {
            { Remove-Branch $branchName -Path $branchRepo -Remote -Confirm:$false -ErrorAction Stop } |
                Should -Throw -ExpectedMessage '*git failed*'
        } finally {
            Invoke-Git @('-C', $branchOrigin, 'config', '--unset', 'receive.denyDeletes')
        }
        Invoke-Git @('-C', $branchRepo, 'remote', 'add', "$branchName-offline", (Join-Path $branchFixtureRoot 'missing.git'))
        { Remove-Branch $branchName -Path $branchRepo -Remote -RemoteName "$branchName-offline" -Confirm:$false -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*git failed*'
        Get-TestBranchNames $branchRepo | Should -Contain "refs/heads/$branchName"
        Get-TestBranchNames $branchOrigin | Should -Contain "refs/heads/$branchName"
    }

    It 'reports invalid repository paths instead of emitting success' {
        foreach ($path in @((Join-Path $branchFixtureRoot 'missing'), $branchFixtureRoot, (Join-Path $branchRepo 'README.md'))) {
            { Remove-Branch $branchName -Path $path -Confirm:$false -ErrorAction Stop } | Should -Throw
        }
        Get-TestBranchNames $branchRepo | Should -Contain "refs/heads/$branchName"
    }

    It 'never invokes push or branch deletion under WhatIf' {
        InModuleScope Shmuelie.Git -Parameters @{ Repo = $branchRepo; Name = $branchName } {
            param($Repo, $Name)
            Mock Invoke-Git {
                [PSCustomObject]@{ RepositoryPath = $Repo; StandardOutput = "origin`n" }
            }
            Remove-Branch $Name -Path $Repo -WhatIf
            Remove-Branch $Name -Path $Repo -Force -WhatIf
            Remove-Branch $Name -Path $Repo -Remote -WhatIf
            Should -Invoke Invoke-Git -Times 0 -ParameterFilter { $Arguments -contains 'push' -or $Arguments -contains 'branch' }
            Should -Invoke Invoke-Git -Times 3 -ParameterFilter {
                $Arguments[0] -eq 'check-ref-format' -and $Arguments[1] -ceq "refs/heads/$Name"
            }
        }
    }
}

Describe 'Set-Branch' {
    BeforeAll {
        $switchEnvironment = @{}
        foreach ($key in @(
            'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_SYSTEM', 'GIT_CONFIG_NOSYSTEM',
            'GIT_CONFIG_COUNT', 'GIT_CONFIG_PARAMETERS', 'GIT_DIR', 'GIT_WORK_TREE',
            'GIT_COMMON_DIR', 'GIT_INDEX_FILE', 'GIT_OBJECT_DIRECTORY',
            'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_NAMESPACE', 'GIT_CEILING_DIRECTORIES',
            'GIT_DEFAULT_HASH', 'GIT_DEFAULT_REF_FORMAT', 'GIT_AUTHOR_DATE', 'GIT_COMMITTER_DATE'
        )) {
            $switchEnvironment[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
            Remove-Item -LiteralPath "Env:$key" -ErrorAction Ignore
        }
        $env:GIT_CONFIG_GLOBAL = Join-Path $TestDrive 'no-global-config'
        $env:GIT_CONFIG_SYSTEM = Join-Path $TestDrive 'no-system-config'
        $env:GIT_CONFIG_NOSYSTEM = '1'
        $env:GIT_CONFIG_COUNT = '0'
        $env:GIT_AUTHOR_DATE = '2024-01-02T03:04:05Z'
        $env:GIT_COMMITTER_DATE = '2024-01-02T03:04:05Z'

        function Get-SwitchTestState {
            param([string]$Path)
            [ordered]@{
                Branch = Invoke-Git @('-C', $Path, 'symbolic-ref', 'HEAD')
                Head = Invoke-Git @('-C', $Path, 'rev-parse', 'HEAD')
                Refs = @(Invoke-Git @('-C', $Path, 'for-each-ref', '--format=%(refname) %(objectname) %(upstream)'))
                Status = @(Invoke-Git @('-C', $Path, 'status', '--porcelain=v1', '--untracked-files=all'))
                Index = @(Invoke-Git @('-C', $Path, 'ls-files', '--stage'))
                Config = Get-Content -LiteralPath (Join-Path $Path '.git' 'config') -Raw
                Files = @(Get-ChildItem -LiteralPath $Path -File | Sort-Object Name | ForEach-Object {
                    "$($_.Name):$([Convert]::ToBase64String([IO.File]::ReadAllBytes($_.FullName)))"
                })
            } | ConvertTo-Json -Depth 5 -Compress
        }
    }

    AfterAll {
        foreach ($key in $switchEnvironment.Keys) {
            if ($null -eq $switchEnvironment[$key]) {
                Remove-Item -LiteralPath "Env:$key" -ErrorAction Ignore
            } else {
                [Environment]::SetEnvironmentVariable($key, $switchEnvironment[$key], 'Process')
            }
        }
    }

    It 'exports the command with help, a required branch, and standard path aliases' {
        $command = Get-Command Set-Branch -Module Shmuelie.Git
        $command.Parameters['Branch'].Attributes.Mandatory | Should -Contain $true
        $command.Parameters['Branch'].Aliases | Should -Contain 'BranchName'
        $command.Parameters['Path'].Aliases | Should -Contain 'RepositoryPath'
        $command.Parameters['Path'].Aliases | Should -Contain 'RepoPath'
        $command.Parameters.Keys | Should -Contain 'WhatIf'
        $command.Parameters.Keys | Should -Contain 'Confirm'
        (Get-Help Set-Branch).Description.Text | Should -Not -BeNullOrEmpty
    }

    It 'uses discrete switch arguments for <Label>' -ForEach @(
        @{ Label = 'existing branch'; Options = @{}; Branch = 'feature/topic'; Expected = @('switch', '--no-guess', '--', 'feature/topic') }
        @{ Label = 'create'; Options = @{ CreateNew = $true }; Branch = 'feature/topic'; Expected = @('switch', '--no-guess', '--no-track', '--create', 'feature/topic', '--') }
        @{ Label = 'force'; Options = @{ Force = $true }; Branch = 'feature/topic'; Expected = @('switch', '--no-guess', '--discard-changes', '--', 'feature/topic') }
        @{ Label = 'force create'; Options = @{ Force = $true; CreateNew = $true }; Branch = 'feature/topic'; Expected = @('switch', '--no-guess', '--no-track', '--create', 'feature/topic', '--discard-changes', '--') }
        @{ Label = 'track'; Options = @{ Track = $true }; Branch = 'origin/feature/topic'; Expected = @('switch', '--no-guess', '--track=direct', '--', 'origin/feature/topic') }
        @{ Label = 'force track'; Options = @{ Track = $true; Force = $true }; Branch = 'origin/feature/topic'; Expected = @('switch', '--no-guess', '--track=direct', '--discard-changes', '--', 'origin/feature/topic') }
        @{ Label = 'literal shell punctuation'; Options = @{}; Branch = 'feature/semicolon;and&literal'; Expected = @('switch', '--no-guess', '--', 'feature/semicolon;and&literal') }
    ) {
        InModuleScope Shmuelie.Git -Parameters @{ Options = $Options; Branch = $Branch; Expected = $Expected } {
            Mock Invoke-Git {
                [pscustomobject]@{ ExitCode = 0; StandardOutput = ''; RepositoryPath = 'resolved repository' }
            }
            Set-Branch -Branch $Branch -Path 'input repository' @Options -Confirm:$false | Should -BeNullOrEmpty
            Should -Invoke Invoke-Git -Exactly -Times 1 -ParameterFilter {
                $Path -ceq 'input repository' -and
                ($Arguments -join '|') -ceq "check-ref-format|--branch|$Branch"
            }
            Should -Invoke Invoke-Git -Exactly -Times 1 -ParameterFilter {
                $Path -ceq 'resolved repository' -and
                ($Arguments -join '|') -ceq ($Expected -join '|')
            }
            $remoteChecks = if ($Options.Track) { 1 } else { 0 }
            Should -Invoke Invoke-Git -Exactly -Times $remoteChecks -ParameterFilter {
                ($Arguments -join '|') -ceq "show-ref|--verify|--quiet|--|refs/remotes/$Branch"
            }
        }
    }

    It 'rejects an unsafe or nonliteral branch before invoking Git: <Branch>' -ForEach @(
        @{ Branch = '--discard-changes' }, @{ Branch = '-c' }, @{ Branch = '-' },
        @{ Branch = '@{-1}' }, @{ Branch = '@' }, @{ Branch = 'refs/heads/main' },
        @{ Branch = 'refs/remotes/origin/main' }, @{ Branch = ' ' },
        @{ Branch = "bad`nbranch" }, @{ Branch = "bad`0branch" }
    ) {
        InModuleScope Shmuelie.Git -Parameters @{ Branch = $Branch } {
            Mock Invoke-Git { throw 'Git must not be invoked.' }
            { Set-Branch -Branch $Branch -Force -Confirm:$false } | Should -Throw
            Should -Invoke Invoke-Git -Exactly -Times 0
        }
    }

    It 'rejects conflicting creation modes before invoking Git' {
        InModuleScope Shmuelie.Git {
            Mock Invoke-Git { throw 'Git must not be invoked.' }
            { Set-Branch -Branch topic -CreateNew -Track -Force -Confirm:$false } | Should -Throw
            Should -Invoke Invoke-Git -Exactly -Times 0
        }
    }

    It 'stops after a failed validation and reports no success' {
        InModuleScope Shmuelie.Git {
            Mock Invoke-Git { Write-Error 'Invalid branch.' }
            Mock Write-Verbose {}
            Set-Branch topic -ErrorAction SilentlyContinue -ErrorVariable failures | Should -BeNullOrEmpty
            $failures | Should -Not -BeNullOrEmpty
            Should -Invoke Invoke-Git -Exactly -Times 1
            Should -Invoke Write-Verbose -Exactly -Times 0
        }
    }

    Context 'real git working trees' {
        BeforeEach {
            $switchRepo = New-TestRepo -Path (Join-Path $TestDrive "switch repo & ; (space) $([guid]::NewGuid().ToString('N'))")
            $mainCommit = Invoke-Git @('-C', $switchRepo, 'rev-parse', 'HEAD')
            Invoke-Git @('-C', $switchRepo, 'switch', '--quiet', '--create', 'target')
            Set-Content -LiteralPath (Join-Path $switchRepo 'README.md') -Value 'target version'
            Invoke-Git @('-C', $switchRepo, 'add', 'README.md')
            Invoke-TestCommit -Path $switchRepo -Message 'target commit'
            $targetCommit = Invoke-Git @('-C', $switchRepo, 'rev-parse', 'HEAD')
            Invoke-Git @('-C', $switchRepo, 'switch', '--quiet', 'main')
        }

        It 'switches an existing branch and preserves non-conflicting local changes and location' {
            Set-Content -LiteralPath (Join-Path $switchRepo 'keep.txt') -Value 'keep staged'
            Invoke-Git @('-C', $switchRepo, 'add', 'keep.txt')
            Set-Content -LiteralPath (Join-Path $switchRepo 'keep.txt') -Value 'keep unstaged'
            $location = Get-Location
            Set-Branch -Branch target -Path $switchRepo -Confirm:$false | Should -BeNullOrEmpty
            Invoke-Git @('-C', $switchRepo, 'symbolic-ref', 'HEAD') | Should -BeExactly 'refs/heads/target'
            Invoke-Git @('-C', $switchRepo, 'rev-parse', 'HEAD') | Should -BeExactly $targetCommit
            Invoke-Git @('-C', $switchRepo, 'show', ':keep.txt') | Should -BeExactly 'keep staged'
            Get-Content -LiteralPath (Join-Path $switchRepo 'keep.txt') | Should -BeExactly 'keep unstaged'
            (Get-Location).Path | Should -BeExactly $location.Path
        }

        It 'creates at HEAD without inheriting tracking even when configured to do so' {
            Invoke-Git @('-C', $switchRepo, 'config', 'branch.autoSetupMerge', 'always')
            Set-Branch -Branch 'feature/new' -CreateNew -Path $switchRepo -Confirm:$false
            Invoke-Git @('-C', $switchRepo, 'symbolic-ref', 'HEAD') | Should -BeExactly 'refs/heads/feature/new'
            Invoke-Git @('-C', $switchRepo, 'rev-parse', 'HEAD') | Should -BeExactly $mainCommit
            Invoke-Git @('-C', $switchRepo, 'for-each-ref', '--format=%(upstream)', 'refs/heads/feature/new') |
                Should -BeNullOrEmpty
        }

        It 'creates a tracked branch from its remote commit rather than current HEAD' {
            Invoke-Git @('-C', $switchRepo, 'config', 'remote.origin.url', (Join-Path $TestDrive 'offline-origin.git'))
            Invoke-Git @('-C', $switchRepo, 'config', 'remote.origin.fetch', '+refs/heads/*:refs/remotes/origin/*')
            Invoke-Git @('-C', $switchRepo, 'update-ref', 'refs/remotes/origin/feature/topic', $targetCommit)
            $location = Get-Location
            Set-Branch -Branch 'origin/feature/topic' -Track -Path $switchRepo -Confirm:$false
            Invoke-Git @('-C', $switchRepo, 'symbolic-ref', 'HEAD') | Should -BeExactly 'refs/heads/feature/topic'
            Invoke-Git @('-C', $switchRepo, 'rev-parse', 'HEAD') | Should -BeExactly $targetCommit
            Invoke-Git @('-C', $switchRepo, 'config', 'branch.feature/topic.remote') | Should -BeExactly 'origin'
            Invoke-Git @('-C', $switchRepo, 'config', 'branch.feature/topic.merge') | Should -BeExactly 'refs/heads/feature/topic'
            Invoke-Git @('-C', $switchRepo, 'for-each-ref', '--format=%(upstream)', 'refs/heads/feature/topic') |
                Should -BeExactly 'refs/remotes/origin/feature/topic'
            (Get-Location).Path | Should -BeExactly $location.Path
        }

        It 'supports cwd, a relative literal subdirectory, path aliases, and pipeline paths' {
            $subdir = New-Item -ItemType Directory -Path (Join-Path $switchRepo 'nested [literal]')
            Push-Location -LiteralPath $subdir.FullName
            try {
                Set-Branch -BranchName target -Confirm:$false
                (Get-Location).Path | Should -BeExactly $subdir.FullName
                Invoke-Git @('-C', $switchRepo, 'symbolic-ref', 'HEAD') | Should -BeExactly 'refs/heads/target'
                Set-Branch main -Path (Join-Path '..' 'nested [literal]') -Confirm:$false
                foreach ($alias in @('RepositoryPath', 'RepoPath')) {
                    $parameters = @{ $alias = $switchRepo }
                    Set-Branch target @parameters -Confirm:$false
                    Invoke-Git @('-C', $switchRepo, 'symbolic-ref', 'HEAD') | Should -BeExactly 'refs/heads/target'
                    Set-Branch main @parameters -Confirm:$false
                }
                foreach ($inputPath in @(
                    $switchRepo, [pscustomobject]@{ Path = $switchRepo },
                    [pscustomobject]@{ RepositoryPath = $switchRepo }, [pscustomobject]@{ RepoPath = $switchRepo }
                )) {
                    $inputPath | Set-Branch target -Confirm:$false
                    Invoke-Git @('-C', $switchRepo, 'symbolic-ref', 'HEAD') | Should -BeExactly 'refs/heads/target'
                    Set-Branch main -Confirm:$false
                }
            } finally {
                Pop-Location
            }
        }

        It 'treats shell metacharacters as literal branch text' {
            $branch = 'feature/semicolon;and&literal'
            Set-Branch $branch -CreateNew -Path $switchRepo -Confirm:$false
            Set-Branch main -Path $switchRepo -Confirm:$false
            Set-Branch $branch -Path $switchRepo -Confirm:$false
            Invoke-Git @('-C', $switchRepo, 'symbolic-ref', 'HEAD') | Should -BeExactly "refs/heads/$branch"
        }

        It 'preserves HEAD, refs, tracking, index and dirty files under WhatIf for <Label>' -ForEach @(
            @{ Label = 'switch'; Options = @{}; Branch = 'target' }
            @{ Label = 'force switch'; Options = @{ Force = $true }; Branch = 'target' }
            @{ Label = 'force create'; Options = @{ Force = $true; CreateNew = $true }; Branch = 'new' }
            @{ Label = 'force track'; Options = @{ Force = $true; Track = $true }; Branch = 'origin/feature/new' }
        ) {
            Invoke-Git @('-C', $switchRepo, 'config', 'remote.origin.url', (Join-Path $TestDrive 'offline-origin.git'))
            Invoke-Git @('-C', $switchRepo, 'config', 'remote.origin.fetch', '+refs/heads/*:refs/remotes/origin/*')
            Invoke-Git @('-C', $switchRepo, 'update-ref', 'refs/remotes/origin/feature/new', $targetCommit)
            Set-Content -LiteralPath (Join-Path $switchRepo 'README.md') -Value 'staged'
            Invoke-Git @('-C', $switchRepo, 'add', 'README.md')
            Set-Content -LiteralPath (Join-Path $switchRepo 'README.md') -Value 'unstaged'
            Set-Content -LiteralPath (Join-Path $switchRepo 'untracked.txt') -Value 'keep'
            $before = Get-SwitchTestState $switchRepo
            Set-Branch $Branch @Options -Path $switchRepo -WhatIf | Should -BeNullOrEmpty
            Get-SwitchTestState $switchRepo | Should -BeExactly $before
        }

        It 'reports a blocked dirty switch, preserves state, then discards changes only with Force' {
            Set-Content -LiteralPath (Join-Path $switchRepo 'README.md') -Value 'staged'
            Invoke-Git @('-C', $switchRepo, 'add', 'README.md')
            Set-Content -LiteralPath (Join-Path $switchRepo 'README.md') -Value 'unstaged'
            $before = Get-SwitchTestState $switchRepo
            Set-Branch target -Path $switchRepo -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable failures |
                Should -BeNullOrEmpty
            $failures | Should -HaveCount 1
            $failures[0].FullyQualifiedErrorId | Should -BeLike 'GitCommandFailed,*'
            $failures[0].TargetObject.ExitCode | Should -Not -Be 0
            $failures[0].TargetObject.StandardError | Should -Match 'would be overwritten'
            Get-SwitchTestState $switchRepo | Should -BeExactly $before
            { Set-Branch target -Path $switchRepo -Confirm:$false -ErrorAction Stop } |
                Should -Throw -ErrorId 'GitCommandFailed,*'
            Get-SwitchTestState $switchRepo | Should -BeExactly $before
            Set-Branch target -Force -Path $switchRepo -Confirm:$false
            Invoke-Git @('-C', $switchRepo, 'symbolic-ref', 'HEAD') | Should -BeExactly 'refs/heads/target'
            Invoke-Git @('-C', $switchRepo, 'rev-parse', 'HEAD') | Should -BeExactly $targetCommit
            Invoke-Git @('-C', $switchRepo, 'status', '--porcelain=v1') | Should -BeNullOrEmpty
            Get-Content -LiteralPath (Join-Path $switchRepo 'README.md') | Should -BeExactly 'target version'
        }

        It 'does not reset an existing branch or discard changes when CreateNew fails with Force' {
            Set-Content -LiteralPath (Join-Path $switchRepo 'README.md') -Value 'keep changes'
            $before = Get-SwitchTestState $switchRepo
            { Set-Branch target -CreateNew -Force -Path $switchRepo -Confirm:$false -ErrorAction Stop } |
                Should -Throw -ExpectedMessage '*already exists*'
            Get-SwitchTestState $switchRepo | Should -BeExactly $before
        }

        It 'does not reset an existing local branch when Track fails with Force' {
            Invoke-Git @('-C', $switchRepo, 'config', 'remote.origin.url', (Join-Path $TestDrive 'offline-origin.git'))
            Invoke-Git @('-C', $switchRepo, 'config', 'remote.origin.fetch', '+refs/heads/*:refs/remotes/origin/*')
            Invoke-Git @('-C', $switchRepo, 'update-ref', 'refs/remotes/origin/target', $mainCommit)
            Set-Content -LiteralPath (Join-Path $switchRepo 'README.md') -Value 'keep changes'
            $before = Get-SwitchTestState $switchRepo
            { Set-Branch origin/target -Track -Force -Path $switchRepo -Confirm:$false -ErrorAction Stop } |
                Should -Throw -ExpectedMessage '*already exists*'
            Get-SwitchTestState $switchRepo | Should -BeExactly $before
        }

        It 'preserves dirty state for missing, invalid, revision and local-only tracking targets' {
            Set-Content -LiteralPath (Join-Path $switchRepo 'README.md') -Value 'keep changes'
            $before = Get-SwitchTestState $switchRepo
            foreach ($branch in @('missing', 'bad..name', 'target~0', 'HEAD')) {
                { Set-Branch $branch -Force -Path $switchRepo -Confirm:$false -ErrorAction Stop } | Should -Throw
                Get-SwitchTestState $switchRepo | Should -BeExactly $before
            }
            foreach ($branch in @('target', 'origin/missing')) {
                { Set-Branch $branch -Track -Force -Path $switchRepo -Confirm:$false -ErrorAction Stop } | Should -Throw
                Get-SwitchTestState $switchRepo | Should -BeExactly $before
            }
        }

        It 'does not implicitly create a local branch for a matching remote branch' {
            Invoke-Git @('-C', $switchRepo, 'config', 'remote.origin.url', (Join-Path $TestDrive 'offline-origin.git'))
            Invoke-Git @('-C', $switchRepo, 'config', 'remote.origin.fetch', '+refs/heads/*:refs/remotes/origin/*')
            Invoke-Git @('-C', $switchRepo, 'update-ref', 'refs/remotes/origin/remote-only', $targetCommit)
            $before = Get-SwitchTestState $switchRepo
            { Set-Branch remote-only -Path $switchRepo -Confirm:$false -ErrorAction Stop } | Should -Throw
            Get-SwitchTestState $switchRepo | Should -BeExactly $before
        }

        It 'leaves both working trees untouched when the target is checked out elsewhere, even with Force' {
            $linkedPath = Join-Path $TestDrive 'other checkout'
            Invoke-Git @('-C', $switchRepo, 'worktree', 'add', '--quiet', '--', $linkedPath, 'target')
            Set-Content -LiteralPath (Join-Path $switchRepo 'README.md') -Value 'keep local'
            Set-Content -LiteralPath (Join-Path $linkedPath 'README.md') -Value 'keep linked'
            $before = Get-SwitchTestState $switchRepo
            { Set-Branch target -Force -Path $switchRepo -Confirm:$false -ErrorAction Stop } |
                Should -Throw -ExpectedMessage '*already used by worktree*'
            Get-SwitchTestState $switchRepo | Should -BeExactly $before
            Invoke-Git @('-C', $linkedPath, 'symbolic-ref', 'HEAD') | Should -BeExactly 'refs/heads/target'
            Invoke-Git @('-C', $linkedPath, 'rev-parse', 'HEAD') | Should -BeExactly $targetCommit
            Get-Content -LiteralPath (Join-Path $linkedPath 'README.md') | Should -BeExactly 'keep linked'
        }

        It 'reports invalid repository paths without affecting the current repository' {
            $before = Get-SwitchTestState $switchRepo
            Push-Location -LiteralPath $switchRepo
            try {
                foreach ($path in @((Join-Path $TestDrive 'missing'), $TestDrive, (Join-Path $switchRepo 'README.md'), 'Env:')) {
                    { Set-Branch target -Force -Path $path -Confirm:$false -ErrorAction Stop } | Should -Throw
                }
                Get-SwitchTestState $switchRepo | Should -BeExactly $before
                (Get-Location).Path | Should -BeExactly $switchRepo
            } finally {
                Pop-Location
            }
        }
    }
}

Describe 'Get-Branch machine-readable contract' {
    It 'exports the command with typed output and repository pipeline metadata' {
        $command = Get-Command Get-Branch -Module Shmuelie.Git
        $command.OutputType.Name | Should -Contain 'GitBranch'
        $command.Parameters.Path.Aliases | Should -Contain 'RepositoryPath'
        $command.Parameters.Path.Aliases | Should -Contain 'RepoPath'
        $parameter = $command.Parameters.Path.Attributes |
            Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] }
        $parameter.ValueFromPipeline | Should -Contain $true
        $parameter.ValueFromPipelineByPropertyName | Should -Contain $true
        (Get-Help Get-Branch).Synopsis | Should -BeLike '*local and remote-tracking branches*'
    }

    It 'preserves subject delimiters, whitespace, Unicode and full ref identities' {
        InModuleScope Shmuelie.Git -Parameters @{ Repo = (Join-Path $TestDrive 'repo [literal]') } {
            param($Repo)
            $subject = "  literal|subject`t'quote'`r`nnext $([char]0x96ea)  "
            $data = (@('refs/heads/origin/main', '*', ('a' * 64), '', '', $subject) -join "`0") + "`0`n" +
                (@('refs/remotes/origin/HEAD', ' ', ('b' * 40), '', 'refs/remotes/origin/main', '') -join "`0") + "`0`n"
            Mock Invoke-Git {
                [PSCustomObject]@{ StandardOutput = $data; RepositoryPath = $Repo }
            }

            $actual = @(Get-Branch -Path $Repo)

            $actual | Should -HaveCount 2
            $actual[0].PSTypeNames[0] | Should -BeExactly 'GitBranch'
            $actual[0].Branch | Should -BeExactly 'origin/main'
            $actual[0].RefName | Should -BeExactly 'refs/heads/origin/main'
            $actual[0].Commit | Should -BeExactly ('a' * 64)
            $actual[0].Current | Should -BeTrue
            $actual[0].IsRemote | Should -BeFalse
            $actual[0].Subject | Should -BeExactly $subject
            $actual[0].RepositoryPath | Should -BeExactly $Repo
            $actual[0].Upstream | Should -BeNullOrEmpty
            $actual[0].AheadBy | Should -BeNullOrEmpty
            $actual[0].BehindBy | Should -BeNullOrEmpty
            $actual[0].UpstreamGone | Should -BeFalse
            $actual[0].SymbolicTarget | Should -BeNullOrEmpty
            $actual[1].Branch | Should -BeExactly 'origin/HEAD'
            $actual[1].IsRemote | Should -BeTrue
            $actual[1].Current | Should -BeFalse
            $actual[1].SymbolicTarget | Should -BeExactly 'refs/remotes/origin/main'
            $actual[1].Subject | Should -BeExactly ''
            Should -Invoke Invoke-Git -Times 1 -Exactly -ParameterFilter {
                $Path -ceq $Repo -and $AllowBare -and $Environment.GIT_NO_LAZY_FETCH -ceq '1' -and
                $Arguments[0] -eq 'for-each-ref' -and $Arguments[1] -eq '--sort=refname' -and
                $Arguments[2] -eq '--format=%(refname)%00%(HEAD)%00%(objectname)%00%(upstream)%00%(symref)%00%(subject)%00' -and
                $Arguments[3] -eq '--' -and $Arguments[4] -eq 'refs/heads/' -and $Arguments[5] -eq 'refs/remotes/'
            }
        }
    }

    It 'selects <Label> using ref namespaces, not remote-name parsing' -ForEach @(
        @{ Label = 'both by default'; Options = @{}; Prefixes = @('refs/heads/', 'refs/remotes/') }
        @{ Label = 'local only'; Options = @{ Local = $true }; Prefixes = @('refs/heads/') }
        @{ Label = 'remote only'; Options = @{ Remote = $true }; Prefixes = @('refs/remotes/') }
        @{ Label = 'both explicitly'; Options = @{ Local = $true; Remote = $true }; Prefixes = @('refs/heads/', 'refs/remotes/') }
    ) {
        InModuleScope Shmuelie.Git -Parameters @{ Options = $Options; Prefixes = $Prefixes } {
            param($Options, $Prefixes)
            Mock Invoke-Git { [PSCustomObject]@{ StandardOutput = ''; RepositoryPath = 'unused' } }
            Get-Branch @Options | Should -BeNullOrEmpty
            Should -Invoke Invoke-Git -Times 1 -Exactly -ParameterFilter {
                ($Arguments[4..($Arguments.Count - 1)] -join '|') -ceq ($Prefixes -join '|')
            }
        }
    }

    It 'rejects malformed output rather than silently returning branches' -ForEach @(
        @{ Data = 'not a record' }
        @{ Data = ("refs/heads/main`0*`0bad-hash`0`0`0subject`0`n") }
        @{ Data = ("refs/tags/main`0*`0" + ('a' * 40) + "`0`0`0subject`0`n") }
        @{ Data = ("refs/heads/main`0*`0" + ('a' * 40) + "`0`0`0subject`0") }
    ) {
        InModuleScope Shmuelie.Git -Parameters @{ Data = $Data } {
            param($Data)
            Mock Invoke-Git { [PSCustomObject]@{ StandardOutput = $Data; RepositoryPath = 'unused' } }
            Get-Branch -ErrorAction SilentlyContinue -ErrorVariable failures | Should -BeNullOrEmpty
            $failures | Should -HaveCount 1
            $failures[0].FullyQualifiedErrorId | Should -Match '^InvalidGitBranchOutput'
            { Get-Branch -ErrorAction Stop } | Should -Throw '*Invalid branch ref*'
        }
    }

    It 'propagates <Stage> failures through the shared helper without partial results' -ForEach @(
        @{ Stage = 'branch query' }
        @{ Stage = 'upstream query' }
        @{ Stage = 'count query' }
    ) {
        InModuleScope Shmuelie.Git -Parameters @{ Stage = $Stage; Repo = $TestDrive } {
            param($Stage, $Repo)
            Mock Resolve-GitRepositoryPath { $Repo }
            Mock Invoke-GitProcess {
                if (($Stage -eq 'branch query' -and $Arguments[3] -eq '--sort=refname') -or
                    ($Stage -eq 'upstream query' -and $Arguments[3] -eq '--format=%(refname)%00%(objectname)') -or
                    ($Stage -eq 'count query' -and $Arguments[2] -eq 'rev-list')) {
                    return [PSCustomObject]@{
                        ExitCode = 42; StandardOutput = ''; StandardError = 'deliberate failure'; Output = @()
                    }
                }
                $data = if ($Arguments[3] -eq '--sort=refname') {
                    # Include an untracked branch first to detect partial emission.
                    "refs/heads/first`0 `0" + ('a' * 40) + "`0`0`0subject`0`n" +
                    "refs/heads/main`0*`0" + ('a' * 40) + "`0refs/remotes/origin/main`0`0subject`0`n"
                } else {
                    "refs/remotes/origin/main`0" + ('b' * 40) + "`n"
                }
                [PSCustomObject]@{ ExitCode = 0; StandardOutput = $data; StandardError = ''; Output = @() }
            }

            Get-Branch -Path $Repo -ErrorAction SilentlyContinue -ErrorVariable failures | Should -BeNullOrEmpty
            $failures | Should -HaveCount 1
            $failures[0].FullyQualifiedErrorId | Should -Match '^GitCommandFailed'
            $failures[0].TargetObject.ExitCode | Should -Be 42
            $failures[0].TargetObject.RepositoryPath | Should -BeExactly $Repo
            { Get-Branch -Path $Repo -ErrorAction Stop } | Should -Throw '*deliberate failure*'
        }
    }

    It 'disables lazy fetching in every child for <Label> without changing the caller environment' -ForEach @(
        @{ Label = 'a worktree'; Bare = $false; ParentValue = '0' }
        @{ Label = 'a bare repository'; Bare = $true; ParentValue = $null }
    ) {
        InModuleScope Shmuelie.Git -Parameters @{ Repo = $TestDrive; Bare = $Bare; ParentValue = $ParentValue } {
            param($Repo, $Bare, $ParentValue)
            $originalValue = [Environment]::GetEnvironmentVariable('GIT_NO_LAZY_FETCH', 'Process')
            try {
                if ($null -eq $ParentValue) {
                    Remove-Item Env:\GIT_NO_LAZY_FETCH -ErrorAction Ignore
                } else {
                    [Environment]::SetEnvironmentVariable('GIT_NO_LAZY_FETCH', $ParentValue, 'Process')
                }
                Mock Invoke-GitProcess {
                    [Environment]::GetEnvironmentVariable('GIT_NO_LAZY_FETCH', 'Process') | Should -BeExactly $ParentValue
                    $data = if ($Arguments[2] -eq 'rev-parse') {
                        if ($Arguments[3] -eq '--is-inside-work-tree' -and $Bare) { "false`n" } else { "true`n" }
                    } elseif ($Arguments[2] -eq 'for-each-ref' -and $Arguments[3] -eq '--sort=refname') {
                        "refs/heads/main`0*`0" + ('a' * 40) + "`0refs/remotes/origin/main`0`0subject`0`n"
                    } elseif ($Arguments[2] -eq 'for-each-ref') {
                        "refs/remotes/origin/main`0" + ('b' * 40) + "`n"
                    } elseif ($Arguments[2] -eq 'rev-list') {
                        "2`t3`n"
                    } else {
                        throw "Unexpected git command: $($Arguments[2])"
                    }
                    [PSCustomObject]@{ ExitCode = 0; StandardOutput = $data; StandardError = ''; Output = @() }
                }

                $actual = @(Get-Branch -Path $Repo -ErrorAction Stop)

                $actual | Should -HaveCount 1
                $actual[0].AheadBy | Should -Be 2
                $actual[0].BehindBy | Should -Be 3
                $discoveryCalls = if ($Bare) { 6 } else { 3 }
                Should -Invoke Invoke-GitProcess -Times ($discoveryCalls + 3) -Exactly
                Should -Invoke Invoke-GitProcess -Times $discoveryCalls -Exactly -ParameterFilter { $Arguments[2] -eq 'rev-parse' }
                Should -Invoke Invoke-GitProcess -Times 2 -Exactly -ParameterFilter { $Arguments[2] -eq 'for-each-ref' }
                Should -Invoke Invoke-GitProcess -Times 1 -Exactly -ParameterFilter { $Arguments[2] -eq 'rev-list' }
                Should -Invoke Invoke-GitProcess -Times 0 -Exactly -ParameterFilter {
                    -not $Environment -or $Environment.GIT_NO_LAZY_FETCH -cne '1'
                }
                [Environment]::GetEnvironmentVariable('GIT_NO_LAZY_FETCH', 'Process') | Should -BeExactly $ParentValue
            } finally {
                if ($null -eq $originalValue) {
                    Remove-Item Env:\GIT_NO_LAZY_FETCH -ErrorAction Ignore
                } else {
                    [Environment]::SetEnvironmentVariable('GIT_NO_LAZY_FETCH', $originalValue, 'Process')
                }
            }
        }
    }

    It 'matches upstreams case-sensitively and rejects prefix-only matches' {
        InModuleScope Shmuelie.Git {
            Mock Invoke-Git {
                $data = if ($Arguments[1] -eq '--sort=refname') {
                    "refs/heads/main`0*`0" + ('a' * 40) + "`0refs/remotes/origin/Main`0`0subject`0`n"
                } else {
                    "refs/remotes/origin/main`0" + ('b' * 40) + "`n" +
                    "refs/remotes/origin/Main/child`0" + ('c' * 40) + "`n"
                }
                [PSCustomObject]@{ StandardOutput = $data; RepositoryPath = 'unused' }
            }
            $actual = Get-Branch
            $actual.UpstreamGone | Should -BeTrue
            $actual.AheadBy | Should -BeNullOrEmpty
            $actual.BehindBy | Should -BeNullOrEmpty
            Should -Invoke Invoke-Git -Times 0 -ParameterFilter { $Arguments[0] -eq 'rev-list' }
        }
    }
}

Describe 'Get-Branch integration' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
    BeforeAll {
        $script:branchGitEnvironment = @{}
        foreach ($item in Get-ChildItem Env: | Where-Object Name -Like 'GIT_*') {
            $script:branchGitEnvironment[$item.Name] = $item.Value
            [Environment]::SetEnvironmentVariable($item.Name, $null, 'Process')
        }
        $env:GIT_CONFIG_GLOBAL = Join-Path $TestDrive 'no-global-git-config'
        $env:GIT_CONFIG_NOSYSTEM = '1'
        $env:GIT_CONFIG_COUNT = '0'
        $script:branchRepo = New-TestRepo -Path (Join-Path $TestDrive 'branch repo [literal]') -NoCommit
        Invoke-Git @('-C', $script:branchRepo, 'commit', '--allow-empty', '-m', 'init', '--quiet')
        $script:branchBase = Invoke-Git @('-C', $script:branchRepo, 'rev-parse', 'HEAD')
        $tree = Invoke-Git @('-C', $script:branchRepo, 'rev-parse', 'HEAD^{tree}')
        $script:branchSubject = "topic|subject`tquote '$([char]0x96ea)'"
        $localFirst = Invoke-Git @('-C', $script:branchRepo, 'commit-tree', $tree, '-p', $script:branchBase, '-m', 'local first')
        $script:branchLocalTip = Invoke-Git @('-C', $script:branchRepo, 'commit-tree', $tree, '-p', $localFirst, '-m', $script:branchSubject)
        $remoteFirst = Invoke-Git @('-C', $script:branchRepo, 'commit-tree', $tree, '-p', $script:branchBase, '-m', 'remote first')
        $remoteSecond = Invoke-Git @('-C', $script:branchRepo, 'commit-tree', $tree, '-p', $remoteFirst, '-m', 'remote second')
        $script:branchRemoteTip = Invoke-Git @('-C', $script:branchRepo, 'commit-tree', $tree, '-p', $remoteSecond, '-m', 'remote third')
        Invoke-Git @('-C', $script:branchRepo, 'remote', 'add', 'origin', (Join-Path $TestDrive 'nonexistent-offline-remote'))
        foreach ($item in @(
            @{ Ref = 'refs/remotes/origin/main'; Commit = $script:branchBase }
            @{ Ref = 'refs/remotes/origin/topic'; Commit = $script:branchRemoteTip }
            @{ Ref = 'refs/remotes/origin/gone/child'; Commit = $script:branchBase }
            @{ Ref = 'refs/remotes/team/sub/main'; Commit = $script:branchBase }
            @{ Ref = 'refs/heads/topic'; Commit = $script:branchLocalTip }
            @{ Ref = 'refs/heads/ahead'; Commit = $script:branchLocalTip }
            @{ Ref = 'refs/heads/behind'; Commit = $script:branchBase }
            @{ Ref = 'refs/heads/gone'; Commit = $script:branchBase }
            @{ Ref = 'refs/heads/origin/main'; Commit = $script:branchBase }
            @{ Ref = 'refs/heads/local-tracking'; Commit = $script:branchLocalTip }
            @{ Ref = 'refs/heads/custom-tracking'; Commit = $script:branchLocalTip }
            @{ Ref = 'refs/archive/trunk'; Commit = $script:branchBase }
            @{ Ref = 'refs/tags/main'; Commit = $script:branchBase }
            @{ Ref = "refs/heads/topic;cash`$($([char]0x96ea))"; Commit = $script:branchBase }
        )) {
            Invoke-Git @('-C', $script:branchRepo, 'update-ref', $item.Ref, $item.Commit)
        }
        Invoke-Git @('-C', $script:branchRepo, 'symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main')
        foreach ($tracking in @(
            @{ Branch = 'main'; Upstream = 'main'; Remote = 'origin' }
            @{ Branch = 'topic'; Upstream = 'topic'; Remote = 'origin' }
            @{ Branch = 'ahead'; Upstream = 'main'; Remote = 'origin' }
            @{ Branch = 'behind'; Upstream = 'topic'; Remote = 'origin' }
            @{ Branch = 'gone'; Upstream = 'gone'; Remote = 'origin' }
            @{ Branch = 'local-tracking'; Upstream = 'main'; Remote = '.' }
            @{ Branch = 'custom-tracking'; Upstream = 'trunk'; Remote = 'custom' }
        )) {
            Invoke-Git @('-C', $script:branchRepo, 'config', "branch.$($tracking.Branch).remote", $tracking.Remote)
            Invoke-Git @('-C', $script:branchRepo, 'config', "branch.$($tracking.Branch).merge", "refs/heads/$($tracking.Upstream)")
        }
        Invoke-Git @('-C', $script:branchRepo, 'config', 'remote.custom.url', (Join-Path $TestDrive 'another-offline-remote'))
        Invoke-Git @('-C', $script:branchRepo, 'config', 'remote.custom.fetch', '+refs/heads/*:refs/archive/*')
    }

    AfterAll {
        foreach ($item in Get-ChildItem Env: | Where-Object Name -Like 'GIT_*') {
            [Environment]::SetEnvironmentVariable($item.Name, $null, 'Process')
        }
        foreach ($name in $script:branchGitEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $script:branchGitEnvironment[$name], 'Process')
        }
    }

    It 'lists only branch namespaces with unambiguous identities and symbolic remote HEAD' {
        $actual = @(Get-Branch -Path $script:branchRepo)
        $actual | Should -HaveCount 14
        @($actual | Where-Object Current) | Should -HaveCount 1
        ($actual | Where-Object Current).RefName | Should -BeExactly 'refs/heads/main'
        @($actual | Where-Object IsRemote) | Should -HaveCount 5
        @($actual | Where-Object Branch -EQ 'origin/main') | Should -HaveCount 2
        ($actual | Where-Object Branch -EQ 'origin/HEAD').SymbolicTarget | Should -BeExactly 'refs/remotes/origin/main'
        ($actual | Where-Object RefName -EQ 'refs/heads/topic').Subject | Should -BeExactly $script:branchSubject
        $actual.RefName | Should -Contain 'refs/remotes/team/sub/main'
        $actual.RefName | Should -Contain "refs/heads/topic;cash`$($([char]0x96ea))"
        $actual.RefName | Should -Not -Contain 'refs/tags/main'
        $actual.RefName | Should -Not -Contain 'refs/archive/trunk'
        $actual.RepositoryPath | Select-Object -Unique | Should -BeExactly $script:branchRepo
        $actual.Current | Should -BeOfType ([bool])
        $actual.IsRemote | Should -BeOfType ([bool])
    }

    It 'computes numeric counts for <Branch> from local history' -ForEach @(
        @{ Branch = 'main'; Ahead = 0; Behind = 0; Upstream = 'refs/remotes/origin/main' }
        @{ Branch = 'topic'; Ahead = 2; Behind = 3; Upstream = 'refs/remotes/origin/topic' }
        @{ Branch = 'ahead'; Ahead = 2; Behind = 0; Upstream = 'refs/remotes/origin/main' }
        @{ Branch = 'behind'; Ahead = 0; Behind = 3; Upstream = 'refs/remotes/origin/topic' }
        @{ Branch = 'local-tracking'; Ahead = 2; Behind = 0; Upstream = 'refs/heads/main' }
        @{ Branch = 'custom-tracking'; Ahead = 2; Behind = 0; Upstream = 'refs/archive/trunk' }
    ) {
        $actual = Get-Branch -Path $script:branchRepo -Local | Where-Object Branch -EQ $Branch
        $actual.Upstream | Should -BeExactly $Upstream
        $actual.AheadBy | Should -Be $Ahead
        $actual.BehindBy | Should -Be $Behind
        $actual.AheadBy | Should -BeOfType ([long])
        $actual.BehindBy | Should -BeOfType ([long])
        $actual.UpstreamGone | Should -BeFalse
    }

    It 'distinguishes an absent upstream from a configured but missing ref' {
        $actual = @(Get-Branch -Path $script:branchRepo -Local)
        $gone = $actual | Where-Object Branch -EQ 'gone'
        $gone.Upstream | Should -BeExactly 'refs/remotes/origin/gone'
        $gone.UpstreamGone | Should -BeTrue
        $gone.AheadBy | Should -BeNullOrEmpty
        $gone.BehindBy | Should -BeNullOrEmpty
        $untracked = $actual | Where-Object Branch -EQ 'origin/main'
        $untracked.Upstream | Should -BeNullOrEmpty
        $untracked.UpstreamGone | Should -BeFalse
        $untracked.AheadBy | Should -BeNullOrEmpty
        $untracked.BehindBy | Should -BeNullOrEmpty
    }

    It 'filters local and remote refs without contacting unavailable remotes' {
        @(Get-Branch -Path $script:branchRepo -Local) | Should -HaveCount 9
        @(Get-Branch -Path $script:branchRepo -Remote) | Should -HaveCount 5
        @(Get-Branch -Path $script:branchRepo -Local -Remote) | Should -HaveCount 14
    }

    It 'preserves location and LASTEXITCODE for literal paths, aliases and pipeline property names' {
        $nested = Join-Path $script:branchRepo 'subdirectory [literal]'
        $null = New-Item -ItemType Directory -Path $nested -Force
        $before = Get-Location
        $global:LASTEXITCODE = 37
        foreach ($name in @('Path', 'RepositoryPath', 'RepoPath')) {
            $options = @{ $name = $nested; Remote = $true }
            $actual = @(Get-Branch @options)
            $actual | Should -HaveCount 5
            $actual.RepositoryPath | Select-Object -Unique | Should -BeExactly $nested
            @([PSCustomObject]@{ $name = $nested } | Get-Branch -Remote) | Should -HaveCount 5
        }
        @($script:branchRepo, $nested | Get-Branch -Remote) | Should -HaveCount 10
        (Get-Location).Path | Should -BeExactly $before.Path
        $global:LASTEXITCODE | Should -Be 37
    }

    It 'uses the current directory by default and resolves relative paths' {
        $before = Get-Location
        try {
            Set-Location -LiteralPath $TestDrive
            @(Get-Branch -Path (Split-Path $script:branchRepo -Leaf) -Local) | Should -HaveCount 9
            Set-Location -LiteralPath $script:branchRepo
            @(Get-Branch -Local) | Should -HaveCount 9
        } finally {
            Set-Location -LiteralPath $before.Path
        }
    }

    It 'reports no current branch for a detached HEAD and uses linked worktree HEAD' {
        $detached = Join-Path $TestDrive 'detached-branch-worktree'
        $linked = Join-Path $TestDrive 'linked-branch-worktree'
        Invoke-Git @('-C', $script:branchRepo, 'worktree', 'add', '--detach', '--quiet', $detached, $script:branchBase)
        Invoke-Git @('-C', $script:branchRepo, 'worktree', 'add', '--quiet', $linked, 'topic')
        $detachedBranches = @(Get-Branch -Path $detached)
        $detachedBranches | Should -HaveCount 14
        @($detachedBranches | Where-Object Current) | Should -HaveCount 0
        $current = @(Get-Branch -Path $linked | Where-Object Current)
        $current | Should -HaveCount 1
        $current[0].Branch | Should -BeExactly 'topic'
        $current[0].RepositoryPath | Should -BeExactly $linked
    }

    It 'returns no fabricated row for an empty repository or an unborn current branch' {
        $empty = New-TestRepo -Path (Join-Path $TestDrive 'branch-empty') -NoCommit
        Get-Branch -Path $empty -ErrorAction Stop | Should -BeNullOrEmpty
        $unborn = New-TestRepo -Path (Join-Path $TestDrive 'branch-unborn')
        Invoke-Git @('-C', $unborn, 'symbolic-ref', 'HEAD', 'refs/heads/not-created')
        $actual = @(Get-Branch -Path $unborn)
        $actual | Should -HaveCount 1
        $actual[0].Branch | Should -BeExactly 'main'
        $actual[0].Current | Should -BeFalse
    }

    It 'supports bare repositories without a worktree' {
        $bare = Join-Path $TestDrive 'branch-bare.git'
        Invoke-Git @('-c', 'safe.bareRepository=all', 'clone', '--bare', '--local', '--quiet', $script:branchRepo, $bare)
        @(Get-Branch -Path $bare -Local -ErrorAction Stop) | Should -HaveCount 9
    }

    It 'emits errors rather than a success-shaped result for invalid repository paths' {
        $nonGit = Join-Path $TestDrive 'branch-not-git'
        $null = New-Item -ItemType Directory -Path $nonGit
        Get-Branch -Path $nonGit -ErrorAction SilentlyContinue -ErrorVariable failures | Should -BeNullOrEmpty
        $failures | Should -HaveCount 1
        { Get-Branch -Path $nonGit -ErrorAction Stop } | Should -Throw '*not inside a git working tree*'
        { Get-Branch -Path (Join-Path $nonGit 'missing') -ErrorAction Stop } | Should -Throw '*path not found*'
        { Get-Branch -Path (Join-Path $script:branchRepo '.git' 'HEAD') -ErrorAction Stop } |
            Should -Throw '*must be a FileSystem directory*'
        @($nonGit, $script:branchRepo | Get-Branch -Remote -ErrorAction SilentlyContinue) | Should -HaveCount 5
    }

    It 'preserves newline and backslash characters in Unix repository paths' -Skip:$IsWindows {
        $repo = New-TestRepo -Path (Join-Path $TestDrive "branch`nrepo\literal")
        $actual = @(Get-Branch -Path $repo)
        $actual | Should -HaveCount 1
        $actual[0].RepositoryPath | Should -BeExactly $repo
        $actual[0].Branch | Should -BeExactly 'main'
    }
}

Describe 'Get-GitTag' {
    BeforeAll {
        $tagEnvironment = @{}
        foreach ($key in @(
            'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_SYSTEM', 'GIT_CONFIG_NOSYSTEM',
            'GIT_CONFIG_COUNT', 'GIT_CONFIG_PARAMETERS', 'GIT_AUTHOR_DATE', 'GIT_COMMITTER_DATE'
        )) {
            $tagEnvironment[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        }
        $env:GIT_CONFIG_GLOBAL = Join-Path $TestDrive 'no-global-config'
        $env:GIT_CONFIG_SYSTEM = Join-Path $TestDrive 'no-system-config'
        $env:GIT_CONFIG_NOSYSTEM = '1'
        $env:GIT_CONFIG_COUNT = '0'
        Remove-Item Env:GIT_CONFIG_PARAMETERS -ErrorAction Ignore
        $env:GIT_AUTHOR_DATE = '2024-01-02T03:04:05-07:00'
        $env:GIT_COMMITTER_DATE = '2024-01-03T04:05:06-07:00'
        $tagRepo = New-TestRepo -Path (Join-Path $TestDrive 'tags repo')
        $emptyTagRepo = New-TestRepo -Path (Join-Path $TestDrive 'no tags') -NoCommit
        $commitId = Invoke-Git @('-C', $tagRepo, 'rev-parse', 'HEAD')
        $treeId = Invoke-Git @('-C', $tagRepo, 'rev-parse', 'HEAD^{tree}')
        $blobId = Invoke-Git @('-C', $tagRepo, 'rev-parse', 'HEAD:README.md')
        $tagSubdirectory = New-Item -ItemType Directory -Path (Join-Path $tagRepo 'subdirectory')
        $env:GIT_COMMITTER_DATE = '2024-02-03T13:45:06+05:45'
        $unicodeName = "release-$([char]0xe9)-$([char]0x65e5)"
        $annotation = "Release $([char]0xe9) $([char]::ConvertFromUtf32(0x1f680))`n`nSecond paragraph`nlast line`n`n"
        $controlAnnotation = "Quote ' and ! and \ and $([char]0x1f) and $([char]0x1e)`n`nTab`tCR`rLF`n`n"

        foreach ($entry in @(
            @{ Name = 'a-light'; Target = $commitId }
            @{ Name = 'blob'; Target = $blobId }
            @{ Name = 'tree'; Target = $treeId }
            @{ Name = 'release/v1.0'; Target = $commitId }
            @{ Name = 'release/v1.1'; Target = $commitId }
            @{ Name = $unicodeName; Target = $commitId }
        )) {
            Invoke-Git @('-C', $tagRepo, 'tag', $entry.Name, $entry.Target)
        }
        foreach ($entry in @(
            @{ Name = 'annotated'; Target = $commitId; Message = $annotation }
            @{ Name = 'control'; Target = $commitId; Message = $controlAnnotation }
            @{ Name = 'empty'; Target = $commitId; Message = '' }
            @{ Name = 'annotated-blob'; Target = $blobId; Message = 'blob annotation' }
            @{ Name = 'annotated-tree'; Target = $treeId; Message = 'tree annotation' }
            @{ Name = 'nested-commit'; Target = 'refs/tags/annotated'; Message = 'outer commit annotation' }
            @{ Name = 'nested-blob'; Target = 'refs/tags/annotated-blob'; Message = 'outer blob annotation' }
            @{ Name = 'nested-tree'; Target = 'refs/tags/annotated-tree'; Message = 'outer tree annotation' }
            @{ Name = 'nested-twice'; Target = 'refs/tags/nested-commit'; Message = 'two levels' }
        )) {
            $messagePath = Join-Path $TestDrive 'tag-message.txt'
            Set-Content -LiteralPath $messagePath -Value $entry.Message -NoNewline -Encoding utf8
            Invoke-Git @(
                '-C', $tagRepo, '-c', 'advice.nestedTag=false', 'tag', '-a', '--cleanup=verbatim',
                '-F', $messagePath, $entry.Name, $entry.Target
            )
        }
        Invoke-Git @('-C', $tagRepo, 'branch', 'annotated')
        Invoke-Git @('-C', $tagRepo, 'update-ref', 'refs/archive/annotated', $commitId)
    }

    AfterAll {
        foreach ($key in $tagEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($key, $tagEnvironment[$key], 'Process')
        }
    }

    It 'exports the documented type and standard pipeline path metadata without ShouldProcess' {
        $command = Get-Command Get-GitTag -Module Shmuelie.Git
        $command.OutputType.Name | Should -Contain 'GitTag'
        $command.Parameters.Path.Aliases | Should -Be @('RepositoryPath', 'RepoPath')
        $pathAttribute = $command.Parameters.Path.Attributes |
            Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] }
        $pathAttribute.ValueFromPipeline | Should -BeTrue
        $pathAttribute.ValueFromPipelineByPropertyName | Should -BeTrue
        $command.Parameters.Keys | Should -Not -Contain 'WhatIf'
        (Get-Help Get-GitTag).Description.Text | Should -Not -BeNullOrEmpty
    }

    It 'returns one stable object per tag, never branches or other refs' {
        $tags = @(Get-GitTag -Path $tagRepo)
        $tags.Count | Should -Be 15
        @($tags.Reference | Where-Object { -not $_.StartsWith('refs/tags/') }) | Should -HaveCount 0
        @($tags | Where-Object Reference -CEQ 'refs/tags/annotated') | Should -HaveCount 1
        $tags.Name | Should -Be @($tags.Name | Sort-Object -CaseSensitive -Culture '')
        foreach ($tag in $tags) {
            $tag.PSTypeNames[0] | Should -BeExactly 'GitTag'
            @($tag.PSObject.Properties.Name) | Should -Be @(
                'Name', 'Reference', 'ObjectId', 'ObjectType', 'IsAnnotated',
                'TargetObjectId', 'TargetObjectType', 'TargetCommit', 'Subject',
                'Annotation', 'TaggerDate', 'CreatorDate', 'RepositoryPath'
            )
            $tag.IsAnnotated | Should -BeOfType ([bool])
            $tag.RepositoryPath | Should -BeExactly $tagRepo
            $tag.ObjectId | Should -Match '^[0-9a-f]{40,64}$'
        }
    }

    It 'supports case-sensitive exact and wildcard full-name filters without duplicate results' -ForEach @(
        @{ Filter = @('annotated'); Expected = @('annotated') }
        @{ Filter = @('release/v1.?'); Expected = @('release/v1.0', 'release/v1.1') }
        @{ Filter = @('release/*', 'release/v1.0'); Expected = @('release/v1.0', 'release/v1.1') }
        @{ Filter = @('release/v1.[01]'); Expected = @('release/v1.0', 'release/v1.1') }
        @{ Filter = @('ANNOTATED'); Expected = @() }
        @{ Filter = @('v1.*'); Expected = @() }
        @{ Filter = @('--contains=HEAD'); Expected = @() }
        @{ Filter = @('refs/heads/*'); Expected = @() }
    ) {
        $tags = @(Get-GitTag -Name $Filter -Path $tagRepo)
        @($tags | ForEach-Object Name) | Should -Be $Expected
    }

    It 'distinguishes lightweight commit tags without inventing annotation or tagger dates' {
        $tag = Get-GitTag 'a-light' -Path $tagRepo
        $tag.IsAnnotated | Should -BeFalse
        $tag.ObjectType | Should -BeExactly 'commit'
        $tag.ObjectId | Should -BeExactly $commitId
        $tag.TargetCommit | Should -BeExactly $commitId
        $tag.Subject | Should -BeExactly 'init'
        ($null -eq $tag.Annotation) | Should -BeTrue
        ($null -eq $tag.TaggerDate) | Should -BeTrue
        $tag.CreatorDate | Should -BeOfType ([DateTimeOffset])
        $tag.CreatorDate.ToString('yyyy-MM-ddTHH:mm:sszzz') | Should -BeExactly '2024-01-03T04:05:06-07:00'
    }

    It 'preserves annotated tag metadata, full multiline contents and recorded date offsets' {
        $tag = Get-GitTag annotated -Path $tagRepo
        $tag.IsAnnotated | Should -BeTrue
        $tag.ObjectType | Should -BeExactly 'tag'
        $tag.ObjectId | Should -Not -Be $commitId
        $tag.TargetCommit | Should -BeExactly $commitId
        $tag.Subject | Should -BeExactly ($annotation -split "`n")[0]
        $tag.Annotation | Should -BeExactly $annotation
        $tag.TaggerDate | Should -BeOfType ([DateTimeOffset])
        $tag.TaggerDate.ToString('yyyy-MM-ddTHH:mm:sszzz') | Should -BeExactly '2024-02-03T13:45:06+05:45'
        $tag.CreatorDate | Should -Be $tag.TaggerDate
    }

    It 'preserves empty annotations and quoted control characters without corrupting adjacent records' {
        $empty = Get-GitTag empty -Path $tagRepo
        $empty.IsAnnotated | Should -BeTrue
        ($null -ne $empty.Annotation) | Should -BeTrue
        $empty.Annotation | Should -BeExactly ''
        $empty.Subject | Should -BeExactly ''
        $tags = @(Get-GitTag -Name 'control', 'empty' -Path $tagRepo)
        $tags | Should -HaveCount 2
        $tags[0].Annotation | Should -BeExactly $controlAnnotation
        $tags[1].Name | Should -BeExactly 'empty'
    }

    It 'returns Unicode tag names without git short-name quoting or ambiguity' {
        $tag = Get-GitTag -Name $unicodeName -Path $tagRepo
        $tag.Name | Should -BeExactly $unicodeName
        $tag.Reference | Should -BeExactly "refs/tags/$unicodeName"
    }

    It 'fully peels <TagName> without mistaking a non-commit object for a commit' -ForEach @(
        @{ TagName = 'blob'; Type = 'blob'; Annotated = $false }
        @{ TagName = 'tree'; Type = 'tree'; Annotated = $false }
        @{ TagName = 'annotated-blob'; Type = 'blob'; Annotated = $true }
        @{ TagName = 'annotated-tree'; Type = 'tree'; Annotated = $true }
        @{ TagName = 'nested-blob'; Type = 'blob'; Annotated = $true }
        @{ TagName = 'nested-tree'; Type = 'tree'; Annotated = $true }
        @{ TagName = 'nested-commit'; Type = 'commit'; Annotated = $true }
        @{ TagName = 'nested-twice'; Type = 'commit'; Annotated = $true }
    ) {
        $tag = Get-GitTag $TagName -Path $tagRepo
        $tag.IsAnnotated | Should -Be $Annotated
        $tag.TargetObjectType | Should -BeExactly $Type
        $expectedId = switch ($Type) { blob { $blobId }; tree { $treeId }; commit { $commitId } }
        $tag.TargetObjectId | Should -BeExactly $expectedId
        if ($Type -eq 'commit') {
            $tag.TargetCommit | Should -BeExactly $commitId
        } else {
            ($null -eq $tag.TargetCommit) | Should -BeTrue
        }
        if (-not $Annotated) {
            ($null -eq $tag.CreatorDate) | Should -BeTrue
            ($null -eq $tag.TaggerDate) | Should -BeTrue
            $tag.Subject | Should -BeExactly ''
        }
    }

    It 'handles no tags and no matches as normal empty results' {
        @(Get-GitTag -Path $emptyTagRepo -ErrorAction Stop) | Should -HaveCount 0
        @(Get-GitTag -Path $tagRepo -Name 'missing*' -ErrorAction Stop) | Should -HaveCount 0
    }

    It 'targets explicit, pipeline and current paths without changing location or repository state' {
        $beforeLocation = (Get-Location).ProviderPath
        $beforeRefs = Invoke-Git @('-C', $tagRepo, 'show-ref')
        $beforeStatus = Invoke-Git @('-C', $tagRepo, 'status', '--porcelain=v1', '--untracked-files=all')
        foreach ($inputPath in @(
            $tagRepo,
            [PSCustomObject]@{ Path = $tagRepo },
            [PSCustomObject]@{ RepositoryPath = $tagRepo },
            [PSCustomObject]@{ RepoPath = $tagRepo }
        )) {
            ($inputPath | Get-GitTag -Name a-light).TargetCommit | Should -BeExactly $commitId
        }
        @($emptyTagRepo, $tagRepo | Get-GitTag -Name a-light) | Should -HaveCount 1
        (Get-GitTag -RepositoryPath $tagSubdirectory.FullName -Name a-light).RepositoryPath |
            Should -BeExactly $tagSubdirectory.FullName
        (Get-GitTag -RepoPath $tagRepo -Name a-light).TargetCommit | Should -BeExactly $commitId
        (Get-Location).ProviderPath | Should -BeExactly $beforeLocation
        Push-Location $tagSubdirectory.FullName
        try {
            (Get-GitTag -Name a-light).RepositoryPath | Should -BeExactly $tagSubdirectory.FullName
            (Get-Location).ProviderPath | Should -BeExactly $tagSubdirectory.FullName
        } finally {
            Pop-Location
        }
        Invoke-Git @('-C', $tagRepo, 'show-ref') | Should -Be $beforeRefs
        Invoke-Git @('-C', $tagRepo, 'status', '--porcelain=v1', '--untracked-files=all') |
            Should -Be $beforeStatus
    }

    It 'supports bare repositories and linked worktrees using only local objects' {
        $barePath = Join-Path $TestDrive 'tags bare.git'
        Invoke-Git @('clone', '--bare', '--quiet', '--', $tagRepo, $barePath)
        (Get-GitTag -Path $barePath -Name nested-commit).TargetCommit | Should -BeExactly $commitId
        $linkedPath = Join-Path $TestDrive 'tags linked'
        Invoke-Git @('-C', $tagRepo, 'worktree', 'add', '--detach', '--quiet', $linkedPath)
        $tag = Get-GitTag -Path $linkedPath -Name annotated
        $tag.RepositoryPath | Should -BeExactly $linkedPath
        $tag.Annotation | Should -BeExactly $annotation
    }

    It 'surfaces invalid repository paths clearly' {
        { Get-GitTag -Path (Join-Path $TestDrive 'missing') -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*repository path not found*'
        { Get-GitTag -Path $TestDrive -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*not inside a git working tree*'
        { Get-GitTag -Path (Join-Path $tagRepo 'README.md') -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*must be a FileSystem directory*'
    }

    It 'surfaces native failures rather than silently returning an empty tag list' {
        InModuleScope Shmuelie.Git -Parameters @{ Repo = $tagRepo } {
            param($Repo)
            Mock Resolve-GitRepositoryPath { $Repo }
            Mock Invoke-GitProcess {
                [PSCustomObject]@{
                    ExitCode = 128; StandardOutput = ''; StandardError = 'tag objects unavailable'; Output = @()
                }
            }
            Get-GitTag -Path $Repo -ErrorAction SilentlyContinue -ErrorVariable failures |
                Should -BeNullOrEmpty
            $failures | Should -HaveCount 1
            $failures[0].FullyQualifiedErrorId | Should -Match '^GitCommandFailed'
            $failures[0].TargetObject.ExitCode | Should -Be 128
            { Get-GitTag -Path $Repo -ErrorAction Stop } |
                Should -Throw -ExpectedMessage '*tag objects unavailable*'
            Should -Invoke Invoke-GitProcess -Times 2 -ParameterFilter {
                $Arguments -contains 'for-each-ref' -and $Arguments -contains 'refs/tags/' -and
                $Arguments -contains '--shell' -and $Environment.GIT_NO_LAZY_FETCH -eq '1'
            }
        }
    }

    It 'parses quoted fields as data even when the contents contain NUL or executable-looking text' {
        InModuleScope Shmuelie.Git {
            $message = "first`0second`n`n" + '$(throw "do not execute")' + "`n"
            $values = @(
                'refs/tags/data', 'tag', ('1' * 40), 'commit', ('2' * 40),
                '', '', 'first', $message
            )
            $output = ($values | ForEach-Object { "'$_'" }) -join "`0"
            Mock Invoke-Git {
                [PSCustomObject]@{ StandardOutput = "$output`n"; RepositoryPath = 'unused' }
            }
            $tag = Get-GitTag
            $tag.Subject | Should -BeExactly 'first'
            $tag.Annotation | Should -BeExactly $message
            ($null -eq $tag.TaggerDate) | Should -BeTrue
            ($null -eq $tag.CreatorDate) | Should -BeTrue
        }
    }

    It 'surfaces a nested tag peeling failure without returning a misleading target' {
        InModuleScope Shmuelie.Git {
            $output = @(
                "'refs/tags/nested'", "'tag'", "'$('1' * 40)'", "'tag'", "'$('2' * 40)'",
                "''", "''", "'subject'", "'annotation'"
            ) -join "`0"
            Mock Resolve-GitRepositoryPath { 'unused' }
            Mock Invoke-GitProcess {
                if ($Arguments -contains 'for-each-ref') {
                    [PSCustomObject]@{ ExitCode = 0; StandardOutput = "$output`n"; StandardError = ''; Output = @() }
                } else {
                    [PSCustomObject]@{ ExitCode = 128; StandardOutput = ''; StandardError = 'missing nested target'; Output = @() }
                }
            }
            Get-GitTag -ErrorAction SilentlyContinue -ErrorVariable failures | Should -BeNullOrEmpty
            $failures | Should -HaveCount 1
            $failures[0].Exception.Message | Should -BeLike '*missing nested target*'
            Should -Invoke Invoke-GitProcess -Times 1 -ParameterFilter {
                $Arguments -contains 'rev-parse' -and $Arguments -contains "$('1' * 40)^{}" -and
                $Environment.GIT_NO_LAZY_FETCH -eq '1'
            }
        }
    }

    It 'rejects malformed machine output instead of producing success-shaped rows' {
        InModuleScope Shmuelie.Git {
            Mock Invoke-Git {
                [PSCustomObject]@{ StandardOutput = "not formatted`n"; RepositoryPath = 'unused' }
            }
            { Get-GitTag } | Should -Throw -ErrorId 'GitTagFormatInvalid,Get-GitTag'
        }
    }
}

Describe 'Private git invocation error contracts' {
    BeforeAll {
        $script:invocationRepo = New-TestRepo -Path (Join-Path $TestDrive 'invocation-contract')
    }

    It 'does not export any invocation helper' {
        $exports = (Get-Module Shmuelie.Git).ExportedFunctions.Keys
        foreach ($name in @('Invoke-Git', 'Invoke-GitProcess', 'Invoke-GitWithEnvironment')) {
            $exports | Should -Not -Contain $name
        }
    }

    It 'reports any non-zero exit as one structured error and no result' -ForEach @(
        @{ ExitCode = 1; StdOut = ''; StdErr = 'ordinary failure' }
        @{ ExitCode = 128; StdOut = ''; StdErr = 'fatal failure' }
        @{ ExitCode = 129; StdOut = 'usage on stdout'; StdErr = '' }
        @{ ExitCode = 42; StdOut = ''; StdErr = '' }
    ) {
        InModuleScope Shmuelie.Git -Parameters @{
            Repo = $script:invocationRepo; Code = $ExitCode; StdOut = $StdOut; StdErr = $StdErr
        } {
            param($Repo, $Code, $StdOut, $StdErr)
            Mock Resolve-GitRepositoryPath { $Repo }
            Mock Invoke-GitProcess {
                [PSCustomObject]@{
                    PSTypeName = 'GitInvocationResult'; ExitCode = $Code
                    StandardOutput = $StdOut; StandardError = $StdErr; Output = @()
                }
            }

            Invoke-Git -Arguments @('status') -ErrorAction SilentlyContinue -ErrorVariable failures |
                Should -BeNullOrEmpty

            $failures | Should -HaveCount 1
            $failures[0].FullyQualifiedErrorId | Should -Match '^GitCommandFailed'
            $failures[0].CategoryInfo.Category | Should -Be 'InvalidOperation'
            $failures[0].TargetObject.ExitCode | Should -Be $Code
            $failures[0].TargetObject.StandardOutput | Should -BeExactly $StdOut
            $failures[0].TargetObject.StandardError | Should -BeExactly $StdErr
            $failures[0].TargetObject.RepositoryPath | Should -BeExactly $Repo
            $detail = if ($StdErr) { $StdErr } elseif ($StdOut) { $StdOut } else { 'No output.' }
            $failures[0].Exception.Message | Should -BeLike "*$detail*"
            Should -Invoke Invoke-GitProcess -Times 1 -ParameterFilter {
                $Arguments.Count -eq 3 -and $Arguments[0] -eq '-C' -and
                $Arguments[1] -ceq $Repo -and $Arguments[2] -eq 'status'
            }
        }
    }

    It 'supports ErrorAction Stop and expected non-zero exits' {
        InModuleScope Shmuelie.Git -Parameters @{ Repo = $script:invocationRepo } {
            param($Repo)
            Mock Resolve-GitRepositoryPath { $Repo }
            Mock Invoke-GitProcess {
                [PSCustomObject]@{
                    PSTypeName = 'GitInvocationResult'; ExitCode = 7
                    StandardOutput = ''; StandardError = 'specific failure'; Output = @('specific failure')
                }
            }
            { Invoke-Git -Arguments @('status') -ErrorAction Stop } |
                Should -Throw -ExpectedMessage '*exit 7*specific failure*'
            $result = Invoke-Git -Arguments @('status') -AllowNonZeroExit -ErrorAction Stop
            $result.ExitCode | Should -Be 7
            $result.StandardError | Should -BeExactly 'specific failure'
        }
    }

    It 'preserves worktree-add false and single-error behavior' {
        InModuleScope Shmuelie.Git -Parameters @{ Repo = $script:invocationRepo } {
            param($Repo)
            Mock Resolve-GitRepositoryPath { $Repo }
            Mock Invoke-GitProcess {
                [PSCustomObject]@{
                    PSTypeName = 'GitInvocationResult'; ExitCode = 5
                    StandardOutput = ''; StandardError = "creation failed`n"; Output = @('creation failed', '')
                }
            }
            Invoke-GitWorktreeAdd -Arguments @('worktree', 'add', 'new') -RepositoryPath $Repo `
                -FailureContext 'the destination' -ErrorAction SilentlyContinue -ErrorVariable failures |
                Should -BeFalse
            $failures | Should -HaveCount 1
            $failures[0].Exception.Message |
                Should -BeExactly 'git worktree add failed for the destination (exit 5): creation failed'
        }
    }

    It 'preserves maintenance result type and native line shape without writing an error' {
        InModuleScope Shmuelie.Git {
            Mock Invoke-GitProcess {
                [PSCustomObject]@{
                    PSTypeName = 'GitInvocationResult'; ExitCode = 9
                    StandardOutput = "one`n`ntwo`n"; StandardError = "failure`n"; Output = @()
                }
            }
            $result = Invoke-GitWorktreeMaintenance -Arguments @('worktree', 'prune') -ErrorAction Stop
            $result.PSTypeNames[0] | Should -Be 'GitWorktreeCommandResult'
            $result.ExitCode | Should -Be 9
            $result.Messages | Should -Be @('one', '', 'two', 'failure')
        }
    }

    It 'reports a missing executable without falling through to shell resolution' {
        InModuleScope Shmuelie.Git {
            Mock Get-Command { $null }
            { Invoke-GitProcess -Arguments @('--version') } |
                Should -Throw -ErrorId 'GitExecutableNotFound,Invoke-GitProcess'
            Should -Invoke Get-Command -Times 1 -ParameterFilter {
                $CommandType -eq 'Application' -and $Name -eq $(if ($IsWindows) { 'git.exe' } else { 'git' })
            }
        }
    }

    It 'terminates with a structured error when the process cannot start' {
        InModuleScope Shmuelie.Git -Parameters @{ MissingExe = (Join-Path $TestDrive 'missing-git.exe') } {
            param($MissingExe)
            Mock Get-Command { [PSCustomObject]@{ Source = $MissingExe } }
            { Invoke-GitProcess -Arguments @('--version') } |
                Should -Throw -ErrorId 'GitProcessFailed,Invoke-GitProcess'
        }
    }

    It 'does not execute the command after repository validation fails' {
        InModuleScope Shmuelie.Git {
            Mock Resolve-GitRepositoryPath { Write-Error 'Invalid repository.' }
            Mock Invoke-GitProcess { throw 'Must not run.' }
            Invoke-Git -Arguments @('status') -ErrorAction SilentlyContinue -ErrorVariable failures |
                Should -BeNullOrEmpty
            $failures | Should -HaveCount 1
            Should -Invoke Invoke-GitProcess -Times 0
        }
    }

    It 'rejects NUL arguments before starting any process' {
        InModuleScope Shmuelie.Git {
            Mock Get-Command { throw 'Should not resolve an executable.' }
            { Invoke-GitProcess -Arguments @('config', "bad`0value") } |
                Should -Throw -ExpectedMessage '*NUL*'
            Should -Invoke Get-Command -Times 0
        }
    }
}

Describe 'Private git invocation integration' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
    BeforeAll {
        $script:literalInvocationRepo = New-TestRepo -Path (Join-Path $TestDrive 'repo [literal] & ; (space)') -NoCommit
        $script:callerInvocationRepo = New-TestRepo -Path (Join-Path $TestDrive 'caller')
    }

    It 'resolves relative literal paths via -C without changing location or LASTEXITCODE' {
        Push-Location $script:callerInvocationRepo
        try {
            $relative = Join-Path '..' (Split-Path $script:literalInvocationRepo -Leaf)
            $result = InModuleScope Shmuelie.Git -Parameters @{ Relative = $relative } {
                param($Relative)
                $LASTEXITCODE = 37
                $result = Invoke-Git -Path $Relative -Arguments @('rev-parse', '--show-toplevel')
                $LASTEXITCODE | Should -Be 37
                $result
            }
            $result.PSTypeNames[0] | Should -Be 'GitInvocationResult'
            $result.ExitCode | Should -Be 0
            ConvertTo-NativeTestPath $result.StandardOutput.Trim() | Should -BeExactly $script:literalInvocationRepo
            $result.StandardError | Should -BeExactly ''
            $result.RepositoryPath | Should -BeExactly $script:literalInvocationRepo
            (Get-Location).ProviderPath | Should -BeExactly $script:callerInvocationRepo
        } finally {
            Pop-Location
        }
    }

    It 'defaults to the PowerShell location rather than the process working directory' {
        Push-Location -LiteralPath $script:literalInvocationRepo
        try {
            $result = InModuleScope Shmuelie.Git { Invoke-Git -Arguments @('rev-parse', '--show-toplevel') }
            ConvertTo-NativeTestPath $result.StandardOutput.Trim() | Should -BeExactly $script:literalInvocationRepo
            $raw = InModuleScope Shmuelie.Git { Invoke-GitWithEnvironment -Arguments @('rev-parse', '--show-toplevel') }
            ConvertTo-NativeTestPath $raw.StandardOutput.Trim() | Should -BeExactly $script:literalInvocationRepo
            $raw.Output.Count | Should -Be 2
            $raw.Output[1] | Should -BeExactly ''
        } finally {
            Pop-Location
        }
    }

    It 'preserves literal argument boundaries for <Name>' -ForEach @(
        @{ Name = 'quotes and shell metacharacters'; Value = 'space "quotes" & | ; $() <> ` %PATH% ! ^' }
        @{ Name = 'empty string'; Value = '' }
        @{ Name = 'trailing backslashes'; Value = 'some path\\' }
        @{ Name = 'newlines and Unicode'; Value = "line one`nline two $([char]0x03A9)" }
    ) {
        InModuleScope Shmuelie.Git -Parameters @{ Repo = $script:literalInvocationRepo; Value = $Value } {
            param($Repo, $Value)
            $arguments = @('config', '--local', 'test.literal', $Value)
            $savedArguments = $arguments.Clone()
            (Invoke-Git -Path $Repo -Arguments $arguments).ExitCode | Should -Be 0
            $arguments | Should -Be $savedArguments
            $result = Invoke-Git -Path $Repo -Arguments @('config', '--local', '--get', 'test.literal')
            $result.StandardOutput | Should -BeExactly "$Value`n"
        }
    }

    It 'captures real stderr and exit code even when native exit errors are enabled' {
        InModuleScope Shmuelie.Git -Parameters @{ Repo = $script:literalInvocationRepo } {
            param($Repo)
            $PSNativeCommandUseErrorActionPreference = $true
            $result = Invoke-Git -Path $Repo -Arguments @('rev-parse', '--verify', 'refs/heads/nonexistent') `
                -AllowNonZeroExit -ErrorAction Stop
            $result.ExitCode | Should -Not -Be 0
            $result.StandardOutput | Should -BeExactly ''
            $result.StandardError | Should -Not -BeNullOrEmpty
        }
    }

    It 'uses an explicit FileSystem path even from another provider' {
        Push-Location Env:
        try {
            InModuleScope Shmuelie.Git -Parameters @{ Repo = $script:literalInvocationRepo } {
                param($Repo)
                (Invoke-Git -Path $Repo -Arguments @('rev-parse', '--is-inside-work-tree')).StandardOutput.Trim() |
                    Should -BeExactly 'true'
            }
            (Get-Location).Provider.Name | Should -BeExactly 'Environment'
        } finally {
            Pop-Location
        }
    }

    It 'ignores a PowerShell function shadowing git during discovery and execution' {
        InModuleScope Shmuelie.Git -Parameters @{ Repo = $script:literalInvocationRepo } {
            param($Repo)
            function git { throw 'A shell function must not run.' }
            (Invoke-Git -Path $Repo -Arguments @('rev-parse', '--is-inside-work-tree')).StandardOutput.Trim() |
                Should -BeExactly 'true'
        }
    }

    It 'keeps simultaneous invocations and the parent environment isolated' {
        $modulePath = (Get-Module Shmuelie.Git).Path
        $target = $script:literalInvocationRepo
        $oldValue = $env:SHMUELIE_GIT_INVOCATION_TEST
        $env:SHMUELIE_GIT_INVOCATION_TEST = 'parent'
        try {
            $results = 1..4 | ForEach-Object -Parallel {
                Import-Module $using:modulePath -Force
                & (Get-Module Shmuelie.Git) {
                    param($Repo, $Value)
                    $result = Invoke-Git -Path $Repo -Arguments @(
                        '--config-env=test.parallel=SHMUELIE_GIT_INVOCATION_TEST',
                        'config', '--get', 'test.parallel'
                    ) -Environment @{ SHMUELIE_GIT_INVOCATION_TEST = $Value }
                    [PSCustomObject]@{ Expected = $Value; Actual = $result.StandardOutput.Trim() }
                } $using:target "child-$_"
            } -ThrottleLimit 4
            $results | Should -HaveCount 4
            foreach ($result in $results) {
                $result.Actual | Should -BeExactly $result.Expected
            }
            $env:SHMUELIE_GIT_INVOCATION_TEST | Should -BeExactly 'parent'
        } finally {
            $env:SHMUELIE_GIT_INVOCATION_TEST = $oldValue
        }
    }

    It 'reports invalid repositories once' -ForEach @(
        @{ Kind = 'missing' }
        @{ Kind = 'plain directory' }
        @{ Kind = 'file' }
        @{ Kind = 'provider' }
    ) {
        $path = Join-Path $TestDrive "invalid-$Kind"
        switch ($Kind) {
            'plain directory' { New-Item -ItemType Directory -Path $path -Force | Out-Null }
            'file' { Set-Content -LiteralPath $path -Value 'not a directory' }
            'provider' { $path = 'Env:' }
        }
        InModuleScope Shmuelie.Git -Parameters @{ InvalidPath = $path } {
            param($InvalidPath)
            Invoke-Git -Path $InvalidPath -Arguments @('status') -ErrorAction SilentlyContinue -ErrorVariable failures |
                Should -BeNullOrEmpty
            $failures | Should -HaveCount 1
        }
    }

    It 'allows bare repositories only when explicitly requested' {
        $bare = Join-Path $TestDrive 'bare.git'
        Invoke-Git @('init', '--bare', '--quiet', $bare)
        InModuleScope Shmuelie.Git -Parameters @{ BarePath = $bare } {
            param($BarePath)
            # Keep the bare fixture independent of the host's discovery policy.
            $environment = @{
                GIT_CONFIG_COUNT = '1'
                GIT_CONFIG_KEY_0 = 'safe.bareRepository'
                GIT_CONFIG_VALUE_0 = 'all'
            }
            Invoke-Git -Path $BarePath -Arguments @('rev-parse', '--is-bare-repository') `
                -Environment $environment -ErrorAction SilentlyContinue -ErrorVariable failures | Should -BeNullOrEmpty
            $failures | Should -HaveCount 1
            (Invoke-Git -Path $BarePath -AllowBare -Environment $environment -Arguments @('rev-parse', '--is-bare-repository')).StandardOutput.Trim() |
                Should -BeExactly 'true'
        }
    }
}

Describe 'Private git process stream and environment handling' {
    BeforeAll {
        $script:invocationPwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
    }

    It 'drains large stdout and stderr concurrently and returns a non-zero exit without errors' {
        InModuleScope Shmuelie.Git -Parameters @{ Pwsh = $script:invocationPwsh } {
            param($Pwsh)
            # Substitute a deterministic native child; no git installation, remote,
            # credential helper or shell alias is involved in the stream contract.
            Mock Get-Command { [PSCustomObject]@{ Source = $Pwsh } }
            $script = '[Console]::Out.Write(("o" * 262144)); [Console]::Error.Write(("e" * 262144)); exit 23'
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
            $result = Invoke-GitProcess -Arguments @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) -ErrorAction Stop
            $result.ExitCode | Should -Be 23
            $result.StandardOutput | Should -BeExactly ('o' * 262144)
            $result.StandardError | Should -BeExactly ('e' * 262144)
            $result.Output | Should -HaveCount 2
        }
    }

    It 'returns empty strings and an empty legacy array for a silent success' {
        InModuleScope Shmuelie.Git -Parameters @{ Pwsh = $script:invocationPwsh } {
            param($Pwsh)
            Mock Get-Command { [PSCustomObject]@{ Source = $Pwsh } }
            $result = Invoke-GitWithEnvironment -Arguments @('-NoProfile', '-NonInteractive', '-Command', 'exit 0')
            $result.ExitCode | Should -Be 0
            $result.StandardOutput | Should -BeExactly ''
            $result.StandardError | Should -BeExactly ''
            $result.Output | Should -HaveCount 0
        }
    }

    It 'isolates environment overrides, removes inherited values, and prevents interactive input' {
        $oldValue = $env:SHMUELIE_GIT_INVOCATION_TEST
        $env:SHMUELIE_GIT_INVOCATION_TEST = 'parent'
        try {
            InModuleScope Shmuelie.Git -Parameters @{ Pwsh = $script:invocationPwsh } {
                param($Pwsh)
                Mock Get-Command { [PSCustomObject]@{ Source = $Pwsh } }
                $script = @'
[ordered]@{
    Value = $env:SHMUELIE_GIT_INVOCATION_TEST
    Prompt = $env:GIT_TERMINAL_PROMPT
    Gcm = $env:GCM_INTERACTIVE
    AskPass = $env:GIT_ASKPASS
    Pager = $env:GIT_PAGER
    Editor = $env:GIT_EDITOR
    SequenceEditor = $env:GIT_SEQUENCE_EDITOR
    Input = [Console]::In.ReadToEnd()
} | ConvertTo-Json -Compress
'@
                $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
                $environment = @{ SHMUELIE_GIT_INVOCATION_TEST = 'child'; GIT_TERMINAL_PROMPT = '1' }
                $result = Invoke-GitWithEnvironment -Arguments @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) `
                    -Environment $environment
                $values = $result.StandardOutput | ConvertFrom-Json
                $values.Value | Should -BeExactly 'child'
                $values.Prompt | Should -BeExactly '0'
                $values.Gcm | Should -BeExactly 'never'
                $values.AskPass | Should -BeExactly 'false'
                $values.Pager | Should -BeExactly 'cat'
                $values.Editor | Should -BeExactly 'false'
                $values.SequenceEditor | Should -BeExactly 'false'
                $values.Input | Should -BeExactly ''
                $env:SHMUELIE_GIT_INVOCATION_TEST | Should -BeExactly 'parent'
                $environment.GIT_TERMINAL_PROMPT | Should -BeExactly '1'
                $removed = Invoke-GitProcess -Arguments @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) `
                    -Environment @{ SHMUELIE_GIT_INVOCATION_TEST = $null }
                ($removed.StandardOutput | ConvertFrom-Json).Value | Should -BeNullOrEmpty
                $env:SHMUELIE_GIT_INVOCATION_TEST | Should -BeExactly 'parent'
            }
        } finally {
            $env:SHMUELIE_GIT_INVOCATION_TEST = $oldValue
        }
    }
}

Describe 'Add-Worktree' {
    It 'requires a non-empty branch name' {
        { Add-Worktree -BranchName '' } | Should -Throw
    }
}

Describe 'Add-Worktree creation' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
    It 'checks out an existing branch to an explicit worktree path' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'add-explicit-main')
        $branch = 'feature/add-explicit'
        $customPath = Join-Path $TestDrive 'custom-add-explicit'
        Invoke-Git @('-C', $repo, 'branch', $branch)

        Push-Location -LiteralPath $repo -ErrorAction Stop
        try {
            Add-Worktree -BranchName $branch -WorktreePath $customPath -Confirm:$false
            (Get-Location).Path | Should -BeExactly (Resolve-Path -LiteralPath $customPath).Path
            Test-Path -LiteralPath $customPath | Should -BeTrue
            (@(Get-Worktrees) | Where-Object Branch -eq $branch).Path |
                Should -BeExactly (Resolve-Path -LiteralPath $customPath).Path
        } finally {
            Pop-Location
        }
    }

    It 'keeps the auto-generated location when no worktree path is supplied' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'add-auto-main')
        $branch = 'feature/add-auto'
        $expectedPath = Join-Path (Split-Path $repo -Parent) $branch
        Invoke-Git @('-C', $repo, 'branch', $branch)

        Push-Location -LiteralPath $repo -ErrorAction Stop
        try {
            Add-Worktree -BranchName $branch -Confirm:$false
            (Get-Location).Path | Should -BeExactly (Resolve-Path -LiteralPath $expectedPath).Path
            Test-Path -LiteralPath $expectedPath | Should -BeTrue
            (@(Get-Worktrees) | Where-Object Branch -eq $branch).Path |
                Should -BeExactly (Resolve-Path -LiteralPath $expectedPath).Path
        } finally {
            Pop-Location
        }
    }

    It 'changes location to the resolved explicit worktree path when SetLocation is used' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'add-setlocation-main')
        $branch = 'feature/add-setlocation'
        $customPath = Join-Path $TestDrive 'custom-add-setlocation'
        Invoke-Git @('-C', $repo, 'branch', $branch)

        Push-Location -LiteralPath $repo -ErrorAction Stop
        try {
            Add-Worktree -BranchName $branch -WorktreePath $customPath -SetLocation -Confirm:$false
            (Get-Location).Path | Should -BeExactly (Resolve-Path -LiteralPath $customPath).Path
        } finally {
            Pop-Location
        }
    }

    It 'surfaces git errors when the destination path is invalid' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'add-failure-main')
        $branch = 'feature/add-failure'
        $existingPath = Join-Path $TestDrive 'existing-add-destination'
        New-Item -ItemType Directory -Path $existingPath -Force | Out-Null
        Set-Content -Path (Join-Path $existingPath 'already-here.txt') -Value 'content'
        Invoke-Git @('-C', $repo, 'branch', $branch)

        Push-Location -LiteralPath $repo -ErrorAction Stop
        try {
            { Add-Worktree -BranchName $branch -WorktreePath $existingPath -Confirm:$false -ErrorAction Stop } |
                Should -Throw -ExpectedMessage '*git worktree add failed*already exists*'
            (Get-Location).Path | Should -BeExactly (Resolve-Path -LiteralPath $repo).Path
        } finally {
            Pop-Location
        }
    }
}

Describe 'Worktree creation navigation' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
    BeforeAll {
        $navigationEnvironment = @{}
        foreach ($key in @(
            'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_SYSTEM', 'GIT_CONFIG_NOSYSTEM',
            'GIT_CONFIG_COUNT', 'GIT_CONFIG_PARAMETERS', 'GIT_DIR', 'GIT_WORK_TREE',
            'GIT_COMMON_DIR', 'GIT_INDEX_FILE', 'GIT_OBJECT_DIRECTORY',
            'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_NAMESPACE', 'GIT_CEILING_DIRECTORIES'
        )) {
            $navigationEnvironment[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
            Remove-Item -LiteralPath "Env:$key" -ErrorAction Ignore
        }
        $env:GIT_CONFIG_GLOBAL = Join-Path $TestDrive 'no-global-config'
        $env:GIT_CONFIG_SYSTEM = Join-Path $TestDrive 'no-system-config'
        $env:GIT_CONFIG_NOSYSTEM = '1'
        $env:GIT_CONFIG_COUNT = '0'
    }

    AfterAll {
        foreach ($key in $navigationEnvironment.Keys) {
            if ($null -eq $navigationEnvironment[$key]) {
                Remove-Item -LiteralPath "Env:$key" -ErrorAction Ignore
            } else {
                [Environment]::SetEnvironmentVariable($key, $navigationEnvironment[$key], 'Process')
            }
        }
    }

    Context '<CommandName>' -ForEach @(
        @{ CommandName = 'Add-Worktree'; CommandParameters = @{ BranchName = 'navigation-test' } }
        @{ CommandName = 'New-Worktree'; CommandParameters = @{ WorkName = 'navigation-test'; NoPrefix = $true } }
    ) {
        BeforeEach {
            $navigationLocationPushed = $false
            $navigationRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $navigationRepo = New-TestRepo -Path (Join-Path $navigationRoot 'main')
            $navigationCaller = Join-Path $navigationRoot 'caller'
            New-Item -ItemType Directory -Path $navigationCaller -ErrorAction Stop | Out-Null
            $navigationDestination = Join-Path $navigationRoot 'created [literal] tree'
            $navigationParameters = $CommandParameters.Clone()
            $navigationParameters.Path = $navigationRepo
            $navigationParameters.WorktreePath = $navigationDestination
            $navigationParameters.Confirm = $false
            if ($CommandName -eq 'Add-Worktree') {
                Invoke-Git @('-C', $navigationRepo, 'branch', 'navigation-test')
            }
            Push-Location -LiteralPath $navigationCaller -ErrorAction Stop
            $navigationLocationPushed = $true
            $navigationCaller = (Get-Location).Path
        }

        AfterEach {
            if ($navigationLocationPushed) {
                Pop-Location -ErrorAction Stop
            }
        }

        It 'uses <Mode> navigation after successful creation' -ForEach @(
            @{ Mode = 'default'; Switches = @{}; Navigate = $true }
            @{ Mode = 'NoSetLocation'; Switches = @{ NoSetLocation = $true }; Navigate = $false }
            @{ Mode = 'NoSetLocation false'; Switches = @{ NoSetLocation = $false }; Navigate = $true }
            @{ Mode = 'SetLocation compatibility'; Switches = @{ SetLocation = $true }; Navigate = $true }
            @{ Mode = 'SetLocation false compatibility'; Switches = @{ SetLocation = $false }; Navigate = $false }
        ) {
            & $CommandName @navigationParameters @Switches -ErrorAction Stop

            Test-Path -LiteralPath $navigationDestination -PathType Container | Should -BeTrue
            $resolvedDestination = (Resolve-Path -LiteralPath $navigationDestination).Path
            (Get-Worktrees -Path $navigationRepo).Path | Should -Contain $resolvedDestination
            $expectedLocation = if ($Navigate) { $resolvedDestination } else { $navigationCaller }
            (Get-Location).Path | Should -BeExactly $expectedLocation
        }

        It 'resolves a relative destination against the explicit source, not the caller' {
            $navigationParameters.WorktreePath = Join-Path '..' (Split-Path $navigationDestination -Leaf)

            & $CommandName @navigationParameters -ErrorAction Stop

            (Get-Location).Path | Should -BeExactly (Resolve-Path -LiteralPath $navigationDestination).Path
        }

        It 'leaves location and worktrees unchanged under WhatIf with <Mode>' -ForEach @(
            @{ Mode = 'default'; Switches = @{} }
            @{ Mode = 'SetLocation'; Switches = @{ SetLocation = $true } }
            @{ Mode = 'NoSetLocation'; Switches = @{ NoSetLocation = $true } }
        ) {
            $branchesBefore = @(Invoke-Git @('-C', $navigationRepo, 'branch', '--list'))

            & $CommandName @navigationParameters @Switches -WhatIf -ErrorAction Stop

            (Get-Location).Path | Should -BeExactly $navigationCaller
            Test-Path -LiteralPath $navigationDestination | Should -BeFalse
            @(Get-Worktrees -Path $navigationRepo) | Should -HaveCount 1
            @(Invoke-Git @('-C', $navigationRepo, 'branch', '--list')) | Should -Be $branchesBefore
        }

        It 'rejects both switches before creation (SetLocation=<Set>, NoSetLocation=<NoSet>)' -ForEach @(
            @{ Set = $true; NoSet = $true }
            @{ Set = $false; NoSet = $true }
            @{ Set = $true; NoSet = $false }
            @{ Set = $false; NoSet = $false }
        ) {
            $branchesBefore = @(Invoke-Git @('-C', $navigationRepo, 'branch', '--list'))

            { & $CommandName @navigationParameters -SetLocation:$Set -NoSetLocation:$NoSet -ErrorAction Stop } |
                Should -Throw -ErrorId 'AmbiguousParameterSet*'

            (Get-Location).Path | Should -BeExactly $navigationCaller
            Test-Path -LiteralPath $navigationDestination | Should -BeFalse
            @(Get-Worktrees -Path $navigationRepo) | Should -HaveCount 1
            @(Invoke-Git @('-C', $navigationRepo, 'branch', '--list')) | Should -Be $branchesBefore
        }

        It 'preserves caller location after a nonterminating git creation error' {
            New-Item -ItemType Directory -Path $navigationDestination -ErrorAction Stop | Out-Null
            Set-Content -LiteralPath (Join-Path $navigationDestination 'occupied.txt') -Value 'keep' -ErrorAction Stop

            & $CommandName @navigationParameters -ErrorAction SilentlyContinue -ErrorVariable creationErrors

            $creationErrors | Should -Not -BeNullOrEmpty
            $creationErrors[-1].Exception.Message | Should -Match 'git worktree add failed'
            (Get-Location).Path | Should -BeExactly $navigationCaller
            @(Get-Worktrees -Path $navigationRepo) | Should -HaveCount 1
            Get-Content -LiteralPath (Join-Path $navigationDestination 'occupied.txt') | Should -BeExactly 'keep'
        }

        It 'preserves caller location after a terminating git creation error' {
            New-Item -ItemType Directory -Path $navigationDestination -ErrorAction Stop | Out-Null
            Set-Content -LiteralPath (Join-Path $navigationDestination 'occupied.txt') -Value 'keep' -ErrorAction Stop

            { & $CommandName @navigationParameters -ErrorAction Stop } |
                Should -Throw -ExpectedMessage '*git worktree add failed*'

            (Get-Location).Path | Should -BeExactly $navigationCaller
            @(Get-Worktrees -Path $navigationRepo) | Should -HaveCount 1
        }

        It 'does not fall back to the current repository when source resolution fails' {
            Set-Location -LiteralPath $navigationRepo -ErrorAction Stop
            $navigationParameters.Path = Join-Path $navigationRoot 'missing-source'

            & $CommandName @navigationParameters -ErrorAction SilentlyContinue -ErrorVariable sourceErrors

            $sourceErrors | Should -Not -BeNullOrEmpty
            (Get-Location).Path | Should -BeExactly (Resolve-Path -LiteralPath $navigationRepo).Path
            Test-Path -LiteralPath $navigationDestination | Should -BeFalse
            @(Get-Worktrees -Path $navigationRepo) | Should -HaveCount 1
        }

        It 'surfaces navigation failure without moving the caller or removing the created worktree' {
            Mock -ModuleName Shmuelie.Git Set-Location { throw 'Navigation unavailable.' }

            { & $CommandName @navigationParameters -ErrorAction Stop } |
                Should -Throw -ExpectedMessage '*Navigation unavailable*'

            (Get-Location).Path | Should -BeExactly $navigationCaller
            Test-Path -LiteralPath $navigationDestination -PathType Container | Should -BeTrue
            @(Get-Worktrees -Path $navigationRepo) | Should -HaveCount 2
            Should -Invoke -ModuleName Shmuelie.Git Set-Location -Times 1 -Exactly -ParameterFilter {
                $LiteralPath -like '*created [[]literal] tree'
            }
        }
    }
}


Describe 'Git repository -Path parameters' {
    BeforeEach {
        $script:pathCallerRepo = New-TestRepo -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $script:pathTargetRepo = New-TestRepo -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
    }

    It 'preserves default current-directory behavior for read-only helpers' {
        Push-Location $script:pathCallerRepo
        try {
            (Get-Worktrees | Select-Object -First 1).Path | Should -BeExactly $script:pathCallerRepo
            (Get-CurrentWorktree).Path | Should -BeExactly $script:pathCallerRepo
            (Get-RootWorktree).Path | Should -BeExactly $script:pathCallerRepo
            (Get-GitStatusSummary).WorktreePath | Should -BeExactly $script:pathCallerRepo
            Get-WorktreePath -BranchName sibling | Should -BeExactly (Join-Path (Split-Path $script:pathCallerRepo -Parent) 'sibling')
        } finally {
            Pop-Location
        }
    }

    It 'targets an explicit repository path without changing the caller location' {
        $targetChild = Join-Path $script:pathTargetRepo 'src'
        New-Item -ItemType Directory -Path $targetChild -Force | Out-Null
        Invoke-Git @('-C', $script:pathTargetRepo, 'branch', 'user/test/local-only')
        $callerLocation = $null

        Push-Location $script:pathCallerRepo
        try {
            $callerLocation = (Get-Location).Path
            (Get-Worktrees -Path $script:pathTargetRepo | Select-Object -First 1).Path | Should -BeExactly $script:pathTargetRepo
            (Get-CurrentWorktree -Path $targetChild).Path | Should -BeExactly $script:pathTargetRepo
            (Get-RootWorktree -Path $targetChild).Path | Should -BeExactly $script:pathTargetRepo
            (Get-GitStatusSummary -Path $targetChild).WorktreePath | Should -BeExactly $script:pathTargetRepo
            (Find-StaleBranch -Path $script:pathTargetRepo -User test -IncludeNeverPushed).Branch | Should -Be 'user/test/local-only'
            Get-WorktreePath -BranchName sibling -Path $script:pathTargetRepo | Should -BeExactly (Join-Path (Split-Path $script:pathTargetRepo -Parent) 'sibling')
            (Get-Location).Path | Should -BeExactly $callerLocation
        } finally {
            Pop-Location
        }
    }

    It 'accepts repository paths from pipeline input' {
        $status = [PSCustomObject]@{ Path = $script:pathTargetRepo } | Get-GitStatusSummary
        $worktree = [PSCustomObject]@{ Path = $script:pathTargetRepo } | Get-Worktrees | Select-Object -First 1

        $status.WorktreePath | Should -BeExactly $script:pathTargetRepo
        $worktree.Path | Should -BeExactly $script:pathTargetRepo
    }

    It 'reports a clear error for a non-git path' {
        $notRepo = Join-Path $TestDrive 'not-a-git-worktree'
        New-Item -ItemType Directory -Path $notRepo -Force | Out-Null

        Get-Worktrees -Path $notRepo -ErrorAction SilentlyContinue -ErrorVariable errors | Should -BeNullOrEmpty

        $errors | Should -HaveCount 1
        $errors[0].Exception.Message | Should -Match 'not inside a git working tree'
    }

    It 'uses explicit source -Path with destination -WorktreePath and NoSetLocation to preserve caller location' {
        Invoke-Git @('-C', $script:pathTargetRepo, 'branch', 'existing-work')
        $existingPath = Join-Path $TestDrive 'explicit-existing-worktree'
        $newPath = Join-Path $TestDrive 'explicit-new-worktree'
        $callerLocation = $null

        Push-Location -LiteralPath $script:pathCallerRepo -ErrorAction Stop
        try {
            $callerLocation = (Get-Location).Path
            Add-Worktree -Path $script:pathTargetRepo -BranchName existing-work -WorktreePath $existingPath -NoSetLocation
            Test-Path -LiteralPath $existingPath -PathType Container | Should -BeTrue
            (Get-Worktrees -Path $script:pathTargetRepo).Path | Should -Contain (Resolve-Path -LiteralPath $existingPath).Path

            New-Worktree -Path $script:pathTargetRepo -WorkName explicit-new -NoPrefix -WorktreePath $newPath -NoSetLocation
            Test-Path -LiteralPath $newPath -PathType Container | Should -BeTrue
            (Get-Worktrees -Path $script:pathTargetRepo).Path | Should -Contain (Resolve-Path -LiteralPath $newPath).Path

            (Get-Location).Path | Should -BeExactly $callerLocation
        } finally {
            Pop-Location
        }
    }

    It 'passes explicit -Path through Sync-GitRemote and Update-Worktrees without changing caller location' {
        Invoke-Git @('-C', $script:pathTargetRepo, 'remote', 'add', 'origin', 'https://github.com/contoso/repo.git')
        Mock -ModuleName Shmuelie.Git Get-GitHubSignedInAccount { @() }
        Mock -ModuleName Shmuelie.Git Invoke-GitWithEnvironment {
            $Arguments[0] | Should -Be '-C'
            $Arguments[1] | Should -BeExactly $script:pathTargetRepo
            [PSCustomObject]@{
                PSTypeName = 'GitInvocationResult'
                ExitCode   = 0
                Output     = @(' * [new branch]      main       -> origin/main')
            }
        }

        $callerLocation = $null
        Push-Location $script:pathCallerRepo
        try {
            $callerLocation = (Get-Location).Path
            (Sync-GitRemote -Path $script:pathTargetRepo -Remote origin -NoGitHubAccountResolve).Ref | Should -Be 'origin/main'
            (Update-Worktrees -Path $script:pathTargetRepo -NoGitHubAccountResolve | Where-Object Branch -eq main).Status | Should -Be 'NoUpstream'
            (Get-Location).Path | Should -BeExactly $callerLocation
        } finally {
            Pop-Location
        }
    }
}

Describe 'Get-GitStatusSummary' {
    It 'does not pop the caller location stack when -Path cannot be pushed' {
        $startingPath = (Get-Location).Path
        $callerPath = Join-Path $TestDrive 'caller-location'
        New-Item -ItemType Directory -Path $callerPath -Force | Out-Null

        Push-Location $callerPath
        try {
            $expectedPath = (Get-Location).Path
            try {
                Get-GitStatusSummary -Path (Join-Path $TestDrive 'does-not-exist') | Out-Null
            } catch {
                # Bad paths fail fast; this test only verifies the caller location is preserved.
            }

            (Get-Location).Path | Should -BeExactly $expectedPath
        } finally {
            if ((Get-Location).Path -ne $startingPath) {
                Pop-Location
            }
        }
    }

    Context 'outside a git repository' {
        It 'reports the directory is not a git repo' {
            $dir = Join-Path $TestDrive 'not-a-repo'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $summary = Get-GitStatusSummary -Path $dir
            $summary.IsGitRepo | Should -BeFalse
            $summary.StatusString | Should -BeNullOrEmpty
            $summary.HasChanges | Should -BeFalse
        }
    }

    Context 'clean repository' {
        BeforeAll {
            $script:cleanRepo = New-TestRepo -Path (Join-Path $TestDrive 'clean')
        }

        It 'is recognized as a git repo' {
            (Get-GitStatusSummary -Path $script:cleanRepo).IsGitRepo | Should -BeTrue
        }

        It 'reports no changes' {
            (Get-GitStatusSummary -Path $script:cleanRepo).HasChanges | Should -BeFalse
        }

        It 'captures the branch name' {
            (Get-GitStatusSummary -Path $script:cleanRepo).Branch | Should -Be 'main'
        }

        It 'renders a status string beginning with the branch' {
            (Get-GitStatusSummary -Path $script:cleanRepo).StatusString | Should -Match '^\[main'
        }
    }

    Context 'empty repository (unborn branch)' {
        BeforeAll {
            # A freshly initialized repo with no commits yet. git status emits
            # '## No commits yet on <branch>' instead of the usual branch header.
            $script:emptyRepo = Join-Path $TestDrive 'empty-unborn'
            New-Item -ItemType Directory -Path $script:emptyRepo -Force | Out-Null
            Invoke-Git @('-C', $script:emptyRepo, '-c', 'init.templateDir=', 'init', '-b', 'main', '--quiet')
            Set-TestRepoConfig $script:emptyRepo
        }

        It 'parses the unborn branch name rather than the whole status phrase' {
            (Get-GitStatusSummary -Path $script:emptyRepo).Branch | Should -Be 'main'
        }

        It 'renders a status string beginning with the branch' {
            (Get-GitStatusSummary -Path $script:emptyRepo).StatusString | Should -Match '^\[main'
        }
    }

    Context 'repository paths' {
        BeforeAll {
            $script:pathRepo = New-TestRepo -Path (Join-Path $TestDrive 'paths')
            $script:expectedTop = ConvertTo-NativeTestPath (Invoke-Git @('-C', $script:pathRepo, 'rev-parse', '--show-toplevel'))
            $script:nestedPath = Join-Path $script:expectedTop (Join-Path 'src' 'nested')
            New-Item -ItemType Directory -Path $script:nestedPath -Force | Out-Null
        }

        It 'returns the worktree path using native separators' {
            (Get-GitStatusSummary -Path $script:pathRepo).WorktreePath | Should -BeExactly $script:expectedTop
        }

        It 'returns the relative path using native separators' {
            $summary = Get-GitStatusSummary -Path $script:nestedPath
            $expected = [System.IO.Path]::DirectorySeparatorChar + (Join-Path 'src' 'nested')
            $summary.RelativePath | Should -BeExactly $expected
        }
    }

    Context 'in-progress operations' {
        $operationCases = @(
            @{
                Name     = 'merge'
                Setup    = { param($d, $r) Set-Content -Path (Join-Path $d 'MERGE_HEAD') -Value (Invoke-Git @('-C', $r, 'rev-parse', 'HEAD')) -NoNewline }
                Expected = 'MERGING'
            }
            @{
                Name     = 'revert'
                Setup    = { param($d, $r) Set-Content -Path (Join-Path $d 'REVERT_HEAD') -Value (Invoke-Git @('-C', $r, 'rev-parse', 'HEAD')) -NoNewline }
                Expected = 'REVERTING'
            }
            @{
                Name     = 'cherry-pick'
                Setup    = { param($d, $r) Set-Content -Path (Join-Path $d 'CHERRY_PICK_HEAD') -Value (Invoke-Git @('-C', $r, 'rev-parse', 'HEAD')) -NoNewline }
                Expected = 'CHERRY-PICKING'
            }
            @{
                Name     = 'bisect'
                Setup    = { param($d) Set-Content -Path (Join-Path $d 'BISECT_LOG') -Value 'git bisect start' -NoNewline }
                Expected = 'BISECTING'
            }
            @{
                Name     = 'merge rebase'
                Setup    = {
                    param($d)
                    $rebase = Join-Path $d 'rebase-merge'
                    New-Item -ItemType Directory -Path $rebase -Force | Out-Null
                    Set-Content -Path (Join-Path $rebase 'msgnum') -Value '2' -NoNewline
                    Set-Content -Path (Join-Path $rebase 'end') -Value '5' -NoNewline
                }
                Expected = 'REBASE-m 2/5'
            }
            @{
                Name     = 'apply rebase'
                Setup    = {
                    param($d)
                    $rebase = Join-Path $d 'rebase-apply'
                    New-Item -ItemType Directory -Path $rebase -Force | Out-Null
                    Set-Content -Path (Join-Path $rebase 'next') -Value '2' -NoNewline
                    Set-Content -Path (Join-Path $rebase 'last') -Value '5' -NoNewline
                    New-Item -ItemType File -Path (Join-Path $rebase 'rebasing') -Force | Out-Null
                }
                Expected = 'REBASE 2/5'
            }
        )

        It 'detects a <Name> operation from git directory sentinels' -ForEach $operationCases {
            $repo = New-TestRepo -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
            $gitDir = Get-TestGitDir -Path $repo
            & $Setup $gitDir $repo
            (Get-GitStatusSummary -Path $repo).Operation | Should -Be $Expected
        }
    }

    Context 'with local changes' {
        $changeCases = @(
            @{
                Name     = 'staged addition'
                Setup    = { param($r) Set-Content (Join-Path $r 'added.txt') 'x'; Invoke-Git @('-C', $r, 'add', 'added.txt') }
                Property = 'IndexAdded'
                Expected = 1
                Token    = '\+1'
            }
            @{
                Name     = 'staged deletion'
                Setup    = { param($r) Invoke-Git @('-C', $r, 'rm', 'README.md', '--quiet') }
                Property = 'IndexDeleted'
                Expected = 1
                Token    = '-1'
            }
            @{
                Name     = 'working-tree modification'
                Setup    = { param($r) Set-Content (Join-Path $r 'README.md') 'changed' }
                Property = 'WorkingModified'
                Expected = 1
                Token    = '~1'
            }
            @{
                Name     = 'untracked file'
                Setup    = { param($r) Set-Content (Join-Path $r 'untracked.txt') 'x' }
                Property = 'Untracked'
                Expected = 1
                Token    = '\?'
            }
        )

        It 'counts a <Name> and reflects it in the status string' -ForEach $changeCases {
            $repo = New-TestRepo -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
            & $Setup $repo
            $summary = Get-GitStatusSummary -Path $repo
            $summary.$Property | Should -Be $Expected
            $summary.HasChanges | Should -BeTrue
            $summary.StatusString | Should -Match $Token
        }
    }

    Context 'tracking an upstream branch' {
        BeforeAll {
            $origin = New-TestRepo -Path (Join-Path $TestDrive 'origin')
            $clone = Join-Path $TestDrive 'clone'
            Invoke-Git @('clone', '--quiet', $origin, $clone)
            Set-TestRepoConfig $clone
            Set-Content (Join-Path $clone 'feature.txt') 'x'
            Invoke-Git @('-C', $clone, 'add', 'feature.txt')
            Invoke-Git @('-C', $clone, 'commit', '-m', 'ahead', '--quiet')
            $script:aheadClone = $clone
        }

        It 'reports the ahead count' {
            (Get-GitStatusSummary -Path $script:aheadClone).AheadBy | Should -Be 1
        }

        It 'shows the ahead indicator in the status string' {
            (Get-GitStatusSummary -Path $script:aheadClone).StatusString | Should -Match ([char]0x2191 + '1')
        }
    }
}

Describe 'Get-GitStatusSummary porcelain counts' -Tag 'TrackedTypeChange' {
    BeforeEach {
        $statusFixture = (New-Item -ItemType Directory -Path (
            Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        ) -ErrorAction Stop).FullName
        $previousStatusExitVariable = Get-Variable LASTEXITCODE -Scope Global -ErrorAction Ignore
        $previousStatusExitCode = if ($previousStatusExitVariable) { $previousStatusExitVariable.Value }
        Mock -ModuleName Shmuelie.Git git {
            if ($args.Count -lt 3 -or $args[0] -cne '-C' -or $args[1] -cne $statusFixture) {
                throw "Unexpected repository context in status fixture: $args"
            }
            $global:LASTEXITCODE = 0
            switch ($args[2..($args.Count - 1)] -join ' ') {
                'rev-parse --is-inside-work-tree' { 'true' }
                'status --porcelain=v1 --branch' { '## main'; $Lines }
                'rev-parse --show-toplevel' { $statusFixture }
                'rev-parse --path-format=absolute --git-dir' { Join-Path $statusFixture '.git' }
                'remote get-url origin' { $global:LASTEXITCODE = 2 }
                'rev-list --walk-reflogs --count refs/stash' { $global:LASTEXITCODE = 128 }
                default { throw "Unexpected Git status fixture call: $args" }
            }
        }
    }

    AfterEach {
        if ($previousStatusExitVariable) {
            $global:LASTEXITCODE = $previousStatusExitCode
        } else {
            Remove-Variable LASTEXITCODE -Scope Global -ErrorAction Ignore
        }
    }

    $countCases = @(
        @{ Name = 'staged type change'; Lines = @('T  file'); Expected = @{ IndexModified = 1 }; Text = '[main +0 ~1 -0 |]' }
        @{ Name = 'working type change'; Lines = @(' T file'); Expected = @{ WorkingModified = 1 }; Text = '[main | +0 ~1 -0]' }
        @{ Name = 'combined type changes'; Lines = @('TT file'); Expected = @{ IndexModified = 1; WorkingModified = 1 }; Text = '[main +0 ~1 -0 | +0 ~1 -0]' }
        @{ Name = 'staged type and working modification'; Lines = @('TM file'); Expected = @{ IndexModified = 1; WorkingModified = 1 }; Text = '[main +0 ~1 -0 | +0 ~1 -0]' }
        @{ Name = 'staged modification and working type'; Lines = @('MT file'); Expected = @{ IndexModified = 1; WorkingModified = 1 }; Text = '[main +0 ~1 -0 | +0 ~1 -0]' }
        @{ Name = 'staged addition'; Lines = @('A  file'); Expected = @{ IndexAdded = 1 }; Text = '[main +1 ~0 -0 |]' }
        @{ Name = 'staged modification'; Lines = @('M  file'); Expected = @{ IndexModified = 1 }; Text = '[main +0 ~1 -0 |]' }
        @{ Name = 'staged deletion'; Lines = @('D  file'); Expected = @{ IndexDeleted = 1 }; Text = '[main +0 ~0 -1 |]' }
        @{ Name = 'staged rename'; Lines = @('R  old -> new'); Expected = @{ IndexModified = 1 }; Text = '[main +0 ~1 -0 |]' }
        @{ Name = 'staged copy'; Lines = @('C  old -> new'); Expected = @{ IndexAdded = 1 }; Text = '[main +1 ~0 -0 |]' }
        @{ Name = 'working addition'; Lines = @(' A file'); Expected = @{ WorkingAdded = 1 }; Text = '[main | +1 ~0 -0]' }
        @{ Name = 'working modification'; Lines = @(' M file'); Expected = @{ WorkingModified = 1 }; Text = '[main | +0 ~1 -0]' }
        @{ Name = 'working deletion'; Lines = @(' D file'); Expected = @{ WorkingDeleted = 1 }; Text = '[main | +0 ~0 -1]' }
        @{ Name = 'multiple independent type changes'; Lines = @('T  first', ' T second', 'TT third'); Expected = @{ IndexModified = 2; WorkingModified = 2 }; Text = '[main +0 ~2 -0 | +0 ~2 -0]' }
        @{
            Name = 'type changes mixed with additions, deletions, renames, copies and conflicts'
            Lines = @('TT type', 'A  added', 'D  deleted', 'R  old -> renamed', 'C  old -> copied', ' M modified', ' D missing', 'UU conflict')
            Expected = @{ IndexAdded = 2; IndexModified = 2; IndexDeleted = 1; WorkingModified = 2; WorkingDeleted = 1; Conflicts = 1 }
            Text = '[main +2 ~2 -1 | +0 ~2 -1 !1]'
        }
    ) + @(
        foreach ($pair in 'UU', 'AA', 'DD', 'AU', 'UA', 'DU', 'UD') {
            @{ Name = "conflict $pair"; Lines = @("$pair file"); Expected = @{ Conflicts = 1 }; Text = '[main !1]' }
        }
    )

    It 'counts and displays <Name> without changing other counters' -ForEach $countCases {
        $summary = Get-GitStatusSummary -Path $statusFixture

        foreach ($property in @(
            'IndexAdded', 'IndexModified', 'IndexDeleted',
            'WorkingAdded', 'WorkingModified', 'WorkingDeleted', 'Conflicts', 'Untracked'
        )) {
            $count = if ($Expected.ContainsKey($property)) { $Expected[$property] } else { 0 }
            $summary.$property | Should -Be $count
        }
        $summary.PSTypeNames[0] | Should -BeExactly 'GitStatusSummary'
        $summary.HasChanges | Should -BeTrue
        $summary.StatusString | Should -BeExactly $Text
        $plain = (Format-GitStatusSegment -Status $summary) -replace "$([char]0x1b)\[[0-9;]*m", ''
        $plain | Should -BeExactly $Text
    }
}

Describe 'Get-GitStatusSummary native type changes' -Tag 'TrackedTypeChange' {
    BeforeAll {
        $nativeTypeRoot = (New-Item -ItemType Directory -Path (
            Join-Path $TestDrive "type-changes-$([guid]::NewGuid().ToString('N'))"
        ) -ErrorAction Stop).FullName
        $nativeTypeEnvironment = @{}
        foreach ($key in @(
            'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_SYSTEM', 'GIT_CONFIG_NOSYSTEM',
            'GIT_CONFIG_COUNT', 'GIT_CONFIG_PARAMETERS', 'GIT_DIR', 'GIT_WORK_TREE',
            'GIT_COMMON_DIR', 'GIT_INDEX_FILE', 'GIT_OBJECT_DIRECTORY',
            'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_CEILING_DIRECTORIES',
            'GIT_AUTHOR_DATE', 'GIT_COMMITTER_DATE', 'GIT_TERMINAL_PROMPT'
        )) {
            $nativeTypeEnvironment[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
            Remove-Item "Env:$key" -ErrorAction Ignore
        }
        $env:GIT_CONFIG_GLOBAL = Join-Path $nativeTypeRoot 'no-global-config'
        $env:GIT_CONFIG_SYSTEM = Join-Path $nativeTypeRoot 'no-system-config'
        $env:GIT_CONFIG_NOSYSTEM = '1'
        $env:GIT_CONFIG_COUNT = '0'
        $env:GIT_CEILING_DIRECTORIES = $TestDrive
        $env:GIT_TERMINAL_PROMPT = '0'

        function Assert-TypeFixturePath {
            param([string]$Path)
            if (-not [IO.Path]::GetFullPath($Path).StartsWith(
                $nativeTypeRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::Ordinal)) {
                throw "Refusing native Git outside the owned type-change fixture: '$Path'."
            }
        }

        function Invoke-TypeFixtureGit {
            param([string[]]$Arguments)
            Assert-TypeFixturePath $nativeTypeRepo
            if ($Arguments[0] -notin @('config', 'rev-parse', 'update-index', 'commit', 'status')) {
                throw "Unexpected native type-change fixture operation: $Arguments"
            }
            Invoke-Git (@('-C', $nativeTypeRepo) + $Arguments)
        }
    }

    BeforeEach {
        $nativeTypeRepo = Join-Path $nativeTypeRoot ([guid]::NewGuid().ToString('N'))
        Assert-TypeFixturePath $nativeTypeRepo
        $null = New-TestRepo -Path $nativeTypeRepo
        $nativeTypeLocationPushed = $false
        Push-Location -LiteralPath $nativeTypeRepo -ErrorAction Stop
        $nativeTypeLocationPushed = $true
        Assert-TypeFixturePath (Get-Location).ProviderPath
    }

    AfterEach {
        if ($nativeTypeLocationPushed) { Pop-Location }
    }

    AfterAll {
        foreach ($key in $nativeTypeEnvironment.Keys) {
            if ($null -eq $nativeTypeEnvironment[$key]) {
                Remove-Item -LiteralPath "Env:$key" -ErrorAction Ignore
            } else {
                [Environment]::SetEnvironmentVariable($key, $nativeTypeEnvironment[$key], 'Process')
            }
        }
        if ($nativeTypeRoot -and (Test-Path -LiteralPath $nativeTypeRoot)) {
            if ((Split-Path $nativeTypeRoot -Parent) -cne $TestDrive) {
                throw 'Refusing cleanup outside the owned type-change TestDrive.'
            }
            Remove-Item -LiteralPath $nativeTypeRoot -Recurse -Force -ErrorAction Stop
        }
    }

    It 'reports native <Mode> type changes without creating a filesystem symlink' -ForEach @(
        @{ Mode = 'staged'; Pair = 'T '; Index = 1; Working = 0; Text = '[main +0 ~1 -0 |]' }
        @{ Mode = 'unstaged'; Pair = ' T'; Index = 0; Working = 1; Text = '[main | +0 ~1 -0]' }
        @{ Mode = 'combined'; Pair = 'TT'; Index = 1; Working = 1; Text = '[main +0 ~1 -0 | +0 ~1 -0]' }
    ) {
        $blob = Invoke-TypeFixtureGit @('rev-parse', 'HEAD:README.md')
        $null = Invoke-TypeFixtureGit @('config', 'core.symlinks', 'false')
        $null = Invoke-TypeFixtureGit @('update-index', '--cacheinfo', "120000,$blob,README.md")
        if ($Mode -eq 'unstaged') {
            $null = Invoke-TypeFixtureGit @('commit', '-m', 'record symlink mode', '--quiet')
        }
        if ($Mode -ne 'staged') {
            # Interpret the existing ordinary file against the symlink index mode;
            # no checkout or filesystem symlink creation is needed.
            $null = Invoke-TypeFixtureGit @('config', 'core.symlinks', 'true')
        }
        @(Invoke-TypeFixtureGit @('status', '--porcelain=v1')) | Should -Be @("$Pair README.md")

        $summary = Get-GitStatusSummary -Path $nativeTypeRepo

        $summary.IndexModified | Should -Be $Index
        $summary.WorkingModified | Should -Be $Working
        $summary.HasChanges | Should -BeTrue
        $summary.StatusString | Should -BeExactly $Text
        $plain = (Format-GitStatusSegment -Status $summary) -replace "$([char]0x1b)\[[0-9;]*m", ''
        $plain | Should -BeExactly $Text
        $compact = (Format-GitStatusSegment -Status $summary -ShowChangeCounts:$false) -replace "$([char]0x1b)\[[0-9;]*m", ''
        $compact | Should -BeExactly '[main]'
        (Get-Item -LiteralPath (Join-Path $nativeTypeRepo 'README.md')).LinkType | Should -BeNullOrEmpty
    }
}

Describe 'Repair-RepositoryLayout' {
    It 'converts git branch separators to native path separators' {
        InModuleScope Shmuelie.Git {
            ConvertTo-RepositoryLayoutPathFragment 'feature/nested' |
                Should -BeExactly ([System.IO.Path]::Combine('feature', 'nested'))
        }
    }

    It 'plans repo-level branch moves with native path separators' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $org = Join-Path $root 'example'
        $repo = Join-Path $org 'repo'
        New-TestRepo -Path $repo | Out-Null
        Invoke-Git @('-C', $repo, 'checkout', '--quiet', '-b', 'feature/nested')

        $result = @(Repair-RepositoryLayout -Root $root -Organization 'example' -Name 'repo' -WhatIf -Confirm:$false)

        $result | Should -HaveCount 1
        $result.Status | Should -Be 'WhatIf'
        $result.To | Should -BeExactly ([System.IO.Path]::Combine($repo, 'feature', 'nested'))
    }

    It 'skips repo-level clones when the current directory is inside them' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $org = Join-Path $root 'example'
        $repo = Join-Path $org 'repo'
        $child = Join-Path $repo 'child'
        New-TestRepo -Path $repo | Out-Null
        New-Item -ItemType Directory -Path $child -Force | Out-Null

        Push-Location $child
        try {
            $result = @(Repair-RepositoryLayout -Root $root -Organization 'example' -Name 'repo' -WhatIf -Confirm:$false)
        } finally {
            Pop-Location
        }

        $result | Should -HaveCount 1
        $result.Status | Should -Be 'Skipped-CwdInside'
    }
}

Describe 'Repair-RepositoryLayout standalone targets' {
    BeforeAll {
        $layoutRoot = (New-Item -ItemType Directory -Path (
            Join-Path $TestDrive "layout-$([guid]::NewGuid().ToString('N'))"
        ) -ErrorAction Stop).FullName
        $layoutEnvironment = @{}
        foreach ($item in @(Get-ChildItem Env: | Where-Object Name -Like 'GIT_*')) {
            $layoutEnvironment[$item.Name] = $item.Value
            Remove-Item -LiteralPath "Env:$($item.Name)" -ErrorAction Stop
        }
        $env:GIT_CONFIG_GLOBAL = Join-Path $layoutRoot 'no-global'
        $env:GIT_CONFIG_SYSTEM = Join-Path $layoutRoot 'no-system'
        $env:GIT_CONFIG_NOSYSTEM = '1'
        $env:GIT_CONFIG_COUNT = '0'
        $env:GIT_CEILING_DIRECTORIES = $TestDrive
        $env:GIT_TERMINAL_PROMPT = '0'
        $env:GIT_ALLOW_PROTOCOL = 'file'

        function Assert-LayoutFixturePath {
            param([string]$Path)
            if (-not [IO.Path]::GetFullPath($Path).StartsWith(
                $layoutRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::Ordinal)) {
                throw "Refusing layout fixture access outside '$layoutRoot': '$Path'."
            }
        }

        function Get-LayoutSnapshot {
            param([string]$Path)
            Assert-LayoutFixturePath $Path
            if (-not (Test-Path -LiteralPath $Path)) { return 'absent' }
            $rootItem = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
            $items = @($rootItem)
            if ($rootItem.PSIsContainer) {
                $items += @(Get-ChildItem -LiteralPath $Path -Force -Recurse -ErrorAction Stop)
            }
            @($items | Sort-Object FullName | ForEach-Object {
                [pscustomobject]@{
                    Path = [IO.Path]::GetRelativePath($Path, $_.FullName)
                    Kind = if ($_.PSIsContainer) { 'directory' } else { 'file' }
                    SHA256 = if (-not $_.PSIsContainer) { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
                }
            }) | ConvertTo-Json -Depth 4 -Compress
        }

        function New-LayoutFixture {
            param([string]$Branch = 'main')
            $root = Join-Path $layoutCase 'repos'
            $source = Join-Path $root 'example' 'project' 'old-name'
            Assert-LayoutFixturePath $source
            $null = New-TestRepo -Path $source
            if ($Branch -ne 'main') { $null = Invoke-Git @('-C', $source, 'branch', '-m', $Branch) }
            $target = Join-Path $root 'example' 'project' ([IO.Path]::Combine([string[]]($Branch -split '/')))
            Assert-LayoutFixturePath $target
            [pscustomobject]@{ Root = $root; Source = $source; Target = $target }
        }

        function Invoke-LayoutFixtureRepair {
            param($Fixture, [switch]$WhatIf)
            Assert-LayoutFixturePath $Fixture.Root
            Assert-LayoutFixturePath (Get-Location).ProviderPath
            Repair-RepositoryLayout -Root $Fixture.Root -Organization example -Name project -Confirm:$false -WhatIf:$WhatIf
        }

        function Write-LayoutEvidence {
            param($Fixture, $BeforeSource, $BeforeTarget, $BeforeLocation, $Results)
            Write-Information -Tags 'RepositoryLayoutEvidence' -MessageData ([pscustomobject]@{
                Source = $Fixture.Source
                Target = $Fixture.Target
                SourceBefore = $BeforeSource
                SourceAfter = Get-LayoutSnapshot $Fixture.Source
                TargetBefore = $BeforeTarget
                TargetAfter = Get-LayoutSnapshot $Fixture.Target
                LocationBefore = $BeforeLocation
                LocationAfter = (Get-Location).ProviderPath
                Results = $Results
            })
        }
    }

    BeforeEach {
        $layoutCase = (New-Item -ItemType Directory -Path (
            Join-Path $layoutRoot ([guid]::NewGuid().ToString('N'))
        ) -ErrorAction Stop).FullName
        $layoutPushed = $false
        Push-Location -LiteralPath $layoutCase -ErrorAction Stop
        $layoutPushed = $true
        Assert-LayoutFixturePath (Get-Location).ProviderPath
    }

    AfterEach {
        if ($layoutPushed) { Pop-Location -ErrorAction Stop }
    }

    AfterAll {
        foreach ($item in @(Get-ChildItem Env: | Where-Object Name -Like 'GIT_*')) {
            Remove-Item -LiteralPath "Env:$($item.Name)" -ErrorAction Stop
        }
        foreach ($key in $layoutEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($key, $layoutEnvironment[$key], 'Process')
        }
        if ($layoutRoot -and (Test-Path -LiteralPath $layoutRoot)) {
            if ((Split-Path $layoutRoot -Parent) -cne $TestDrive) { throw 'Layout cleanup escaped TestDrive.' }
            Remove-Item -LiteralPath $layoutRoot -Recurse -Force -ErrorAction Stop
        }
    }

    It 'leaves both paths unchanged for an occupied <Kind> target with WhatIf=<Preview>' -ForEach @(
        foreach ($kind in 'empty directory', 'nonempty directory', 'file', 'repository') {
            foreach ($preview in $false, $true) { @{ Kind = $kind; Preview = $preview } }
        }
    ) {
        $fixture = New-LayoutFixture
        switch ($Kind) {
            'empty directory' { $null = New-Item -ItemType Directory -Path $fixture.Target -ErrorAction Stop }
            'nonempty directory' {
                $null = New-Item -ItemType Directory -Path $fixture.Target -ErrorAction Stop
                Set-Content -LiteralPath (Join-Path $fixture.Target 'keep.txt') -Value 'unrelated data'
            }
            'file' { Set-Content -LiteralPath $fixture.Target -Value 'unrelated file' }
            'repository' { $null = New-TestRepo -Path $fixture.Target }
        }
        $sourceBefore = Get-LayoutSnapshot $fixture.Source
        $targetBefore = Get-LayoutSnapshot $fixture.Target
        $locationBefore = (Get-Location).ProviderPath

        $results = @(Invoke-LayoutFixtureRepair $fixture -WhatIf:$Preview)

        Write-LayoutEvidence $fixture $sourceBefore $targetBefore $locationBefore $results
        $results | Should -HaveCount 1
        $results[0].PSTypeNames[0] | Should -BeExactly 'RepositoryLayoutResult'
        $results[0].Status | Should -BeExactly 'Skipped-TargetExists'
        $results[0].Action | Should -BeExactly 'none'
        $results[0].From | Should -BeExactly $fixture.Source
        $results[0].To | Should -BeExactly $fixture.Target
        Get-LayoutSnapshot $fixture.Source | Should -BeExactly $sourceBefore
        Get-LayoutSnapshot $fixture.Target | Should -BeExactly $targetBefore
        (Get-Location).ProviderPath | Should -BeExactly $locationBefore
    }

    It 'moves a standalone <Branch> clone to exactly the reported root' -ForEach @(
        @{ Branch = 'main' }
        @{ Branch = 'feature/nested' }
    ) {
        $fixture = New-LayoutFixture -Branch $Branch
        $sourceBefore = Get-LayoutSnapshot $fixture.Source
        $locationBefore = (Get-Location).ProviderPath

        $results = @(Invoke-LayoutFixtureRepair $fixture)

        Write-LayoutEvidence $fixture $sourceBefore 'absent' $locationBefore $results
        $results | Should -HaveCount 1
        $results[0].Status | Should -BeExactly 'Converted'
        $results[0].Action | Should -BeExactly 'renamed'
        $results[0].To | Should -BeExactly $fixture.Target
        Test-Path -LiteralPath $fixture.Source | Should -BeFalse
        Get-LayoutSnapshot $fixture.Target | Should -BeExactly $sourceBefore
        $top = Invoke-Git @('-C', $results[0].To, 'rev-parse', '--show-toplevel')
        ConvertTo-NativeTestPath $top | Should -BeExactly $results[0].To
        (Get-Location).ProviderPath | Should -BeExactly $locationBefore
    }

    It 'previews a standalone nested move without creating destination parents' {
        $fixture = New-LayoutFixture -Branch feature/nested
        $sourceBefore = Get-LayoutSnapshot $fixture.Source
        $locationBefore = (Get-Location).ProviderPath

        $results = @(Invoke-LayoutFixtureRepair $fixture -WhatIf)

        Write-LayoutEvidence $fixture $sourceBefore 'absent' $locationBefore $results
        $results | Should -HaveCount 1
        $results[0].Status | Should -BeExactly 'WhatIf'
        $results[0].Action | Should -BeExactly 'would-rename'
        $results[0].To | Should -BeExactly $fixture.Target
        Get-LayoutSnapshot $fixture.Source | Should -BeExactly $sourceBefore
        Test-Path -LiteralPath (Split-Path $fixture.Target -Parent) | Should -BeFalse
        (Get-Location).ProviderPath | Should -BeExactly $locationBefore
    }

    It 'preserves the standalone current-directory guard' {
        $fixture = New-LayoutFixture
        $child = Join-Path $fixture.Source 'child'
        $null = New-Item -ItemType Directory -Path $child -ErrorAction Stop
        Set-Location -LiteralPath $child -ErrorAction Stop
        Assert-LayoutFixturePath (Get-Location).ProviderPath
        $sourceBefore = Get-LayoutSnapshot $fixture.Source

        $results = @(Invoke-LayoutFixtureRepair $fixture)

        Write-LayoutEvidence $fixture $sourceBefore 'absent' $child $results
        $results[0].Status | Should -BeExactly 'Skipped-CwdInside'
        Get-LayoutSnapshot $fixture.Source | Should -BeExactly $sourceBefore
        Test-Path -LiteralPath $fixture.Target | Should -BeFalse
        (Get-Location).ProviderPath | Should -BeExactly $child
    }

    It 'preserves the standalone dependent-worktree guard' {
        $fixture = New-LayoutFixture
        $linked = Join-Path $layoutCase 'linked'
        Assert-LayoutFixturePath $linked
        $null = Invoke-Git @('-C', $fixture.Source, 'worktree', 'add', '--quiet', '-b', 'other', $linked)
        $sourceBefore = Get-LayoutSnapshot $fixture.Source
        $linkedBefore = Get-LayoutSnapshot $linked
        $locationBefore = (Get-Location).ProviderPath

        $results = @(Invoke-LayoutFixtureRepair $fixture)

        Write-LayoutEvidence $fixture $sourceBefore 'absent' $locationBefore $results
        $results[0].Status | Should -BeExactly 'Skipped-HasWorktrees'
        Get-LayoutSnapshot $fixture.Source | Should -BeExactly $sourceBefore
        Get-LayoutSnapshot $linked | Should -BeExactly $linkedBefore
        Test-Path -LiteralPath $fixture.Target | Should -BeFalse
        (Get-Location).ProviderPath | Should -BeExactly $locationBefore
    }

    It 'does not treat a destination created after the occupancy check as a container' {
        $fixture = New-LayoutFixture -Branch feature/nested
        $targetParent = Split-Path $fixture.Target -Parent
        $race = @{ TargetBeforeMove = $null }
        Mock -ModuleName Shmuelie.Git New-Item {
            Assert-LayoutFixturePath $Path
            $null = [IO.Directory]::CreateDirectory($Path)
            $null = [IO.Directory]::CreateDirectory($fixture.Target)
            [IO.File]::WriteAllText((Join-Path $fixture.Target 'keep.txt'), 'concurrent destination')
            $race.TargetBeforeMove = Get-LayoutSnapshot $fixture.Target
        } -ParameterFilter { $ItemType -eq 'Directory' -and $Path -ceq $targetParent }
        $sourceBefore = Get-LayoutSnapshot $fixture.Source
        $locationBefore = (Get-Location).ProviderPath

        $results = @(Invoke-LayoutFixtureRepair $fixture)

        Write-LayoutEvidence $fixture $sourceBefore $race.TargetBeforeMove $locationBefore $results
        Should -Invoke -ModuleName Shmuelie.Git New-Item -Times 1 -Exactly -ParameterFilter { $Path -ceq $targetParent }
        $results[0].Action | Should -BeExactly 'rename-failed'
        $results[0].Status | Should -Match '^Error:'
        Get-LayoutSnapshot $fixture.Source | Should -BeExactly $sourceBefore
        Get-LayoutSnapshot $fixture.Target | Should -BeExactly $race.TargetBeforeMove
        (Get-Location).ProviderPath | Should -BeExactly $locationBefore
    }

    It 'reports a failed exact move when a destination parent is a file' {
        $fixture = New-LayoutFixture -Branch feature/nested
        $parent = Split-Path $fixture.Target -Parent
        Set-Content -LiteralPath $parent -Value 'keep parent file'
        $sourceBefore = Get-LayoutSnapshot $fixture.Source
        $parentBefore = Get-LayoutSnapshot $parent
        $locationBefore = (Get-Location).ProviderPath

        $results = @(Invoke-LayoutFixtureRepair $fixture)

        Write-LayoutEvidence $fixture $sourceBefore 'absent' $locationBefore $results
        $results[0].Action | Should -BeExactly 'rename-failed'
        $results[0].Status | Should -Match '^Error:'
        Get-LayoutSnapshot $fixture.Source | Should -BeExactly $sourceBefore
        Get-LayoutSnapshot $parent | Should -BeExactly $parentBefore
        (Get-Location).ProviderPath | Should -BeExactly $locationBefore
    }
}

Describe 'Find-StaleBranch' {
    BeforeAll {
        function New-AdoLikeRemote {
            param(
                [Parameter(Mandatory)][string]$Path,
                [string]$Organization = 'example',
                [string]$Project = 'project',
                [string]$Repository = 'repo.git',
                [switch]$EncodeSpaces
            )

            $remotePath = Join-Path $Path 'dev.azure.com' $Organization $Project '_git' $Repository
            Invoke-Git @('init', '--bare', '--quiet', $remotePath)
            $remoteUrlPath = ($remotePath -replace '\\', '/').TrimStart('/')
            if ($EncodeSpaces) {
                $remoteUrlPath = $remoteUrlPath -replace ' ', '%20'
            }
            'file:///' + $remoteUrlPath
        }

        function Add-GoneUpstreamBranch {
            param(
                [Parameter(Mandatory)][string]$Repo,
                [Parameter(Mandatory)][string]$Branch
            )

            Invoke-Git @('-C', $Repo, 'branch', $Branch)
            Invoke-Git @('-C', $Repo, 'update-ref', "refs/remotes/origin/$Branch", 'HEAD')
            Invoke-Git @('-C', $Repo, 'branch', '--set-upstream-to', "origin/$Branch", $Branch)
            Invoke-Git @('-C', $Repo, 'update-ref', '-d', "refs/remotes/origin/$Branch")
        }
    }

    BeforeEach {
        $global:FindStaleBranchAzCalls = [System.Collections.Generic.List[object]]::new()
        # This mock proves the guard skips az execution; it cannot prove cmd.exe
        # neutralization directly because unsafe input should never reach az.
        function global:az {
            $global:FindStaleBranchAzCalls.Add(@($args)) | Out-Null
            '{"id":123,"title":"Merged branch","status":"completed"}'
        }
    }

    AfterEach {
        Remove-Item Function:\az -Force -ErrorAction SilentlyContinue
        Remove-Variable -Name FindStaleBranchAzCalls -Scope Global -Force -ErrorAction SilentlyContinue
    }

    It 'excludes never-pushed branches by default and includes gone upstream branches' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'stale-default-filter')
        $remoteUrl = New-AdoLikeRemote -Path (Join-Path $TestDrive 'stale-default-remote')
        Invoke-Git @('-C', $repo, 'remote', 'add', 'origin', $remoteUrl)
        Add-GoneUpstreamBranch -Repo $repo -Branch 'user/test/gone-branch'
        Invoke-Git @('-C', $repo, 'branch', 'user/test/never-pushed')

        Push-Location $repo
        try {
            $result = @(Find-StaleBranch -User test)
        } finally {
            Pop-Location
        }

        $result.Branch | Should -Be @('user/test/gone-branch')
    }

    It 'includes never-pushed branches when explicitly requested' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'stale-include-never-pushed')
        $remoteUrl = New-AdoLikeRemote -Path (Join-Path $TestDrive 'stale-include-remote')
        Invoke-Git @('-C', $repo, 'remote', 'add', 'origin', $remoteUrl)
        Add-GoneUpstreamBranch -Repo $repo -Branch 'user/test/gone-branch'
        Invoke-Git @('-C', $repo, 'branch', 'user/test/never-pushed')

        Push-Location $repo
        try {
            $result = @(Find-StaleBranch -User test -IncludeNeverPushed)
        } finally {
            Pop-Location
        }

        $result.Branch | Sort-Object | Should -Be @('user/test/gone-branch', 'user/test/never-pushed')
    }

    It 'reports a clear error and no stale branches when the remote is unreachable' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'stale-unreachable-repo')
        # Point origin at a path that is not a git repository so ls-remote fails.
        $missing = Join-Path $TestDrive 'stale-unreachable-missing'
        $missingUrl = 'file:///' + (($missing -replace '\\', '/'))
        Invoke-Git @('-C', $repo, 'remote', 'add', 'origin', $missingUrl)
        Invoke-Git @('-C', $repo, 'branch', 'user/test/local-only')

        Push-Location $repo
        try {
            $result = @(Find-StaleBranch -All -IncludeNeverPushed -ErrorAction SilentlyContinue -ErrorVariable staleErrors)
        } finally {
            Pop-Location
        }

        $result | Should -HaveCount 0
        $staleErrors | Should -HaveCount 1
        $staleErrors[0].Exception.Message | Should -Match 'Failed to list remote branches'
        $staleErrors[0].Exception.Message | Should -Match 'ls-remote'
    }

    It 'queries PR status for branch names in the safe allow-list' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'safe-stale-branch')
        $remoteUrl = New-AdoLikeRemote -Path (Join-Path $TestDrive 'safe-remote')
        Invoke-Git @('-C', $repo, 'remote', 'add', 'origin', $remoteUrl)
        Invoke-Git @('-C', $repo, 'branch', 'user/test/safe-branch')

        Push-Location $repo
        try {
            $result = Find-StaleBranch -IncludePrStatus -IncludeNeverPushed -User test
        } finally {
            Pop-Location
        }

        $result | Should -HaveCount 1
        $result.Branch | Should -Be 'user/test/safe-branch'
        $result.PrStatus | Should -Be 'completed'
        $result.PrId | Should -Be 123
        $global:FindStaleBranchAzCalls.Count | Should -Be 1
        $sourceBranchIndex = [array]::IndexOf($global:FindStaleBranchAzCalls[0], '--source-branch')
        $global:FindStaleBranchAzCalls[0][$sourceBranchIndex + 1] | Should -Be 'user/test/safe-branch'
    }

    It 'queries PR status for URL-encoded ADO names that decode to spaces' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'safe-ado-context')
        $remoteUrl = New-AdoLikeRemote `
            -Path (Join-Path $TestDrive 'safe-context-remote') `
            -Project 'space project' `
            -Repository 'repo with space.git' `
            -EncodeSpaces
        Invoke-Git @('-C', $repo, 'remote', 'add', 'origin', $remoteUrl)
        Invoke-Git @('-C', $repo, 'branch', 'user/test/safe-branch')

        Push-Location $repo
        try {
            $result = Find-StaleBranch -IncludePrStatus -IncludeNeverPushed -User test
        } finally {
            Pop-Location
        }

        $result | Should -HaveCount 1
        $result.PrStatus | Should -Be 'completed'
        $global:FindStaleBranchAzCalls.Count | Should -Be 1
        $projectIndex = [array]::IndexOf($global:FindStaleBranchAzCalls[0], '--project')
        $repositoryIndex = [array]::IndexOf($global:FindStaleBranchAzCalls[0], '--repository')
        $global:FindStaleBranchAzCalls[0][$projectIndex + 1] | Should -Be 'space project'
        $global:FindStaleBranchAzCalls[0][$repositoryIndex + 1] | Should -Be 'repo with space.git'
    }

    It 'skips PR status lookup and warns for branch names outside the safe allow-list' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'unsafe-stale-branch')
        $remoteUrl = New-AdoLikeRemote -Path (Join-Path $TestDrive 'unsafe-remote')
        Invoke-Git @('-C', $repo, 'remote', 'add', 'origin', $remoteUrl)
        Invoke-Git @('-C', $repo, 'branch', 'user/test/a&calc.exe')

        Push-Location $repo
        try {
            $result = Find-StaleBranch -IncludePrStatus -IncludeNeverPushed -User test -WarningVariable warnings
        } finally {
            Pop-Location
        }

        $result | Should -HaveCount 1
        $result.Branch | Should -Be 'user/test/a&calc.exe'
        $result.PrStatus | Should -BeNullOrEmpty
        $result.PrId | Should -BeNullOrEmpty
        $result.PrTitle | Should -BeNullOrEmpty
        $global:FindStaleBranchAzCalls.Count | Should -Be 0
        $warnings[0].Message | Should -Match 'Skipping PR lookup'
        $warnings[0].Message | Should -Match 'unsafe'
    }

    It 'skips PR status lookup and warns for ADO context names with cmd metacharacters' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'unsafe-ado-context')
        $remoteUrl = New-AdoLikeRemote -Path (Join-Path $TestDrive 'unsafe-context-remote') -Project 'bad&project'
        Invoke-Git @('-C', $repo, 'remote', 'add', 'origin', $remoteUrl)
        Invoke-Git @('-C', $repo, 'branch', 'user/test/safe-branch')

        Push-Location $repo
        try {
            $result = Find-StaleBranch -IncludePrStatus -IncludeNeverPushed -User test -WarningVariable warnings
        } finally {
            Pop-Location
        }

        $result | Should -HaveCount 1
        $result.Branch | Should -Be 'user/test/safe-branch'
        $result.PrStatus | Should -BeNullOrEmpty
        $result.PrId | Should -BeNullOrEmpty
        $result.PrTitle | Should -BeNullOrEmpty
        $global:FindStaleBranchAzCalls.Count | Should -Be 0
        $warnings[0].Message | Should -Match 'Skipping PR lookup'
        $warnings[0].Message | Should -Match 'unsafe'
    }
}

Describe 'AllWorktreesChangedResult formatting' {
    BeforeAll {
        function New-ChangedResultFixture {
            param([switch]$Long, [string]$Status = 'Updated')
            [pscustomobject][ordered]@{
                PSTypeName = 'AllWorktreesChangedResult'
                Organization = if ($Long) { 'organization-' + ('abcdef0123456789' * 18) + '-org-end' } else { 'example' }
                Repository = if ($Long) { 'repository-' + ('9876543210fedcba' * 19) + '-repo-end' } else { 'short' }
                Branch = if ($Long) { 'feature/' + ('long-branch-' * 28) + 'branch-end' } else { '' }
                Status = $Status
                BehindBy = if ($Long) { [int]::MaxValue } else { 0 }
                Path = if ($Long) { '/repos/' + ('unbroken-path-' * 30) + 'path-end' } else { '/repos/short' }
                Error = if ($Long) {
                    ('Failed to update the selected worktree; retain all local changes. ' * 7) +
                    "`r`n`r`nRecovery: " + ('diagnostic-' * 24) + "error-end`nFinal instruction: retry only after resolving the conflict."
                } else { $null }
            }
        }
    }

    It 'keeps the multiline default and the explicitly selectable legacy table' {
        $views = (Get-FormatData -TypeName AllWorktreesChangedResult).FormatViewDefinition
        $views[0].Name | Should -BeExactly 'AllWorktreesChangedResultDetails'
        $views[0].Control | Should -BeOfType ([System.Management.Automation.CustomControl])
        $table = @($views | Where-Object Name -EQ AllWorktreesChangedResult)
        $table | Should -HaveCount 1
        $table[0].Control | Should -BeOfType ([System.Management.Automation.TableControl])
        $table[0].Control.Headers.Label | Should -Be @('Organization', 'Repository', 'Branch', 'Status', 'Behind', 'Path', 'Error')
    }

    It 'preserves every value at <Width> columns after a short success' -ForEach @(
        @{ Width = 80 }; @{ Width = 100 }; @{ Width = 120 }; @{ Width = 160 }
    ) {
        $rows = @(
            New-ChangedResultFixture
            New-ChangedResultFixture -Long -Status Failed
            New-ChangedResultFixture -Long -Status StashFailed
        )
        $before = ConvertTo-Json -InputObject $rows -Depth 4 -Compress
        $rendered = $rows | Out-String -Width $Width
        $expected = foreach ($row in $rows) {
            "Status: $($row.Status) (Behind: $($row.BehindBy))"
            "Organization: $($row.Organization)"
            "Repository: $($row.Repository)"
            "Branch: $($row.Branch)"
            "Path: $($row.Path)"
            if ($row.Error) { "Error: $($row.Error)" }
        }
        # Ignore only whitespace introduced by wrapping; compare every field's
        # complete content and order, so a missing column or suffix still fails.
        ($rendered -replace '\s', '') | Should -BeExactly (($expected -join "`n") -replace '\s', '')
        @($rendered -split '\r?\n' | Where-Object { $_.Length -gt $Width }) | Should -HaveCount 0
        @([regex]::Matches($rendered, '(?m)^Status: (Updated|Failed|StashFailed) \(Behind: \d+\)\r?$')) | Should -HaveCount 3
        @([regex]::Matches($rendered, '(?m)^Error: ')) | Should -HaveCount 2
        $rendered | Should -Match '\r?\n\r?\nRecovery: '
        (ConvertTo-Json -InputObject $rows -Depth 4 -Compress) | Should -BeExactly $before
    }

    It 'omits the error label for <Kind> errors while retaining empty branch and zero behind' -ForEach @(
        @{ Kind = 'null'; Value = $null }; @{ Kind = 'empty'; Value = '' }
    ) {
        $row = New-ChangedResultFixture
        $row.Error = $Value
        $rendered = $row | Out-String -Width 80
        $rendered | Should -Not -Match '(?m)^Error:'
        $rendered | Should -Match '(?m)^Branch: *\r?$'
        $rendered | Should -Match '(?m)^Status: Updated \(Behind: 0\)\r?$'
    }

    It 'preserves whitespace-only errors rather than silently treating them as absent' {
        $row = New-ChangedResultFixture
        $row.Error = '   '
        ($row | Out-String -Width 80) | Should -Match '(?m)^Error:'
    }

    It 'renders a table only when explicitly requested' {
        $row = New-ChangedResultFixture
        $row.Branch = 'main'
        $row.Error = 'example diagnostic'
        $rendered = $row | Format-Table -View AllWorktreesChangedResult | Out-String -Width 160
        $rendered | Should -Match 'Organization\s+Repository\s+Branch\s+Status\s+Behind\s+Path\s+Error'
        foreach ($value in 'example', 'short', 'main', 'Updated', '0', '/repos/short', 'example diagnostic') {
            $rendered | Should -Match ([regex]::Escape($value))
        }
        $rendered | Should -Not -Match '(?m)^Status:'
    }

    It 'does not change the repository summary or single-repository worktree default' {
        foreach ($name in 'AllWorktreesUpdateResult', 'WorktreeUpdateResult') {
            (Get-FormatData -TypeName $name).FormatViewDefinition[0].Control |
                Should -BeOfType ([System.Management.Automation.TableControl])
        }
    }

    It 'keeps typed results streamable, filterable and exportable without format records' {
        InModuleScope Shmuelie.Git {
            $events = [System.Collections.Generic.List[string]]::new()
            $rows = @(
                & {
                    foreach ($name in 'first', 'second') {
                        $events.Add("input:$name")
                        [pscustomobject]@{
                            Organization = 'example'; Repository = $name; Path = "/repos/$name"
                            Status = 'Completed'; Error = $null
                            WorktreeResults = @(
                                [pscustomobject]@{ Branch = 'main'; Status = 'Updated'; BehindBy = 2; Path = "/repos/$name/main" }
                                [pscustomobject]@{ Branch = 'current'; Status = 'Current'; BehindBy = 0; Path = "/repos/$name/current" }
                            )
                        }
                    }
                } | ConvertTo-UpdateAllWorktreesOutput -ChangedOnly | ForEach-Object {
                    $events.Add("output:$($_.Repository)")
                    $_
                }
            )
            $events | Should -Be @('input:first', 'output:first', 'input:second', 'output:second')
            $rows | Should -HaveCount 2
            foreach ($row in $rows) {
                $row.PSTypeNames[0] | Should -BeExactly 'AllWorktreesChangedResult'
                @($row.PSObject.Properties.Name) | Should -Be @('Organization', 'Repository', 'Branch', 'Status', 'BehindBy', 'Path', 'Error')
            }
            @($rows | Where-Object Status -EQ Updated) | Should -HaveCount 2
            $jsonRows = @($rows | ConvertTo-Json -Depth 4 | ConvertFrom-Json)
            $csvRows = @($rows | ConvertTo-Csv -NoTypeInformation | ConvertFrom-Csv)
            $jsonRows.Repository | Should -Be @('first', 'second')
            $csvRows.Path | Should -Be @('/repos/first/main', '/repos/second/main')
            $jsonRows.BehindBy | Should -Be @(2, 2)
            $csvRows.BehindBy | Should -Be @('2', '2')
        }
    }
}

Describe 'Update-AllWorktrees' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
    BeforeAll {
        function New-LayoutRepo {
            param(
                [Parameter(Mandatory)][string]$Root,
                [Parameter(Mandatory)][string]$Organization,
                [Parameter(Mandatory)][string]$Name,
                [string]$Branch = 'main'
            )

            $path = Join-Path (Join-Path (Join-Path $Root $Organization) $Name) $Branch
            New-TestRepo -Path $path
        }
    }

    It 'discovers multiple repositories across organizations and returns one result per repo' {
        $root = Join-Path $TestDrive 'all-discovery-root'
        New-LayoutRepo -Root $root -Organization 'alpha' -Name 'one' | Out-Null
        New-LayoutRepo -Root $root -Organization 'beta' -Name 'two' | Out-Null

        $results = @(Update-AllWorktrees -Path $root -WhatIf -Confirm:$false)

        $results | Should -HaveCount 2
        $results[0].PSTypeNames[0] | Should -Be 'AllWorktreesUpdateResult'
        ($results | ForEach-Object { "$($_.Organization)/$($_.Repository)" } | Sort-Object) |
            Should -Be @('alpha/one', 'beta/two')
        $results.Status | Should -Be @('WhatIf', 'WhatIf')
    }

    It 'applies multi-valued wildcard organization, name, and exclude filters' {
        $root = Join-Path $TestDrive 'all-filter-root'
        New-LayoutRepo -Root $root -Organization 'alpha' -Name 'one' | Out-Null
        New-LayoutRepo -Root $root -Organization 'alpha' -Name 'two' | Out-Null
        New-LayoutRepo -Root $root -Organization 'beta' -Name 'one' | Out-Null
        New-LayoutRepo -Root $root -Organization 'beta' -Name 'skipme' | Out-Null

        $results = @(Update-AllWorktrees `
            -Path $root `
            -Organization 'alpha,beta' `
            -Name 'o*','two' `
            -Exclude 'beta/one','*skip*' `
            -WhatIf `
            -Confirm:$false)

        ($results | ForEach-Object { "$($_.Organization)/$($_.Repository)" } | Sort-Object) |
            Should -Be @('alpha/one', 'alpha/two')
    }

    It 'reports a clear error for a non-existent root' {
        $missing = Join-Path $TestDrive 'missing-root'

        $results = @(Update-AllWorktrees -Path $missing -ErrorAction SilentlyContinue -ErrorVariable errors)

        $results | Should -HaveCount 0
        $errors | Should -HaveCount 1
        $errors[0].Exception.Message | Should -Match 'Repository root not found'
        $errors[0].Exception.Message | Should -Match ([regex]::Escape($missing))
    }

    It 'tags result objects with the discovered organization and repository' {
        $root = Join-Path $TestDrive 'all-tagging-root'
        $repoPath = New-LayoutRepo -Root $root -Organization 'org-name' -Name 'repo-name'

        $result = @(Update-AllWorktrees -Path $root -WhatIf -Confirm:$false) | Select-Object -First 1

        $result.Organization | Should -BeExactly 'org-name'
        $result.Repository | Should -BeExactly 'repo-name'
        $result.Path | Should -BeExactly (Resolve-Path -LiteralPath $repoPath).Path
        $result.WorktreeResults | Should -BeNullOrEmpty
    }

    It 'preserves repository-level structured output when ChangedOnly is omitted' {
        InModuleScope Shmuelie.Git {
            $repositoryResult = [PSCustomObject]@{
                PSTypeName      = 'AllWorktreesUpdateResult'
                Organization    = 'example'
                Repository      = 'repo'
                Path            = 'repo-path'
                Status          = 'Completed'
                WorktreeResults = @()
                Error           = $null
            }

            $result = $repositoryResult | ConvertTo-UpdateAllWorktreesOutput

            [object]::ReferenceEquals($result, $repositoryResult) | Should -BeTrue
            $result.PSTypeNames[0] | Should -Be 'AllWorktreesUpdateResult'
        }
    }

    It 'flattens only actionable worktree statuses with repository context' {
        InModuleScope Shmuelie.Git {
            $worktrees = @(
                [PSCustomObject]@{ Branch = 'current'; Status = 'Current'; BehindBy = 0; Path = 'current-path' }
                [PSCustomObject]@{ Branch = 'no-upstream'; Status = 'NoUpstream'; BehindBy = 0; Path = 'no-upstream-path' }
                [PSCustomObject]@{ Branch = 'updated'; Status = 'Updated'; BehindBy = 2; Path = 'updated-path' }
                [PSCustomObject]@{ Branch = 'removed'; Status = 'Removed'; BehindBy = 0; Path = 'removed-path' }
                [PSCustomObject]@{ Branch = 'failed'; Status = 'Failed'; BehindBy = 1; Path = 'failed-path' }
                [PSCustomObject]@{ Branch = 'stash'; Status = 'StashFailed'; BehindBy = 3; Path = 'stash-path' }
            )
            $repositoryResult = [PSCustomObject]@{
                PSTypeName      = 'AllWorktreesUpdateResult'
                Organization    = 'example'
                Repository      = 'repo'
                Path            = 'repo-path'
                Status          = 'Failed'
                WorktreeResults = $worktrees
                Error           = 'update failed'
            }

            $results = @($repositoryResult | ConvertTo-UpdateAllWorktreesOutput -ChangedOnly)

            $results | Should -HaveCount 4
            $results[0].PSTypeNames[0] | Should -Be 'AllWorktreesChangedResult'
            $results.Branch | Should -Be @('updated', 'removed', 'failed', 'stash')
            $results.Organization | Should -Be @('example', 'example', 'example', 'example')
            $results.Repository | Should -Be @('repo', 'repo', 'repo', 'repo')
            ($results | Where-Object Status -eq 'Updated').BehindBy | Should -Be 2
            ($results | Where-Object Status -eq 'Failed').Error | Should -Be 'update failed'
            ($results | Where-Object Status -eq 'Updated').Error | Should -BeNullOrEmpty
        }
    }

    It 'retains a repository-level failure when worktree results are <Name>' -ForEach @(
        @{ Name = 'empty'; WorktreeResults = @() }
        @{ Name = 'null'; WorktreeResults = $null }
    ) {
        InModuleScope Shmuelie.Git -Parameters @{ WorktreeResults = $WorktreeResults } {
            param($WorktreeResults)
            $repositoryResult = [PSCustomObject]@{
                PSTypeName      = 'AllWorktreesUpdateResult'
                Organization    = 'example'
                Repository      = 'repo'
                Path            = 'repo-path'
                Status          = 'Failed'
                WorktreeResults = $WorktreeResults
                Error           = 'worker failed before update'
            }

            $result = $repositoryResult | ConvertTo-UpdateAllWorktreesOutput -ChangedOnly

            $result.PSTypeNames[0] | Should -Be 'AllWorktreesChangedResult'
            $result.Status | Should -Be 'Failed'
            $result.Branch | Should -Be ''
            $result.Error | Should -Be 'worker failed before update'
        }
    }

    It 'retains a repository-level failure alongside a successful worktree row' {
        InModuleScope Shmuelie.Git {
            $repositoryResult = [PSCustomObject]@{
                PSTypeName      = 'AllWorktreesUpdateResult'
                Organization    = 'example'
                Repository      = 'repo'
                Path            = 'repo-path'
                Status          = 'Failed'
                WorktreeResults = @(
                    [PSCustomObject]@{
                        Branch = 'updated'
                        Status = 'Updated'
                        BehindBy = 1
                        Path = 'updated-path'
                    }
                )
                Error           = 'worker emitted a separate error'
            }

            $results = @($repositoryResult | ConvertTo-UpdateAllWorktreesOutput -ChangedOnly)

            $results | Should -HaveCount 2
            $results.Status | Should -Be @('Updated', 'Failed')
            $results[1].Branch | Should -Be ''
            $results[1].Error | Should -Be 'worker emitted a separate error'
        }
    }

    It 'keeps ChangedOnly WhatIf previews visible as compact rows' {
        $root = Join-Path $TestDrive 'all-changed-whatif-root'
        New-LayoutRepo -Root $root -Organization 'alpha' -Name 'one' | Out-Null

        $result = Update-AllWorktrees -Path $root -ChangedOnly -WhatIf -Confirm:$false

        $result.PSTypeNames[0] | Should -Be 'AllWorktreesChangedResult'
        $result.Organization | Should -Be 'alpha'
        $result.Repository | Should -Be 'one'
        $result.Status | Should -Be 'WhatIf'
    }

    It 'loads compact format views for both result shapes' {
        (Get-FormatData -TypeName AllWorktreesUpdateResult).FormatViewDefinition.Name |
            Should -Contain 'AllWorktreesUpdateResult'
        (Get-FormatData -TypeName AllWorktreesChangedResult).FormatViewDefinition.Name |
            Should -Contain 'AllWorktreesChangedResult'
    }

    It 'updates an offline local repository end-to-end' {
        $root = Join-Path $TestDrive 'all-e2e-root'
        $origin = Join-Path $TestDrive 'all-e2e-origin.git'
        Invoke-Git @('init', '--bare', '-b', 'main', '--quiet', $origin)

        $seed = Join-Path $TestDrive 'all-e2e-seed'
        Invoke-Git @('clone', '--quiet', $origin, $seed)
        Set-TestRepoConfig $seed
        Set-Content -Path (Join-Path $seed 'README.md') -Value 'initial' -NoNewline
        Invoke-Git @('-C', $seed, 'add', 'README.md')
        Invoke-TestCommit -Path $seed -Message 'init'
        Invoke-Git @('-C', $seed, 'push', '-u', 'origin', 'main', '--quiet')

        $target = Join-Path (Join-Path (Join-Path $root 'alpha') 'offline') 'main'
        Invoke-Git @('clone', '--quiet', $origin, $target)
        Set-TestRepoConfig $target

        $results = @(Update-AllWorktrees -Path $root -NoGitHubAccountResolve -ThrottleLimit 2)

        $results | Should -HaveCount 1
        $results[0].Organization | Should -BeExactly 'alpha'
        $results[0].Repository | Should -BeExactly 'offline'
        $results[0].Status | Should -Be 'Completed'
        $results[0].Error | Should -BeNullOrEmpty
        $worktreeResult = @($results[0].WorktreeResults | Where-Object Branch -eq 'main')
        $worktreeResult | Should -HaveCount 1
        $worktreeResult[0].Status | Should -Be 'Current'
    }

    It 'resolves GitHub accounts in the parent runspace and merges them into a per-repository map' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'resolver-parent-repo')
        Invoke-Git @('-C', $repo, 'remote', 'add', 'origin', 'https://github.com/contoso/repo.git')

        $result = InModuleScope Shmuelie.Git -ArgumentList $repo {
            param($repoPath)
            # A closure variable proves the resolver runs in the parent: it could
            # not be captured if the scriptblock were serialized into a worker.
            $captured = 'work-account'
            $resolver = { param($h, $o) if ($o -eq 'contoso') { $captured } }
            Resolve-AllWorktreesAccountMap -RepositoryPath $repoPath -Resolver $resolver
        }

        $result['github.com/contoso'] | Should -Be 'work-account'
    }

    It 'lets a caller-supplied GitHubAccountMap override resolver-derived entries' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'resolver-override-repo')
        Invoke-Git @('-C', $repo, 'remote', 'add', 'origin', 'https://github.com/contoso/repo.git')

        $result = InModuleScope Shmuelie.Git -ArgumentList $repo {
            param($repoPath)
            Resolve-AllWorktreesAccountMap `
                -RepositoryPath $repoPath `
                -Resolver { param($h, $o) 'resolved' } `
                -BaseMap @{ 'github.com/contoso' = 'explicit' }
        }

        $result['github.com/contoso'] | Should -Be 'explicit'
    }

    It 'accepts a GitHubAccountResolver scriptblock without a ForEach-Object -Parallel binding error' {
        $root = Join-Path $TestDrive 'resolver-e2e-root'
        $origin = Join-Path $TestDrive 'resolver-e2e-origin.git'
        Invoke-Git @('init', '--bare', '-b', 'main', '--quiet', $origin)

        $seed = Join-Path $TestDrive 'resolver-e2e-seed'
        Invoke-Git @('clone', '--quiet', $origin, $seed)
        Set-TestRepoConfig $seed
        Set-Content -Path (Join-Path $seed 'README.md') -Value 'initial' -NoNewline
        Invoke-Git @('-C', $seed, 'add', 'README.md')
        Invoke-TestCommit -Path $seed -Message 'init'
        Invoke-Git @('-C', $seed, 'push', '-u', 'origin', 'main', '--quiet')

        $target = Join-Path (Join-Path (Join-Path $root 'alpha') 'offline') 'main'
        Invoke-Git @('clone', '--quiet', $origin, $target)
        Set-TestRepoConfig $target

        # The file:// origin keeps the fetch offline and means no GitHub host is
        # ever contacted; passing the resolver scriptblock at all is what
        # reproduced the original ForEach-Object -Parallel binding failure.
        $results = @(Update-AllWorktrees `
            -Path $root `
            -GitHubAccountResolver { param($h, $o) 'work' } `
            -ThrottleLimit 2)

        $results | Should -HaveCount 1
        $results[0].Status | Should -Be 'Completed'
        $results[0].Error | Should -BeNullOrEmpty
    }
}

Describe 'Changed worktree result selection' {
    It 'keeps the selector private' {
        (Get-Module Shmuelie.Git).ExportedFunctions.Keys | Should -Not -Contain 'Select-ChangedWorktreeResult'
    }

    It 'selects <Status> only when actionable, preserving the original object' -ForEach @(
        @{ Status = 'Updated'; ExpectedCount = 1 }
        @{ Status = 'Removed'; ExpectedCount = 1 }
        @{ Status = 'Failed'; ExpectedCount = 1 }
        @{ Status = 'StashFailed'; ExpectedCount = 1 }
        @{ Status = 'Current'; ExpectedCount = 0 }
        @{ Status = 'NoUpstream'; ExpectedCount = 0 }
        @{ Status = 'Skipped'; ExpectedCount = 0 }
        @{ Status = 'InProgress'; ExpectedCount = 0 }
        @{ Status = 'Unknown'; ExpectedCount = 0 }
        @{ Status = 'WhatIf'; ExpectedCount = 0 }
    ) {
        InModuleScope Shmuelie.Git -Parameters @{ Status = $Status; ExpectedCount = $ExpectedCount } {
            param($Status, $ExpectedCount)
            $original = [PSCustomObject]@{
                PSTypeName = 'WorktreeUpdateResult'
                Branch = 'branch'
                Path = 'worktree-path'
                Status = $Status
                BehindBy = 2
                Stashed = $true
                Operation = $null
                PopFailed = $true
            }

            $results = @($original | Select-ChangedWorktreeResult)

            $results | Should -HaveCount $ExpectedCount
            if ($ExpectedCount) {
                [object]::ReferenceEquals($original, $results[0]) | Should -BeTrue
                $results[0].PSTypeNames[0] | Should -Be 'WorktreeUpdateResult'
                $results[0].PopFailed | Should -BeTrue
            }
        }
    }
}

Describe 'Update-Worktrees ChangedOnly' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
    BeforeAll {
        function New-UpdateFixture {
            param([string]$Name, [switch]$Current)

            $root = Join-Path $TestDrive $Name
            $seed = New-TestRepo -Path (Join-Path $root 'seed')
            $origin = Join-Path $root 'origin.git'
            Invoke-Git @('init', '--bare', '-b', 'main', '--quiet', $origin)
            Invoke-Git @('-C', $seed, 'remote', 'add', 'origin', $origin)
            Invoke-Git @('-C', $seed, 'push', '-u', 'origin', 'main', '--quiet')
            $clone = Join-Path $root 'clone'
            Invoke-Git @('clone', '--quiet', $origin, $clone)
            Set-TestRepoConfig $clone

            if (-not $Current) {
                Set-Content -LiteralPath (Join-Path $seed 'README.md') -Value 'updated'
                Invoke-Git @('-C', $seed, 'add', 'README.md')
                Invoke-TestCommit -Path $seed -Message 'upstream update'
                Invoke-Git @('-C', $seed, 'push', 'origin', 'main', '--quiet')
            }

            [PSCustomObject]@{ Root = $root; Seed = $seed; Origin = $origin; Clone = $clone }
        }
    }

    It 'filters output but performs the same update with ChangedOnly <Mode>' -ForEach @(
        @{ Mode = 'omitted'; Options = @{}; ExpectedCount = 5 }
        @{ Mode = 'false'; Options = @{ ChangedOnly = $false }; ExpectedCount = 5 }
        @{ Mode = 'true'; Options = @{ ChangedOnly = $true }; ExpectedCount = 2 }
    ) {
        $fixture = New-UpdateFixture -Name "mixed-$Mode"
        $clone = $fixture.Clone
        foreach ($branch in 'current', 'skipped', 'no-upstream', 'removed') {
            $worktree = Join-Path $fixture.Root $branch
            Invoke-Git @('-C', $clone, 'worktree', 'add', '--quiet', '-b', $branch, $worktree, 'HEAD')
            if ($branch -ne 'no-upstream') {
                Invoke-Git @('-C', $clone, 'update-ref', "refs/remotes/origin/$branch", 'HEAD')
                Invoke-Git @('-C', $clone, 'branch', "--set-upstream-to=origin/$branch", $branch)
            }
            if ($branch -eq 'skipped') {
                Invoke-Git @('-C', $worktree, 'commit', '--allow-empty', '-m', 'local commit', '--quiet')
            }
        }
        Invoke-Git @('-C', $clone, 'update-ref', '-d', 'refs/remotes/origin/removed')
        Invoke-Git @('-C', $clone, 'fetch', '--quiet', 'origin', 'main')
        # Keep the synthetic current/skipped tracking refs; real fetch pruning
        # is covered by the separate offline integration scenarios below.
        Mock -ModuleName Shmuelie.Git Sync-GitRemote { @() }

        $results = @(Update-Worktrees -Path $clone @Options -NoGitHubAccountResolve -Confirm:$false)

        $results | Should -HaveCount $ExpectedCount
        foreach ($result in $results) {
            $result.PSTypeNames[0] | Should -Be 'WorktreeUpdateResult'
            $result.Path | Should -Not -BeNullOrEmpty
        }
        ($results | Where-Object Branch -eq 'main').Status | Should -Be 'Updated'
        ($results | Where-Object Branch -eq 'main').BehindBy | Should -Be 1
        ($results | Where-Object Branch -eq 'removed').Status | Should -Be 'Removed'
        if ($Mode -ne 'true') {
            ($results | Where-Object Branch -eq 'current').Status | Should -Be 'Current'
            ($results | Where-Object Branch -eq 'skipped').Status | Should -Be 'Skipped'
            ($results | Where-Object Branch -eq 'no-upstream').Status | Should -Be 'NoUpstream'
        }
        (Get-Content -LiteralPath (Join-Path $clone 'README.md') -Raw).Trim() | Should -BeExactly 'updated'
        Invoke-Git @('-C', $clone, 'rev-parse', 'HEAD') | Should -Be (Invoke-Git @('-C', $fixture.Seed, 'rev-parse', 'HEAD'))
        Should -Invoke -ModuleName Shmuelie.Git Sync-GitRemote -Times 1 -ParameterFilter { $Path -eq $clone }
    }

    It 'preserves <Status> results and diagnostics for <Scenario>' -ForEach @(
        @{ Scenario = 'merge failure'; Status = 'Failed'; Dirty = $false; LockIndex = $true; Warning = 'Fast-forward failed'; PopFailed = $false }
        @{ Scenario = 'stash failure'; Status = 'StashFailed'; Dirty = $true; LockIndex = $true; Warning = 'git stash push failed'; PopFailed = $false }
        @{ Scenario = 'stash pop conflict'; Status = 'Updated'; Dirty = $true; LockIndex = $false; Warning = 'git stash restoration failed'; PopFailed = $true }
    ) {
        $fixture = New-UpdateFixture -Name ($Scenario -replace ' ', '-')
        $clone = $fixture.Clone
        if ($Dirty) {
            Set-Content -LiteralPath (Join-Path $clone 'README.md') -Value 'local edits'
        }
        $indexLock = Join-Path (Get-TestGitDir -Path $clone) 'index.lock'
        if ($LockIndex) { New-Item -ItemType File -Path $indexLock | Out-Null }
        $headBefore = Invoke-Git @('-C', $clone, 'rev-parse', 'HEAD')
        try {
            $results = @(Update-Worktrees -Path $clone -ChangedOnly -NoGitHubAccountResolve -Confirm:$false -WarningVariable diagnostics)

            $results | Should -HaveCount 1
            $results[0].Status | Should -Be $Status
            $results[0].PSTypeNames[0] | Should -Be 'WorktreeUpdateResult'
            $results[0].BehindBy | Should -Be 1
            $results[0].PopFailed | Should -Be $PopFailed
            $results[0].Stashed | Should -Be $PopFailed
            ($diagnostics -join "`n") | Should -Match $Warning
            if ($LockIndex) {
                Invoke-Git @('-C', $clone, 'rev-parse', 'HEAD') | Should -Be $headBefore
                @(Invoke-Git @('-C', $clone, 'stash', 'list')) | Should -HaveCount 0
                if ($Dirty) {
                    (Get-Content -LiteralPath (Join-Path $clone 'README.md') -Raw).Trim() | Should -BeExactly 'local edits'
                }
            } else {
                @(Invoke-Git @('-C', $clone, 'stash', 'list')) | Should -HaveCount 1
            }
        } finally {
            if ($LockIndex) { Remove-Item -LiteralPath $indexLock }
        }
    }

    It 'processes each pipeline repository independently with <InputKind> paths and keeps errors without rows' -ForEach @(
        @{ InputKind = 'string' }
        @{ InputKind = 'property-bound' }
    ) {
        $current = New-UpdateFixture -Name "pipeline-current-$InputKind" -Current
        $behind = New-UpdateFixture -Name "pipeline-behind-$InputKind"
        $paths = @($current.Clone, (Join-Path $TestDrive 'missing-repository'), $behind.Clone)
        $inputPaths = if ($InputKind -eq 'string') { $paths } else {
            $paths | ForEach-Object { [PSCustomObject]@{ RepositoryPath = $_ } }
        }
        $locationBefore = (Get-Location).Path

        $results = @($inputPaths | Update-Worktrees -ChangedOnly -NoGitHubAccountResolve -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable failures)

        $results | Should -HaveCount 1
        $results[0].Status | Should -Be 'Updated'
        $results[0].Path | Should -BeExactly (ConvertTo-NativeTestPath $behind.Clone)
        $failures | Should -Not -BeNullOrEmpty
        ($failures -join "`n") | Should -Match 'missing-repository'
        (Get-Location).Path | Should -BeExactly $locationBefore
        (Get-Content -LiteralPath (Join-Path $current.Clone 'README.md') -Raw).Trim() | Should -BeExactly 'initial'
        (Get-Content -LiteralPath (Join-Path $behind.Clone 'README.md') -Raw).Trim() | Should -BeExactly 'updated'
    }

    It 'does not turn a fetch error without a worktree result into successful output' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'fetch-failure')
        Invoke-Git @('-C', $repo, 'remote', 'add', 'origin', (Join-Path $TestDrive 'missing-origin.git'))

        $results = @(Update-Worktrees -Path $repo -ChangedOnly -NoGitHubAccountResolve -ErrorAction SilentlyContinue -ErrorVariable failures)

        $results | Should -HaveCount 0
        $failures | Should -Not -BeNullOrEmpty
        ($failures -join "`n") | Should -Match 'git fetch'
    }

    It 'filters only after CheckRemote reclassifies a local-only branch' {
        $fixture = New-UpdateFixture -Name 'check-remote' -Current
        $worktree = Join-Path $fixture.Root 'local-only'
        Invoke-Git @('-C', $fixture.Clone, 'worktree', 'add', '--quiet', '-b', 'local-only', $worktree)

        $results = @(Update-Worktrees -Path $fixture.Clone -ChangedOnly -CheckRemote -NoGitHubAccountResolve -Confirm:$false)

        $results | Should -HaveCount 1
        $results[0].Branch | Should -Be 'local-only'
        $results[0].Status | Should -Be 'Removed'
        Test-Path -LiteralPath $worktree | Should -BeTrue
    }

    It 'keeps WhatIf previews visible without fetching, merging, or stashing' {
        $fixture = New-UpdateFixture -Name 'preview'
        $clone = $fixture.Clone
        Invoke-Git @('-C', $clone, 'fetch', '--quiet', 'origin', 'main')
        $trackingBefore = Invoke-Git @('-C', $clone, 'rev-parse', 'origin/main')
        $headBefore = Invoke-Git @('-C', $clone, 'rev-parse', 'HEAD')
        Set-Content -LiteralPath (Join-Path $fixture.Seed 'README.md') -Value 'latest'
        Invoke-Git @('-C', $fixture.Seed, 'add', 'README.md')
        Invoke-TestCommit -Path $fixture.Seed -Message 'another upstream update'
        Invoke-Git @('-C', $fixture.Seed, 'push', 'origin', 'main', '--quiet')
        $localFile = Join-Path $clone 'local.txt'
        Set-Content -LiteralPath $localFile -Value 'keep local changes'
        $transcript = Join-Path $TestDrive 'changed-only-preview.txt'

        Start-Transcript -Path $transcript -Force | Out-Null
        try {
            $results = @(Update-Worktrees -Path $clone -ChangedOnly -WhatIf -NoGitHubAccountResolve -Confirm:$false)
        } finally {
            Stop-Transcript | Out-Null
        }

        $results | Should -HaveCount 0
        $preview = Get-Content -LiteralPath $transcript -Raw
        $preview | Should -Match 'What if:.*git fetch'
        $preview | Should -Match 'What if:.*Fast-forward merge from upstream'
        Invoke-Git @('-C', $clone, 'rev-parse', 'origin/main') | Should -BeExactly $trackingBefore
        Invoke-Git @('-C', $clone, 'rev-parse', 'HEAD') | Should -BeExactly $headBefore
        @(Invoke-Git @('-C', $clone, 'stash', 'list')) | Should -HaveCount 0
        (Get-Content -LiteralPath $localFile -Raw).Trim() | Should -BeExactly 'keep local changes'

        $applied = @(Update-Worktrees -Path $clone -ChangedOnly -NoGitHubAccountResolve -Confirm:$false)
        $applied | Should -HaveCount 1
        $applied[0].Status | Should -Be 'Updated'
        $applied[0].Stashed | Should -BeTrue
        $applied[0].PopFailed | Should -BeFalse
        (Get-Content -LiteralPath (Join-Path $clone 'README.md') -Raw).Trim() | Should -BeExactly 'latest'
        (Get-Content -LiteralPath $localFile -Raw).Trim() | Should -BeExactly 'keep local changes'
    }
}

Describe 'Update-Worktrees owned stash restoration' -Tag 'OwnedUpdateStash' {
    BeforeAll {
        $ownedUpdateRoot = (New-Item -ItemType Directory -Path (
            Join-Path $TestDrive "owned-update-$([guid]::NewGuid().ToString('N'))"
        ) -ErrorAction Stop).FullName
        $ownedUpdateEnvironment = @{}
        foreach ($key in @(
            'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_SYSTEM', 'GIT_CONFIG_NOSYSTEM',
            'GIT_CONFIG_COUNT', 'GIT_CONFIG_PARAMETERS', 'GIT_DIR', 'GIT_WORK_TREE',
            'GIT_COMMON_DIR', 'GIT_INDEX_FILE', 'GIT_OBJECT_DIRECTORY',
            'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_CEILING_DIRECTORIES',
            'GIT_AUTHOR_DATE', 'GIT_COMMITTER_DATE', 'GIT_TERMINAL_PROMPT'
        )) {
            $ownedUpdateEnvironment[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
            Remove-Item "Env:$key" -ErrorAction Ignore
        }
        $env:GIT_CONFIG_GLOBAL = Join-Path $ownedUpdateRoot 'no-global-config'
        $env:GIT_CONFIG_SYSTEM = Join-Path $ownedUpdateRoot 'no-system-config'
        $env:GIT_CONFIG_NOSYSTEM = '1'
        $env:GIT_CONFIG_COUNT = '0'
        $env:GIT_CEILING_DIRECTORIES = $TestDrive
        $env:GIT_TERMINAL_PROMPT = '0'

        function Assert-OwnedUpdatePath {
            param([Parameter(Mandatory)][string]$Path)
            $prefix = $ownedUpdateRoot + [IO.Path]::DirectorySeparatorChar
            if (-not [IO.Path]::GetFullPath($Path).StartsWith($prefix, [StringComparison]::Ordinal)) {
                throw "Refusing Git fixture access outside '$ownedUpdateRoot': '$Path'."
            }
        }

        function Invoke-OwnedUpdateGit {
            param([string]$Path, [string[]]$Arguments)
            Assert-OwnedUpdatePath $Path
            if ($Arguments -contains 'fetch' -or
                ($Arguments -contains 'push' -and $Arguments -notcontains 'stash')) {
                throw 'This fixture uses local upstreams only; fetch/push is forbidden.'
            }
            Invoke-Git (@('-C', $Path) + $Arguments)
        }

        function New-OwnedUpdateFixture {
            param([switch]$Submodule, [switch]$Conflict)
            $path = Join-Path $ownedCaseRoot 'parent'
            Assert-OwnedUpdatePath $path
            $null = New-TestRepo -Path $path
            if ($Submodule) {
                $sub = Join-Path $ownedCaseRoot 'sub-source'
                Assert-OwnedUpdatePath $sub
                $null = New-TestRepo -Path $sub
                $null = Invoke-OwnedUpdateGit $path @('submodule', 'add', '--', $sub, 'sub')
                $null = Invoke-OwnedUpdateGit $path @('commit', '-m', 'add submodule', '--quiet')
            }
            $null = Invoke-OwnedUpdateGit $path @('branch', 'behind')
            $upstreamFile = if ($Conflict) { 'README.md' } else { 'upstream.txt' }
            Set-Content -LiteralPath (Join-Path $path $upstreamFile) -Value 'upstream'
            $null = Invoke-OwnedUpdateGit $path @('add', '--', $upstreamFile)
            $null = Invoke-OwnedUpdateGit $path @('commit', '-m', 'advance upstream', '--quiet')
            $null = Invoke-OwnedUpdateGit $path @('switch', 'behind', '--quiet')
            $null = Invoke-OwnedUpdateGit $path @('branch', '--set-upstream-to=main', 'behind')
            $path
        }

        function Save-OwnedUpdatePreviousStash {
            param([string]$Path)
            Set-Content -LiteralPath (Join-Path $Path 'previous.txt') -Value 'unrelated saved work'
            $null = Invoke-OwnedUpdateGit $Path @('stash', 'push', '--include-untracked', '-m', 'previous', '--quiet')
            Invoke-OwnedUpdateGit $Path @('rev-parse', 'refs/stash')
        }
    }

    BeforeEach {
        $ownedCaseRoot = (New-Item -ItemType Directory -Path (
            Join-Path $ownedUpdateRoot ([guid]::NewGuid().ToString('N'))
        ) -ErrorAction Stop).FullName
        $ownedLocationPushed = $false
        Push-Location -LiteralPath $ownedCaseRoot -ErrorAction Stop
        $ownedLocationPushed = $true
        Assert-OwnedUpdatePath (Get-Location).ProviderPath
        Mock -ModuleName Shmuelie.Git Sync-GitRemote { } -ParameterFilter {
            $Path -and [IO.Path]::GetFullPath($Path).StartsWith(
                $ownedCaseRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::Ordinal)
        }
    }

    AfterEach {
        if ($ownedLocationPushed) { Pop-Location }
    }

    AfterAll {
        foreach ($key in $ownedUpdateEnvironment.Keys) {
            if ($null -eq $ownedUpdateEnvironment[$key]) {
                Remove-Item -LiteralPath "Env:$key" -ErrorAction Ignore
            } else {
                [Environment]::SetEnvironmentVariable($key, $ownedUpdateEnvironment[$key], 'Process')
            }
        }
        if ($ownedUpdateRoot -and (Test-Path -LiteralPath $ownedUpdateRoot)) {
            if ((Split-Path $ownedUpdateRoot -Parent) -cne $TestDrive) {
                throw 'Refusing cleanup outside the owned TestDrive root.'
            }
            Remove-Item -LiteralPath $ownedUpdateRoot -Recurse -Force -ErrorAction Stop
        }
    }

    It 'skips a no-op submodule stash with ExistingStash=<ExistingStash>, ChangedOnly=<ChangedOnly>' -ForEach @(
        @{ ExistingStash = $false; ChangedOnly = $false }
        @{ ExistingStash = $true; ChangedOnly = $false }
        @{ ExistingStash = $false; ChangedOnly = $true }
        @{ ExistingStash = $true; ChangedOnly = $true }
    ) {
        $repo = New-OwnedUpdateFixture -Submodule
        if ($ExistingStash) { $previous = Save-OwnedUpdatePreviousStash $repo }
        $head = Invoke-OwnedUpdateGit $repo @('rev-parse', 'HEAD')
        Set-Content -LiteralPath (Join-Path $repo 'sub' 'README.md') -Value 'submodule-only work'

        $results = @(Update-Worktrees -Path $repo -ChangedOnly:$ChangedOnly -NoGitHubAccountResolve -Confirm:$false -WarningVariable warnings)

        $results | Should -HaveCount 1
        $results[0].Status | Should -Be 'StashFailed'
        $results[0].Stashed | Should -BeFalse
        $results[0].PopFailed | Should -BeFalse
        ($warnings -join "`n") | Should -Match 'did not create.*stash'
        Invoke-OwnedUpdateGit $repo @('rev-parse', 'HEAD') | Should -BeExactly $head
        Test-Path -LiteralPath (Join-Path $repo 'previous.txt') | Should -BeFalse
        (Get-Content -LiteralPath (Join-Path $repo 'sub' 'README.md') -Raw).Trim() | Should -BeExactly 'submodule-only work'
        $stashes = @(Invoke-OwnedUpdateGit $repo @('stash', 'list', '--format=%H'))
        if ($ExistingStash) {
            $stashes | Should -Be @($previous)
        } else {
            $stashes | Should -HaveCount 0
        }
    }

    It 'restores ordinary changes and drops only the new stash with ExistingStash=<ExistingStash>' -ForEach @(
        @{ ExistingStash = $false }
        @{ ExistingStash = $true }
    ) {
        $repo = New-OwnedUpdateFixture
        if ($ExistingStash) { $previous = Save-OwnedUpdatePreviousStash $repo }
        Set-Content -LiteralPath (Join-Path $repo 'README.md') -Value 'tracked work'
        Set-Content -LiteralPath (Join-Path $repo 'loose.txt') -Value 'untracked work'

        $results = @(Update-Worktrees -Path $repo -NoGitHubAccountResolve -Confirm:$false)

        $results | Should -HaveCount 1
        $results[0].Status | Should -Be 'Updated'
        $results[0].Stashed | Should -BeTrue
        $results[0].PopFailed | Should -BeFalse
        Invoke-OwnedUpdateGit $repo @('rev-parse', 'HEAD') | Should -BeExactly (Invoke-OwnedUpdateGit $repo @('rev-parse', 'main'))
        (Get-Content -LiteralPath (Join-Path $repo 'README.md') -Raw).Trim() | Should -BeExactly 'tracked work'
        (Get-Content -LiteralPath (Join-Path $repo 'loose.txt') -Raw).Trim() | Should -BeExactly 'untracked work'
        Test-Path -LiteralPath (Join-Path $repo 'previous.txt') | Should -BeFalse
        $stashes = @(Invoke-OwnedUpdateGit $repo @('stash', 'list', '--format=%H'))
        if ($ExistingStash) { $stashes | Should -Be @($previous) }
        else { $stashes | Should -HaveCount 0 }
    }

    It 'retains both owned and pre-existing stashes when restoration conflicts' {
        $repo = New-OwnedUpdateFixture -Conflict
        $previous = Save-OwnedUpdatePreviousStash $repo
        Set-Content -LiteralPath (Join-Path $repo 'README.md') -Value 'conflicting local work'

        $results = @(Update-Worktrees -Path $repo -NoGitHubAccountResolve -Confirm:$false -WarningVariable warnings)

        $results[0].Status | Should -Be 'Updated'
        $results[0].Stashed | Should -BeTrue
        $results[0].PopFailed | Should -BeTrue
        ($warnings -join "`n") | Should -Match 'stash.*failed'
        $stashes = @(Invoke-OwnedUpdateGit $repo @('stash', 'list', '--format=%H'))
        $stashes | Should -HaveCount 2
        $stashes[1] | Should -BeExactly $previous
        Invoke-OwnedUpdateGit $repo @('show', "$($stashes[0]):README.md") | Should -BeExactly 'conflicting local work'
        Test-Path -LiteralPath (Join-Path $repo 'previous.txt') | Should -BeFalse
        @(Invoke-OwnedUpdateGit $repo @('ls-files', '--unmerged')) | Should -Not -BeNullOrEmpty
    }

    It 'keeps dirty linked worktrees and their shared pre-existing stash isolated' {
        $repo = New-OwnedUpdateFixture
        $previous = Save-OwnedUpdatePreviousStash $repo
        $linked = Join-Path $ownedCaseRoot 'linked'
        Assert-OwnedUpdatePath $linked
        $null = Invoke-OwnedUpdateGit $repo @('worktree', 'add', '-b', 'behind-linked', '--', $linked, 'HEAD')
        $null = Invoke-OwnedUpdateGit $repo @('branch', '--set-upstream-to=main', 'behind-linked')
        Set-Content -LiteralPath (Join-Path $repo 'parent-only.txt') -Value 'parent work'
        Set-Content -LiteralPath (Join-Path $linked 'linked-only.txt') -Value 'linked work'

        $results = @(Update-Worktrees -Path $repo -NoGitHubAccountResolve -Confirm:$false)

        $results | Should -HaveCount 2
        foreach ($result in $results) {
            $result.Status | Should -Be 'Updated'
            $result.Stashed | Should -BeTrue
            $result.PopFailed | Should -BeFalse
        }
        (Get-Content -LiteralPath (Join-Path $repo 'parent-only.txt') -Raw).Trim() | Should -BeExactly 'parent work'
        (Get-Content -LiteralPath (Join-Path $linked 'linked-only.txt') -Raw).Trim() | Should -BeExactly 'linked work'
        Test-Path -LiteralPath (Join-Path $repo 'linked-only.txt') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $linked 'parent-only.txt') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $repo 'previous.txt') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $linked 'previous.txt') | Should -BeFalse
        @(Invoke-OwnedUpdateGit $repo @('stash', 'list', '--format=%H')) | Should -Be @($previous)
    }

    It 'does not merge or restore a previous stash when stash creation fails' {
        $repo = New-OwnedUpdateFixture
        $previous = Save-OwnedUpdatePreviousStash $repo
        $head = Invoke-OwnedUpdateGit $repo @('rev-parse', 'HEAD')
        Set-Content -LiteralPath (Join-Path $repo 'README.md') -Value 'unstashed work'
        $lock = Join-Path $repo '.git' 'index.lock'
        $null = New-Item -ItemType File -Path $lock -ErrorAction Stop
        try {
            $results = @(Update-Worktrees -Path $repo -NoGitHubAccountResolve -Confirm:$false -WarningVariable warnings)
        } finally {
            Remove-Item -LiteralPath $lock -ErrorAction Stop
        }

        $results[0].Status | Should -Be 'StashFailed'
        $results[0].Stashed | Should -BeFalse
        $results[0].PopFailed | Should -BeFalse
        ($warnings -join "`n") | Should -Match 'git stash push failed'
        Invoke-OwnedUpdateGit $repo @('rev-parse', 'HEAD') | Should -BeExactly $head
        @(Invoke-OwnedUpdateGit $repo @('stash', 'list', '--format=%H')) | Should -Be @($previous)
        (Get-Content -LiteralPath (Join-Path $repo 'README.md') -Raw).Trim() | Should -BeExactly 'unstashed work'
    }

    It 'restores the captured object and retains the stack when another stash becomes newest' {
        $repo = New-OwnedUpdateFixture
        Set-Content -LiteralPath (Join-Path $repo 'owned.txt') -Value 'owned work'
        $owned = Save-GitStash -Path $repo -IncludeUntracked -Confirm:$false
        $other = Save-OwnedUpdatePreviousStash $repo

        $restored = InModuleScope Shmuelie.Git -Parameters @{ Repo = $repo; ObjectId = $owned.ObjectId } {
            Restore-WorktreeUpdateStash -Path $Repo -ObjectId $ObjectId -WarningVariable restoreWarnings
        }

        $restored | Should -BeFalse
        (Get-Content -LiteralPath (Join-Path $repo 'owned.txt') -Raw).Trim() | Should -BeExactly 'owned work'
        Test-Path -LiteralPath (Join-Path $repo 'previous.txt') | Should -BeFalse
        @(Invoke-OwnedUpdateGit $repo @('stash', 'list', '--format=%H')) | Should -Be @($other, $owned.ObjectId)
    }

    It 'rejects a saved identity whose message belongs to a different writer' {
        $repo = New-OwnedUpdateFixture
        $previous = Save-OwnedUpdatePreviousStash $repo
        $head = Invoke-OwnedUpdateGit $repo @('rev-parse', 'HEAD')
        Set-Content -LiteralPath (Join-Path $repo 'README.md') -Value 'unsaved local work'
        Mock -ModuleName Shmuelie.Git Save-GitStash {
            [PSCustomObject]@{
                ObjectId = $previous
                RepositoryPath = $repo
                Subject = 'On behind: a different writer'
            }
        } -ParameterFilter { $Path -eq $repo -and $IncludeUntracked }

        $results = @(Update-Worktrees -Path $repo -NoGitHubAccountResolve -Confirm:$false -WarningVariable warnings)

        $results[0].Status | Should -Be 'StashFailed'
        $results[0].Stashed | Should -BeFalse
        ($warnings -join "`n") | Should -Match 'not created by this update'
        Invoke-OwnedUpdateGit $repo @('rev-parse', 'HEAD') | Should -BeExactly $head
        @(Invoke-OwnedUpdateGit $repo @('stash', 'list', '--format=%H')) | Should -Be @($previous)
        (Get-Content -LiteralPath (Join-Path $repo 'README.md') -Raw).Trim() | Should -BeExactly 'unsaved local work'
        Test-Path -LiteralPath (Join-Path $repo 'previous.txt') | Should -BeFalse
    }

    It 'retains the owned stash when cleanup fails after successful restoration' {
        $repo = New-OwnedUpdateFixture
        $previous = Save-OwnedUpdatePreviousStash $repo
        Set-Content -LiteralPath (Join-Path $repo 'owned.txt') -Value 'owned work'
        $owned = Save-GitStash -Path $repo -IncludeUntracked -Confirm:$false
        $lock = Join-Path $repo '.git' 'refs' 'stash.lock'
        $null = New-Item -ItemType File -Path $lock -ErrorAction Stop
        try {
            $restored = InModuleScope Shmuelie.Git -Parameters @{ Repo = $repo; ObjectId = $owned.ObjectId } {
                Restore-WorktreeUpdateStash -Path $Repo -ObjectId $ObjectId
            }
        } finally {
            Remove-Item -LiteralPath $lock -ErrorAction Stop
        }

        $restored | Should -BeFalse
        (Get-Content -LiteralPath (Join-Path $repo 'owned.txt') -Raw).Trim() | Should -BeExactly 'owned work'
        Test-Path -LiteralPath (Join-Path $repo 'previous.txt') | Should -BeFalse
        @(Invoke-OwnedUpdateGit $repo @('stash', 'list', '--format=%H')) | Should -Be @($owned.ObjectId, $previous)
    }

    It 'does not create or restore stashes during WhatIf' {
        $repo = New-OwnedUpdateFixture
        $previous = Save-OwnedUpdatePreviousStash $repo
        $head = Invoke-OwnedUpdateGit $repo @('rev-parse', 'HEAD')
        Set-Content -LiteralPath (Join-Path $repo 'README.md') -Value 'preview work'

        @(Update-Worktrees -Path $repo -NoGitHubAccountResolve -WhatIf) | Should -HaveCount 0

        Invoke-OwnedUpdateGit $repo @('rev-parse', 'HEAD') | Should -BeExactly $head
        @(Invoke-OwnedUpdateGit $repo @('stash', 'list', '--format=%H')) | Should -Be @($previous)
        (Get-Content -LiteralPath (Join-Path $repo 'README.md') -Raw).Trim() | Should -BeExactly 'preview work'
    }
}

Describe 'Update-Worktrees' {
    It 'keeps each dirty worktree change with its own worktree while fast-forwarding' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
        $origin = Join-Path $TestDrive 'origin.git'
        Invoke-Git @('init', '--bare', '-b', 'main', '--quiet', $origin)

        $seed = Join-Path $TestDrive 'seed'
        Invoke-Git @('clone', '--quiet', $origin, $seed)
        Set-TestRepoConfig $seed
        Set-Content -Path (Join-Path $seed 'README.md') -Value 'initial' -NoNewline
        Invoke-Git @('-C', $seed, 'add', 'README.md')
        Invoke-TestCommit -Path $seed -Message 'init'
        Invoke-Git @('-C', $seed, 'push', '-u', 'origin', 'main', '--quiet')

        Invoke-Git @('-C', $seed, 'switch', '-c', 'branch-a', '--quiet')
        Set-Content -Path (Join-Path $seed 'tracked-a.txt') -Value 'branch-a v1' -NoNewline
        Invoke-Git @('-C', $seed, 'add', 'tracked-a.txt')
        Invoke-TestCommit -Path $seed -Message 'branch a v1'
        Invoke-Git @('-C', $seed, 'push', '-u', 'origin', 'branch-a', '--quiet')
        Invoke-Git @('-C', $seed, 'branch', '--set-upstream-to=origin/branch-a', 'branch-a')

        Invoke-Git @('-C', $seed, 'switch', 'main', '--quiet')
        Invoke-Git @('-C', $seed, 'switch', '-c', 'branch-b', '--quiet')
        Set-Content -Path (Join-Path $seed 'tracked-b.txt') -Value 'branch-b v1' -NoNewline
        Invoke-Git @('-C', $seed, 'add', 'tracked-b.txt')
        Invoke-TestCommit -Path $seed -Message 'branch b v1'
        Invoke-Git @('-C', $seed, 'push', '-u', 'origin', 'branch-b', '--quiet')
        Invoke-Git @('-C', $seed, 'branch', '--set-upstream-to=origin/branch-b', 'branch-b')

        $clone = Join-Path $TestDrive 'clone'
        Invoke-Git @('clone', '--quiet', $origin, $clone)
        Set-TestRepoConfig $clone
        $worktreeA = Join-Path $TestDrive 'worktree-a'
        $worktreeB = Join-Path $TestDrive 'worktree-b'
        Invoke-Git @('-C', $clone, 'worktree', 'add', '--quiet', '--track', '-b', 'branch-a', $worktreeA, 'origin/branch-a')
        Invoke-Git @('-C', $clone, 'worktree', 'add', '--quiet', '--track', '-b', 'branch-b', $worktreeB, 'origin/branch-b')
        Set-TestRepoConfig $worktreeA
        Set-TestRepoConfig $worktreeB

        $updater = Join-Path $TestDrive 'updater'
        Invoke-Git @('clone', '--quiet', $origin, $updater)
        Set-TestRepoConfig $updater

        Invoke-Git @('-C', $updater, 'switch', 'branch-a', '--quiet')
        Set-Content -Path (Join-Path $updater 'tracked-a.txt') -Value 'branch-a v2' -NoNewline
        Invoke-Git @('-C', $updater, 'add', 'tracked-a.txt')
        Invoke-TestCommit -Path $updater -Message 'branch a v2'
        Invoke-Git @('-C', $updater, 'push', 'origin', 'branch-a', '--quiet')

        Invoke-Git @('-C', $updater, 'switch', 'branch-b', '--quiet')
        Set-Content -Path (Join-Path $updater 'tracked-b.txt') -Value 'branch-b v2' -NoNewline
        Invoke-Git @('-C', $updater, 'add', 'tracked-b.txt')
        Invoke-TestCommit -Path $updater -Message 'branch b v2'
        Invoke-Git @('-C', $updater, 'push', 'origin', 'branch-b', '--quiet')

        Invoke-Git @('-C', $clone, 'fetch', '--all', '--prune')
        Invoke-Git @('-C', $clone, 'rev-list', '--count', 'branch-a..origin/branch-a') | Should -Be '1'
        Invoke-Git @('-C', $clone, 'rev-list', '--count', 'branch-b..origin/branch-b') | Should -Be '1'

        Set-Content -Path (Join-Path $worktreeA 'local-a.txt') -Value 'local change from worktree A' -NoNewline
        Set-Content -Path (Join-Path $worktreeB 'local-b.txt') -Value 'local change from worktree B' -NoNewline

        $realGit = (Get-Command git -CommandType Application | Select-Object -First 1).Source
        $shimDir = Join-Path $TestDrive 'git-shim'
        $shimState = Join-Path $TestDrive 'stash-race-state'
        New-Item -ItemType Directory -Path $shimDir, $shimState -Force | Out-Null
        $shimProject = Join-Path $TestDrive 'git-shim-src'
        New-Item -ItemType Directory -Path $shimProject -Force | Out-Null
        Set-Content -Path (Join-Path $shimProject 'git-shim.csproj') -Value @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net8.0</TargetFramework>
    <AssemblyName>git</AssemblyName>
    <UseAppHost>true</UseAppHost>
    <Nullable>disable</Nullable>
  </PropertyGroup>
</Project>
'@
        Set-Content -Path (Join-Path $shimProject 'Program.cs') -Value @'
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;

public static class GitShim
{
    public static int Main(string[] args)
    {
        string realGit = Environment.GetEnvironmentVariable("SHMUELIE_REAL_GIT");
        string state = Environment.GetEnvironmentVariable("SHMUELIE_STASH_RACE_STATE");
        if (String.IsNullOrEmpty(realGit))
        {
            Console.Error.WriteLine("SHMUELIE_REAL_GIT is not set.");
            return 1;
        }

        if (!String.IsNullOrEmpty(state) && args.Length >= 2 && args[0] == "stash" && args[1] == "push")
        {
            int exitCode = Run(realGit, args);
            if (exitCode == 0)
            {
                string current = Directory.GetCurrentDirectory();
                int slot = 0;
                while (slot == 0)
                {
                    foreach (int candidate in new[] { 1, 2 })
                    {
                        try
                        {
                            WriteMarker(Path.Combine(state, "push-" + candidate + ".txt"), current);
                            slot = candidate;
                            break;
                        }
                        catch (IOException)
                        {
                        }
                    }

                    if (slot == 0)
                    {
                        Thread.Sleep(10);
                    }
                }

                WaitForTwoPushes(state);
            }

            return exitCode;
        }

        if (!String.IsNullOrEmpty(state) && args.Length >= 2 && args[0] == "stash" && args[1] == "pop")
        {
            string current = Directory.GetCurrentDirectory();
            string[] pushes = Directory.GetFiles(state, "push-*.txt");
            if (pushes.Length >= 2)
            {
                string first = File.ReadAllText(Path.Combine(state, "push-1.txt"));
                string second = File.ReadAllText(Path.Combine(state, "push-2.txt"));
                if (String.Equals(current, second, StringComparison.OrdinalIgnoreCase))
                {
                    DateTime deadline = DateTime.UtcNow.AddSeconds(10);
                    string firstPopped = Path.Combine(state, "first-popped.txt");
                    while (!File.Exists(firstPopped) && DateTime.UtcNow < deadline)
                    {
                        Thread.Sleep(25);
                    }
                }

                int exitCode = Run(realGit, args);

                if (String.Equals(current, first, StringComparison.OrdinalIgnoreCase))
                {
                    try
                    {
                        WriteMarker(Path.Combine(state, "first-popped.txt"), current);
                    }
                    catch (IOException)
                    {
                    }
                }
                else if (String.Equals(current, second, StringComparison.OrdinalIgnoreCase))
                {
                    ClearPushMarkers(state);
                }

                return exitCode;
            }

            int singleExitCode = Run(realGit, args);
            ClearPushMarkers(state);
            return singleExitCode;
        }

        return Run(realGit, args);
    }

    private static int Run(string realGit, string[] args)
    {
        ProcessStartInfo startInfo = new ProcessStartInfo(realGit);
        startInfo.UseShellExecute = false;
        startInfo.RedirectStandardOutput = true;
        startInfo.RedirectStandardError = true;
        startInfo.Arguments = String.Join(" ", Array.ConvertAll(args, QuoteArgument));

        using (Process process = Process.Start(startInfo))
        {
            string output = process.StandardOutput.ReadToEnd();
            string error = process.StandardError.ReadToEnd();
            process.WaitForExit();
            Console.Out.Write(output);
            Console.Error.Write(error);
            return process.ExitCode;
        }
    }

    private static string QuoteArgument(string argument)
    {
        if (String.IsNullOrEmpty(argument))
        {
            return "\"\"";
        }

        if (argument.IndexOfAny(new[] { ' ', '\t', '\n', '\v', '"' }) < 0)
        {
            return argument;
        }

        StringBuilder builder = new StringBuilder();
        builder.Append('"');
        int backslashes = 0;
        foreach (char character in argument)
        {
            if (character == '\\')
            {
                backslashes++;
            }
            else if (character == '"')
            {
                builder.Append('\\', (backslashes * 2) + 1);
                builder.Append('"');
                backslashes = 0;
            }
            else
            {
                builder.Append('\\', backslashes);
                backslashes = 0;
                builder.Append(character);
            }
        }

        builder.Append('\\', backslashes * 2);
        builder.Append('"');
        return builder.ToString();
    }

    private static void WaitForTwoPushes(string state)
    {
        DateTime deadline = DateTime.UtcNow.AddSeconds(2);
        do
        {
            if (Directory.GetFiles(state, "push-*.txt").Length >= 2)
            {
                return;
            }

            Thread.Sleep(25);
        } while (DateTime.UtcNow < deadline);
    }

    private static void WriteMarker(string path, string content)
    {
        using (FileStream stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.Read))
        using (StreamWriter writer = new StreamWriter(stream))
        {
            writer.Write(content);
        }
    }

    private static void ClearPushMarkers(string state)
    {
        foreach (string path in new[]
        {
            Path.Combine(state, "push-1.txt"),
            Path.Combine(state, "push-2.txt"),
            Path.Combine(state, "first-popped.txt")
        })
        {
            try
            {
                File.Delete(path);
            }
            catch
            {
            }
        }
    }
}
'@
        $csc = Get-Command csc -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($csc) {
            $compileOutput = & $csc.Source -nologo -target:exe "-out:$(Join-Path $shimDir 'git.exe')" (Join-Path $shimProject 'Program.cs') 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "csc failed (exit $LASTEXITCODE): $compileOutput"
            }
        } else {
            $dotnet = Get-Command dotnet -CommandType Application -ErrorAction SilentlyContinue
            $dotnet | Should -Not -BeNullOrEmpty
            $publishOutput = & $dotnet.Source publish (Join-Path $shimProject 'git-shim.csproj') -c Release -o $shimDir --nologo -v q 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "dotnet publish failed (exit $LASTEXITCODE): $publishOutput"
            }
        }

        $oldPath = $env:PATH
        $oldRealGit = $env:SHMUELIE_REAL_GIT
        $oldRaceState = $env:SHMUELIE_STASH_RACE_STATE
        $oldGitTerminalPrompt = $env:GIT_TERMINAL_PROMPT
        $oldGitConfigCount = $env:GIT_CONFIG_COUNT
        $oldGitConfigKey0 = $env:GIT_CONFIG_KEY_0
        $oldGitConfigValue0 = $env:GIT_CONFIG_VALUE_0
        $env:PATH = "$shimDir$([System.IO.Path]::PathSeparator)$oldPath"
        $env:SHMUELIE_REAL_GIT = $realGit
        $env:SHMUELIE_STASH_RACE_STATE = $shimState
        $env:GIT_TERMINAL_PROMPT = '0'
        $env:GIT_CONFIG_COUNT = '1'
        $env:GIT_CONFIG_KEY_0 = 'protocol.file.allow'
        $env:GIT_CONFIG_VALUE_0 = 'always'

        Mock -ModuleName Shmuelie.Git Sync-GitRemote { @() }

        Push-Location $clone
        try {
            $results = Update-Worktrees -NoGitHubAccountResolve
        } finally {
            Pop-Location
            $env:PATH = $oldPath
            $env:SHMUELIE_REAL_GIT = $oldRealGit
            $env:SHMUELIE_STASH_RACE_STATE = $oldRaceState
            $env:GIT_TERMINAL_PROMPT = $oldGitTerminalPrompt
            $env:GIT_CONFIG_COUNT = $oldGitConfigCount
            $env:GIT_CONFIG_KEY_0 = $oldGitConfigKey0
            $env:GIT_CONFIG_VALUE_0 = $oldGitConfigValue0
        }

        foreach ($branch in 'branch-a', 'branch-b') {
            $result = $results | Where-Object Branch -eq $branch
            $result.Status | Should -Be 'Updated'
            $result.Stashed | Should -BeTrue
            $result.PopFailed | Should -BeFalse
            $result.BehindBy | Should -Be 1
        }

        Get-Content -LiteralPath (Join-Path $worktreeA 'tracked-a.txt') -Raw | Should -BeExactly 'branch-a v2'
        Get-Content -LiteralPath (Join-Path $worktreeB 'tracked-b.txt') -Raw | Should -BeExactly 'branch-b v2'
        Get-Content -LiteralPath (Join-Path $worktreeA 'local-a.txt') -Raw | Should -BeExactly 'local change from worktree A'
        Get-Content -LiteralPath (Join-Path $worktreeB 'local-b.txt') -Raw | Should -BeExactly 'local change from worktree B'
        Test-Path -LiteralPath (Join-Path $worktreeA 'local-b.txt') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $worktreeB 'local-a.txt') | Should -BeFalse
    }

    It 'reports Current for a worktree that is already up to date' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
        $origin = Join-Path $TestDrive 'current-origin.git'
        Invoke-Git @('init', '--bare', '-b', 'main', '--quiet', $origin)

        $seed = Join-Path $TestDrive 'current-seed'
        Invoke-Git @('clone', '--quiet', $origin, $seed)
        Set-TestRepoConfig $seed
        Set-Content -Path (Join-Path $seed 'README.md') -Value 'initial' -NoNewline
        Invoke-Git @('-C', $seed, 'add', 'README.md')
        Invoke-TestCommit -Path $seed -Message 'init'
        Invoke-Git @('-C', $seed, 'push', '-u', 'origin', 'main', '--quiet')

        $clone = Join-Path $TestDrive 'current-clone'
        Invoke-Git @('clone', '--quiet', $origin, $clone)
        Set-TestRepoConfig $clone

        Mock -ModuleName Shmuelie.Git Sync-GitRemote { @() }

        Push-Location $clone
        try {
            $results = Update-Worktrees -NoGitHubAccountResolve
        } finally {
            Pop-Location
        }

        $result = @($results | Where-Object Branch -eq 'main')
        $result | Should -HaveCount 1
        $result[0].Status | Should -Be 'Current'
        $result[0].BehindBy | Should -Be 0
        $result[0].Stashed | Should -BeFalse
    }

    It 'reports NoUpstream for a worktree without an upstream branch' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
        $origin = Join-Path $TestDrive 'no-upstream-origin.git'
        Invoke-Git @('init', '--bare', '-b', 'main', '--quiet', $origin)

        $seed = Join-Path $TestDrive 'no-upstream-seed'
        Invoke-Git @('clone', '--quiet', $origin, $seed)
        Set-TestRepoConfig $seed
        Set-Content -Path (Join-Path $seed 'README.md') -Value 'initial' -NoNewline
        Invoke-Git @('-C', $seed, 'add', 'README.md')
        Invoke-TestCommit -Path $seed -Message 'init'
        Invoke-Git @('-C', $seed, 'push', '-u', 'origin', 'main', '--quiet')

        $clone = Join-Path $TestDrive 'no-upstream-clone'
        Invoke-Git @('clone', '--quiet', $origin, $clone)
        Set-TestRepoConfig $clone
        Invoke-Git @('-C', $clone, 'branch', 'local-only')
        $worktree = Join-Path $TestDrive 'no-upstream-worktree'
        Invoke-Git @('-C', $clone, 'worktree', 'add', '--quiet', $worktree, 'local-only')
        Set-TestRepoConfig $worktree

        Mock -ModuleName Shmuelie.Git Sync-GitRemote { @() }

        Push-Location $clone
        try {
            $results = Update-Worktrees -NoGitHubAccountResolve
        } finally {
            Pop-Location
        }

        $result = @($results | Where-Object Branch -eq 'local-only')
        $result | Should -HaveCount 1
        $result[0].Status | Should -Be 'NoUpstream'
        $result[0].BehindBy | Should -Be 0
        $result[0].Stashed | Should -BeFalse
    }

    It 'leaves NoUpstream worktrees unclassified and warns when -CheckRemote cannot reach the remote (ChangedOnly=<ChangedOnly>)' -ForEach @(
        @{ ChangedOnly = $false }
        @{ ChangedOnly = $true }
    ) -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
        $clone = Join-Path $TestDrive "checkremote-unreachable-$ChangedOnly-clone"
        New-TestRepo -Path $clone | Out-Null
        # Origin points at a path that is not a git repository, so the
        # -CheckRemote ls-remote call fails rather than returning an empty set.
        $missing = Join-Path $TestDrive "checkremote-unreachable-$ChangedOnly-missing"
        $missingUrl = 'file:///' + (($missing -replace '\\', '/'))
        Invoke-Git @('-C', $clone, 'remote', 'add', 'origin', $missingUrl)
        Invoke-Git @('-C', $clone, 'branch', 'local-only')
        $worktree = Join-Path $TestDrive "checkremote-unreachable-$ChangedOnly-worktree"
        Invoke-Git @('-C', $clone, 'worktree', 'add', '--quiet', $worktree, 'local-only')
        Set-TestRepoConfig $worktree

        Mock -ModuleName Shmuelie.Git Sync-GitRemote { @() }

        Push-Location $clone
        try {
            $results = @(Update-Worktrees -CheckRemote -ChangedOnly:$ChangedOnly -NoGitHubAccountResolve -WarningVariable checkWarnings)
        } finally {
            Pop-Location
        }

        $result = @($results | Where-Object Branch -eq 'local-only')
        if ($ChangedOnly) {
            @($results) | Should -HaveCount 0
        } else {
            $result | Should -HaveCount 1
            # The unreachable remote must NOT cause a false 'Removed' classification.
            $result[0].Status | Should -Be 'NoUpstream'
        }
        ($checkWarnings | ForEach-Object { "$_" }) -join "`n" | Should -Match 'ls-remote failed'
    }

    It 'reports Updated for a clean fast-forwarded worktree' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
        $origin = Join-Path $TestDrive 'clean-update-origin.git'
        Invoke-Git @('init', '--bare', '-b', 'main', '--quiet', $origin)

        $seed = Join-Path $TestDrive 'clean-update-seed'
        Invoke-Git @('clone', '--quiet', $origin, $seed)
        Set-TestRepoConfig $seed
        Set-Content -Path (Join-Path $seed 'README.md') -Value 'initial' -NoNewline
        Invoke-Git @('-C', $seed, 'add', 'README.md')
        Invoke-TestCommit -Path $seed -Message 'init'
        Invoke-Git @('-C', $seed, 'push', '-u', 'origin', 'main', '--quiet')

        $clone = Join-Path $TestDrive 'clean-update-clone'
        Invoke-Git @('clone', '--quiet', $origin, $clone)
        Set-TestRepoConfig $clone

        $updater = Join-Path $TestDrive 'clean-update-updater'
        Invoke-Git @('clone', '--quiet', $origin, $updater)
        Set-TestRepoConfig $updater
        Set-Content -Path (Join-Path $updater 'README.md') -Value 'updated' -NoNewline
        Invoke-Git @('-C', $updater, 'add', 'README.md')
        Invoke-TestCommit -Path $updater -Message 'update readme'
        Invoke-Git @('-C', $updater, 'push', 'origin', 'main', '--quiet')

        Invoke-Git @('-C', $clone, 'fetch', '--all', '--prune')
        Invoke-Git @('-C', $clone, 'rev-list', '--count', 'main..origin/main') | Should -Be '1'

        Mock -ModuleName Shmuelie.Git Sync-GitRemote { @() }

        Push-Location $clone
        try {
            $results = Update-Worktrees -NoGitHubAccountResolve
        } finally {
            Pop-Location
        }

        $result = @($results | Where-Object Branch -eq 'main')
        $result | Should -HaveCount 1
        $result[0].Status | Should -Be 'Updated'
        $result[0].BehindBy | Should -Be 1
        $result[0].Stashed | Should -BeFalse
        $result[0].PopFailed | Should -BeFalse
        Get-Content -LiteralPath (Join-Path $clone 'README.md') -Raw | Should -BeExactly 'updated'
    }

    $inProgressCases = @(
        @{
            Name              = 'merge'
            ExpectedOperation = 'MERGING'
            SetupSentinel     = {
                param($GitDir, $RepositoryPath)

                $head = Invoke-Git @('-C', $RepositoryPath, 'rev-parse', 'HEAD')
                $sentinelPath = Join-Path $GitDir 'MERGE_HEAD'
                Set-Content -Path $sentinelPath -Value $head -NoNewline
                [PSCustomObject]@{
                    Path    = $sentinelPath
                    Content = $head
                }
            }
        }
        @{
            Name              = 'interactive rebase'
            ExpectedOperation = 'REBASE-i 1/3'
            SetupSentinel     = {
                param($GitDir)

                $rebase = Join-Path $GitDir 'rebase-merge'
                New-Item -ItemType Directory -Path $rebase -Force | Out-Null
                New-Item -ItemType File -Path (Join-Path $rebase 'interactive') -Force | Out-Null
                Set-Content -Path (Join-Path $rebase 'msgnum') -Value '1' -NoNewline
                Set-Content -Path (Join-Path $rebase 'end') -Value '3' -NoNewline
                $sentinelPath = Join-Path $rebase 'operation-marker.txt'
                Set-Content -Path $sentinelPath -Value 'rebase in progress' -NoNewline
                [PSCustomObject]@{
                    Path    = $sentinelPath
                    Content = 'rebase in progress'
                }
            }
        }
    )

    It 'reports InProgress and leaves a behind <Name> worktree untouched' -ForEach $inProgressCases -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
        $safeName = $Name -replace '[^a-z0-9]+', '-'
        $origin = Join-Path $TestDrive "in-progress-$safeName-origin.git"
        Invoke-Git @('init', '--bare', '-b', 'main', '--quiet', $origin)

        $seed = Join-Path $TestDrive "in-progress-$safeName-seed"
        Invoke-Git @('clone', '--quiet', $origin, $seed)
        Set-TestRepoConfig $seed
        Set-Content -Path (Join-Path $seed 'README.md') -Value 'initial' -NoNewline
        Invoke-Git @('-C', $seed, 'add', 'README.md')
        Invoke-TestCommit -Path $seed -Message 'init'
        Invoke-Git @('-C', $seed, 'push', '-u', 'origin', 'main', '--quiet')

        $clone = Join-Path $TestDrive "in-progress-$safeName-clone"
        Invoke-Git @('clone', '--quiet', $origin, $clone)
        Set-TestRepoConfig $clone

        $updater = Join-Path $TestDrive "in-progress-$safeName-updater"
        Invoke-Git @('clone', '--quiet', $origin, $updater)
        Set-TestRepoConfig $updater
        Set-Content -Path (Join-Path $updater 'README.md') -Value 'updated' -NoNewline
        Invoke-Git @('-C', $updater, 'add', 'README.md')
        Invoke-TestCommit -Path $updater -Message 'update readme'
        Invoke-Git @('-C', $updater, 'push', 'origin', 'main', '--quiet')

        Invoke-Git @('-C', $clone, 'fetch', '--all', '--prune')
        Invoke-Git @('-C', $clone, 'rev-list', '--count', 'main..origin/main') | Should -Be '1'

        Set-Content -Path (Join-Path $clone 'local.txt') -Value 'local work' -NoNewline
        $gitDir = Get-TestGitDir -Path $clone
        $sentinel = & $SetupSentinel $gitDir $clone
        $readmeBefore = Get-Content -LiteralPath (Join-Path $clone 'README.md') -Raw
        $localBefore = Get-Content -LiteralPath (Join-Path $clone 'local.txt') -Raw
        $stashBefore = @(Invoke-Git @('-C', $clone, 'stash', 'list')).Count

        Mock -ModuleName Shmuelie.Git Sync-GitRemote { @() }

        Push-Location $clone
        try {
            $results = Update-Worktrees -NoGitHubAccountResolve
        } finally {
            Pop-Location
        }

        $result = @($results | Where-Object Branch -eq 'main')
        $result | Should -HaveCount 1
        $result[0].Status | Should -Be 'InProgress'
        $result[0].Status | Should -Not -Be 'Updated'
        $result[0].Status | Should -Not -Be 'Failed'
        $result[0].Operation | Should -Be $ExpectedOperation
        $result[0].BehindBy | Should -Be 1
        $result[0].Stashed | Should -BeFalse
        $result[0].PopFailed | Should -BeFalse

        Get-Content -LiteralPath (Join-Path $clone 'README.md') -Raw | Should -BeExactly $readmeBefore
        Get-Content -LiteralPath (Join-Path $clone 'local.txt') -Raw | Should -BeExactly $localBefore
        Get-Content -LiteralPath $sentinel.Path -Raw | Should -BeExactly $sentinel.Content
        @(Invoke-Git @('-C', $clone, 'stash', 'list')).Count | Should -Be $stashBefore
        Invoke-Git @('-C', $clone, 'rev-list', '--count', 'main..origin/main') | Should -Be '1'
    }
}


Describe 'Format-GitStatusSegment' {
    BeforeAll {
        # Build a synthetic GitStatusSummary so the formatter can be exercised
        # without a real repository: the formatter's contract is its input object,
        # not the git CLI. Each -ForEach case below overrides just the properties
        # for one rendering rule (relation indicator, index/working counts,
        # untracked folding, conflicts, operation) and asserts the rendered token.
        function New-Summary {
            param([hashtable]$Override = @{})
            $props = @{
                PSTypeName      = 'GitStatusSummary'
                IsGitRepo       = $true
                Branch          = 'main'
                Upstream        = 'origin/main'
                UpstreamGone    = $false
                Operation       = $null
                AheadBy         = 0
                BehindBy        = 0
                IndexAdded      = 0
                IndexModified   = 0
                IndexDeleted    = 0
                WorkingAdded    = 0
                WorkingModified = 0
                WorkingDeleted  = 0
                Untracked       = 0
                Conflicts       = 0
            }
            foreach ($key in $Override.Keys) { $props[$key] = $Override[$key] }
            [PSCustomObject]$props
        }

        function ConvertTo-PlainText {
            param([string]$Value)
            $Value -replace "$([char]0x1b)\[[0-9;]*m", ''
        }
    }

    It 'returns an empty string when the summary is not a git repo' {
        Format-GitStatusSegment -Status (New-Summary @{ IsGitRepo = $false }) | Should -BeExactly ''
    }

    It 'accepts pipeline input' {
        (New-Summary | Format-GitStatusSegment) | Should -Match 'main'
    }

    $relationCases = @(
        @{
            Name        = 'diverged branch with StatusString order'
            Override    = @{ AheadBy = 1; BehindBy = 4 }
            Contains    = "$([char]0x2193)4 $([char]0x2191)1"
            NotContains = "$([char]0x2191)1$([char]0x2193)4"
        }
        @{
            Name        = 'ahead-only branch'
            Override    = @{ AheadBy = 2 }
            Contains    = "$([char]0x2191)2"
            NotContains = "$([char]0x2193)2 $([char]0x2191)2"
        }
        @{
            Name        = 'behind-only branch'
            Override    = @{ BehindBy = 3 }
            Contains    = "$([char]0x2193)3"
            NotContains = "$([char]0x2193)3 $([char]0x2191)3"
        }
        @{
            Name        = 'up-to-date branch'
            Override    = @{}
            Contains    = "$([char]0x2261)"
            NotContains = "$([char]0x2191)"
        }
        @{
            Name        = 'gone upstream'
            Override    = @{ UpstreamGone = $true }
            Contains    = "$([char]0x00D7)"
            NotContains = "$([char]0x2261)"
        }
    )

    It 'renders the <Name> relation' -ForEach $relationCases {
        $plain = ConvertTo-PlainText (Format-GitStatusSegment -Status (New-Summary $Override))
        $plain | Should -Match ([regex]::Escape($Contains))
        $plain | Should -Not -Match ([regex]::Escape($NotContains))
    }

    $segmentCases = @(
        @{
            Name        = 'clean tracked branch (up-to-date relation)'
            Override    = @{}
            Contains    = @('main', "$([char]0x2261)")
            NotContains = @()
        }
        @{
            Name        = 'ahead of upstream'
            Override    = @{ AheadBy = 2 }
            Contains    = @("$([char]0x2191)2")
            NotContains = @()
        }
        @{
            Name        = 'behind upstream'
            Override    = @{ BehindBy = 3 }
            Contains    = @("$([char]0x2193)3")
            NotContains = @()
        }
        @{
            Name        = 'diverged (ahead and behind)'
            Override    = @{ AheadBy = 1; BehindBy = 2 }
            Contains    = @("$([char]0x2193)2 $([char]0x2191)1")
            NotContains = @("$([char]0x2191)1$([char]0x2193)2")
        }
        @{
            Name        = 'gone upstream'
            Override    = @{ UpstreamGone = $true }
            Contains    = @("$([char]0x00D7)")
            NotContains = @()
        }
        @{
            Name        = 'staged (index) change counts'
            Override    = @{ IndexAdded = 1; IndexModified = 2; IndexDeleted = 0 }
            Contains    = @('+1 ~2 -0')
            NotContains = @()
        }
        @{
            Name        = 'working counts fold untracked into added'
            Override    = @{ WorkingModified = 3; Untracked = 2; WorkingAdded = 1 }
            Contains    = @('+3 ~3 -0')
            NotContains = @()
        }
        @{
            Name        = 'conflicts marker'
            Override    = @{ Conflicts = 2 }
            Contains    = @('!2')
            NotContains = @()
        }
        @{
            Name        = 'in-progress operation'
            Override    = @{ Operation = 'REBASE 1/3' }
            Contains    = @('|REBASE 1/3')
            NotContains = @()
        }
    )

    It 'renders <Name>' -ForEach $segmentCases {
        $out = Format-GitStatusSegment -Status (New-Summary $Override)
        foreach ($token in $Contains) { $out | Should -Match ([regex]::Escape($token)) }
        foreach ($token in $NotContains) { $out | Should -Not -Match ([regex]::Escape($token)) }
    }

    It 'omits change counts when -ShowChangeCounts is false' {
        $out = Format-GitStatusSegment -Status (New-Summary @{ IndexAdded = 5 }) -ShowChangeCounts:$false
        $out | Should -Match 'main'
        $out | Should -Not -Match ([regex]::Escape('+5'))
    }
}

Describe 'Git explicit Path context' {
    BeforeAll {
        $pathContextLocation = Get-Location
        $pathContextRoot = Join-Path $TestDrive 'path-context'
        $null = New-Item -ItemType Directory -Path $pathContextRoot -ErrorAction Stop
        $pathContextEnvironment = @{}
        foreach ($key in @('GIT_CONFIG_GLOBAL', 'GIT_CONFIG_SYSTEM', 'GIT_CONFIG_NOSYSTEM',
            'GIT_CONFIG_COUNT', 'GIT_CONFIG_PARAMETERS', 'GIT_DIR', 'GIT_WORK_TREE',
            'GIT_COMMON_DIR', 'GIT_INDEX_FILE', 'GIT_OBJECT_DIRECTORY', 'GIT_ALTERNATE_OBJECT_DIRECTORIES')) {
            $pathContextEnvironment[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
            Remove-Item -LiteralPath "Env:$key" -ErrorAction Ignore
        }
        $env:GIT_CONFIG_GLOBAL = Join-Path $pathContextRoot 'no-global'
        $env:GIT_CONFIG_SYSTEM = Join-Path $pathContextRoot 'no-system'
        $env:GIT_CONFIG_NOSYSTEM = '1'
        $env:GIT_CONFIG_COUNT = '0'
        $contextA = New-TestRepo -Path (Join-Path $pathContextRoot 'a')
        $contextB = New-TestRepo -Path (Join-Path $pathContextRoot 'b [literal]')
        $contextOutside = Join-Path $pathContextRoot 'outside'
        $null = New-Item -ItemType Directory -Path $contextOutside -ErrorAction Stop
        Invoke-Git @('-C', $contextA, 'branch', 'feature/a-only')
        Invoke-Git @('-C', $contextB, 'branch', 'feature/b-only')
        Invoke-Git @('-C', $contextB, 'branch', 'feature/price$tag')
        Invoke-Git @('-C', $contextB, 'branch', "feature/quote'branch")
        $contextLinked = Join-Path $pathContextRoot 'linked [b]'
        Invoke-Git @('-C', $contextB, 'worktree', 'add', '--quiet', '-b', 'feature/b-tree', $contextLinked)
        $contextDetached = Join-Path $pathContextRoot 'detached'
        Invoke-Git @('-C', $contextB, 'worktree', 'add', '--quiet', '--detach', $contextDetached, 'HEAD')

        function Get-ContextCompletions {
            param([string]$Line)
            $cursor = $Line.IndexOf('feature/') + 'feature/'.Length
            @((TabExpansion2 -InputScript $Line -CursorColumn $cursor).CompletionMatches |
                Where-Object ResultType -EQ ParameterValue)
        }

        function New-ContextTarget {
            $branch = 'target-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
            $path = Join-Path $pathContextRoot $branch
            Invoke-Git @('-C', $contextA, 'branch', $branch)
            Invoke-Git @('-C', $contextB, 'worktree', 'add', '--quiet', '-b', $branch, $path)
            [pscustomobject]@{ Path = $path; Branch = $branch }
        }
    }
    BeforeEach {
        Set-Location -LiteralPath $contextA -ErrorAction Stop
    }
    AfterEach {
        Set-Location -LiteralPath $contextA -ErrorAction Stop
    }
    AfterAll {
        Set-Location -LiteralPath $pathContextLocation.ProviderPath -ErrorAction Stop
        foreach ($key in $pathContextEnvironment.Keys) {
            if ($null -eq $pathContextEnvironment[$key]) {
                Remove-Item -LiteralPath "Env:$key" -ErrorAction Ignore
            } else {
                [Environment]::SetEnvironmentVariable($key, $pathContextEnvironment[$key], 'Process')
            }
        }
    }

    It 'completes the selected repository via <Parameter> with Path after branch=<After>' -ForEach @(
        @{ Parameter = 'Path'; After = $false }; @{ Parameter = 'Path'; After = $true }
        @{ Parameter = 'RepositoryPath'; After = $false }; @{ Parameter = 'RepoPath'; After = $true }
        @{ Parameter = 'pa'; After = $false }
    ) {
        $pathArgument = "-$Parameter '$($contextB.Replace("'", "''"))'"
        $line = if ($After) { "Add-Worktree -BranchName feature/ $pathArgument" }
            else { "Add-Worktree $pathArgument -BranchName feature/" }
        $beforeIndex = Get-FileHash -LiteralPath (Join-Path $contextB '.git' 'index')
        $branches = @(Invoke-Git @('-C', $contextB, 'for-each-ref', '--format=%(refname)', 'refs/heads/'))
        $names = @(Get-ContextCompletions $line).ListItemText
        $names | Should -Contain 'feature/b-only'
        $names | Should -Not -Contain 'feature/a-only'
        $names | Should -Not -Contain 'feature/b-tree'
        $names | Should -Not -Contain '(detached)'
        (Get-Location).ProviderPath | Should -BeExactly $contextA
        (Get-FileHash -LiteralPath (Join-Path $contextB '.git' 'index')).Hash | Should -Be $beforeIndex.Hash
        @(Invoke-Git @('-C', $contextB, 'for-each-ref', '--format=%(refname)', 'refs/heads/')) | Should -Be $branches
        @(Get-Worktrees -Path $contextB) | Should -HaveCount 3
    }

    It 'completes relative paths from a non-repository directory' {
        Set-Location -LiteralPath $contextOutside -ErrorAction Stop
        $relative = Join-Path '..' 'b [literal]'
        @(Get-ContextCompletions "Add-Worktree -BranchName feature/ -Path '$relative'").ListItemText |
            Should -Contain 'feature/b-only'
        @(Get-ContextCompletions "Add-Worktree -RepoPath '$relative' -BranchName feature/").ListItemText |
            Should -Not -Contain 'feature/a-only'
        (Get-Location).ProviderPath | Should -BeExactly $contextOutside
    }

    It 'uses bound variables without evaluating path expressions' {
        $contextCompletionPath = $contextB
        @(Get-ContextCompletions 'Add-Worktree -Path $contextCompletionPath -BranchName feature/').ListItemText |
            Should -Contain 'feature/b-only'
        $global:PathCompletionExpressionRan = $false
        try {
            @(Get-ContextCompletions 'Add-Worktree -Path $( $global:PathCompletionExpressionRan = $true; ''missing'' ) -BranchName feature/') |
                Should -HaveCount 0
            $global:PathCompletionExpressionRan | Should -BeFalse
        } finally {
            Remove-Variable PathCompletionExpressionRan -Scope Global -ErrorAction Ignore
        }
    }

    It 'never falls back to caller branches for <Kind> explicit paths' -ForEach @(
        @{ Kind = 'missing' }; @{ Kind = 'file' }; @{ Kind = 'outside' }
        @{ Kind = 'empty' }; @{ Kind = 'null variable' }; @{ Kind = 'unresolved positional expression' }
    ) {
        $line = switch ($Kind) {
            missing { "Add-Worktree -Path '$pathContextRoot/missing' -BranchName feature/" }
            file { "Add-Worktree -Path '$(Join-Path $contextB 'README.md')' -BranchName feature/" }
            outside { "Add-Worktree -Path '$contextOutside' -BranchName feature/" }
            empty { "Add-Worktree -Path '' -BranchName feature/" }
            'null variable' { 'Add-Worktree -Path $null -BranchName feature/' }
            'unresolved positional expression' { 'Add-Worktree feature/ (Join-Path $contextOutside ''missing'')' }
        }
        @(Get-ContextCompletions $line) | Should -HaveCount 0
    }

    It 'retains current-repository completion and safely quotes shell-sensitive branches' {
        @(Get-ContextCompletions 'Add-Worktree -BranchName feature/').ListItemText |
            Should -Be @('feature/a-only')
        $items = @(Get-ContextCompletions "Add-Worktree -Path '$contextB' -BranchName feature/")
        ($items | Where-Object ListItemText -EQ 'feature/price$tag').CompletionText | Should -BeExactly "'feature/price`$tag'"
        ($items | Where-Object ListItemText -EQ "feature/quote'branch").CompletionText | Should -BeExactly "'feature/quote''branch'"
    }

    It 'keeps branch completion in the current repository for <Command>' -ForEach @(
        @{ Command = 'Set-Worktree' }; @{ Command = 'Move-Worktree' }; @{ Command = 'Remove-Worktree' }
        @{ Command = 'Lock-Worktree' }; @{ Command = 'Unlock-Worktree' }
    ) {
        Set-Location -LiteralPath $contextB -ErrorAction Stop
        @(Get-ContextCompletions "$Command -BranchName feature/").ListItemText | Should -Be @('feature/b-tree')
    }

    It 'preserves mutually exclusive worktree Path and BranchName selection for <Command>' -ForEach @(
        @{ Command = 'Set-Worktree' }; @{ Command = 'Remove-Worktree' }; @{ Command = 'Move-Worktree' }
    ) {
        @(Get-ContextCompletions "$Command -Path '$contextLinked' -BranchName feature/") | Should -HaveCount 0
        $arguments = @{ Path = $contextLinked; BranchName = 'feature/a-only'; ErrorAction = 'Stop' }
        if ($Command -eq 'Move-Worktree') { $arguments.DestinationPath = Join-Path $pathContextRoot 'never-move' }
        { & $Command @arguments } | Should -Throw -ErrorId 'AmbiguousParameterSet*'
        Test-Path -LiteralPath $contextLinked | Should -BeTrue
    }

    It 'validates branch operations against pipeline repository context via <Property>' -ForEach @(
        @{ Property = 'Path' }; @{ Property = 'RepositoryPath' }; @{ Property = 'RepoPath' }
    ) {
        Set-Location -LiteralPath $contextOutside -ErrorAction Stop
        $target = Join-Path $pathContextRoot ('add-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $inputPath = [pscustomobject]@{ $Property = $contextB }
        try {
            $inputPath | Add-Worktree -BranchName 'feature/b-only' -WorktreePath $target -NoSetLocation -Confirm:$false -ErrorAction Stop
            (Get-Worktrees -Path $contextB).Path | Should -Contain $target
            (Get-Location).ProviderPath | Should -BeExactly $contextOutside
        } finally {
            if (Test-Path -LiteralPath $target) { Invoke-Git @('-C', $contextB, 'worktree', 'remove', $target) }
        }
        { $inputPath | Add-Worktree -BranchName 'feature/a-only' -WorktreePath $target -NoSetLocation -Confirm:$false -ErrorAction Stop } |
            Should -Throw '*git worktree add failed*'
        Test-Path -LiteralPath $target | Should -BeFalse
    }

    It 'validates Set-Branch and Remove-Branch against the supplied repository rather than the caller' {
        try {
            [pscustomobject]@{ RepoPath = $contextB } | Set-Branch -Branch 'feature/b-only' -Confirm:$false -ErrorAction Stop
            Invoke-Git @('-C', $contextB, 'branch', '--show-current') | Should -BeExactly 'feature/b-only'
            Invoke-Git @('-C', $contextA, 'branch', '--show-current') | Should -BeExactly 'main'
        } finally { Invoke-Git @('-C', $contextB, 'switch', '--quiet', 'main') }
        $branch = 'delete-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        Invoke-Git @('-C', $contextA, 'branch', $branch)
        Invoke-Git @('-C', $contextB, 'branch', $branch)
        [pscustomobject]@{ RepoPath = $contextB; BranchName = $branch } | Remove-Branch -Confirm:$false -ErrorAction Stop
        Invoke-Git @('-C', $contextA, 'branch', '--list', $branch) | Should -Not -BeNullOrEmpty
        Invoke-Git @('-C', $contextB, 'branch', '--list', $branch) | Should -BeNullOrEmpty
        (Get-Location).ProviderPath | Should -BeExactly $contextA
    }

    It 'selects a foreign registered worktree using <InputKind>' -ForEach @(
        @{ InputKind = 'absolute' }; @{ InputKind = 'relative outside' }; @{ InputKind = 'pipeline' }; @{ InputKind = 'detached' }
    ) {
        switch ($InputKind) {
            absolute { Set-Worktree -Path $contextLinked -ErrorAction Stop }
            'relative outside' {
                Set-Location -LiteralPath $contextOutside -ErrorAction Stop
                Set-Worktree -Path (Join-Path '..' 'linked [b]') -ErrorAction Stop
            }
            pipeline { Get-Worktrees -Path $contextB | Where-Object Branch -EQ 'feature/b-tree' | Set-Worktree -ErrorAction Stop }
            detached { Set-Worktree -Path $contextDetached -ErrorAction Stop }
        }
        $expected = if ($InputKind -eq 'detached') { $contextDetached } else { $contextLinked }
        (Get-Location).ProviderPath | Should -BeExactly $expected
    }

    It 'removes only the selected repository worktree and branch from <Caller> with KeepBranch=<Keep>' -ForEach @(
        @{ Caller = 'repo'; Keep = $false }; @{ Caller = 'outside'; Keep = $false }; @{ Caller = 'outside'; Keep = $true }
    ) {
        $target = New-ContextTarget
        $callerPath = if ($Caller -eq 'repo') { $contextA } else { $contextOutside }
        Set-Location -LiteralPath $callerPath -ErrorAction Stop
        Get-Worktrees -Path $contextB | Where-Object Branch -EQ $target.Branch |
            Remove-Worktree -KeepBranch:$Keep -Confirm:$false -ErrorAction Stop
        Test-Path -LiteralPath $target.Path | Should -BeFalse
        Invoke-Git @('-C', $contextA, 'branch', '--list', $target.Branch) | Should -Not -BeNullOrEmpty
        [bool](Invoke-Git @('-C', $contextB, 'branch', '--list', $target.Branch)) | Should -Be $Keep
        (Get-Location).ProviderPath | Should -BeExactly $callerPath
    }

    It 'moves a foreign target and resolves the destination relative to the caller' {
        $target = New-ContextTarget
        Set-Location -LiteralPath $contextOutside -ErrorAction Stop
        $destination = 'moved-' + $target.Branch
        $result = $target | Move-Worktree -DestinationPath $destination -Confirm:$false -ErrorAction Stop
        $result.NewPath | Should -BeExactly (Join-Path $contextOutside $destination)
        Test-Path -LiteralPath $target.Path | Should -BeFalse
        (Get-Worktrees -Path $contextB).Path | Should -Contain $result.NewPath
        Invoke-Git @('-C', $contextA, 'branch', '--list', $target.Branch) | Should -Not -BeNullOrEmpty
        (Get-Location).ProviderPath | Should -BeExactly $contextOutside
    }

    It 'previews foreign worktree mutations without changing either repository' {
        Set-Location -LiteralPath $contextOutside -ErrorAction Stop
        $before = @(Get-Worktrees -Path $contextB)
        $before | Where-Object Branch -EQ 'feature/b-tree' | Remove-Worktree -WhatIf -ErrorAction Stop
        Move-Worktree -Path $contextLinked -DestinationPath (Join-Path $contextOutside 'never') -WhatIf -ErrorAction Stop
        (Get-Worktrees -Path $contextB).Path | Should -Be $before.Path
        Test-Path -LiteralPath $contextLinked | Should -BeTrue
        (Get-Location).ProviderPath | Should -BeExactly $contextOutside
    }

    It 'rejects unregistered paths and foreign main-worktree moves without falling back' {
        $subdirectory = Join-Path $contextLinked 'not-a-root'
        $null = New-Item -ItemType Directory -Path $subdirectory
        { Set-Worktree -Path $subdirectory -ErrorAction Stop } | Should -Throw '*No worktree was found*'
        { Remove-Worktree -Path $contextOutside -WhatIf -ErrorAction Stop } | Should -Throw '*not inside a git working tree*'
        { Move-Worktree -Path $contextB -DestinationPath (Join-Path $pathContextRoot 'never') -ErrorAction Stop } |
            Should -Throw '*main/root worktree*'
        { Set-Worktree -BranchName 'feature/b-tree' -ErrorAction Stop } | Should -Throw '*No worktree was found*'
        (Get-Location).ProviderPath | Should -BeExactly $contextA
        Test-Path -LiteralPath $contextLinked | Should -BeTrue
    }

    It 'rejects non-filesystem target paths before repository lookup' {
        foreach ($command in 'Set-Worktree', 'Move-Worktree', 'Remove-Worktree') {
            $arguments = @{ Path = 'Env:PATH'; ErrorAction = 'Stop' }
            if ($command -eq 'Move-Worktree') { $arguments.DestinationPath = Join-Path $pathContextRoot 'never' }
            { & $command @arguments } | Should -Throw '*FileSystem path*'
        }
        (Get-Location).ProviderPath | Should -BeExactly $contextA
        Test-Path -LiteralPath $contextLinked | Should -BeTrue
    }
}

Describe 'Git tab completion literal insertion' -Tag 'GitTabCompletion' {
    BeforeAll {
        function Assert-LiteralGitCompletion {
            param(
                [string]$Line,
                [string]$Value,
                [switch]$Unquoted,
                [string]$Suffix = ''
            )

            $inputLine = $Line + $Suffix
            $result = [System.Management.Automation.CommandCompletion]::CompleteInput($inputLine, $Line.Length, $null)
            $matches = @($result.CompletionMatches | Where-Object ListItemText -CEQ $Value)
            $matches | Should -HaveCount 1
            $match = $matches[0]
            $match.ToolTip | Should -BeExactly $Value
            $match.ResultType | Should -Be 'ParameterValue'
            if ($Unquoted) {
                $match.CompletionText | Should -BeExactly $Value
            } else {
                $match.CompletionText[0] | Should -Be ([char]"'")
            }

            $accepted = $inputLine.Substring(0, $result.ReplacementIndex) + $match.CompletionText +
                $inputLine.Substring($result.ReplacementIndex + $result.ReplacementLength)
            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($accepted, [ref]$tokens, [ref]$parseErrors)
            $parseErrors | Should -BeNullOrEmpty
            $ast.EndBlock.Statements | Should -HaveCount 1
            $pipeline = $ast.EndBlock.Statements[0]
            $pipeline | Should -BeOfType ([System.Management.Automation.Language.PipelineAst])
            $pipeline.PipelineElements | Should -HaveCount 1
            $command = $pipeline.PipelineElements[0]
            $command | Should -BeOfType ([System.Management.Automation.Language.CommandAst])
            $command.Redirections | Should -HaveCount 0
            $words = @($Line -split ' ')
            $command.CommandElements | Should -HaveCount ($words.Count + [int][bool]$Suffix)
            $argument = $command.CommandElements[$words.Count - 1]
            if ($Unquoted -and $argument -is [System.Management.Automation.Language.CommandParameterAst]) {
                $argument.Extent.Text | Should -BeExactly $Value
                $argument.Argument | Should -BeNullOrEmpty
            } else {
                $argument | Should -BeOfType ([System.Management.Automation.Language.StringConstantExpressionAst])
                $argument.Value | Should -BeExactly $Value
            }
            if (-not $Unquoted) {
                $argument.StringConstantType | Should -Be 'SingleQuoted'
            }
            if ($Suffix) {
                $command.CommandElements[-1].Extent.Text | Should -BeExactly $Suffix.TrimStart()
            }
        }
    }

    BeforeEach {
        $completionLocation = Get-Location
        $completionRoot = (New-Item -ItemType Directory -Path (
            Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        ) -ErrorAction Stop).FullName
        Set-Location -LiteralPath $completionRoot -ErrorAction Stop
        if ((Get-Location).ProviderPath -cne $completionRoot) { throw 'Completion fixture location was not entered.' }
        $completionData = @{
            Status = @()
            Branches = @('unrelated-branch')
            RemoteBranches = @('origin/unrelated-branch')
            Tags = @()
            Remotes = @()
            Stashes = @()
            Commands = @('add', 'status')
            Aliases = @()
            Unexpected = [System.Collections.Generic.List[string]]::new()
        }
        Mock -ModuleName Shmuelie.Git git {
            if ((Get-Location).ProviderPath -cne $completionRoot) { throw 'Unexpected completion location.' }
            switch -CaseSensitive ($args -join ' ') {
                '-c core.quotePath=false status --porcelain' { $completionData.Status }
                'branch --format=%(refname:short)' { $completionData.Branches }
                'branch -r --format=%(refname:short)' { $completionData.RemoteBranches }
                'tag -l' { $completionData.Tags }
                'remote' { $completionData.Remotes }
                'stash list --format=%gd' { $completionData.Stashes }
                '--list-cmds=main' { $completionData.Commands }
                'config --get-regexp ^alias\.' { $completionData.Aliases }
                default {
                    $completionData.Unexpected.Add($args -join ' ')
                    throw "Unexpected native Git completion call: $args"
                }
            }
        }
    }

    AfterEach {
        try {
            $completionData.Unexpected | Should -HaveCount 0
            (Get-Location).ProviderPath | Should -BeExactly $completionRoot
        } finally {
            Set-Location -LiteralPath $completionLocation.ProviderPath -ErrorAction Stop
        }
    }

    It 'round-trips the filename <Value> without evaluation' -ForEach @(
        @{ Value = 'literal two words.txt' }
        @{ Value = "literal'quote.txt" }
        @{ Value = 'literal$price.txt' }
        @{ Value = 'literal`escape.txt' }
        @{ Value = 'literal;separator.txt' }
        @{ Value = 'literal&operator.txt' }
        @{ Value = 'literal(paren).txt' }
        @{ Value = 'literal{brace}.txt' }
        @{ Value = 'literal[bracket].txt' }
        @{ Value = 'literal,comma.txt' }
        @{ Value = 'literal@at.txt' }
        @{ Value = 'literal#hash.txt' }
        @{ Value = 'literal!bang.txt' }
        @{ Value = 'literal%percent.txt' }
        @{ Value = 'literal$(throw ''Never execute suggestions'').txt' }
        @{ Value = "literal' `$price``; & (name).txt" }
        @{ Value = ('literal' + [char]0x2018 + 'quote.txt') }
        @{ Value = ('literal' + [char]0x2019 + 'quote.txt') }
        @{ Value = ('literal' + [char]0x201A + 'quote.txt') }
        @{ Value = ('literal' + [char]0x201B + 'quote.txt') }
        @{ Value = ('literal' + [char]0x201C + 'quote.txt') }
        @{ Value = ('literal' + [char]0x201D + 'quote.txt') }
    ) {
        $completionData.Status = @('?? "' + $Value + '"')
        Assert-LiteralGitCompletion -Line 'git add literal' -Value $Value
        Should -Invoke -ModuleName Shmuelie.Git git -Times 1 -Exactly -ParameterFilter {
            ($args -join ' ') -ceq '-c core.quotePath=false status --porcelain'
        }
    }

    It 'quotes paths from <Line>' -ForEach @(
        @{ Line = 'git add literal' }
        @{ Line = 'git reset HEAD literal' }
        @{ Line = 'git reset HEAD -- literal' }
        @{ Line = 'git checkout -- literal' }
        @{ Line = 'git restore literal' }
        @{ Line = 'git rm literal' }
        @{ Line = 'git diff literal' }
        @{ Line = 'git diff --cached literal' }
        @{ Line = 'git difftool --staged literal' }
    ) {
        $value = 'literal space''$tag`;file.txt'
        $completionData.Status = @('MM "' + $value + '"')
        Assert-LiteralGitCompletion -Line $Line -Value $value
        Should -Invoke -ModuleName Shmuelie.Git git -Times 1 -Exactly
    }

    It 'round-trips the branch <Value> without evaluation' -ForEach @(
        @{ Value = "literal/quote'branch" }
        @{ Value = 'literal/price$tag' }
        @{ Value = 'literal/back`tick' }
        @{ Value = 'literal/semicolon;branch' }
        @{ Value = 'literal/amp&branch' }
        @{ Value = 'literal/(group)' }
        @{ Value = 'literal/{group}' }
        @{ Value = 'literal/a,b' }
        @{ Value = 'literal/$(@(1;2))' }
        @{ Value = ('literal/' + [char]0x2019 + 'quote') }
    ) {
        $completionData.Branches = @($Value)
        Assert-LiteralGitCompletion -Line 'git show literal/' -Value $Value
        Should -Invoke -ModuleName Shmuelie.Git git -Times 2 -Exactly
    }

    It 'quotes refs from <Line>' -ForEach @(
        @{ Line = 'git branch -d literal'; Prefix = '' }
        @{ Line = 'git checkout literal'; Prefix = '' }
        @{ Line = 'git switch literal'; Prefix = '' }
        @{ Line = 'git restore -s literal'; Prefix = '' }
        @{ Line = 'git restore --source=literal'; Prefix = '--source=' }
        @{ Line = 'git worktree add destination literal'; Prefix = '' }
        @{ Line = 'git merge literal'; Prefix = '' }
        @{ Line = 'git push origin literal'; Prefix = '' }
        @{ Line = 'git push origin +literal'; Prefix = '+' }
    ) {
        $value = 'literal/quote''$tag`;branch'
        $completionData.Branches = @($value)
        Assert-LiteralGitCompletion -Line $Line -Value ($Prefix + $value)
    }

    It 'quotes <Kind> while displaying the original value' -ForEach @(
        @{ Kind = 'tag'; Line = 'git show literal'; Key = 'Tags'; Value = 'literal/tag''$value' }
        @{ Kind = 'remote-only branch'; Line = 'git checkout literal'; Key = 'RemoteBranches'; Value = 'origin/literal/remote''$value' }
        @{ Kind = 'remote'; Line = 'git remote show literal'; Key = 'Remotes'; Value = 'literal/remote''$value' }
        @{ Kind = 'stash'; Line = 'git stash show stash'; Key = 'Stashes'; Value = 'stash@{0}' }
        @{ Kind = 'alias'; Line = 'git literal'; Key = 'Aliases'; Value = 'alias.literal$alias status' }
    ) {
        $completionData[$Key] = @($Value)
        $expected = switch ($Kind) {
            'remote-only branch' { $Value.Substring('origin/'.Length) }
            'alias' { 'literal$alias' }
            default { $Value }
        }
        Assert-LiteralGitCompletion -Line $Line -Value $expected
    }

    It 'preserves the unquoted completion <Value>' -ForEach @(
        @{ Line = 'git add literal'; Value = 'literal-file_1.txt'; Key = 'Status'; Output = '?? literal-file_1.txt' }
        @{ Line = 'git show literal'; Value = 'literal/topic-1.0'; Key = 'Branches'; Output = 'literal/topic-1.0' }
        @{ Line = 'git push origin +literal'; Value = '+literal/topic'; Key = 'Branches'; Output = 'literal/topic' }
        @{ Line = 'git restore --source=literal'; Value = '--source=literal/topic'; Key = 'Branches'; Output = 'literal/topic' }
        @{ Line = 'git status --sho'; Value = '--short'; Key = 'Status'; Output = '' }
        @{ Line = 'git clean -f'; Value = '-f'; Key = 'Status'; Output = '' }
        @{ Line = 'git sta'; Value = 'status'; Key = 'Commands'; Output = 'status' }
        @{ Line = 'git stash po'; Value = 'pop'; Key = 'Status'; Output = '' }
    ) {
        $completionData[$Key] = @($Output)
        Assert-LiteralGitCompletion -Line $Line -Value $Value -Unquoted
    }

    It 'preserves the rest of the line when accepting a completion before the cursor suffix' {
        $value = 'literal space''$tag`;file.txt'
        $completionData.Status = @('?? "' + $value + '"')
        Assert-LiteralGitCompletion -Line 'git add literal' -Value $value -Suffix ' --dry-run'
    }
}

Describe 'Git tab completion status parsing' -Tag 'GitTabCompletion' {
    BeforeAll {
        $completionGit = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    }

    BeforeEach {
        $completionNativeErrors = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName Shmuelie.Git git {
            $fixturePrefix = [IO.Path]::GetFullPath($TestDrive).TrimEnd([IO.Path]::DirectorySeparatorChar) +
                [IO.Path]::DirectorySeparatorChar
            if (-not $repo -or -not [IO.Path]::GetFullPath($repo).StartsWith($fixturePrefix, [StringComparison]::OrdinalIgnoreCase) -or
                (Get-Location).ProviderPath -cne $repo -or
                ($args -join ' ') -cne '-c core.quotePath=false status --porcelain') {
                $completionNativeErrors.Add("Unexpected Git fixture call: $args")
                throw $completionNativeErrors[-1]
            }
            $gitDirectory = Get-Item -LiteralPath (Join-Path $repo '.git') -Force -ErrorAction Stop
            if (-not $gitDirectory.PSIsContainer -or $gitDirectory.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Completion fixture must own its Git directory.'
            }
            & $completionGit.Source --no-optional-locks -C $repo @args
            if ($LASTEXITCODE -ne 0) {
                $completionNativeErrors.Add("Git fixture query failed: $LASTEXITCODE")
                throw $completionNativeErrors[-1]
            }
        }
    }

    AfterEach {
        $completionNativeErrors | Should -HaveCount 0
    }

    It 'extracts the destination path from rename and copy porcelain entries' {
        InModuleScope Shmuelie.Git {
            Get-GitStatusPorcelainPath 'R  old.txt -> new.txt' | Should -BeExactly 'new.txt'
            Get-GitStatusPorcelainPath 'C  "old name.txt" -> "new name.txt"' | Should -BeExactly 'new name.txt'
        }
    }

    It 'leaves normal and quoted non-ASCII paths unchanged except surrounding quotes' {
        InModuleScope Shmuelie.Git {
            Get-GitStatusPorcelainPath ' M normal.txt' | Should -BeExactly 'normal.txt'
            Get-GitStatusPorcelainPath '?? "文.txt"' | Should -BeExactly '文.txt'
        }
    }

    It 'completes a non-ASCII file name even when repository quotePath is enabled' {
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'git is not available'
            return
        }

        $repo = New-TestRepo -Path (Join-Path $TestDrive 'completion-quotepath')
        Invoke-Git @('-C', $repo, 'config', 'core.quotePath', 'true')
        Set-Content -Path (Join-Path $repo '文.txt') -Value 'content'

        Push-Location -LiteralPath $repo -ErrorAction Stop
        try {
            if ((Get-Location).ProviderPath -cne $repo) { throw 'Completion fixture location was not entered.' }
            $files = InModuleScope Shmuelie.Git { gitAddFiles '' }
        } finally {
            Pop-Location -ErrorAction Stop
        }

        $files | Should -Contain '文.txt'
        $files | Should -Not -Contain '\346\226\207.txt'
    }

    It 'completes the new path for a staged rename' {
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'git is not available'
            return
        }

        $repo = New-TestRepo -Path (Join-Path $TestDrive 'completion-rename')
        Invoke-Git @('-C', $repo, 'mv', 'README.md', 'README-renamed.md')

        Push-Location -LiteralPath $repo -ErrorAction Stop
        try {
            if ((Get-Location).ProviderPath -cne $repo) { throw 'Completion fixture location was not entered.' }
            $files = InModuleScope Shmuelie.Git { gitIndexFiles '' }
        } finally {
            Pop-Location -ErrorAction Stop
        }

        $files | Should -Contain 'README-renamed.md'
        $files | Should -Not -Contain 'README.md -> README-renamed.md'
    }

    It 'round-trips actual native status filenames without executing the accepted lines' {
        if (-not $completionGit) {
            Set-ItResult -Skipped -Because 'git is not available'
            return
        }

        $repo = New-TestRepo -Path (Join-Path $TestDrive 'completion-literals')
        $names = @(
            'literal two words.txt', "literal'quote.txt", 'literal$price.txt',
            'literal`escape.txt', 'literal;separator.txt', 'literal$(1;2).txt',
            "literal' `$price``; & (name).txt"
        )
        foreach ($name in $names) {
            Set-Content -LiteralPath (Join-Path $repo $name) -Value 'content' -ErrorAction Stop
        }
        $index = Join-Path $repo '.git' 'index'
        $beforeIndex = Get-FileHash -LiteralPath $index
        Push-Location -LiteralPath $repo -ErrorAction Stop
        try {
            if ((Get-Location).ProviderPath -cne $repo) { throw 'Completion fixture location was not entered.' }
            $line = 'git add literal'
            $result = [System.Management.Automation.CommandCompletion]::CompleteInput($line, $line.Length, $null)
            $result.CompletionMatches | Should -HaveCount $names.Count
            foreach ($name in $names) {
                $matches = @($result.CompletionMatches | Where-Object ListItemText -CEQ $name)
                $matches | Should -HaveCount 1
                $accepted = $line.Substring(0, $result.ReplacementIndex) + $matches[0].CompletionText +
                    $line.Substring($result.ReplacementIndex + $result.ReplacementLength)
                $tokens = $null
                $parseErrors = $null
                $ast = [System.Management.Automation.Language.Parser]::ParseInput($accepted, [ref]$tokens, [ref]$parseErrors)
                $parseErrors | Should -BeNullOrEmpty
                $ast.EndBlock.Statements | Should -HaveCount 1
                $ast.EndBlock.Statements[0].PipelineElements | Should -HaveCount 1
                $elements = $ast.EndBlock.Statements[0].PipelineElements[0].CommandElements
                $elements | Should -HaveCount 3
                $elements[2] | Should -BeOfType ([System.Management.Automation.Language.StringConstantExpressionAst])
                $elements[2].StringConstantType | Should -Be 'SingleQuoted'
                $elements[2].Value | Should -BeExactly $name
            }
            (Get-Location).ProviderPath | Should -BeExactly $repo
            (Get-FileHash -LiteralPath $index).Hash | Should -BeExactly $beforeIndex.Hash
            Should -Invoke -ModuleName Shmuelie.Git git -Times 1 -Exactly
        } finally {
            Pop-Location -ErrorAction Stop
        }
    }
}

Describe 'Sync-GitRemote' {
    It 'returns Updated for a fast-forwarded remote ref' {
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'git is not available'
            return
        }

        $originWork = New-TestRepo -Path (Join-Path $TestDrive 'sync-origin-work')
        $bare = Join-Path $TestDrive 'sync-origin.git'
        Invoke-Git @('clone', '--bare', '--quiet', $originWork, $bare)
        $clone = Join-Path $TestDrive 'sync-clone'
        Invoke-Git @('clone', '--quiet', $bare, $clone)
        Set-TestRepoConfig $clone

        Set-Content -Path (Join-Path $originWork 'README.md') -Value 'updated'
        Invoke-Git @('-C', $originWork, 'add', 'README.md')
        Invoke-Git @('-C', $originWork, 'commit', '-m', 'advance', '--quiet')
        Invoke-Git @('-C', $originWork, 'push', '--quiet', $bare, 'main')

        Push-Location $clone
        try {
            $results = @(Sync-GitRemote -Remote origin -NoGitHubAccountResolve)
        } finally {
            Pop-Location
        }

        $updated = @($results | Where-Object { $_.Action -eq 'Updated' -and $_.Ref -eq 'origin/main' })
        $updated | Should -HaveCount 1
        $updated[0].PSTypeNames[0] | Should -Be 'GitFetchResult'
    }

    It 'runs the parsed fetch invocation with the C locale' {
        Mock -ModuleName Shmuelie.Git Get-GitHubSignedInAccount { @() }
        Mock -ModuleName Shmuelie.Git Invoke-GitWithEnvironment {
            $Arguments[0] | Should -Be '-C'
            ($Arguments[2..4] -join ' ') | Should -Be 'fetch origin --prune'
            $Environment['LC_ALL'] | Should -Be 'C'
            $Environment['LANG'] | Should -Be 'C'
            [PSCustomObject]@{
                PSTypeName = 'GitInvocationResult'
                ExitCode   = 0
                Output     = @(' * [new branch]      main       -> origin/main')
            }
        }

        $result = Sync-GitRemote -Remote origin

        $result.Action | Should -Be 'New branch'
        Should -Invoke -ModuleName Shmuelie.Git Invoke-GitWithEnvironment -Times 1
    }
}


Describe 'GitHub account helpers' {
    Context 'Get-GitHubRemoteInfo' {
        $remoteCases = @(
            @{ Name = 'https github';        Url = 'https://github.com/contoso/repo.git';        ExpectHost = 'github.com';      ExpectOwner = 'contoso' }
            @{ Name = 'https github no .git'; Url = 'https://github.com/contoso/repo';             ExpectHost = 'github.com';      ExpectOwner = 'contoso' }
            @{ Name = 'https user@host';      Url = 'https://user@github.com/contoso/repo.git';    ExpectHost = 'github.com';      ExpectOwner = 'contoso' }
            @{ Name = 'https ghe host';       Url = 'https://ghe.example.com/team/repo.git';       ExpectHost = 'ghe.example.com'; ExpectOwner = 'team' }
            @{ Name = 'https port';           Url = 'https://ghe.example.com:8443/team/repo.git';  ExpectHost = 'ghe.example.com'; ExpectOwner = 'team' }
            @{ Name = 'scp-like';             Url = 'git@github.com:contoso/repo.git';             ExpectHost = 'github.com';      ExpectOwner = 'contoso' }
            @{ Name = 'ssh scheme';           Url = 'ssh://git@github.com/contoso/repo.git';       ExpectHost = 'github.com';      ExpectOwner = 'contoso' }
            @{ Name = 'ghe scp-like';         Url = 'git@ghe.example.com:team/repo.git';           ExpectHost = 'ghe.example.com'; ExpectOwner = 'team' }
            @{ Name = 'uppercase host';       Url = 'https://GitHub.com/contoso/repo.git';         ExpectHost = 'github.com';      ExpectOwner = 'contoso' }
        )

        It 'parses <Name>' -ForEach $remoteCases {
            InModuleScope Shmuelie.Git -Parameters @{ Url = $Url; ExpectHost = $ExpectHost; ExpectOwner = $ExpectOwner } {
                param($Url, $ExpectHost, $ExpectOwner)
                $info = Get-GitHubRemoteInfo -Url $Url
                $info.Host | Should -BeExactly $ExpectHost
                $info.Owner | Should -BeExactly $ExpectOwner
            }
        }

        It 'returns nothing for a non-remote-looking URL' {
            InModuleScope Shmuelie.Git {
                Get-GitHubRemoteInfo -Url 'file:///C:/repos/local.git' | Should -BeNullOrEmpty
                Get-GitHubRemoteInfo -Url 'not a url' | Should -BeNullOrEmpty
            }
        }
    }

    Context 'Test-GitHubHostName / Test-GitHubAccountName' {
        It 'accepts valid and rejects unsafe host names' {
            InModuleScope Shmuelie.Git {
                Test-GitHubHostName 'github.com' | Should -BeTrue
                Test-GitHubHostName 'ghe.example.com' | Should -BeTrue
                Test-GitHubHostName 'github.com & calc' | Should -BeFalse
                Test-GitHubHostName 'a|b' | Should -BeFalse
                Test-GitHubHostName '' | Should -BeFalse
            }
        }

        It 'accepts valid and rejects unsafe account names' {
            InModuleScope Shmuelie.Git {
                Test-GitHubAccountName 'octocat' | Should -BeTrue
                Test-GitHubAccountName 'work-user' | Should -BeTrue
                Test-GitHubAccountName '-bad' | Should -BeFalse
                Test-GitHubAccountName 'a b' | Should -BeFalse
                Test-GitHubAccountName 'a&b' | Should -BeFalse
            }
        }
    }

    Context 'Get-GitHubAccountMapValue' {
        It 'matches host/owner and bare owner keys case-insensitively' {
            InModuleScope Shmuelie.Git {
                $map = @{ 'github.com/Contoso' = 'work'; 'fabrikam' = 'personal' }
                Get-GitHubAccountMapValue -Map $map -HostName 'github.com' -Owner 'contoso' | Should -Be 'work'
                Get-GitHubAccountMapValue -Map $map -HostName 'ghe.example.com' -Owner 'FABRIKAM' | Should -Be 'personal'
                Get-GitHubAccountMapValue -Map $map -HostName 'github.com' -Owner 'nobody' | Should -BeNullOrEmpty
                Get-GitHubAccountMapValue -Map $null -HostName 'github.com' -Owner 'contoso' | Should -BeNullOrEmpty
            }
        }
    }

    Context 'Test-GitHubAuthFailure' {
        It 'detects auth/access failures but not clean output' {
            InModuleScope Shmuelie.Git {
                Test-GitHubAuthFailure -Output @('remote: Repository not found') | Should -BeTrue
                Test-GitHubAuthFailure -Output @('fatal: Authentication failed for https://github.com') | Should -BeTrue
                Test-GitHubAuthFailure -Output @('   abc123..def456  main -> origin/main') | Should -BeFalse
            }
        }
    }

    Context 'Get-GitHubSignedInAccount' {
        BeforeEach {
            function global:gh {
                @(
                    'github.com'
                    '  Logged in to github.com account personal (keyring)'
                    '  - Active account: true'
                    '  Logged in to github.com account work (keyring)'
                    '  - Active account: false'
                    'ghe.example.com'
                    '  Logged in to ghe.example.com account enterprise-user (keyring)'
                    '  - Active account: true'
                )
            }
        }
        AfterEach {
            Remove-Item Function:\gh -Force -ErrorAction SilentlyContinue
        }

        It 'parses accounts across hosts with active flags' {
            Mock -ModuleName Shmuelie.Git Test-GhAvailable { $true }
            $accounts = InModuleScope Shmuelie.Git { Get-GitHubSignedInAccount }

            $accounts | Should -HaveCount 3
            ($accounts | Where-Object { $_.Host -eq 'github.com' }).Account | Should -Be @('personal', 'work')
            ($accounts | Where-Object { $_.Account -eq 'personal' }).Active | Should -BeTrue
            ($accounts | Where-Object { $_.Account -eq 'work' }).Active | Should -BeFalse
            ($accounts | Where-Object { $_.Host -eq 'ghe.example.com' }).Account | Should -Be 'enterprise-user'
        }

        It 'returns nothing when gh is unavailable' {
            Mock -ModuleName Shmuelie.Git Test-GhAvailable { $false }
            InModuleScope Shmuelie.Git { Get-GitHubSignedInAccount } | Should -BeNullOrEmpty
        }
    }

    Context 'Get-GitHubAccountToken' {
        It 'returns the token on success' {
            function global:gh { 'gho_exampletoken'; $global:LASTEXITCODE = 0 }
            try {
                InModuleScope Shmuelie.Git { Get-GitHubAccountToken -HostName 'github.com' -Account 'work' } |
                    Should -Be 'gho_exampletoken'
            } finally { Remove-Item Function:\gh -Force -ErrorAction SilentlyContinue }
        }

        It 'refuses unsafe host/account without calling gh' {
            $script:called = $false
            function global:gh { $script:called = $true; 'nope' }
            try {
                InModuleScope Shmuelie.Git { Get-GitHubAccountToken -HostName 'bad host' -Account 'work' } |
                    Should -BeNullOrEmpty
            } finally { Remove-Item Function:\gh -Force -ErrorAction SilentlyContinue }
            $script:called | Should -BeFalse
        }
    }
}

Describe 'Sync-GitRemote GitHub account awareness' {
    BeforeAll {
        function New-GitHubRepo {
            param([Parameter(Mandatory)][string]$Path, [string]$Url = 'https://github.com/contoso/repo.git')
            $repo = New-TestRepo -Path $Path
            Invoke-Git @('-C', $repo, 'remote', 'add', 'origin', $Url)
            $repo
        }
    }

    BeforeEach {
        # Fresh session cache per test so caching assertions are deterministic.
        InModuleScope Shmuelie.Git { $script:GitHubAccountCache = $null }
        $global:GhFetchTokens = [System.Collections.Generic.List[string]]::new()
    }
    AfterEach {
        Remove-Variable -Name GhFetchTokens -Scope Global -Force -ErrorAction SilentlyContinue
    }

    Context 'account selection' {
        BeforeEach {
            Mock -ModuleName Shmuelie.Git Get-GitHubSignedInAccount {
                @(
                    [PSCustomObject]@{ PSTypeName = 'GitHubAccount'; Host = 'github.com'; Account = 'personal'; Active = $true }
                    [PSCustomObject]@{ PSTypeName = 'GitHubAccount'; Host = 'github.com'; Account = 'work'; Active = $false }
                )
            }
            Mock -ModuleName Shmuelie.Git Get-GitHubAccountToken { "tok-$Account" }
            # Record which token each fetch used; succeed unless the token is
            # flagged to fail via $global:GhFailToken.
            Mock -ModuleName Shmuelie.Git Invoke-GitWithEnvironment {
                $tok = if ($Environment) { [string]$Environment['GH_TOKEN'] } else { '' }
                $global:GhFetchTokens.Add($tok)
                if ($global:GhFailToken -and $tok -eq $global:GhFailToken) {
                    [PSCustomObject]@{ PSTypeName = 'GitInvocationResult'; ExitCode = 1; Output = @('remote: Repository not found') }
                } else {
                    [PSCustomObject]@{ PSTypeName = 'GitInvocationResult'; ExitCode = 0; Output = @(' * [new branch]      main       -> origin/main') }
                }
            }
        }
        AfterEach {
            Remove-Variable -Name GhFailToken -Scope Global -Force -ErrorAction SilentlyContinue
        }

        It 'uses the account from -GitHubAccountMap' {
            $repo = New-GitHubRepo -Path (Join-Path $TestDrive 'map-repo')
            Push-Location $repo
            try {
                $result = Sync-GitRemote -GitHubAccountMap @{ 'github.com/contoso' = 'work' }
            } finally { Pop-Location }

            $global:GhFetchTokens | Should -Contain 'tok-work'
            $global:GhFetchTokens[0] | Should -Be 'tok-work'
            $result.Action | Should -Be 'New branch'
            InModuleScope Shmuelie.Git { $script:GitHubAccountCache['github.com/contoso'] } | Should -Be 'work'
        }

        It 'uses the account from -GitHubAccountResolver' {
            $repo = New-GitHubRepo -Path (Join-Path $TestDrive 'resolver-repo')
            Push-Location $repo
            try {
                Sync-GitRemote -GitHubAccountResolver { param($h, $o) if ($o -eq 'contoso') { 'work' } } | Out-Null
            } finally { Pop-Location }

            $global:GhFetchTokens[0] | Should -Be 'tok-work'
        }

        It 'tries the active account first when no mapping is given' {
            $repo = New-GitHubRepo -Path (Join-Path $TestDrive 'active-repo')
            Push-Location $repo
            try {
                Sync-GitRemote | Out-Null
            } finally { Pop-Location }

            $global:GhFetchTokens[0] | Should -Be 'tok-personal'
        }

        It 'falls back to another account when the first cannot access, and caches it' {
            $global:GhFailToken = 'tok-personal'
            $repo = New-GitHubRepo -Path (Join-Path $TestDrive 'fallback-repo')
            Push-Location $repo
            try {
                $result = Sync-GitRemote
            } finally { Pop-Location }

            $global:GhFetchTokens | Should -Be @('tok-personal', 'tok-work')
            $result.Action | Should -Be 'New branch'
            InModuleScope Shmuelie.Git { $script:GitHubAccountCache['github.com/contoso'] } | Should -Be 'work'
        }

        It 'still engages via -GitHubAccountMap even with a single account on the host' {
            Mock -ModuleName Shmuelie.Git Get-GitHubSignedInAccount {
                @([PSCustomObject]@{ PSTypeName = 'GitHubAccount'; Host = 'github.com'; Account = 'work'; Active = $true })
            }
            $repo = New-GitHubRepo -Path (Join-Path $TestDrive 'single-map-repo')
            Push-Location $repo
            try {
                Sync-GitRemote -GitHubAccountMap @{ 'github.com/contoso' = 'work' } | Out-Null
            } finally { Pop-Location }

            $global:GhFetchTokens[0] | Should -Be 'tok-work'
        }

        It 'passes GH_HOST and a token to the git child environment' {
            Mock -ModuleName Shmuelie.Git Invoke-GitWithEnvironment {
                $Environment['GH_HOST'] | Should -Be 'github.com'
                $Environment['GH_TOKEN'] | Should -Be 'tok-work'
                $Environment['GIT_TERMINAL_PROMPT'] | Should -Be '0'
                $Environment['LC_ALL'] | Should -Be 'C'
                $Environment['LANG'] | Should -Be 'C'
                [PSCustomObject]@{ PSTypeName = 'GitInvocationResult'; ExitCode = 0; Output = @() }
            }
            $repo = New-GitHubRepo -Path (Join-Path $TestDrive 'env-repo')
            Push-Location $repo
            try {
                Sync-GitRemote -GitHubAccountMap @{ 'github.com/contoso' = 'work' } | Out-Null
            } finally { Pop-Location }
            Should -Invoke -ModuleName Shmuelie.Git Invoke-GitWithEnvironment -Times 1
        }
    }

    Context 'graceful no-op paths' {
        It 'does not engage tokened fetch for a single account on the host' {
            Mock -ModuleName Shmuelie.Git Get-GitHubSignedInAccount {
                @([PSCustomObject]@{ PSTypeName = 'GitHubAccount'; Host = 'github.com'; Account = 'solo'; Active = $true })
            }
            Mock -ModuleName Shmuelie.Git Get-GitHubAccountToken { 'should-not-be-called' }
            Mock -ModuleName Shmuelie.Git Invoke-GitWithEnvironment { [PSCustomObject]@{ PSTypeName = 'GitInvocationResult'; ExitCode = 0; Output = @() } }
            # Local bare remote reachable offline; rewrite the github URL to it so
            # the default (non-tokened) fetch path can run without the network.
            $bare = Join-Path $TestDrive 'solo-bare'
            Invoke-Git @('init', '--bare', '--quiet', $bare)
            $repo = New-GitHubRepo -Path (Join-Path $TestDrive 'solo-repo')
            $bareUrl = 'file:///' + ($bare -replace '\\', '/')
            Invoke-Git @('-C', $repo, 'config', ('url.' + $bareUrl + '.insteadOf'), 'https://github.com/contoso/repo.git')

            Push-Location $repo
            try { Sync-GitRemote | Out-Null } finally { Pop-Location }

            Should -Invoke -ModuleName Shmuelie.Git Get-GitHubAccountToken -Times 0
            Should -Invoke -ModuleName Shmuelie.Git Invoke-GitWithEnvironment -Times 1
        }

        It 'does not engage for a non gh-managed host' {
            Mock -ModuleName Shmuelie.Git Get-GitHubSignedInAccount {
                @([PSCustomObject]@{ PSTypeName = 'GitHubAccount'; Host = 'github.com'; Account = 'personal'; Active = $true }
                  [PSCustomObject]@{ PSTypeName = 'GitHubAccount'; Host = 'github.com'; Account = 'work'; Active = $false })
            }
            Mock -ModuleName Shmuelie.Git Get-GitHubAccountToken { 'should-not-be-called' }
            $bare = Join-Path $TestDrive 'ado-bare'
            Invoke-Git @('init', '--bare', '--quiet', $bare)
            $repo = New-TestRepo -Path (Join-Path $TestDrive 'ado-repo')
            $bareUrl = 'file:///' + ($bare -replace '\\', '/')
            Invoke-Git @('-C', $repo, 'remote', 'add', 'origin', $bareUrl)

            Push-Location $repo
            try { Sync-GitRemote | Out-Null } finally { Pop-Location }

            Should -Invoke -ModuleName Shmuelie.Git Get-GitHubAccountToken -Times 0
        }

        It 'does not consult gh when -NoGitHubAccountResolve is set' {
            Mock -ModuleName Shmuelie.Git Get-GitHubSignedInAccount { throw 'should not be called' }
            $bare = Join-Path $TestDrive 'noresolve-bare'
            Invoke-Git @('init', '--bare', '--quiet', $bare)
            $repo = New-TestRepo -Path (Join-Path $TestDrive 'noresolve-repo')
            $bareUrl = 'file:///' + ($bare -replace '\\', '/')
            Invoke-Git @('-C', $repo, 'remote', 'add', 'origin', $bareUrl)

            Push-Location $repo
            try { Sync-GitRemote -NoGitHubAccountResolve | Out-Null } finally { Pop-Location }

            Should -Invoke -ModuleName Shmuelie.Git Get-GitHubSignedInAccount -Times 0
        }
    }
}

Describe 'Get-Worktrees' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
    It 'parses normal and detached worktrees' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'worktrees-list-main')
        $head = Invoke-Git @('-C', $repo, 'rev-parse', 'HEAD')
        Invoke-Git @('-C', $repo, 'branch', 'feature/alpha')
        Invoke-Git @('-C', $repo, 'branch', 'feature/beta')
        $alpha = Join-Path $TestDrive (Join-Path 'feature' 'alpha')
        $beta = Join-Path $TestDrive (Join-Path 'feature' 'beta')
        $detached = Join-Path $TestDrive 'detached-worktree'
        Invoke-Git @('-C', $repo, 'worktree', 'add', '--quiet', $alpha, 'feature/alpha')
        Invoke-Git @('-C', $repo, 'worktree', 'add', '--quiet', $beta, 'feature/beta')
        Invoke-Git @('-C', $repo, 'worktree', 'add', '--quiet', '--detach', $detached, 'HEAD')

        Push-Location $repo
        try {
            $worktrees = @(Get-Worktrees)
        } finally {
            Pop-Location
        }

        $worktrees | Should -HaveCount 4
        foreach ($case in @(
            @{ Branch = 'main'; Path = $repo },
            @{ Branch = 'feature/alpha'; Path = $alpha },
            @{ Branch = 'feature/beta'; Path = $beta },
            @{ Branch = '(detached)'; Path = $detached }
        )) {
            $match = @($worktrees | Where-Object Branch -eq $case.Branch)
            $match | Should -HaveCount 1
            $match[0].Path | Should -BeExactly (Resolve-Path -LiteralPath $case.Path).Path
            $match[0].Commit | Should -BeExactly $head
            $match[0].PSTypeNames[0] | Should -Be 'Worktree'
            $match[0].Bare | Should -BeFalse
            $match[0].Locked | Should -BeFalse
            $match[0].LockReason | Should -BeExactly ''
            $match[0].Prunable | Should -BeFalse
            $match[0].PrunableReason | Should -BeExactly ''
            $match[0].Detached | Should -Be ($case.Branch -eq '(detached)')
        }
    }

    It 'reports the lock state and reason for a locked worktree' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'worktrees-locked-main')
        $locked = Join-Path $TestDrive 'locked-worktree'
        Invoke-Git @('-C', $repo, 'worktree', 'add', '--quiet', '--detach', $locked, 'HEAD')
        Invoke-Git @('-C', $repo, 'worktree', 'lock', '--reason', 'held for testing', $locked)

        Push-Location $repo
        try {
            $worktrees = @(Get-Worktrees)
        } finally {
            Pop-Location
        }

        $match = @($worktrees | Where-Object Locked)
        $match | Should -HaveCount 1
        $match[0].Path | Should -BeExactly (Resolve-Path -LiteralPath $locked).Path
        $match[0].Locked | Should -BeTrue
        $match[0].LockReason | Should -BeExactly 'held for testing'
    }

    It 'reports Prunable when the worktree directory is removed' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'worktrees-prunable-main')
        $gone = Join-Path $TestDrive 'gone-worktree'
        Invoke-Git @('-C', $repo, 'worktree', 'add', '--quiet', '--detach', $gone, 'HEAD')
        Remove-Item -LiteralPath $gone -Recurse -Force

        Push-Location $repo
        try {
            $worktrees = @(Get-Worktrees)
        } finally {
            Pop-Location
        }

        $match = @($worktrees | Where-Object Prunable)
        $match | Should -HaveCount 1
        $match[0].Prunable | Should -BeTrue
        $match[0].PrunableReason | Should -Not -BeNullOrEmpty
    }

    It 'reports Bare for a bare repository worktree' {
        $bare = Join-Path $TestDrive 'bare-repo.git'
        Invoke-Git @('init', '--bare', '--quiet', $bare)

        # This machine may set safe.bareRepository=explicit, which makes git refuse
        # to read a bare repo discovered via the working directory. Override it for
        # the Get-Worktrees call so the test behaves the same on any host.
        $priorCount = $env:GIT_CONFIG_COUNT
        $priorKey = $env:GIT_CONFIG_KEY_0
        $priorValue = $env:GIT_CONFIG_VALUE_0
        $env:GIT_CONFIG_COUNT = '1'
        $env:GIT_CONFIG_KEY_0 = 'safe.bareRepository'
        $env:GIT_CONFIG_VALUE_0 = 'all'
        Push-Location $bare
        try {
            $worktrees = @(Get-Worktrees)
        } finally {
            Pop-Location
            if ($null -eq $priorCount) { Remove-Item Env:\GIT_CONFIG_COUNT -ErrorAction SilentlyContinue } else { $env:GIT_CONFIG_COUNT = $priorCount }
            if ($null -eq $priorKey) { Remove-Item Env:\GIT_CONFIG_KEY_0 -ErrorAction SilentlyContinue } else { $env:GIT_CONFIG_KEY_0 = $priorKey }
            if ($null -eq $priorValue) { Remove-Item Env:\GIT_CONFIG_VALUE_0 -ErrorAction SilentlyContinue } else { $env:GIT_CONFIG_VALUE_0 = $priorValue }
        }

        $match = @($worktrees | Where-Object Bare)
        $match | Should -HaveCount 1
        $match[0].Bare | Should -BeTrue
    }
}

Describe 'Get-RepositoryName' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
    It 'derives the repository name from an origin URL ending in .git' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'repo-name-dotgit')
        Invoke-Git @('-C', $repo, 'remote', 'add', 'origin', 'https://github.com/example/repo-name.git')

        Push-Location $repo
        try {
            Get-RepositoryName | Should -BeExactly 'repo-name'
        } finally {
            Pop-Location
        }
    }

    It 'derives the repository name from an origin URL without .git' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'repo-name-no-dotgit')
        Invoke-Git @('-C', $repo, 'remote', 'add', 'origin', 'https://github.com/example/repo-name')

        Push-Location $repo
        try {
            Get-RepositoryName | Should -BeExactly 'repo-name'
        } finally {
            Pop-Location
        }
    }
}

Describe 'Get-RootWorktree and Get-CurrentWorktree' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
    It 'resolves the root and current worktree from a subdirectory of the main worktree' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'current-main')
        $subdir = Join-Path $repo (Join-Path 'src' 'nested')
        New-Item -ItemType Directory -Path $subdir -Force | Out-Null

        Push-Location $subdir
        try {
            $root = Get-RootWorktree
            $current = Get-CurrentWorktree
        } finally {
            Pop-Location
        }

        $root.Path | Should -BeExactly (Resolve-Path -LiteralPath $repo).Path
        $root.Branch | Should -BeExactly 'main'
        $current.Path | Should -BeExactly (Resolve-Path -LiteralPath $repo).Path
        $current.Branch | Should -BeExactly 'main'
    }

    It 'resolves the root and current worktree from an added worktree' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'current-added-main')
        Invoke-Git @('-C', $repo, 'branch', 'feature/current-added')
        $worktree = Join-Path $TestDrive (Join-Path 'feature' 'current-added')
        Invoke-Git @('-C', $repo, 'worktree', 'add', '--quiet', $worktree, 'feature/current-added')
        $subdir = Join-Path $worktree 'child'
        New-Item -ItemType Directory -Path $subdir -Force | Out-Null

        Push-Location $subdir
        try {
            $root = Get-RootWorktree
            $current = Get-CurrentWorktree
        } finally {
            Pop-Location
        }

        $root.Path | Should -BeExactly (Resolve-Path -LiteralPath $repo).Path
        $root.Branch | Should -BeExactly 'main'
        $current.Path | Should -BeExactly (Resolve-Path -LiteralPath $worktree).Path
        $current.Branch | Should -BeExactly 'feature/current-added'
    }
}

Describe 'Get-WorktreePath' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
    It 'constructs the sibling worktree path for a branch name' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'main')
        $branchName = 'feature/path-test'
        $expected = Join-Path (Split-Path $repo -Parent) $branchName

        Push-Location $repo
        try {
            Get-WorktreePath -BranchName $branchName | Should -BeExactly $expected
        } finally {
            Pop-Location
        }
    }
}

Describe 'New-Worktree' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
    It 'does not create a branch or worktree when WhatIf is used' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'new-worktree-whatif-main')
        $branchName = 'user/tester/dry-run'
        $expectedPath = Join-Path (Split-Path $repo -Parent) $branchName

        Push-Location -LiteralPath $repo -ErrorAction Stop
        try {
            $transcriptPath = Join-Path $TestDrive 'new-worktree-auto-whatif.txt'
            Start-Transcript -Path $transcriptPath -Force | Out-Null
            try {
                New-Worktree -WorkName 'dry-run' -UserName 'tester' -WhatIf -Confirm:$false
            } finally {
                Stop-Transcript | Out-Null
            }
            (Get-Content -LiteralPath $transcriptPath -Raw) | Should -Match ([regex]::Escape($expectedPath))
            Test-Path -LiteralPath $expectedPath | Should -BeFalse
            Invoke-Git @('-C', $repo, 'branch', '--list', $branchName) | Should -BeNullOrEmpty
            (Get-Location).Path | Should -BeExactly (Resolve-Path -LiteralPath $repo).Path
        } finally {
            Pop-Location
        }
    }

    It 'creates a user-prefixed branch and worktree at the expected path' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'new-worktree-user-main')
        $branchName = 'user/tester/happy-path'
        $expectedPath = Join-Path (Split-Path $repo -Parent) $branchName

        Push-Location -LiteralPath $repo -ErrorAction Stop
        try {
            New-Worktree -WorkName 'happy-path' -UserName 'tester' -Confirm:$false
            (Get-Location).Path | Should -BeExactly (Resolve-Path -LiteralPath $expectedPath).Path
            Test-Path -LiteralPath $expectedPath | Should -BeTrue
            Invoke-Git @('-C', $repo, 'rev-parse', '--verify', $branchName) | Should -Not -BeNullOrEmpty
            (@(Get-Worktrees) | Where-Object Branch -eq $branchName).Path | Should -BeExactly (Resolve-Path -LiteralPath $expectedPath).Path
        } finally {
            Pop-Location
        }
    }

    It 'creates a new branch and worktree at an explicit worktree path' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'new-worktree-explicit-main')
        $branchName = 'user/tester/explicit-path'
        $customPath = Join-Path $TestDrive 'custom-new-explicit'

        Push-Location -LiteralPath $repo -ErrorAction Stop
        try {
            New-Worktree -WorkName 'explicit-path' -UserName 'tester' -WorktreePath $customPath -Confirm:$false
            (Get-Location).Path | Should -BeExactly (Resolve-Path -LiteralPath $customPath).Path
            Test-Path -LiteralPath $customPath | Should -BeTrue
            Invoke-Git @('-C', $repo, 'rev-parse', '--verify', $branchName) | Should -Not -BeNullOrEmpty
            (@(Get-Worktrees) | Where-Object Branch -eq $branchName).Path |
                Should -BeExactly (Resolve-Path -LiteralPath $customPath).Path
        } finally {
            Pop-Location
        }
    }

    It 'changes location to the resolved explicit worktree path for a new branch when SetLocation is used' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'new-worktree-setlocation-main')
        $customPath = Join-Path $TestDrive 'custom-new-setlocation'

        Push-Location -LiteralPath $repo -ErrorAction Stop
        try {
            New-Worktree -WorkName 'setlocation-path' -UserName 'tester' -WorktreePath $customPath -SetLocation -Confirm:$false
            (Get-Location).Path | Should -BeExactly (Resolve-Path -LiteralPath $customPath).Path
        } finally {
            Pop-Location
        }
    }

    It 'reports an explicit worktree path in WhatIf output and creates nothing' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'new-worktree-explicit-whatif-main')
        $branchName = 'user/tester/explicit-dry-run'
        $customPath = Join-Path $TestDrive 'custom-new-explicit-whatif'

        Push-Location -LiteralPath $repo -ErrorAction Stop
        try {
            $transcriptPath = Join-Path $TestDrive 'new-worktree-explicit-whatif.txt'
            Start-Transcript -Path $transcriptPath -Force | Out-Null
            try {
                New-Worktree -WorkName 'explicit-dry-run' -UserName 'tester' -WorktreePath $customPath -WhatIf -Confirm:$false
            } finally {
                Stop-Transcript | Out-Null
            }
            (Get-Content -LiteralPath $transcriptPath -Raw) | Should -Match ([regex]::Escape($customPath))
            Test-Path -LiteralPath $customPath | Should -BeFalse
            Invoke-Git @('-C', $repo, 'branch', '--list', $branchName) | Should -BeNullOrEmpty
            (Get-Location).Path | Should -BeExactly (Resolve-Path -LiteralPath $repo).Path
        } finally {
            Pop-Location
        }
    }

    It 'creates an unprefixed branch and worktree when NoPrefix is used' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'new-worktree-noprefix-main')
        $branchName = 'plain-work'
        $expectedPath = Join-Path (Split-Path $repo -Parent) $branchName

        Push-Location -LiteralPath $repo -ErrorAction Stop
        try {
            New-Worktree -WorkName $branchName -NoPrefix -Confirm:$false
            (Get-Location).Path | Should -BeExactly (Resolve-Path -LiteralPath $expectedPath).Path
            Test-Path -LiteralPath $expectedPath | Should -BeTrue
            Invoke-Git @('-C', $repo, 'rev-parse', '--verify', $branchName) | Should -Not -BeNullOrEmpty
            (@(Get-Worktrees) | Where-Object Branch -eq $branchName).Path | Should -BeExactly (Resolve-Path -LiteralPath $expectedPath).Path
        } finally {
            Pop-Location
        }
    }
}

Describe 'Remove-Worktree' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
    BeforeAll {
        $removalLocation = Get-Location
        $removalRoot = Join-Path $TestDrive 'remove-worktree'
        $null = New-Item -ItemType Directory -Path $removalRoot -ErrorAction Stop
        $removalEnvironment = @{}
        foreach ($key in @(
            'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_SYSTEM', 'GIT_CONFIG_NOSYSTEM',
            'GIT_CONFIG_COUNT', 'GIT_CONFIG_PARAMETERS', 'GIT_DIR', 'GIT_WORK_TREE',
            'GIT_COMMON_DIR', 'GIT_INDEX_FILE', 'GIT_OBJECT_DIRECTORY',
            'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_NAMESPACE', 'GIT_CEILING_DIRECTORIES',
            'GIT_DEFAULT_HASH', 'GIT_DEFAULT_REF_FORMAT', 'GIT_AUTHOR_DATE', 'GIT_COMMITTER_DATE'
        )) {
            $removalEnvironment[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
            Remove-Item -LiteralPath "Env:$key" -ErrorAction Ignore
        }
        $env:GIT_CONFIG_GLOBAL = Join-Path $removalRoot 'no-global-config'
        $env:GIT_CONFIG_SYSTEM = Join-Path $removalRoot 'no-system-config'
        $env:GIT_CONFIG_NOSYSTEM = '1'
        $env:GIT_CONFIG_COUNT = '0'
        $PSNativeCommandUseErrorActionPreference = $false

        function Assert-RemovalFixturePath {
            param([Parameter(Mandatory)][string]$Path)
            $root = [IO.Path]::GetFullPath((Join-Path $TestDrive 'remove-worktree'))
            $full = [IO.Path]::GetFullPath($Path)
            if ($root -ne $removalRoot -or
                -not $full.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::Ordinal) -or
                -not (Test-Path -LiteralPath $full -PathType Container)) {
                throw "Not an owned removal fixture: $Path"
            }
            $item = Get-Item -LiteralPath $full -ErrorAction Stop
            while ($item.FullName -ne $root) {
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked fixture: $Path" }
                $item = $item.Parent
            }
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked fixture root: $root" }
        }

        function Invoke-RemovalGit {
            param([Parameter(Mandatory)][string[]]$Arguments, [string]$Path = $removalRepo)
            Assert-RemovalFixturePath $Path
            Invoke-Git (@('-C', $Path) + $Arguments)
        }

        function Get-RemovalBranches {
            @(Invoke-RemovalGit @('for-each-ref', '--format=%(refname)', 'refs/heads/'))
        }

        function Invoke-RemovalWithHost {
            param([int[]]$Answers = @(), [hashtable]$Options = @{})
            Assert-RemovalFixturePath $removalRepo
            $hostStub = [WorktreeRemovalConfirmationHost]::new()
            foreach ($answer in $Answers) { $hostStub.PromptUI.Answers.Enqueue($answer) }
            $runspace = [runspacefactory]::CreateRunspace($hostStub)
            $powershell = [powershell]::Create()
            try {
                $runspace.Open()
                $powershell.Runspace = $runspace
                $null = $powershell.AddScript({
                    param($moduleRoot, $path, $target, $options)
                    $ErrorActionPreference = 'Stop'
                    $ConfirmPreference = 'High'
                    Set-Location -LiteralPath $path -ErrorAction Stop
                    if ((Get-Location).ProviderPath -ne $path) { throw 'Fixture location was not entered.' }
                    Import-Module (Join-Path $moduleRoot 'modules' 'Shmuelie.Git' 'Shmuelie.Git.psd1')
                    try {
                        Remove-Worktree -Path $target @options
                    } finally {
                        Remove-Module Shmuelie.Git
                    }
                }.ToString()).AddArgument($repoRoot).AddArgument($removalRepo).
                    AddArgument($removalTarget).AddArgument($Options)
                $null = $powershell.Invoke()
                $powershell.HadErrors | Should -BeFalse -Because ($powershell.Streams.Error -join "`n")
                $hostStub
            } finally {
                $powershell.Dispose()
                $runspace.Dispose()
            }
        }

        if (-not ('WorktreeRemovalConfirmationHost' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Management.Automation;
using System.Management.Automation.Host;
using System.Security;

public sealed class WorktreeRemovalConfirmationHost : PSHost
{
    public readonly WorktreeRemovalConfirmationUI PromptUI = new WorktreeRemovalConfirmationUI();
    public override Guid InstanceId { get; } = Guid.NewGuid();
    public override string Name => "WorktreeRemovalConfirmationHost";
    public override Version Version => new Version(1, 0);
    public override PSHostUserInterface UI => PromptUI;
    public override CultureInfo CurrentCulture => CultureInfo.InvariantCulture;
    public override CultureInfo CurrentUICulture => CultureInfo.InvariantCulture;
    public override void SetShouldExit(int exitCode) { }
    public override void EnterNestedPrompt() => throw new NotSupportedException();
    public override void ExitNestedPrompt() => throw new NotSupportedException();
    public override void NotifyBeginApplication() { }
    public override void NotifyEndApplication() { }
}

public sealed class WorktreeRemovalConfirmationUI : PSHostUserInterface
{
    public readonly Queue<int> Answers = new Queue<int>();
    public readonly List<string> Prompts = new List<string>();
    public readonly List<string> Messages = new List<string>();
    public override PSHostRawUserInterface RawUI => null;
    public override int PromptForChoice(string caption, string message, Collection<ChoiceDescription> choices, int defaultChoice)
    {
        Prompts.Add(message);
        if (Answers.Count == 0) throw new InvalidOperationException("Unexpected confirmation prompt.");
        return Answers.Dequeue();
    }
    public override string ReadLine() => throw new NotSupportedException();
    public override SecureString ReadLineAsSecureString() => throw new NotSupportedException();
    public override Dictionary<string, PSObject> Prompt(string caption, string message, Collection<FieldDescription> descriptions) => throw new NotSupportedException();
    public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName) => throw new NotSupportedException();
    public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName, PSCredentialTypes types, PSCredentialUIOptions options) => throw new NotSupportedException();
    public override void Write(string value) => Messages.Add(value);
    public override void Write(ConsoleColor foreground, ConsoleColor background, string value) => Messages.Add(value);
    public override void WriteLine(string value) => Messages.Add(value);
    public override void WriteErrorLine(string value) => Messages.Add(value);
    public override void WriteDebugLine(string value) => Messages.Add(value);
    public override void WriteVerboseLine(string value) => Messages.Add(value);
    public override void WriteWarningLine(string value) => Messages.Add(value);
    public override void WriteProgress(long sourceId, ProgressRecord record) { }
}
'@
        }
    }

    BeforeEach {
        $removalSandbox = Join-Path $removalRoot 'case'
        $null = New-Item -ItemType Directory -Path $removalSandbox -ErrorAction Stop
        Assert-RemovalFixturePath $removalSandbox
        $removalRepo = New-TestRepo -Path (Join-Path $removalSandbox 'main')
        Assert-RemovalFixturePath $removalRepo
        $gitDir = Get-Item -LiteralPath (Join-Path $removalRepo '.git') -Force -ErrorAction Stop
        if (-not $gitDir.PSIsContainer -or $gitDir.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Fixture must own its git directory.'
        }
        $removalBranch = 'feature/remove-target'
        $removalTarget = Join-Path $removalSandbox 'custom worktree [target]'
        Invoke-RemovalGit @('worktree', 'add', '--quiet', '-b', $removalBranch, $removalTarget)
        Set-Location -LiteralPath $removalRepo -ErrorAction Stop
        if ((Get-Location).ProviderPath -ne $removalRepo) { throw 'Fixture location was not entered.' }
    }

    AfterEach {
        Set-Location -LiteralPath $removalRoot -ErrorAction Stop
        if ($removalSandbox -and (Test-Path -LiteralPath $removalSandbox)) {
            Assert-RemovalFixturePath $removalSandbox
            Get-ChildItem -LiteralPath $removalSandbox -Recurse -Force -File -ErrorAction Stop |
                ForEach-Object { $_.IsReadOnly = $false }
            Remove-Item -LiteralPath $removalSandbox -Recurse -Force -ErrorAction Stop
        }
    }

    AfterAll {
        try {
            Set-Location -LiteralPath $removalLocation.ProviderPath -ErrorAction Stop
        } finally {
            foreach ($key in $removalEnvironment.Keys) {
                if ($null -eq $removalEnvironment[$key]) {
                    Remove-Item -LiteralPath "Env:$key" -ErrorAction Ignore
                } else {
                    [Environment]::SetEnvironmentVariable($key, $removalEnvironment[$key], 'Process')
                }
            }
        }
    }

    It 'declares high-impact confirmation and documents the cleanup switches' {
        $command = Get-Command Remove-Worktree -Module Shmuelie.Git
        $binding = $command.ScriptBlock.Attributes |
            Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] }
        $binding.SupportsShouldProcess | Should -BeTrue
        $binding.ConfirmImpact | Should -Be 'High'
        $command.Parameters.Keys | Should -Contain 'KeepBranch'
        $command.Parameters.Keys | Should -Contain 'RemoveBranch'
        (Get-Help Remove-Worktree).Description.Text | Should -Match 'unmerged'
    }

    It 'removes only the target worktree and branch using <InputKind>' -ForEach @(
        @{ InputKind = 'standard layout' }, @{ InputKind = 'branch' },
        @{ InputKind = 'path' }, @{ InputKind = 'pipeline' }
    ) {
        if ($InputKind -eq 'standard layout') {
            $standardPath = Join-Path $removalSandbox $removalBranch
            $null = New-Item -ItemType Directory -Path (Split-Path $standardPath -Parent) -ErrorAction Stop
            Invoke-RemovalGit @('worktree', 'move', $removalTarget, $standardPath)
            $removalTarget = $standardPath
        }
        $keeper = Join-Path $removalSandbox 'keep'
        Invoke-RemovalGit @('worktree', 'add', '--quiet', '-b', 'feature/keep', $keeper)
        switch ($InputKind) {
            'standard layout' { Remove-Worktree -BranchName $removalBranch -Confirm:$false }
            branch { Remove-Worktree -BranchName $removalBranch -Confirm:$false }
            path { Remove-Worktree -Path $removalTarget -Confirm:$false }
            pipeline { Get-Worktrees | Where-Object Branch -eq $removalBranch | Remove-Worktree -Confirm:$false }
        }
        Test-Path -LiteralPath $removalTarget | Should -BeFalse
        Test-Path -LiteralPath $keeper | Should -BeTrue
        Get-RemovalBranches | Should -Not -Contain "refs/heads/$removalBranch"
        Get-RemovalBranches | Should -Contain 'refs/heads/feature/keep'
        Get-RemovalBranches | Should -Contain 'refs/heads/main'
        @(Get-Worktrees | Where-Object Branch -eq $removalBranch) | Should -HaveCount 0
        @(Get-Worktrees | Where-Object Branch -eq 'feature/keep') | Should -HaveCount 1
    }

    It 'honors <Mode> switch values' -ForEach @(
        @{ Mode = 'KeepBranch'; Options = @{ KeepBranch = $true }; Keep = $true }
        @{ Mode = 'legacy false'; Options = @{ RemoveBranch = $false }; Keep = $true }
        @{ Mode = 'both keep requests'; Options = @{ KeepBranch = $true; RemoveBranch = $false }; Keep = $true }
        @{ Mode = 'both false'; Options = @{ KeepBranch = $false; RemoveBranch = $false }; Keep = $true }
        @{ Mode = 'legacy true'; Options = @{ RemoveBranch = $true }; Keep = $false }
        @{ Mode = 'KeepBranch false'; Options = @{ KeepBranch = $false }; Keep = $false }
        @{ Mode = 'both delete requests'; Options = @{ KeepBranch = $false; RemoveBranch = $true }; Keep = $false }
    ) {
        Remove-Worktree -Path $removalTarget @Options -Confirm:$false
        Test-Path -LiteralPath $removalTarget | Should -BeFalse
        ((Get-RemovalBranches) -contains "refs/heads/$removalBranch") | Should -Be $Keep
    }

    It 'rejects conflicting switches before removal even for WhatIf=<Preview>' -ForEach @(
        @{ Preview = $false }, @{ Preview = $true }
    ) {
        { Remove-Worktree -Path $removalTarget -KeepBranch -RemoveBranch -WhatIf:$Preview -Confirm:$false } |
            Should -Throw '*KeepBranch and RemoveBranch cannot both be enabled*'
        Test-Path -LiteralPath $removalTarget | Should -BeTrue
        Get-RemovalBranches | Should -Contain "refs/heads/$removalBranch"
    }

    It 'previews <Mode> without changing either resource' -ForEach @(
        @{ Mode = 'default'; Options = @{ WhatIf = $true }; BranchPreview = $true }
        @{ Mode = 'forced'; Options = @{ WhatIf = $true; Force = $true }; BranchPreview = $true }
        @{ Mode = 'legacy'; Options = @{ WhatIf = $true; RemoveBranch = $true }; BranchPreview = $true }
        @{ Mode = 'kept branch'; Options = @{ WhatIf = $true; KeepBranch = $true }; BranchPreview = $false }
        @{ Mode = 'legacy false'; Options = @{ WhatIf = $true; RemoveBranch = $false }; BranchPreview = $false }
    ) {
        $hostStub = Invoke-RemovalWithHost -Options $Options
        $hostStub.PromptUI.Prompts.Count | Should -Be 0
        $messages = $hostStub.PromptUI.Messages -join "`n"
        $messages | Should -Match 'Remove worktree'
        $messages | Should -Match ([regex]::Escape($removalTarget))
        ($messages -match 'Delete local branch') | Should -Be $BranchPreview
        if ($BranchPreview) { $messages | Should -Match ([regex]::Escape($removalBranch)) }
        Test-Path -LiteralPath $removalTarget | Should -BeTrue
        Get-RemovalBranches | Should -Contain "refs/heads/$removalBranch"
        @(Get-Worktrees | Where-Object Branch -eq $removalBranch) | Should -HaveCount 1
    }

    It 'handles <Mode> confirmation independently for each mutation' -ForEach @(
        @{ Mode = 'implicit refusal'; Answers = @(2); Options = @{}; WorktreeRemains = $true; BranchRemains = $true }
        @{ Mode = 'explicit refusal'; Answers = @(2); Options = @{ Confirm = $true }; WorktreeRemains = $true; BranchRemains = $true }
        @{ Mode = 'forced refusal'; Answers = @(2); Options = @{ Force = $true }; WorktreeRemains = $true; BranchRemains = $true }
        @{ Mode = 'declined branch deletion'; Answers = @(0, 2); Options = @{}; WorktreeRemains = $false; BranchRemains = $true }
        @{ Mode = 'both approved'; Answers = @(0, 0); Options = @{}; WorktreeRemains = $false; BranchRemains = $false }
        @{ Mode = 'kept branch approved'; Answers = @(0); Options = @{ KeepBranch = $true }; WorktreeRemains = $false; BranchRemains = $true }
        @{ Mode = 'unattended'; Answers = @(); Options = @{ Confirm = $false }; WorktreeRemains = $false; BranchRemains = $false }
    ) {
        $hostStub = Invoke-RemovalWithHost -Answers $Answers -Options $Options
        $hostStub.PromptUI.Prompts.Count | Should -Be $Answers.Count
        if ($Answers.Count -gt 0) { $hostStub.PromptUI.Prompts[0] | Should -Match 'Remove worktree' }
        if ($Answers.Count -gt 1) { $hostStub.PromptUI.Prompts[1] | Should -Match 'Delete local branch' }
        (Test-Path -LiteralPath $removalTarget) | Should -Be $WorktreeRemains
        ((Get-RemovalBranches) -contains "refs/heads/$removalBranch") | Should -Be $BranchRemains
    }

    It 'retains the existing deletion of unmerged branches with <Mode>' -ForEach @(
        @{ Mode = 'default'; Options = @{} }, @{ Mode = 'legacy'; Options = @{ RemoveBranch = $true } }
    ) {
        Invoke-RemovalGit -Path $removalTarget @('commit', '--allow-empty', '--quiet', '-m', 'unmerged work')
        Invoke-RemovalGit @('rev-list', '--count', "main..$removalBranch") | Should -Be '1'
        Remove-Worktree -Path $removalTarget @Options -Confirm:$false
        Test-Path -LiteralPath $removalTarget | Should -BeFalse
        Get-RemovalBranches | Should -Not -Contain "refs/heads/$removalBranch"
    }

    It 'preserves the branch after a <Reason> removal failure' -ForEach @(
        @{ Reason = 'dirty'; Locked = $false; UseForce = $false }
        @{ Reason = 'locked'; Locked = $true; UseForce = $false }
        @{ Reason = 'locked with one force'; Locked = $true; UseForce = $true }
    ) {
        if ($Locked) {
            Invoke-RemovalGit @('worktree', 'lock', '--reason', 'fixture lock', $removalTarget)
        } else {
            Set-Content -LiteralPath (Join-Path $removalTarget 'README.md') -Value 'keep local changes'
        }
        $warnings = @()
        Remove-Worktree -Path $removalTarget -Force:$UseForce -Confirm:$false -WarningVariable warnings -WarningAction SilentlyContinue 2>$null
        Test-Path -LiteralPath $removalTarget | Should -BeTrue
        Get-RemovalBranches | Should -Contain "refs/heads/$removalBranch"
        ($warnings -join "`n") | Should -Match 'Worktree removal failed; leaving branch'
        if (-not $Locked) {
            Get-Content -LiteralPath (Join-Path $removalTarget 'README.md') | Should -Be 'keep local changes'
        }
    }

    It 'removes a dirty worktree only when explicitly forced, with KeepBranch=<Keep>' -ForEach @(
        @{ Keep = $false }, @{ Keep = $true }
    ) {
        Set-Content -LiteralPath (Join-Path $removalTarget 'README.md') -Value 'discard local changes'
        Remove-Worktree -Path $removalTarget -Force -KeepBranch:$Keep -Confirm:$false
        Test-Path -LiteralPath $removalTarget | Should -BeFalse
        ((Get-RemovalBranches) -contains "refs/heads/$removalBranch") | Should -Be $Keep
    }

    It 'removes a detached worktree by pipeline path without deleting any branch, legacy=<Legacy>' -ForEach @(
        @{ Legacy = $false }, @{ Legacy = $true }
    ) {
        Invoke-RemovalGit -Path $removalTarget @('switch', '--quiet', '--detach')
        $keeper = Join-Path $removalSandbox 'detached-keep'
        Invoke-RemovalGit @('worktree', 'add', '--quiet', '--detach', $keeper, 'HEAD')
        $branches = Get-RemovalBranches
        $options = if ($Legacy) { @{ RemoveBranch = $true } } else { @{} }
        Get-Worktrees | Where-Object Path -eq $removalTarget |
            Remove-Worktree @options -Confirm:$false -WarningAction SilentlyContinue
        Test-Path -LiteralPath $removalTarget | Should -BeFalse
        Test-Path -LiteralPath $keeper | Should -BeTrue
        Get-RemovalBranches | Should -Be $branches
        @(Get-Worktrees | Where-Object Detached) | Should -HaveCount 1
    }

    It 'previews only worktree removal for a detached target' {
        Invoke-RemovalGit -Path $removalTarget @('switch', '--quiet', '--detach')
        $hostStub = Invoke-RemovalWithHost -Options @{ WhatIf = $true }
        ($hostStub.PromptUI.Messages -join "`n") | Should -Match 'Remove worktree'
        ($hostStub.PromptUI.Messages -join "`n") | Should -Not -Match 'Delete local branch'
        Test-Path -LiteralPath $removalTarget | Should -BeTrue
        Get-RemovalBranches | Should -Contain "refs/heads/$removalBranch"
    }

    It 'removes a prunable worktree entry by path with Detached=<Detached>' -ForEach @(
        @{ Detached = $false }, @{ Detached = $true }
    ) {
        if ($Detached) { Invoke-RemovalGit -Path $removalTarget @('switch', '--quiet', '--detach') }
        Assert-RemovalFixturePath $removalTarget
        Remove-Item -LiteralPath $removalTarget -Recurse -Force -ErrorAction Stop
        $entry = @(Get-Worktrees | Where-Object Prunable)
        $entry | Should -HaveCount 1
        Remove-Worktree -Path $entry[0].Path -Confirm:$false
        @(Get-Worktrees | Where-Object Prunable) | Should -HaveCount 0
        ((Get-RemovalBranches) -contains "refs/heads/$removalBranch") | Should -Be $Detached
    }
}

Describe 'Move-Worktree' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
    It 'moves a worktree by branch name to the requested destination' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'move-worktree-main')
        $branch = 'feature/move-target'
        $oldPath = Join-Path $TestDrive (Join-Path 'feature' 'move-target')
        $newPath = Join-Path $TestDrive 'moved-target'
        Invoke-Git @('-C', $repo, 'branch', $branch)
        Invoke-Git @('-C', $repo, 'worktree', 'add', '--quiet', $oldPath, $branch)
        $oldResolved = (Resolve-Path -LiteralPath $oldPath).Path

        Push-Location $repo
        try {
            $result = Move-Worktree -BranchName $branch -DestinationPath $newPath -Confirm:$false
            Test-Path -LiteralPath $oldPath | Should -BeFalse
            Test-Path -LiteralPath $newPath | Should -BeTrue
            (@(Get-Worktrees) | Where-Object Branch -eq $branch).Path |
                Should -BeExactly (Resolve-Path -LiteralPath $newPath).Path
            $result.PSTypeNames[0] | Should -Be 'WorktreeMoveResult'
            $result.Branch | Should -BeExactly $branch
            $result.OldPath | Should -BeExactly $oldResolved
            $result.NewPath | Should -BeExactly (Resolve-Path -LiteralPath $newPath).Path
        } finally {
            Pop-Location
        }
    }

    It 'does not move a worktree when WhatIf is used' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'move-worktree-whatif-main')
        $branch = 'feature/move-whatif'
        $oldPath = Join-Path $TestDrive (Join-Path 'feature' 'move-whatif')
        $newPath = Join-Path $TestDrive 'moved-whatif'
        Invoke-Git @('-C', $repo, 'branch', $branch)
        Invoke-Git @('-C', $repo, 'worktree', 'add', '--quiet', $oldPath, $branch)

        Push-Location $repo
        try {
            Move-Worktree -BranchName $branch -DestinationPath $newPath -WhatIf -Confirm:$false
            Test-Path -LiteralPath $oldPath | Should -BeTrue
            Test-Path -LiteralPath $newPath | Should -BeFalse
            (@(Get-Worktrees) | Where-Object Branch -eq $branch).Path |
                Should -BeExactly (Resolve-Path -LiteralPath $oldPath).Path
        } finally {
            Pop-Location
        }
    }

    It 'refuses to move the main/root worktree with a clear error' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'move-worktree-root-main')
        $newPath = Join-Path $TestDrive 'moved-root'

        Push-Location $repo
        try {
            { Move-Worktree -BranchName 'main' -DestinationPath $newPath -Confirm:$false -ErrorAction Stop } |
                Should -Throw -ExpectedMessage '*main/root worktree*cannot be moved*'
            Test-Path -LiteralPath $repo | Should -BeTrue
            Test-Path -LiteralPath $newPath | Should -BeFalse
        } finally {
            Pop-Location
        }
    }

    It 'refuses to move into an existing destination path' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'move-worktree-destination-exists-main')
        $branch = 'feature/move-destination-exists'
        $oldPath = Join-Path $TestDrive (Join-Path 'feature' 'move-destination-exists')
        $newPath = Join-Path $TestDrive 'existing-move-destination'
        Invoke-Git @('-C', $repo, 'branch', $branch)
        Invoke-Git @('-C', $repo, 'worktree', 'add', '--quiet', $oldPath, $branch)
        New-Item -ItemType Directory -Path $newPath -Force | Out-Null
        Set-Content -Path (Join-Path $newPath 'file.txt') -Value 'existing'

        Push-Location $repo
        try {
            { Move-Worktree -BranchName $branch -DestinationPath $newPath -Confirm:$false -ErrorAction Stop } |
                Should -Throw -ExpectedMessage '*Destination path*already exists*'
            Test-Path -LiteralPath $oldPath | Should -BeTrue
            (@(Get-Worktrees) | Where-Object Branch -eq $branch).Path |
                Should -BeExactly (Resolve-Path -LiteralPath $oldPath).Path
        } finally {
            Pop-Location
        }
    }

    It 'surfaces a clear git error when git rejects the move' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'move-worktree-locked-main')
        $branch = 'feature/move-locked'
        $oldPath = Join-Path $TestDrive (Join-Path 'feature' 'move-locked')
        $newPath = Join-Path $TestDrive 'moved-locked'
        Invoke-Git @('-C', $repo, 'branch', $branch)
        Invoke-Git @('-C', $repo, 'worktree', 'add', '--quiet', $oldPath, $branch)
        Invoke-Git @('-C', $repo, 'worktree', 'lock', '--reason', 'test lock', $oldPath)

        Push-Location $repo
        try {
            { Move-Worktree -BranchName $branch -DestinationPath $newPath -Confirm:$false -ErrorAction Stop } |
                Should -Throw -ExpectedMessage '*git worktree move failed*locked*'
            Test-Path -LiteralPath $oldPath | Should -BeTrue
            Test-Path -LiteralPath $newPath | Should -BeFalse
        } finally {
            Pop-Location
        }
    }

    It 'moves a worktree from pipeline input by property name' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'move-worktree-pipeline-main')
        $branch = 'feature/move-pipeline'
        $oldPath = Join-Path $TestDrive (Join-Path 'feature' 'move-pipeline')
        $newPath = Join-Path $TestDrive 'moved-pipeline'
        Invoke-Git @('-C', $repo, 'branch', $branch)
        Invoke-Git @('-C', $repo, 'worktree', 'add', '--quiet', $oldPath, $branch)

        Push-Location $repo
        try {
            $result = Get-Worktrees | Where-Object Branch -eq $branch | Move-Worktree -DestinationPath $newPath -Confirm:$false
            Test-Path -LiteralPath $oldPath | Should -BeFalse
            Test-Path -LiteralPath $newPath | Should -BeTrue
            $result.Branch | Should -BeExactly $branch
            (@(Get-Worktrees) | Where-Object Branch -eq $branch).Path |
                Should -BeExactly (Resolve-Path -LiteralPath $newPath).Path
        } finally {
            Pop-Location
        }
    }

    It 'resolves a relative destination against the caller PowerShell location' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'move-worktree-relative-main')
        $branch = 'feature/move-relative'
        $oldPath = Join-Path $TestDrive (Join-Path 'feature' 'move-relative')
        Invoke-Git @('-C', $repo, 'branch', $branch)
        Invoke-Git @('-C', $repo, 'worktree', 'add', '--quiet', $oldPath, $branch)

        Push-Location $repo
        try {
            $result = Move-Worktree -BranchName $branch -DestinationPath 'moved-relative-here' -Confirm:$false
            $expected = Join-Path $repo 'moved-relative-here'
            Test-Path -LiteralPath $expected | Should -BeTrue
            Test-Path -LiteralPath $oldPath | Should -BeFalse
            $result.NewPath | Should -BeExactly (Resolve-Path -LiteralPath $expected).Path
        } finally {
            Pop-Location
        }
    }

    It 'changes to the moved worktree path when -SetLocation is used' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'move-worktree-setloc-main')
        $branch = 'feature/move-setloc'
        $oldPath = Join-Path $TestDrive (Join-Path 'feature' 'move-setloc')
        $newPath = Join-Path $TestDrive 'moved-setloc'
        Invoke-Git @('-C', $repo, 'branch', $branch)
        Invoke-Git @('-C', $repo, 'worktree', 'add', '--quiet', $oldPath, $branch)

        Push-Location $repo
        try {
            Move-Worktree -BranchName $branch -DestinationPath $newPath -SetLocation -Confirm:$false
            (Get-Location).ProviderPath | Should -BeExactly (Resolve-Path -LiteralPath $newPath).Path
        } finally {
            Pop-Location
        }
    }
}

Describe 'Worktree maintenance' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
    It 'prunes stale worktree entries' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'prune-stale-main')
        Invoke-Git @('-C', $repo, 'branch', 'feature/prune-stale')
        $worktree = Join-Path $TestDrive (Join-Path 'feature' 'prune-stale')
        Invoke-Git @('-C', $repo, 'worktree', 'add', '--quiet', $worktree, 'feature/prune-stale')
        Remove-Item -LiteralPath $worktree -Recurse -Force

        Push-Location $repo
        try {
            (@(Get-Worktrees) | Where-Object Prunable) | Should -HaveCount 1
            $result = Remove-StaleWorktree -Expire now -Confirm:$false
            $result.PSTypeNames[0] | Should -Be 'WorktreeMaintenanceResult'
            $result.Command | Should -BeExactly 'prune'
            $result.DryRun | Should -BeFalse
            $result.ExitCode | Should -Be 0
            (@(Get-Worktrees) | Where-Object Branch -eq 'feature/prune-stale') | Should -BeNullOrEmpty
        } finally {
            Pop-Location
        }
    }

    It 'leaves stale worktree entries in place when DryRun is used' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'prune-dryrun-main')
        Invoke-Git @('-C', $repo, 'branch', 'feature/prune-dryrun')
        $worktree = Join-Path $TestDrive (Join-Path 'feature' 'prune-dryrun')
        Invoke-Git @('-C', $repo, 'worktree', 'add', '--quiet', $worktree, 'feature/prune-dryrun')
        Remove-Item -LiteralPath $worktree -Recurse -Force

        Push-Location $repo
        try {
            $result = Remove-StaleWorktree -DryRun -Expire now -Confirm:$false
            $result.DryRun | Should -BeTrue
            $result.ExitCode | Should -Be 0
            (@(Get-Worktrees) | Where-Object Branch -eq 'feature/prune-dryrun') | Should -HaveCount 1
            (@(Get-Worktrees) | Where-Object Prunable) | Should -HaveCount 1
        } finally {
            Pop-Location
        }
    }

    It 'leaves stale worktree entries in place when WhatIf is used' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'prune-whatif-main')
        Invoke-Git @('-C', $repo, 'branch', 'feature/prune-whatif')
        $worktree = Join-Path $TestDrive (Join-Path 'feature' 'prune-whatif')
        Invoke-Git @('-C', $repo, 'worktree', 'add', '--quiet', $worktree, 'feature/prune-whatif')
        Remove-Item -LiteralPath $worktree -Recurse -Force

        Push-Location $repo
        try {
            $result = Remove-StaleWorktree -Expire now -WhatIf -Confirm:$false
            $result.DryRun | Should -BeTrue
            $result.ExitCode | Should -Be 0
            (@(Get-Worktrees) | Where-Object Branch -eq 'feature/prune-whatif') | Should -HaveCount 1
            (@(Get-Worktrees) | Where-Object Prunable) | Should -HaveCount 1
        } finally {
            Pop-Location
        }
    }

    It 'repairs a moved worktree path' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'repair-worktree-main')
        Invoke-Git @('-C', $repo, 'branch', 'feature/repair-target')
        $worktree = Join-Path $TestDrive (Join-Path 'feature' 'repair-target')
        Invoke-Git @('-C', $repo, 'worktree', 'add', '--quiet', $worktree, 'feature/repair-target')
        $movedParent = Join-Path $TestDrive 'moved-worktrees'
        $movedWorktree = Join-Path $movedParent 'repair-target'
        New-Item -ItemType Directory -Path $movedParent -Force | Out-Null
        Move-Item -LiteralPath $worktree -Destination $movedWorktree

        Push-Location $repo
        try {
            $result = Repair-Worktree -Path $movedWorktree -Confirm:$false
            $result.PSTypeNames[0] | Should -Be 'WorktreeMaintenanceResult'
            $result.Command | Should -BeExactly 'repair'
            $result.Paths | Should -Be @($movedWorktree)
            $result.ExitCode | Should -Be 0
            Invoke-Git @('-C', $movedWorktree, 'status', '--short') | Should -BeNullOrEmpty
            $match = @((Get-Worktrees) | Where-Object Branch -eq 'feature/repair-target')
            $match | Should -HaveCount 1
            $match[0].Path | Should -BeExactly (Resolve-Path -LiteralPath $movedWorktree).Path
        } finally {
            Pop-Location
        }
    }
}

Describe 'Set-Worktree' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
    It 'changes the current location to the requested standard-layout worktree by branch name' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'set-worktree-main')
        Invoke-Git @('-C', $repo, 'branch', 'feature/set-target')
        $worktree = Join-Path $TestDrive (Join-Path 'feature' 'set-target')
        Invoke-Git @('-C', $repo, 'worktree', 'add', '--quiet', $worktree, 'feature/set-target')

        Push-Location $repo
        try {
            Set-Worktree -BranchName 'feature/set-target'
            (Get-Location).Path | Should -BeExactly (Resolve-Path -LiteralPath $worktree).Path
        } finally {
            Pop-Location
        }
    }

    It 'changes the current location to a non-standard worktree by path' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'set-worktree-custom-path-main')
        $branch = 'feature/set-custom-path'
        $actualPath = Join-Path $TestDrive 'custom-set-path'
        Invoke-Git @('-C', $repo, 'branch', $branch)
        Invoke-Git @('-C', $repo, 'worktree', 'add', '--quiet', $actualPath, $branch)

        Push-Location $repo
        try {
            Set-Worktree -Path $actualPath
            (Get-Location).Path | Should -BeExactly (Resolve-Path -LiteralPath $actualPath).Path
        } finally {
            Pop-Location
        }
    }

    It 'changes the current location to a non-standard worktree from pipeline input' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'set-worktree-pipeline-main')
        $branch = 'feature/set-pipeline-path'
        $actualPath = Join-Path $TestDrive 'custom-set-pipeline-path'
        Invoke-Git @('-C', $repo, 'branch', $branch)
        Invoke-Git @('-C', $repo, 'worktree', 'add', '--quiet', $actualPath, $branch)

        Push-Location $repo
        try {
            Get-Worktrees | Where-Object Branch -eq $branch | Set-Worktree
            (Get-Location).Path | Should -BeExactly (Resolve-Path -LiteralPath $actualPath).Path
        } finally {
            Pop-Location
        }
    }

    It 'changes the current location to a detached worktree by path without colliding with another detached worktree' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'set-worktree-detached-main')
        $first = Join-Path $TestDrive 'set-detached-keep'
        $second = Join-Path $TestDrive 'set-detached-target'
        Invoke-Git @('-C', $repo, 'worktree', 'add', '--quiet', '--detach', $first, 'HEAD')
        Invoke-Git @('-C', $repo, 'worktree', 'add', '--quiet', '--detach', $second, 'HEAD')
        $secondResolved = (Resolve-Path -LiteralPath $second).Path

        Push-Location $repo
        try {
            Get-Worktrees | Where-Object Path -eq $secondResolved | Set-Worktree
            (Get-Location).Path | Should -BeExactly $secondResolved
        } finally {
            Pop-Location
        }
    }
}

Describe 'Lock-Worktree and Unlock-Worktree' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
    BeforeAll {
        function New-LockTestWorktree {
            param(
                [Parameter(Mandatory)][string]$Name,
                [Parameter(Mandatory)][string]$BranchName
            )

            $repo = New-TestRepo -Path (Join-Path $TestDrive "$Name-main")
            Invoke-Git @('-C', $repo, 'branch', $BranchName)
            $worktree = Join-Path $TestDrive "$Name-worktree"
            Invoke-Git @('-C', $repo, 'worktree', 'add', '--quiet', $worktree, $BranchName)
            [PSCustomObject]@{
                Repo     = $repo
                Branch   = $BranchName
                Worktree = $worktree
            }
        }
    }

    It 'locks a worktree without a reason' {
        $case = New-LockTestWorktree -Name 'lock-no-reason' -BranchName 'feature/lock-no-reason'

        Push-Location $case.Repo
        try {
            Lock-Worktree -BranchName $case.Branch -Confirm:$false
            $worktree = @(Get-Worktrees | Where-Object Branch -eq $case.Branch)
        } finally {
            Pop-Location
        }

        $worktree | Should -HaveCount 1
        $worktree[0].Locked | Should -BeTrue
        $worktree[0].LockReason | Should -BeExactly ''
    }

    It 'locks a worktree with a reason from pipeline property name' {
        $case = New-LockTestWorktree -Name 'lock-with-reason' -BranchName 'feature/lock-with-reason'
        $reason = 'keep this test worktree'

        Push-Location $case.Repo
        try {
            [PSCustomObject]@{ Branch = $case.Branch } | Lock-Worktree -Reason $reason -Confirm:$false
            $worktree = @(Get-Worktrees | Where-Object Branch -eq $case.Branch)
        } finally {
            Pop-Location
        }

        $worktree | Should -HaveCount 1
        $worktree[0].Locked | Should -BeTrue
        $worktree[0].LockReason | Should -BeExactly $reason
    }

    It 'unlocks a locked worktree' {
        $case = New-LockTestWorktree -Name 'unlock-locked' -BranchName 'feature/unlock-locked'

        Push-Location $case.Repo
        try {
            Lock-Worktree -BranchName $case.Branch -Reason 'temporary lock' -Confirm:$false
            Unlock-Worktree -BranchName $case.Branch -Confirm:$false
            $worktree = @(Get-Worktrees | Where-Object Branch -eq $case.Branch)
        } finally {
            Pop-Location
        }

        $worktree | Should -HaveCount 1
        $worktree[0].Locked | Should -BeFalse
        $worktree[0].LockReason | Should -BeExactly ''
    }

    It 'does not lock or unlock when WhatIf is used' {
        $case = New-LockTestWorktree -Name 'lock-whatif' -BranchName 'feature/lock-whatif'

        Push-Location $case.Repo
        try {
            Lock-Worktree -BranchName $case.Branch -WhatIf -Confirm:$false
            (@(Get-Worktrees | Where-Object Branch -eq $case.Branch)[0]).Locked | Should -BeFalse

            Lock-Worktree -BranchName $case.Branch -Reason 'real lock' -Confirm:$false
            Unlock-Worktree -BranchName $case.Branch -WhatIf -Confirm:$false
            $worktree = @(Get-Worktrees | Where-Object Branch -eq $case.Branch)
        } finally {
            Pop-Location
        }

        $worktree | Should -HaveCount 1
        $worktree[0].Locked | Should -BeTrue
        $worktree[0].LockReason | Should -BeExactly 'real lock'
    }

    It 'surfaces a clear git error when locking an already locked worktree' {
        $case = New-LockTestWorktree -Name 'lock-already-locked' -BranchName 'feature/lock-already-locked'

        Push-Location $case.Repo
        try {
            Lock-Worktree -BranchName $case.Branch -Reason 'first lock' -Confirm:$false
            { Lock-Worktree -BranchName $case.Branch -Reason 'second lock' -Confirm:$false -ErrorAction Stop } |
                Should -Throw -ExpectedMessage '*already locked*'
        } finally {
            Pop-Location
        }
    }
}
