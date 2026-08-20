# Validate-set generator that supplies the current repo's worktree branch names
# for tab-completion / -ValidateSet on worktree parameters.
class WorktreeSetValuesGenerator : System.Management.Automation.IValidateSetValuesGenerator {
    [string[]] GetValidValues() {
        <#
        .SYNOPSIS
            Return the branch name of every worktree in the current repository,
            used to supply -ValidateSet/tab-completion values for worktree parameters.
        #>
        return [string[]](Get-Worktrees | Select-Object -ExpandProperty Branch)
    }
}
