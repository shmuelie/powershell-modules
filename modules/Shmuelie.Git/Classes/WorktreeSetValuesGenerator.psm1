# Validate-set generator that supplies the current repo's worktree branch names
# for tab-completion / -ValidateSet on worktree parameters.
class WorktreeSetValuesGenerator : System.Management.Automation.IValidateSetValuesGenerator {
    [string[]] GetValidValues() {
        <#
        .SYNOPSIS
            Return the branch name of every branch-backed worktree in the current
            repository, used to supply -ValidateSet/tab-completion values for
            worktree parameters. Detached worktrees are path-addressed because
            they all share the ambiguous '(detached)' branch label.
        #>
        return [string[]](
            Get-Worktrees |
                Where-Object { -not $_.Detached -and $_.Branch } |
                Select-Object -ExpandProperty Branch -Unique
        )
    }
}
