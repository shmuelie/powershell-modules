function Set-Config {
    <#
    .SYNOPSIS
    Set a local, global or system git configuration value.
    .DESCRIPTION
    Sets one key to a literal string value using git config. Defaults to the
    repository's local configuration. Existing single values are replaced;
    multiple existing values, invalid keys and write failures are reported by git.
    Does not replace the configuration file or modify other keys.

    Global and system configuration can be updated outside a repository. The
    supplied Path must still be an existing FileSystem directory. Git chooses
    the configuration file for the selected scope, including its standard
    environment overrides. System writes may require elevated permissions.
    .PARAMETER Property
    Git configuration key, such as user.name or remote.origin.url. Git validates
    the key syntax; subsection names are passed literally.
    .PARAMETER Value
    Literal string to store, including empty strings, quotes and leading dashes.
    The value is not evaluated as PowerShell code or interpreted as git options.
    .PARAMETER Location
    Configuration scope: local (default), global or system.
    .PARAMETER Path
    Literal working directory for git. Defaults to the current location and does
    not change it. Local scope requires a working tree or bare repository.
    Accepts pipeline paths or objects with Path, RepositoryPath or RepoPath.
    Repository is also accepted as a compatibility alias.
    .OUTPUTS
    None.
    .EXAMPLE
    Set-Config -Property user.name -Value 'Example User'
    Sets user.name in the current repository's local configuration.
    .EXAMPLE
    Set-Config core.editor 'code --wait' -Location global -WhatIf
    Previews a global configuration change without writing it.
    .EXAMPLE
    Set-Config -Path ../project -Property example.value -Value '--literal'
    Stores a leading-dash value in another repository without changing location.
    .LINK
    https://git-scm.com/docs/git-config
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({ -not $_.Contains([char]0) }, ErrorMessage = 'Git configuration keys must not contain NUL characters.')]
        [string]$Property,

        [Parameter(Mandatory, Position = 1)]
        [AllowEmptyString()]
        [ValidateScript({ -not $_.Contains([char]0) }, ErrorMessage = 'Git configuration values must not contain NUL characters.')]
        [string]$Value,

        [ValidateSet('local', 'global', 'system')]
        [string]$Location = 'local',

        [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('RepositoryPath', 'RepoPath', 'Repository')]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    process {
        $scope = $Location.ToLowerInvariant()
        $allowNonRepository = $scope -ne 'local'
        $directory = Resolve-GitRepositoryPath -Path $Path -AllowBare -AllowNonRepository:$allowNonRepository
        if (-not $directory) { return }

        if ($PSCmdlet.ShouldProcess("$scope git configuration '$Property' (directory '$directory')", 'Set git configuration value')) {
            # The separator protects both operands without requiring git config set.
            $null = Invoke-Git -Path $directory -AllowBare -AllowNonRepository:$allowNonRepository -Arguments @(
                'config', "--$scope", '--', $Property, $Value
            )
        }
    }
}
