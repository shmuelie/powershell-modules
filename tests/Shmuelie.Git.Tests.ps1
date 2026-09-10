#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.2.0' }

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
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        Invoke-Git @('-C', $Path, '-c', 'init.templateDir=', 'init', '-b', 'main', '--quiet')
        Set-TestRepoConfig $Path
        if (-not $NoCommit) {
            Set-Content -Path (Join-Path $Path 'README.md') -Value 'initial'
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

        Push-Location $repo
        try {
            Add-Worktree -BranchName $branch -WorktreePath $customPath -Confirm:$false
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

        Push-Location $repo
        try {
            Add-Worktree -BranchName $branch -Confirm:$false
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

        Push-Location $repo
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

        Push-Location $repo
        try {
            { Add-Worktree -BranchName $branch -WorktreePath $existingPath -Confirm:$false -ErrorAction Stop } |
                Should -Throw -ExpectedMessage '*git worktree add failed*already exists*'
        } finally {
            Pop-Location
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

    It 'uses explicit source -Path with destination -WorktreePath for worktree creation without changing caller location' {
        Invoke-Git @('-C', $script:pathTargetRepo, 'branch', 'existing-work')
        $existingPath = Join-Path $TestDrive 'explicit-existing-worktree'
        $newPath = Join-Path $TestDrive 'explicit-new-worktree'
        $callerLocation = $null

        Push-Location $script:pathCallerRepo
        try {
            $callerLocation = (Get-Location).Path
            Add-Worktree -Path $script:pathTargetRepo -BranchName existing-work -WorktreePath $existingPath
            Test-Path -LiteralPath $existingPath -PathType Container | Should -BeTrue
            (Get-Worktrees -Path $script:pathTargetRepo).Path | Should -Contain (Resolve-Path -LiteralPath $existingPath).Path

            New-Worktree -Path $script:pathTargetRepo -WorkName explicit-new -NoPrefix -WorktreePath $newPath
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
        @{ Scenario = 'stash pop conflict'; Status = 'Updated'; Dirty = $true; LockIndex = $false; Warning = 'git stash pop failed'; PopFailed = $true }
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

Describe 'Git tab completion status parsing' {
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

        Push-Location $repo
        try {
            $files = InModuleScope Shmuelie.Git { gitAddFiles '' }
        } finally {
            Pop-Location
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

        Push-Location $repo
        try {
            $files = InModuleScope Shmuelie.Git { gitIndexFiles '' }
        } finally {
            Pop-Location
        }

        $files | Should -Contain 'README-renamed.md'
        $files | Should -Not -Contain 'README.md -> README-renamed.md'
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

        Push-Location $repo
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
        } finally {
            Pop-Location
        }
    }

    It 'creates a user-prefixed branch and worktree at the expected path' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'new-worktree-user-main')
        $branchName = 'user/tester/happy-path'
        $expectedPath = Join-Path (Split-Path $repo -Parent) $branchName

        Push-Location $repo
        try {
            New-Worktree -WorkName 'happy-path' -UserName 'tester' -Confirm:$false
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

        Push-Location $repo
        try {
            New-Worktree -WorkName 'explicit-path' -UserName 'tester' -WorktreePath $customPath -Confirm:$false
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

        Push-Location $repo
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

        Push-Location $repo
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
        } finally {
            Pop-Location
        }
    }

    It 'creates an unprefixed branch and worktree when NoPrefix is used' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'new-worktree-noprefix-main')
        $branchName = 'plain-work'
        $expectedPath = Join-Path (Split-Path $repo -Parent) $branchName

        Push-Location $repo
        try {
            New-Worktree -WorkName $branchName -NoPrefix -Confirm:$false
            Test-Path -LiteralPath $expectedPath | Should -BeTrue
            Invoke-Git @('-C', $repo, 'rev-parse', '--verify', $branchName) | Should -Not -BeNullOrEmpty
            (@(Get-Worktrees) | Where-Object Branch -eq $branchName).Path | Should -BeExactly (Resolve-Path -LiteralPath $expectedPath).Path
        } finally {
            Pop-Location
        }
    }
}

Describe 'Remove-Worktree' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
    It 'does not remove a worktree when WhatIf is used' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'remove-worktree-whatif-main')
        Invoke-Git @('-C', $repo, 'branch', 'feature/remove-whatif')
        $worktree = Join-Path $TestDrive (Join-Path 'feature' 'remove-whatif')
        Invoke-Git @('-C', $repo, 'worktree', 'add', '--quiet', $worktree, 'feature/remove-whatif')

        Push-Location $repo
        try {
            Remove-Worktree -BranchName 'feature/remove-whatif' -WhatIf -Confirm:$false
            Test-Path -LiteralPath $worktree | Should -BeTrue
            (@(Get-Worktrees) | Where-Object Branch -eq 'feature/remove-whatif') | Should -HaveCount 1
        } finally {
            Pop-Location
        }
    }

    It 'removes exactly the standard-layout target worktree by branch name' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'remove-worktree-main')
        Invoke-Git @('-C', $repo, 'branch', 'feature/remove-target')
        Invoke-Git @('-C', $repo, 'branch', 'feature/keep-target')
        $target = Join-Path $TestDrive (Join-Path 'feature' 'remove-target')
        $keeper = Join-Path $TestDrive (Join-Path 'feature' 'keep-target')
        Invoke-Git @('-C', $repo, 'worktree', 'add', '--quiet', $target, 'feature/remove-target')
        Invoke-Git @('-C', $repo, 'worktree', 'add', '--quiet', $keeper, 'feature/keep-target')

        Push-Location $repo
        try {
            Remove-Worktree -BranchName 'feature/remove-target' -Confirm:$false
            Test-Path -LiteralPath $target | Should -BeFalse
            Test-Path -LiteralPath $keeper | Should -BeTrue
            (@(Get-Worktrees) | Where-Object Branch -eq 'feature/remove-target') | Should -BeNullOrEmpty
            (@(Get-Worktrees) | Where-Object Branch -eq 'feature/keep-target') | Should -HaveCount 1
        } finally {
            Pop-Location
        }
    }

    It 'removes a non-standard worktree by branch name using its real path' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'remove-worktree-custom-branch-main')
        $branch = 'feature/remove-custom-branch'
        $actualPath = Join-Path $TestDrive 'custom-remove-branch-path'
        Invoke-Git @('-C', $repo, 'branch', $branch)
        Invoke-Git @('-C', $repo, 'worktree', 'add', '--quiet', $actualPath, $branch)

        Push-Location $repo
        try {
            Remove-Worktree -BranchName $branch -Confirm:$false
            Test-Path -LiteralPath $actualPath | Should -BeFalse
            (@(Get-Worktrees) | Where-Object Branch -eq $branch) | Should -BeNullOrEmpty
        } finally {
            Pop-Location
        }
    }

    It 'removes a non-standard worktree by path from pipeline input' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'remove-worktree-custom-path-main')
        $branch = 'feature/remove-custom-path'
        $actualPath = Join-Path $TestDrive 'custom-remove-path'
        Invoke-Git @('-C', $repo, 'branch', $branch)
        Invoke-Git @('-C', $repo, 'worktree', 'add', '--quiet', $actualPath, $branch)

        Push-Location $repo
        try {
            Get-Worktrees | Where-Object Branch -eq $branch | Remove-Worktree -Confirm:$false
            Test-Path -LiteralPath $actualPath | Should -BeFalse
            (@(Get-Worktrees) | Where-Object Branch -eq $branch) | Should -BeNullOrEmpty
        } finally {
            Pop-Location
        }
    }

    It 'removes a detached worktree by path without colliding with another detached worktree' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'remove-worktree-detached-main')
        $first = Join-Path $TestDrive 'detached-keep'
        $second = Join-Path $TestDrive 'detached-remove'
        Invoke-Git @('-C', $repo, 'worktree', 'add', '--quiet', '--detach', $first, 'HEAD')
        Invoke-Git @('-C', $repo, 'worktree', 'add', '--quiet', '--detach', $second, 'HEAD')
        $secondResolved = (Resolve-Path -LiteralPath $second).Path

        Push-Location $repo
        try {
            Get-Worktrees | Where-Object Path -eq $secondResolved | Remove-Worktree -Confirm:$false
            Test-Path -LiteralPath $first | Should -BeTrue
            Test-Path -LiteralPath $second | Should -BeFalse
            (@(Get-Worktrees) | Where-Object Detached) | Should -HaveCount 1
        } finally {
            Pop-Location
        }
    }

    It 'removes a prunable worktree entry by path' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'remove-worktree-prunable-main')
        $gone = Join-Path $TestDrive 'prunable-remove'
        Invoke-Git @('-C', $repo, 'worktree', 'add', '--quiet', '--detach', $gone, 'HEAD')
        Remove-Item -LiteralPath $gone -Recurse -Force

        Push-Location $repo
        try {
            $entry = @(Get-Worktrees | Where-Object Prunable)
            $entry | Should -HaveCount 1
            Remove-Worktree -Path $entry[0].Path -Confirm:$false
            @(Get-Worktrees | Where-Object Prunable) | Should -HaveCount 0
        } finally {
            Pop-Location
        }
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
