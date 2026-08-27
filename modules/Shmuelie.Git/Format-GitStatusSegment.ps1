function Format-GitStatusSegment {
    <#
    .SYNOPSIS
        Render a GitStatusSummary as a colored posh-git-style prompt segment.
    .DESCRIPTION
        Takes a GitStatusSummary (from Get-GitStatusSummary) and returns an
        ANSI-colored string of the form

            [branch|OP ↓B ↑A +A ~M -D | +A ~M -D !C]

        suitable for embedding in a prompt. Colors are emitted with $PSStyle, so
        the result is a plain string that can be captured, tested, or written with
        Write-Host -NoNewline.

        Branch color reflects upstream state: green when ahead, red when behind,
        yellow when both, dark-cyan when the upstream is gone, cyan otherwise. The
        staged (index) counts are dark green, the working-tree counts dark red, and
        conflicts red. Untracked files are folded into the working-tree "added"
        count rather than shown as a separate marker.

        Returns an empty string when the summary is not a git repository.
    .PARAMETER Status
        A GitStatusSummary object, typically from Get-GitStatusSummary. Accepts
        pipeline input.
    .PARAMETER ShowChangeCounts
        Whether to include the index/working/conflict change counts. Defaults to
        $true. Pass -ShowChangeCounts:$false to render only the branch, in-progress
        operation, and ahead/behind relation (e.g. for very large repositories
        where counting working-tree changes is expensive).
    .EXAMPLE
        Get-GitStatusSummary | Format-GitStatusSegment
        Renders the current repository's colored status segment.
    .EXAMPLE
        Write-Host -NoNewline (Format-GitStatusSegment -Status $summary -ShowChangeCounts:$false)
        Writes a compact segment (branch + relation only) into a prompt.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [PSTypeName('GitStatusSummary')]
        $Status,

        [bool]$ShowChangeCounts = $true
    )

    process {
        if (-not $Status.IsGitRepo) { return '' }

        $fg = $PSStyle.Foreground
        # Map the classic prompt console colors to their $PSStyle equivalents:
        # the bright ANSI colors match the console's Yellow/Cyan/Green/Red, and the
        # normal ANSI colors match the Dark* console variants.
        $branchColor = if ($Status.UpstreamGone) { $fg.Cyan }                                  # DarkCyan
            elseif ($Status.AheadBy -gt 0 -and $Status.BehindBy -gt 0) { $fg.BrightYellow }    # Yellow
            elseif ($Status.AheadBy -gt 0) { $fg.BrightGreen }                                 # Green
            elseif ($Status.BehindBy -gt 0) { $fg.BrightRed }                                  # Red
            else { $fg.BrightCyan }                                                            # Cyan

        $relation = if ($Status.AheadBy -gt 0 -and $Status.BehindBy -gt 0) { "↓$($Status.BehindBy) ↑$($Status.AheadBy)" }
            elseif ($Status.AheadBy -gt 0) { "↑$($Status.AheadBy)" }
            elseif ($Status.BehindBy -gt 0) { "↓$($Status.BehindBy)" }
            elseif ($Status.UpstreamGone) { '×' }
            elseif ($Status.Upstream) { '≡' }
            else { '' }

        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.Append("$($fg.BrightYellow)[")
        [void]$sb.Append("$branchColor$($Status.Branch)")
        if ($Status.Operation) { [void]$sb.Append("$($fg.BrightMagenta)|$($Status.Operation)") }
        if ($relation) { [void]$sb.Append("$branchColor $relation") }

        if ($ShowChangeCounts) {
            $hasIndex = ($Status.IndexAdded + $Status.IndexModified + $Status.IndexDeleted) -gt 0
            $workingAdded = $Status.WorkingAdded + $Status.Untracked
            $hasWorking = ($workingAdded + $Status.WorkingModified + $Status.WorkingDeleted) -gt 0

            if ($hasIndex) {
                [void]$sb.Append("$($fg.Green) +$($Status.IndexAdded) ~$($Status.IndexModified) -$($Status.IndexDeleted)")
            }
            if ($hasIndex -or $hasWorking) {
                [void]$sb.Append("$($fg.BrightYellow) |")
            }
            if ($hasWorking) {
                [void]$sb.Append("$($fg.Red) +$workingAdded ~$($Status.WorkingModified) -$($Status.WorkingDeleted)")
            }
            if ($Status.Conflicts -gt 0) {
                [void]$sb.Append("$($fg.BrightRed) !$($Status.Conflicts)")
            }
        }

        [void]$sb.Append("$($fg.BrightYellow)]$($PSStyle.Reset)")
        $sb.ToString()
    }
}
