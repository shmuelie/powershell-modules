function Select-CopilotSessionMatch {
    [CmdletBinding()]
    [OutputType('CopilotSession')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [psobject]$InputObject,

        [SupportsWildcards()]
        [ValidateNotNullOrEmpty()]
        [string]$Id,

        [SupportsWildcards()]
        [ValidateNotNullOrEmpty()]
        [string]$Repository,

        [SupportsWildcards()]
        [ValidateNotNullOrEmpty()]
        [string]$Branch,

        [SupportsWildcards()]
        [ValidateNotNullOrEmpty()]
        [string]$Cwd,

        [SupportsWildcards()]
        [ValidateNotNullOrEmpty()]
        [string]$Summary,

        [datetimeoffset]$UpdatedBefore,

        [ValidateScript({ $_ -gt [timespan]::Zero }, ErrorMessage = 'OlderThan must be a positive TimeSpan.')]
        [timespan]$OlderThan
    )

    begin {
        $stringFilters = @{}
        foreach ($field in 'Id', 'Repository', 'Branch', 'Cwd', 'Summary') {
            if ($PSBoundParameters.ContainsKey($field)) {
                $stringFilters[$field] = $PSBoundParameters[$field]
            }
        }

        $cutoff = $null
        if ($PSBoundParameters.ContainsKey('UpdatedBefore')) {
            $cutoff = $UpdatedBefore
        }
        if ($PSBoundParameters.ContainsKey('OlderThan')) {
            # Freeze the clock once so a streaming batch shares one age boundary.
            $ageCutoff = ([datetimeoffset](Get-Date -AsUTC)).Subtract($OlderThan)
            if ($null -eq $cutoff -or $ageCutoff -lt $cutoff) {
                $cutoff = $ageCutoff
            }
        }
    }

    process {
        foreach ($field in $stringFilters.Keys) {
            $value = $InputObject.$field
            if ([string]::IsNullOrEmpty($value) -or $value -notlike $stringFilters[$field]) {
                return
            }
        }
        if ($null -ne $cutoff -and ($null -eq $InputObject.UpdatedAt -or $InputObject.UpdatedAt -ge $cutoff)) {
            return
        }

        $InputObject
    }
}
