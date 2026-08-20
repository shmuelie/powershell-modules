function Get-CopilotWorkspaceIndentLength {
    param([AllowEmptyString()][string]$Line)

    if ($Line -match '^[ \t]*') { return $Matches[0].Length }
    return 0
}

function Split-CopilotWorkspaceLines {
    param([AllowEmptyString()][string]$Content)

    [regex]::Split($Content, '\r\n|\n|\r')
}

function ConvertFrom-CopilotWorkspaceFlowScalar {
    param([AllowEmptyString()][string]$Value)

    $trimmed = $Value.Trim()
    if ($trimmed.Length -eq 0) { return '' }

    if ($trimmed[0] -eq "'") {
        $result = [System.Text.StringBuilder]::new()
        for ($i = 1; $i -lt $trimmed.Length; $i++) {
            if ($trimmed[$i] -eq "'") {
                if ($i + 1 -lt $trimmed.Length -and $trimmed[$i + 1] -eq "'") {
                    [void]$result.Append("'")
                    $i++
                    continue
                }
                return $result.ToString()
            }
            [void]$result.Append($trimmed[$i])
        }
        return $result.ToString()
    }

    if ($trimmed[0] -eq '"') {
        $result = [System.Text.StringBuilder]::new()
        for ($i = 1; $i -lt $trimmed.Length; $i++) {
            $char = $trimmed[$i]
            if ($char -eq '"') { return $result.ToString() }
            if ($char -eq '\' -and $i + 1 -lt $trimmed.Length) {
                $i++
                switch ($trimmed[$i]) {
                    'n' { [void]$result.Append("`n") }
                    'r' { [void]$result.Append("`r") }
                    't' { [void]$result.Append("`t") }
                    '"' { [void]$result.Append('"') }
                    '\' { [void]$result.Append('\') }
                    default { [void]$result.Append($trimmed[$i]) }
                }
                continue
            }
            [void]$result.Append($char)
        }
        return $result.ToString()
    }

    $comment = [regex]::Match($trimmed, '\s+#')
    if ($comment.Success) {
        return $trimmed.Substring(0, $comment.Index).TrimEnd()
    }

    $trimmed
}

function ConvertFrom-CopilotWorkspaceBlockScalar {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory)][int]$StartIndex,
        [Parameter(Mandatory)][int]$BaseIndent,
        [Parameter(Mandatory)][ValidateSet('|', '>')][string]$Style,
        [string]$Chomp
    )

    $blockLines = [System.Collections.Generic.List[string]]::new()
    $blockIndent = $null

    for ($i = $StartIndex + 1; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        if ($line -match '^[ \t]*$') {
            $blockLines.Add('')
            continue
        }

        $indent = Get-CopilotWorkspaceIndentLength $line
        if ($indent -le $BaseIndent) { break }
        if ($null -eq $blockIndent) { $blockIndent = $indent }

        $remove = [Math]::Min($blockIndent, $line.Length)
        $blockLines.Add($line.Substring($remove))
    }

    if ($Style -eq '|') {
        $text = $blockLines -join "`n"
    } else {
        $foldedLines = [System.Collections.Generic.List[string]]::new()
        $paragraph = [System.Collections.Generic.List[string]]::new()
        foreach ($line in $blockLines) {
            if ($line -eq '') {
                if ($paragraph.Count -gt 0) {
                    $foldedLines.Add(($paragraph -join ' '))
                    $paragraph.Clear()
                }
                $foldedLines.Add('')
            } else {
                $paragraph.Add($line.TrimEnd())
            }
        }
        if ($paragraph.Count -gt 0) { $foldedLines.Add(($paragraph -join ' ')) }
        $text = $foldedLines -join "`n"
    }

    if ($Chomp -ne '-') { $text += "`n" }
    $text
}

function Find-CopilotWorkspaceFieldLine {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory)][string]$Field
    )

    $escapedField = [regex]::Escape($Field)
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match "^(?<indent>[ \t]*)$escapedField\s*:\s*(?<value>.*)$") {
            return [PSCustomObject]@{
                Index  = $i
                Indent = $Matches['indent']
                Value  = $Matches['value']
            }
        }
    }

    $null
}

function ConvertTo-CopilotWorkspaceFlowScalar {
    param([AllowEmptyString()][string]$Value)

    if ($Value -match '\r|\n') {
        $lines = Split-CopilotWorkspaceLines $Value
        if ($lines.Count -gt 0 -and $lines[-1] -eq '') {
            $lines = $lines[0..($lines.Count - 2)]
        }
        return "|-`n  $($lines -join "`n  ")"
    }

    if ($Value -eq '') { return '""' }

    $needsQuotes = $Value -match '^\s|\s$|[:#\[\]{},&*!?|>''"%@`]|\s#|:\s'
    if (-not $needsQuotes) { return $Value }

    $escaped = $Value.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')
    '"' + $escaped + '"'
}

function Get-CopilotWorkspaceField {
    <#
    .SYNOPSIS
        Reads a scalar field from Copilot CLI workspace.yaml content.

    .DESCRIPTION
        Parses the simple top-level workspace.yaml shape used by Copilot CLI
        session metadata. Supports plain scalars, single-quoted and
        double-quoted flow scalars, and literal or folded block scalars using
        |, |-, >, or >-. The parser accepts either raw content or a path.

    .PARAMETER Field
        The workspace.yaml field name to read.

    .PARAMETER Content
        Raw workspace.yaml content.

    .PARAMETER Path
        Path to a workspace.yaml file.

    .EXAMPLE
        Get-CopilotWorkspaceField -Field name -Content 'name: "Build tests"'

        Returns Build tests.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Content')]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Field,

        [Parameter(Mandatory, ParameterSetName = 'Content', ValueFromPipeline)]
        [AllowEmptyString()]
        [string]$Content,

        [Parameter(Mandatory, ParameterSetName = 'Path')]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    process {
        if ($PSCmdlet.ParameterSetName -eq 'Path') {
            if (-not (Test-Path -LiteralPath $Path)) { return $null }
            $Content = Get-Content -LiteralPath $Path -Raw
        }

        $lines = Split-CopilotWorkspaceLines $Content
        $match = Find-CopilotWorkspaceFieldLine -Lines $lines -Field $Field
        if ($null -eq $match) { return $null }

        $value = $match.Value.Trim()
        if ($value -match '^(?<style>[|>])(?<chomp>[-+]?)\s*(?:#.*)?$') {
            return ConvertFrom-CopilotWorkspaceBlockScalar `
                -Lines $lines `
                -StartIndex $match.Index `
                -BaseIndent $match.Indent.Length `
                -Style $Matches['style'] `
                -Chomp $Matches['chomp']
        }

        ConvertFrom-CopilotWorkspaceFlowScalar $match.Value
    }
}

function Set-CopilotWorkspaceField {
    <#
    .SYNOPSIS
        Rewrites a scalar field in Copilot CLI workspace.yaml content.

    .DESCRIPTION
        Replaces an existing workspace.yaml field while preserving the field's
        indentation and the file's dominant line ending. Existing block scalar
        bodies are removed before the replacement is written. Single-line values
        are emitted as plain scalars when safe and double-quoted otherwise;
        multi-line values are emitted as a literal block scalar.

    .PARAMETER Field
        The workspace.yaml field name to rewrite.

    .PARAMETER Value
        The replacement scalar value.

    .PARAMETER Content
        Raw workspace.yaml content.

    .PARAMETER Path
        Path to a workspace.yaml file to update in place.

    .EXAMPLE
        Set-CopilotWorkspaceField -Field name -Value 'Merged session' -Content $yaml

        Returns updated workspace.yaml content.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Content')]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Field,

        [Parameter(Mandatory, Position = 1)]
        [AllowEmptyString()]
        [string]$Value,

        [Parameter(Mandatory, ParameterSetName = 'Content', ValueFromPipeline)]
        [AllowEmptyString()]
        [string]$Content,

        [Parameter(Mandatory, ParameterSetName = 'Path')]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    process {
        if ($PSCmdlet.ParameterSetName -eq 'Path') {
            if (-not (Test-Path -LiteralPath $Path)) { return $null }
            $Content = Get-Content -LiteralPath $Path -Raw
        }

        $newLine = if ($Content -match "`r`n") { "`r`n" } elseif ($Content -match "`r") { "`r" } else { "`n" }
        $lines = Split-CopilotWorkspaceLines $Content
        $match = Find-CopilotWorkspaceFieldLine -Lines $lines -Field $Field
        if ($null -eq $match) { return $Content }

        $endIndex = $match.Index + 1
        if ($match.Value.Trim() -match '^[|>]') {
            for (; $endIndex -lt $lines.Count; $endIndex++) {
                $line = $lines[$endIndex]
                if ($line -match '^[ \t]*$') { continue }
                if ((Get-CopilotWorkspaceIndentLength $line) -le $match.Indent.Length) { break }
            }
        }

        $scalar = ConvertTo-CopilotWorkspaceFlowScalar $Value
        $replacement = "$($match.Indent)${Field}: $scalar" -replace "`n", $newLine
        $replacementLines = Split-CopilotWorkspaceLines $replacement

        $updatedLines = [System.Collections.Generic.List[string]]::new()
        for ($i = 0; $i -lt $match.Index; $i++) { $updatedLines.Add($lines[$i]) }
        foreach ($line in $replacementLines) { $updatedLines.Add($line) }
        for ($i = $endIndex; $i -lt $lines.Count; $i++) { $updatedLines.Add($lines[$i]) }

        $updated = $updatedLines -join $newLine
        if ($PSCmdlet.ParameterSetName -eq 'Path') {
            Set-Content -LiteralPath $Path -Value $updated -Encoding UTF8 -NoNewline
        }

        $updated
    }
}
