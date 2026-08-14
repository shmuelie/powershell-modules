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
