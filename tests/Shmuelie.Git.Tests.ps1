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

Describe 'Add-Worktree' {
    It 'requires a non-empty branch name' {
        { Add-Worktree -BranchName '' } | Should -Throw
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

            $remotePath = Join-Path $Path "dev.azure.com\$Organization\$Project\_git\$Repository"
            Invoke-Git @('init', '--bare', '--quiet', $remotePath)
            $remoteUrlPath = $remotePath -replace '\\', '/'
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
            New-Worktree -WorkName 'dry-run' -UserName 'tester' -WhatIf -Confirm:$false
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
