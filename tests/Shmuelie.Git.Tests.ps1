#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.2.0' }

BeforeAll {
    $repoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent
    Import-Module (Join-Path $repoRoot 'modules\Shmuelie.Git\Shmuelie.Git.psd1') -Force

    # Run a git command and throw on failure. $ErrorActionPreference does not turn
    # a native non-zero exit into a terminating error, so setup failures would
    # otherwise surface as a confusing later assertion rather than at the source.
    # Pass all tokens as a single array so leading switches (e.g. -C) are not
    # mistaken for parameters of this function.
    function Invoke-Git {
        param([Parameter(Mandatory, Position = 0)][string[]]$Arguments)
        $output = & git @Arguments 2>&1
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
}

Describe 'Get-GitStatusSummary' {
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

    It 'queries PR status for branch names in the safe allow-list' {
        $repo = New-TestRepo -Path (Join-Path $TestDrive 'safe-stale-branch')
        $remoteUrl = New-AdoLikeRemote -Path (Join-Path $TestDrive 'safe-remote')
        Invoke-Git @('-C', $repo, 'remote', 'add', 'origin', $remoteUrl)
        Invoke-Git @('-C', $repo, 'branch', 'user/test/safe-branch')

        Push-Location $repo
        try {
            $result = Find-StaleBranch -IncludePrStatus -User test
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
            $result = Find-StaleBranch -IncludePrStatus -User test
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
            $result = Find-StaleBranch -IncludePrStatus -User test -WarningVariable warnings
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
            $result = Find-StaleBranch -IncludePrStatus -User test -WarningVariable warnings
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
    }

    It 'returns an empty string when the summary is not a git repo' {
        Format-GitStatusSegment -Status (New-Summary @{ IsGitRepo = $false }) | Should -BeExactly ''
    }

    It 'accepts pipeline input' {
        (New-Summary | Format-GitStatusSegment) | Should -Match 'main'
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
            Contains    = @("$([char]0x2191)1$([char]0x2193)2")
            NotContains = @()
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
