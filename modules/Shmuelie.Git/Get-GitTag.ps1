function Get-GitTag {
    <#
    .SYNOPSIS
        Get typed information about local git tags.
    .DESCRIPTION
        Reads refs/tags with git for-each-ref, sorted by reference name. Does not
        fetch, change the repository, or change the caller's location. Supports
        working trees (including subdirectories and linked worktrees) and bare
        repositories. No tags or no matching names produces no output.
    .PARAMETER Name
        One or more exact tag names or PowerShell wildcard patterns, matched
        case-sensitively against the full name without the refs/tags/ prefix.
        Defaults to all tags. Overlapping patterns do not duplicate results.
    .PARAMETER Path
        Literal directory inside the repository. Defaults to the current location.
        Accepts pipeline paths and objects with Path, RepositoryPath or RepoPath.
    .OUTPUTS
        GitTag
        Name and Reference identify the tag. ObjectId and ObjectType describe
        the referenced object (type 'tag' for annotated tags). IsAnnotated is a
        Boolean. TargetObjectId and TargetObjectType describe the fully peeled
        target; TargetCommit is its full ID only when that target is a commit,
        otherwise null. Tags pointing to blobs, trees and other tags are supported.

        Subject is git's contents:subject (the tag subject for annotated tags,
        commit subject for lightweight commit tags, or empty where unavailable).
        Annotation is git's contents field for annotated tags, including whitespace
        and any signature, or null for lightweight tags. It is UTF-8 decoded,
        not a byte-for-byte representation of non-UTF-8 objects. TaggerDate and
        CreatorDate are DateTimeOffset values, or null when unavailable. For
        lightweight commit tags CreatorDate is the commit's committer date, not
        a tag creation date (which git does not record). RepositoryPath is the
        resolved input directory, not necessarily the repository root.
    .EXAMPLE
        Get-GitTag
        Lists all local tags in the current repository.
    .EXAMPLE
        Get-GitTag -Name 'v1.*', 'stable' -Path ../project
        Lists matching local tags without changing location.
    .EXAMPLE
        Get-Worktrees | Get-GitTag -Name 'v*'
        Lists matching tags for each supplied worktree.
    #>
    [OutputType('GitTag')]
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [Alias('TagName')]
        [SupportsWildcards()]
        [ValidateNotNullOrEmpty()]
        [string[]]$Name = @('*'),

        [Parameter(Position = 1, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('RepositoryPath', 'RepoPath')]
        [string]$Path
    )

    begin {
        $fields = @(
            'refname', 'objecttype', 'objectname', '*objecttype', '*objectname',
            'taggerdate:iso-strict', 'creatordate:iso-strict', 'contents:subject', 'contents'
        )
        $format = ($fields | ForEach-Object { "%($_)" }) -join '%00'
        # Git shell-quotes each atom, escaping apostrophes and exclamation marks.
        # Parse the quotes as data, never execute them. Unlike splitting on NUL
        # or newlines, this framing also handles delimiters within tag messages.
        $quotedField = "'((?:[^']|'\\['!]')*)'"
        $recordPattern = [regex]::new('\G' + (($fields | ForEach-Object { $quotedField }) -join '\x00') + '\r?\n')
        $gitEnvironment = @{ GIT_NO_LAZY_FETCH = '1' }
    }

    process {
        $result = Invoke-Git -Path $Path -AllowBare -Environment $gitEnvironment -Arguments @(
            'for-each-ref', '--shell', '--sort=refname', "--format=$format", '--', 'refs/tags/'
        )
        if ($null -eq $result) { return }

        $offset = 0
        while ($offset -lt $result.StandardOutput.Length) {
            $match = $recordPattern.Match($result.StandardOutput, $offset)
            if (-not $match.Success) {
                $PSCmdlet.ThrowTerminatingError([System.Management.Automation.ErrorRecord]::new(
                    [System.FormatException]::new('Unexpected git for-each-ref tag output.'),
                    'GitTagFormatInvalid', [System.Management.Automation.ErrorCategory]::InvalidData, $result.RepositoryPath))
            }
            $offset += $match.Length
            $values = @($match.Groups | Select-Object -Skip 1 | ForEach-Object {
                $_.Value.Replace("'\''", "'").Replace("'\!'", '!')
            })
            $tagName = $values[0].Substring('refs/tags/'.Length)
            $matchesName = $false
            foreach ($pattern in $Name) {
                if ($tagName -clike $pattern) { $matchesName = $true; break }
            }
            if (-not $matchesName) { continue }

            $isAnnotated = $values[1] -ceq 'tag'
            $targetType = if ($isAnnotated) { $values[3] } else { $values[1] }
            $targetId = if ($isAnnotated) { $values[4] } else { $values[2] }
            if ($targetType -ceq 'tag') {
                # Peel any remaining tag levels using the captured object ID,
                # not a ref that may have moved since for-each-ref.
                $peeled = Invoke-Git -Path $result.RepositoryPath -AllowBare -Environment $gitEnvironment -Arguments @(
                    'rev-parse', '--verify', '--end-of-options', "$($values[2])^{}"
                )
                if ($null -eq $peeled) { continue }
                $targetId = $peeled.StandardOutput.Trim()
                $type = Invoke-Git -Path $result.RepositoryPath -AllowBare -Environment $gitEnvironment -Arguments @('cat-file', '-t', $targetId)
                if ($null -eq $type) { continue }
                $targetType = $type.StandardOutput.Trim()
            }

            $dates = foreach ($value in $values[5..6]) {
                if ($value) {
                    [DateTimeOffset]::Parse($value, [System.Globalization.CultureInfo]::InvariantCulture)
                } else {
                    $null
                }
            }
            [PSCustomObject]@{
                PSTypeName       = 'GitTag'
                Name             = $tagName
                Reference        = $values[0]
                ObjectId         = $values[2]
                ObjectType       = $values[1]
                IsAnnotated      = $isAnnotated
                TargetObjectId   = $targetId
                TargetObjectType = $targetType
                TargetCommit     = if ($targetType -ceq 'commit') { $targetId } else { $null }
                Subject          = $values[7]
                Annotation       = if ($isAnnotated) { $values[8] } else { $null }
                TaggerDate       = $dates[0]
                CreatorDate      = $dates[1]
                RepositoryPath   = $result.RepositoryPath
            }
        }
    }
}
