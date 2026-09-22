param(
    [Parameter(Mandatory)][string]$AssemblyPath
)

$ErrorActionPreference = 'Stop'
$env:PSModulePath = Join-Path $PSHOME 'Modules'
$env:PATH = ''
if ('WorktreePredictor.WorktreeCommandPredictor' -as [type]) {
    throw 'Run this fixture in a fresh no-profile process without a predictor loaded.'
}

# Loading the assembly as a type library does not run its module initializer.
# No predictor registration, cache refresh, history access or command execution.
$null = [Reflection.Assembly]::LoadFrom($AssemblyPath)
$predictorType = [WorktreePredictor.WorktreeCommandPredictor]
$flags = [Reflection.BindingFlags]'Instance,NonPublic'
$worktreeCache = $predictorType.GetField('_cachedWorktreeBranches', $flags)
$checkoutCache = $predictorType.GetField('_cachedCheckoutableBranches', $flags)
$client = [System.Management.Automation.Subsystem.Prediction.PredictionClient]::new(
    'LiteralArgumentFixture', [System.Management.Automation.Subsystem.Prediction.PredictionClientKind]::Terminal)

function Get-FixtureSuggestion {
    param(
        [string]$InputText,
        [AllowNull()][string[]]$WorktreeBranches,
        [AllowNull()][string[]]$CheckoutableBranches,
        [switch]$Cancelled
    )

    $predictor = [WorktreePredictor.WorktreeCommandPredictor]::new()
    $worktreeCache.SetValue($predictor, $WorktreeBranches)
    $checkoutCache.SetValue($predictor, $CheckoutableBranches)
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($InputText, [ref]$tokens, [ref]$errors)
    $context = [System.Management.Automation.Subsystem.Prediction.PredictionContext]::new($ast, $tokens)
    $package = $predictor.GetSuggestion($client, $context, [Threading.CancellationToken]::new([bool]$Cancelled))
    if ($predictorType.GetField('_refreshing', $flags).GetValue($predictor) -ne 0 -or
        $null -ne $predictorType.GetField('_cachedCwd', $flags).GetValue($predictor) -or
        $predictorType.GetField('_cacheTimeTicks', $flags).GetValue($predictor) -ne [datetime]::MinValue.Ticks) {
        throw 'Prediction unexpectedly refreshed the cache.'
    }
    foreach ($entry in $package.SuggestionEntries) { $entry.SuggestionText }
}

function Assert-LiteralSuggestion {
    param(
        [string]$Suggestion,
        [string]$Prefix,
        [string]$Branch,
        [switch]$Bare
    )

    if (-not $Suggestion.StartsWith($Prefix, [StringComparison]::Ordinal)) {
        throw "Typed prefix changed: $Suggestion"
    }
    $tokens = $null
    $errors = $null
    $prefixAst = [System.Management.Automation.Language.Parser]::ParseInput($Prefix, [ref]$tokens, [ref]$errors)
    $prefixCount = $prefixAst.EndBlock.Statements[0].PipelineElements[0].CommandElements.Count
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Suggestion, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0 -or $ast.EndBlock.Statements.Count -ne 1 -or
        $ast.EndBlock.Statements[0] -isnot [System.Management.Automation.Language.PipelineAst] -or
        $ast.EndBlock.Statements[0].PipelineElements.Count -ne 1) {
        throw "Suggestion did not parse as one pipeline: $Suggestion ($errors)"
    }
    $command = $ast.EndBlock.Statements[0].PipelineElements[0]
    if ($command -isnot [System.Management.Automation.Language.CommandAst] -or
        $command.Redirections.Count -ne 0 -or $command.CommandElements.Count -ne ($prefixCount + 1)) {
        throw "Suggestion did not add exactly one argument: $Suggestion"
    }
    $argument = $command.CommandElements[-1]
    if ($argument -isnot [System.Management.Automation.Language.StringConstantExpressionAst] -or
        $argument.Value -cne $Branch -or $argument.StringConstantType -notin @('BareWord', 'SingleQuoted')) {
        throw "Suggestion changed or expanded the literal branch: $Suggestion"
    }
    if ($Bare -and $Suggestion -cne ($Prefix + $Branch)) {
        throw "Ordinary bare-branch suggestion changed: $Suggestion"
    }
}

$branches = @(
    'main'
    'feature/simple-branch'
    'Feature/Case.Mixed_42'
    'feature/a+b'
    "feature/quote'branch"
    "feature/two''quotes"
    'feature/"branch"'
    'feature/$branch'
    'feature/${branch}'
    'feature/$(Get-Item)'
    'feature/`branch'
    'feature/a;b'
    'feature/a|b'
    'feature/a&b'
    'feature/(branch)'
    'feature/{branch}'
    'feature/a,b'
    'feature/a<b>c'
    '#branch'
    '@branch'
    '$branch'
    '$(Get-Item)'
    '(Get-Item)'
    '{Get-Item}'
    'branch;Get-Item'
    '>branch'
    '001'
    '0x10'
    '1e2'
    "feature/$([char]0x2018)branch"
    "feature/$([char]0x2019)branch"
    "feature/$([char]0x201a)branch"
    "feature/$([char]0x201b)branch"
    "feature/$([char]0x201c)branch$([char]0x201d)"
    "feature/$([char]0x96ea)"
)
$commands = @(
    @{ Prefix = 'sEt-WoRkTrEe -bRaNcHnAmE '; Checkoutable = $false }
    @{ Prefix = 'Remove-Worktree -KeepBranch -Force -BranchName '; Checkoutable = $false }
    @{ Prefix = 'CW '; Checkoutable = $false }
    @{ Prefix = "rw`t-RemoveBranch`t-Force`t"; Checkoutable = $false }
    @{ Prefix = 'aDd-WoRkTrEe -NoSetLocation -BranchName '; Checkoutable = $true }
)
$literalCases = 0
foreach ($command in $commands) {
    foreach ($branch in $branches) {
        $worktrees = if ($command.Checkoutable) { @('wrong-cache') } else { @($branch) }
        $checkoutable = if ($command.Checkoutable) { @($branch) } else { @('wrong-cache') }
        $suggestions = @(Get-FixtureSuggestion $command.Prefix $worktrees $checkoutable)
        if ($suggestions.Count -ne 1) { throw "Expected exactly one suggestion for $($command.Prefix)$branch" }
        Assert-LiteralSuggestion $suggestions[0] $command.Prefix $branch -Bare:($branch -in $branches[0..3])
        $literalCases++
    }
}

$compatibilityCases = 0
foreach ($case in @(
    @{ InputText = 'Remove-Worktree -BranchName feature/q'; Prefix = 'Remove-Worktree -BranchName '; Branch = "feature/quote'branch"; Checkoutable = $false }
    @{ InputText = "Remove-Worktree -BranchName quote'"; Prefix = 'Remove-Worktree -BranchName '; Branch = "feature/quote'branch"; Checkoutable = $false }
    @{ InputText = 'rEmOvE-wOrKtReE -KeepBranch -FORCE -bRaNcHnAmE QuOtE'; Prefix = 'rEmOvE-wOrKtReE -KeepBranch -FORCE -bRaNcHnAmE '; Branch = "Feature/Quote'Branch"; Checkoutable = $false }
    @{ InputText = 'aDd-WoRkTrEe -NoSetLocation -BranchName QuOtE'; Prefix = 'aDd-WoRkTrEe -NoSetLocation -BranchName '; Branch = "Feature/Quote'Branch"; Checkoutable = $true }
    @{ InputText = 'cw wIM'; Prefix = 'cw '; Branch = 'user/alex/wim-work'; Checkoutable = $false }
    @{ InputText = "Set-Worktree`t -BranchName`t$"; Prefix = "Set-Worktree`t -BranchName`t"; Branch = 'feature/$branch'; Checkoutable = $false }
    @{ InputText = 'Add-Worktree'; Prefix = 'Add-Worktree '; Branch = 'main'; Checkoutable = $true }
    @{ InputText = 'Remove-Worktree'; Prefix = 'Remove-Worktree '; Branch = 'main'; Checkoutable = $false }
)) {
    $worktrees = if ($case.Checkoutable) { @('wrong-cache') } else { @($case.Branch, 'unmatched') }
    $checkoutable = if ($case.Checkoutable) { @($case.Branch, 'unmatched') } else { @('wrong-cache') }
    $suggestions = @(Get-FixtureSuggestion $case.InputText $worktrees $checkoutable)
    $expectedCount = if ($case.InputText -in @('Add-Worktree', 'Remove-Worktree')) { 2 } else { 1 }
    if ($suggestions.Count -ne $expectedCount) { throw "Incorrect substring matches for $($case.InputText)" }
    Assert-LiteralSuggestion $suggestions[0] $case.Prefix $case.Branch -Bare:($case.Branch -in @('main', 'user/alex/wim-work'))
    if ($expectedCount -eq 2 -and $suggestions[1] -cne ($case.Prefix + 'unmatched')) {
        throw 'Cache ordering changed.'
    }
    $compatibilityCases++
}

foreach ($case in @(
    @{ InputText = 'Remove-Worktree -Rem'; Worktrees = @('main'); Checkoutable = @('main') }
    @{ InputText = 'Add-Worktree -Bra'; Worktrees = @('main'); Checkoutable = @('main') }
    @{ InputText = 'cwd main'; Worktrees = @('main'); Checkoutable = @('main') }
    @{ InputText = 'Set-WorktreeOther main'; Worktrees = @('main'); Checkoutable = @('main') }
    @{ InputText = 'Set-Worktree nope'; Worktrees = @('main'); Checkoutable = @('main') }
    @{ InputText = 'Set-Worktree '; Worktrees = $null; Checkoutable = @('main') }
    @{ InputText = 'Add-Worktree '; Worktrees = @('main'); Checkoutable = @() }
    @{ InputText = ''; Worktrees = @('main'); Checkoutable = @('main') }
    @{ InputText = 'Set-Worktree '; Worktrees = @('main'); Checkoutable = @('main'); Cancelled = $true }
)) {
    $suggestions = @(Get-FixtureSuggestion $case.InputText $case.Worktrees $case.Checkoutable -Cancelled:([bool]$case.Cancelled))
    if ($suggestions.Count -ne 0) { throw "Unexpected prediction for negative case: $($case.InputText)" }
    $compatibilityCases++
}

if ($null -ne $predictorType.GetProperty('Instance', [Reflection.BindingFlags]'Static,NonPublic').GetValue($null)) {
    throw 'The fixture unexpectedly registered a predictor instance.'
}
[pscustomobject]@{
    Passed = $literalCases + $compatibilityCases
    Failed = 0
    LiteralCases = $literalCases
    CompatibilityCases = $compatibilityCases
} | ConvertTo-Json -Compress
