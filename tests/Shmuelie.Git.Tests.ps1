#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent
    Import-Module (Join-Path $repoRoot 'modules\Shmuelie.Git\Shmuelie.Git.psd1') -Force

    # Create an isolated git repository with a deterministic default branch and a
    # single initial commit. Returns the repository path.
    function New-TestRepo {
        param(
            [Parameter(Mandatory)][string]$Path,
            [switch]$NoCommit
        )
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        git -C $Path init -b main --quiet
        git -C $Path config user.email 'test@example.com'
        git -C $Path config user.name 'Test User'
        git -C $Path config commit.gpgsign false
        if (-not $NoCommit) {
            Set-Content -Path (Join-Path $Path 'README.md') -Value 'initial'
            git -C $Path add README.md
            git -C $Path commit -m 'init' --quiet
        }
        $Path
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

    Context 'with local changes' {
        $changeCases = @(
            @{
                Name     = 'staged addition'
                Setup    = { param($r) Set-Content (Join-Path $r 'added.txt') 'x'; git -C $r add added.txt }
                Property = 'IndexAdded'
                Expected = 1
                Token    = '\+1'
            }
            @{
                Name     = 'staged deletion'
                Setup    = { param($r) git -C $r rm README.md --quiet }
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
            git clone --quiet $origin $clone
            git -C $clone config user.email 'test@example.com'
            git -C $clone config user.name 'Test User'
            git -C $clone config commit.gpgsign false
            Set-Content (Join-Path $clone 'feature.txt') 'x'
            git -C $clone add feature.txt
            git -C $clone commit -m 'ahead' --quiet
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

Describe 'Format-GitStatusSegment' {
    BeforeAll {
        # Build a synthetic GitStatusSummary so the formatter can be exercised
        # without a real repository. Only the properties the formatter reads are
        # defaulted; pass a hashtable to override any of them.
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
