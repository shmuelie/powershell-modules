# Git tab completion — self-contained replacement for posh-git tab expansion.
# Registers a native argument completer for git that provides context-aware
# completions for subcommands, branches, tags, remotes, stashes, files, and
# parameters using only the git CLI (no external module dependency).

# Subcommand sub-operations
$script:gitSubcommands = @{
    bisect    = 'start bad good skip reset visualize replay log run'
    notes     = 'add append copy edit get-ref list merge prune remove show'
    reflog    = 'show delete expire'
    remote    = 'add rename remove set-head set-branches get-url set-url show prune update'
    rerere    = 'clear forget diff remaining status gc'
    stash     = 'push save list show apply clear drop pop create branch'
    submodule = 'add status init deinit update summary foreach sync'
    worktree  = 'add list lock move prune remove unlock'
}

# Short parameter flags per command
$script:shortGitParams = @{
    add         = 'n v f i p e u A N'
    branch      = 'd D l f m M r a v vv q t u'
    checkout    = 'q f b B t l m p'
    'cherry-pick' = 'e x r m n s S X'
    clean       = 'd f i n q e x X'
    clone       = 'l s q v n o b u c'
    commit      = 'a p C c z F m t s n e i o u v q S'
    diff        = 'p u s U z B M C D l S G O R a b w W'
    fetch       = 'a f k p n t u q v'
    log         = 'L n i E F g c c m r t'
    merge       = 'e n s X q v S m'
    mv          = 'f k n v'
    pull        = 'q v e n s X r a f k u'
    push        = 'n f u q v'
    rebase      = 'm s X S q v n C f i p x'
    reset       = 'q p'
    restore     = 's p W S q m'
    revert      = 'e m n S s X'
    rm          = 'f n r q'
    show        = 's'
    stash       = 'p k u a q'
    status      = 's b u z'
    switch      = 'c C d f m q t'
    tag         = 'a s u f d v n l m F'
}

# Long parameter names per command
$script:longGitParams = @{
    add         = 'dry-run verbose force interactive patch edit update all no-ignore-removal no-all ignore-removal intent-to-add refresh ignore-errors ignore-missing renormalize'
    branch      = 'color no-color list abbrev no-abbrev column no-column merged no-merged contains set-upstream track no-track set-upstream-to unset-upstream edit-description delete create-reflog force move all verbose quiet sort format'
    checkout    = 'quiet force ours theirs track no-track detach orphan ignore-skip-worktree-bits merge conflict patch'
    'cherry-pick' = 'edit mainline no-commit signoff gpg-sign ff allow-empty allow-empty-message keep-redundant-commits strategy strategy-option continue quit abort'
    clean       = 'force interactive dry-run quiet exclude'
    clone       = 'local no-hardlinks shared reference quiet verbose progress no-checkout bare mirror origin branch upload-pack depth shallow-since shallow-exclude single-branch no-single-branch no-tags recurse-submodules shallow-submodules jobs filter'
    commit      = 'all patch reuse-message reedit-message fixup squash reset-author short branch porcelain long null file author date message template signoff no-verify allow-empty allow-empty-message cleanup edit amend no-post-rewrite include only untracked-files verbose quiet dry-run status no-status gpg-sign no-gpg-sign'
    diff        = 'patch no-patch unified stat numstat shortstat summary patch-with-stat name-only name-status color no-color word-diff check cached staged no-index binary full-index abbrev break-rewrites find-renames find-copies find-copies-harder diff-filter'
    fetch       = 'all append depth deepen shallow-since shallow-exclude unshallow update-shallow dry-run force keep multiple prune no-tags tags recurse-submodules jobs no-recurse-submodules update-head-ok upload-pack quiet verbose progress'
    log         = 'follow no-decorate decorate source use-mailmap full-diff log-size all-match invert-grep regexp-ignore-case basic-regexp extended-regexp fixed-strings perl-regexp oneline format short medium full fuller email raw date author committer grep all-match invert-grep since until after before graph'
    merge       = 'commit no-commit edit no-edit ff no-ff ff-only log no-log signoff no-signoff stat no-stat squash no-squash strategy strategy-option verify-signatures no-verify-signatures summary no-summary quiet verbose progress no-progress allow-unrelated-histories rerere-autoupdate no-rerere-autoupdate abort continue'
    pull        = 'quiet verbose progress no-progress no-recurse-submodules recurse-submodules commit no-commit edit no-edit ff no-ff ff-only log no-log signoff no-signoff stat no-stat squash no-squash strategy strategy-option verify-signatures no-verify-signatures summary no-summary autostash no-autostash allow-unrelated-histories rebase no-rebase all append depth deepen shallow-since shallow-exclude unshallow update-shallow force keep no-tags update-head-ok upload-pack'
    push        = 'all prune mirror dry-run porcelain delete tags follow-tags signed no-signed atomic force force-with-lease no-force-with-lease repo set-upstream thin no-thin quiet verbose progress no-progress recurse-submodules no-recurse-submodules verify no-verify'
    rebase      = 'onto continue abort skip quit edit-todo keep-empty no-keep-empty rebase-merges no-rebase-merges fork-point no-fork-point ignore-whitespace whitespace committer-date-is-author-date ignore-date signoff interactive exec root autosquash no-autosquash autostash no-autostash stat no-stat verify no-verify gpg-sign'
    reset       = 'soft mixed hard merge keep quiet'
    restore     = 'source patch worktree staged quiet progress no-progress ours theirs merge conflict'
    revert      = 'edit mainline no-commit signoff gpg-sign strategy strategy-option continue quit abort'
    show        = 'format oneline short medium full fuller email raw abbrev-commit no-abbrev-commit encoding expand-tabs no-expand-tabs notes no-notes show-signature stat no-stat shortstat numstat summary name-only name-status'
    stash       = 'patch no-keep-index keep-index include-untracked all quiet message'
    status      = 'short branch show-stash porcelain long verbose untracked-files ignore-submodules ignored no-renames find-renames'
    switch      = 'create force-create detach guess no-guess force track no-track merge conflict quiet discard-changes orphan ignore-other-worktrees recurse-submodules no-recurse-submodules'
    tag         = 'annotate sign force delete verify list sort column no-column contains merged no-merged points-at message file cleanup local-user create-reflog'
    worktree    = 'force detach checkout lock reason'
}

# Commands that take refs (branches/tags) as arguments
$script:refCommands = 'cherry|cherry-pick|diff|difftool|log|merge|rebase|reflog\s+show|reset|revert|show'

# Helper: complete git subcommand names
function script:gitCommands($filter) {
    <#
    .SYNOPSIS
        Complete git subcommand and alias names matching the filter.
    .PARAMETER filter
        The partial word being completed (prefix match).
    #>
    $cmds = git --list-cmds=main 2>$null
    $aliases = git config --get-regexp '^alias\.' 2>$null | ForEach-Object {
        ($_ -split '\s', 2)[0] -replace '^alias\.', ''
    }
    @($cmds) + @($aliases) | Where-Object { $_ -like "$filter*" } | Sort-Object -Unique
}

# Helper: complete branch names
function script:gitBranches($filter, $includeHEAD = $false, $prefix = '') {
    <#
    .SYNOPSIS
        Complete local branch names matching the filter.
    .PARAMETER filter
        The partial word being completed (prefix match).
    .PARAMETER includeHEAD
        When true, also offer pseudo-refs (HEAD, FETCH_HEAD, ORIG_HEAD, MERGE_HEAD).
    .PARAMETER prefix
        Optional string prepended to each completion (e.g. for 'remote/branch').
    #>
    $branches = git branch --format='%(refname:short)' 2>$null
    if ($includeHEAD) { $branches = @('HEAD', 'FETCH_HEAD', 'ORIG_HEAD', 'MERGE_HEAD') + @($branches) }
    $branches | Where-Object { $_ -like "$filter*" } | ForEach-Object { "$prefix$_" }
}

# Helper: complete unique remote branch names (for checkout -b)
function script:gitRemoteUniqueBranches($filter) {
    <#
    .SYNOPSIS
        Complete remote branch names that have no matching local branch (for checkout -b).
    .PARAMETER filter
        The partial word being completed (prefix match).
    #>
    $local = [System.Collections.Generic.HashSet[string]]::new(
        [string[]](git branch --format='%(refname:short)' 2>$null),
        [System.StringComparer]::OrdinalIgnoreCase)
    git branch -r --format='%(refname:short)' 2>$null | ForEach-Object {
        $short = $_ -replace '^[^/]+/', ''
        if (-not $local.Contains($short)) { $short }
    } | Where-Object { $_ -like "$filter*" }
}

# Helper: complete remote names
function script:gitRemotes($filter) {
    <#
    .SYNOPSIS
        Complete configured git remote names matching the filter.
    .PARAMETER filter
        The partial word being completed (prefix match).
    #>
    git remote 2>$null | Where-Object { $_ -like "$filter*" }
}

# Helper: complete tag names
function script:gitTags($filter, $prefix = '') {
    <#
    .SYNOPSIS
        Complete git tag names matching the filter.
    .PARAMETER filter
        The partial word being completed (prefix match).
    .PARAMETER prefix
        Optional string prepended to each completion.
    #>
    git tag -l 2>$null | Where-Object { $_ -like "$filter*" } | ForEach-Object { "$prefix$_" }
}

# Helper: complete stash names
function script:gitStashes($filter) {
    <#
    .SYNOPSIS
        Complete stash reference names (e.g. stash@{0}) matching the filter.
    .PARAMETER filter
        The partial word being completed (prefix match).
    #>
    git stash list --format='%gd' 2>$null | Where-Object { $_ -like "$filter*" }
}

# Helper: complete files for git add (untracked + modified)
function script:gitAddFiles($filter) {
    <#
    .SYNOPSIS
        Complete paths stageable by 'git add' (untracked or modified/deleted/added working files).
    .PARAMETER filter
        The partial word being completed (prefix match).
    #>
    git status --porcelain 2>$null | ForEach-Object {
        $x = $_[0]; $y = $_[1]
        if ($x -eq '?' -or $y -eq 'M' -or $y -eq 'D' -or $y -eq 'A') {
            $_.Substring(3).Trim('"')
        }
    } | Where-Object { $_ -like "$filter*" }
}

# Helper: complete staged files for git reset
function script:gitIndexFiles($filter) {
    <#
    .SYNOPSIS
        Complete staged (index) file paths, e.g. for 'git reset'.
    .PARAMETER filter
        The partial word being completed (prefix match).
    #>
    git status --porcelain 2>$null | ForEach-Object {
        $x = $_[0]
        if ($x -ne ' ' -and $x -ne '?') {
            $_.Substring(3).Trim('"')
        }
    } | Where-Object { $_ -like "$filter*" }
}

# Helper: complete modified files for git checkout --
function script:gitCheckoutFiles($filter) {
    <#
    .SYNOPSIS
        Complete modified/deleted working-tree file paths, e.g. for 'git checkout --'.
    .PARAMETER filter
        The partial word being completed (prefix match).
    #>
    git status --porcelain 2>$null | ForEach-Object {
        $y = $_[1]
        if ($y -eq 'M' -or $y -eq 'D') {
            $_.Substring(3).Trim('"')
        }
    } | Where-Object { $_ -like "$filter*" }
}

# Helper: complete diff files
function script:gitDiffFiles($filter, $staged) {
    <#
    .SYNOPSIS
        Complete file paths for 'git diff' — staged files when -staged, else modified working files.
    .PARAMETER filter
        The partial word being completed (prefix match).
    .PARAMETER staged
        When true, complete staged (index) files instead of working-tree changes.
    #>
    if ($staged) {
        gitIndexFiles $filter
    } else {
        git status --porcelain 2>$null | ForEach-Object {
            $y = $_[1]
            if ($y -eq 'M' -or $y -eq 'D') {
                $_.Substring(3).Trim('"')
            }
        } | Where-Object { $_ -like "$filter*" }
    }
}

# Helper: complete subcommand sub-operations
function script:gitSubOps($cmd, $filter) {
    <#
    .SYNOPSIS
        Complete sub-operations for a git subcommand (e.g. 'stash push', 'remote add').
    .PARAMETER cmd
        The git subcommand whose sub-operations to complete (e.g. stash, remote, worktree).
    .PARAMETER filter
        The partial word being completed (prefix match).
    #>
    $ops = $script:gitSubcommands[$cmd]
    if ($ops) {
        $ops -split '\s+' | Where-Object { $_ -like "$filter*" }
    }
}

# Helper: complete long parameters
function script:gitLongParams($cmd, $filter) {
    <#
    .SYNOPSIS
        Complete '--long' option names for a git subcommand.
    .PARAMETER cmd
        The git subcommand whose long options to complete.
    .PARAMETER filter
        The partial word being completed (prefix match, without leading dashes).
    #>
    $params = $script:longGitParams[$cmd]
    if ($params) {
        $params -split '\s+' | Where-Object { $_ -like "$filter*" } | ForEach-Object { "--$_" }
    }
}

# Helper: complete short parameters
function script:gitShortParams($cmd, $filter) {
    <#
    .SYNOPSIS
        Complete '-x' short option flags for a git subcommand.
    .PARAMETER cmd
        The git subcommand whose short flags to complete.
    .PARAMETER filter
        The partial word being completed (prefix match, without leading dash).
    #>
    $params = $script:shortGitParams[$cmd]
    if ($params) {
        $params -split '\s+' | Where-Object { $_ -like "$filter*" } | ForEach-Object { "-$_" }
    }
}

# Register the native argument completer for git
$gitCmdNames = @('git')
# Also register for common git aliases
$gitAliases = Get-Alias | Where-Object { $_.Definition -eq 'git' } | ForEach-Object { $_.Name }
if ($gitAliases) { $gitCmdNames += @($gitAliases) }

Register-ArgumentCompleter -CommandName $gitCmdNames -Native -ScriptBlock {
    param($wordToComplete, $commandAst, $cursorPosition)

    $padLength = $cursorPosition - $commandAst.Extent.StartOffset
    $textToComplete = $commandAst.ToString().PadRight($padLength, ' ').Substring(0, $padLength)

    # Strip leading 'git ' to get the subcommand context
    $cmd = $textToComplete -replace '^\S+\s+', ''
    $ignoreParams = '(?:\s+-(?:[aA-zZ0-9]+|-[aA-zZ0-9][aA-zZ0-9-]*)(?:=\S+)?)*'

    $completions = switch -regex ($cmd) {

        # git <subcmd> <op> (subcommand with sub-operations)
        "^(?<cmd>$($script:gitSubcommands.Keys -join '|'))\s+(?<op>\S*)$" {
            gitSubOps $Matches['cmd'] $Matches['op']
            break
        }

        # git remote <op> <remote>
        "^remote\s+(?:rename|rm|set-head|set-branches|set-url|show|prune)\s+(?<remote>\S*)$" {
            gitRemotes $Matches['remote']
            break
        }

        # git stash (show|apply|drop|pop|branch) <stash>
        "^stash\s+(?:show|apply|drop|pop|branch)\s+(?<stash>\S*)$" {
            gitStashes $Matches['stash']
            break
        }

        # git branch -d|-D|-m|-M <branch> or git branch <name> <start-point>
        "^branch${ignoreParams}\s+(?<branch>\S*)$" {
            gitBranches $Matches['branch']
            break
        }

        # git push remote <ref>:<branch>
        "^push${ignoreParams}\s+(?<remote>[^\s-]\S*).*\s+(?<force>\+?)(?<ref>[^\s\:]*\:)(?<branch>\S*)$" {
            git branch -r --format='%(refname:short)' 2>$null |
                Where-Object { $_ -match "^$($Matches['remote'])/" } |
                ForEach-Object { "$($Matches['force'])$($Matches['ref'])$($_ -replace '^[^/]+/', '')" } |
                Where-Object { $_ -like "*$($Matches['branch'])*" }
            break
        }

        # git push/pull/fetch remote <ref>
        "^(?:push|pull)${ignoreParams}\s+(?<remote>[^\s-]\S*).*\s+(?<force>\+?)(?<ref>[^\s\:]*)$" {
            gitBranches $Matches['ref'] -prefix $Matches['force']
            gitTags $Matches['ref'] -prefix $Matches['force']
            break
        }

        # git push/pull/fetch <remote>
        "^(?:push|pull|fetch)${ignoreParams}\s+(?<remote>\S*)$" {
            gitRemotes $Matches['remote']
            break
        }

        # git reset HEAD <path>
        "^reset.*\s+HEAD(?:\s+--)?\s+(?<path>\S*)$" {
            gitIndexFiles $Matches['path']
            break
        }

        # git add <path>
        "^add${ignoreParams}\s+(?<files>\S*)$" {
            gitAddFiles $Matches['files']
            break
        }

        # git checkout -- <path>
        "^checkout.*\s+--\s+(?<files>\S*)$" {
            gitCheckoutFiles $Matches['files']
            break
        }

        # git restore -s <ref> / --source=<ref>
        "^restore.*\s+(?:-s\s*|(?<source>--source=))(?<ref>\S*)$" {
            gitBranches $Matches['ref'] $true $Matches['source']
            gitTags $Matches['ref']
            break
        }

        # git restore <path>
        "^restore${ignoreParams}\s+(?<files>\S*)$" {
            gitCheckoutFiles $Matches['files']
            break
        }

        # git rm <path>
        "^rm${ignoreParams}\s+(?<files>\S*)$" {
            gitIndexFiles $Matches['files']
            break
        }

        # git diff/difftool <path>
        "^(?:diff|difftool)(?:.*\s+(?<staged>--cached|--staged)|.*)\s+(?<files>\S*)$" {
            gitDiffFiles $Matches['files'] $Matches['staged']
            break
        }

        # git checkout/switch <ref>
        "^(?:checkout|switch)${ignoreParams}\s+(?<ref>\S*)$" {
            & {
                gitBranches $Matches['ref'] $true
                gitRemoteUniqueBranches $Matches['ref']
                gitTags $Matches['ref']
            } | Select-Object -Unique
            break
        }

        # git worktree add <path> <ref>
        "^worktree\s+add\s+\S+\s+(?<ref>\S*)$" {
            gitBranches $Matches['ref']
            break
        }

        # git <ref-cmd> <ref> (cherry-pick, merge, rebase, log, show, etc.)
        "^(?:$($script:refCommands))${ignoreParams}\s+(?<ref>\S*)$" {
            gitBranches $Matches['ref'] $true
            gitTags $Matches['ref']
            break
        }

        # git help <cmd>
        "^help\s+(?<cmd>\S*)$" {
            gitCommands $Matches['cmd']
            break
        }

        # git <cmd> --<param> (long parameter)
        "^(?<cmd>\S+).*\s+--(?<param>\S*)$" {
            gitLongParams $Matches['cmd'] $Matches['param']
            break
        }

        # git <cmd> -<param> (short parameter)
        "^(?<cmd>\S+).*\s+-(?<param>[^-]\S*)$" {
            gitShortParams $Matches['cmd'] $Matches['param']
            break
        }

        # git <cmd> (top-level command completion)
        "^(?<cmd>\S*)$" {
            gitCommands $Matches['cmd']
            break
        }
    }

    $completions | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
    }
}
