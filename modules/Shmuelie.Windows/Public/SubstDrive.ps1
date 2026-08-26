function ConvertTo-SubstDriveLetter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$DriveLetter
    )

    if ($DriveLetter -notmatch '^[A-Za-z]:?$') {
        throw [System.ArgumentException]::new(
            'DriveLetter must be a single letter A-Z, optionally followed by a colon.',
            'DriveLetter')
    }

    return "$($DriveLetter.Substring(0, 1).ToUpperInvariant()):"
}

function Resolve-SubstTargetDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$TargetPath
    )

    try {
        $item = Get-Item -LiteralPath $TargetPath -ErrorAction Stop
    }
    catch {
        throw [System.IO.DirectoryNotFoundException]::new("TargetPath must be an existing directory: $TargetPath")
    }

    if (-not $item.PSIsContainer) {
        throw [System.IO.DirectoryNotFoundException]::new("TargetPath must be an existing directory: $TargetPath")
    }

    if ($item.PSProvider.Name -ne 'FileSystem') {
        throw [System.ArgumentException]::new(
            "TargetPath must resolve to a FileSystem directory: $TargetPath",
            'TargetPath')
    }

    return $item.FullName
}

function New-SubstDriveObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$DriveLetter,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$TargetPath
    )

    $item = Get-Item -LiteralPath $TargetPath -ErrorAction SilentlyContinue
    if ($item -and $item.PSIsContainer -and $item.PSProvider.Name -eq 'FileSystem') {
        $TargetPath = $item.FullName
    }

    $drive = [PSCustomObject]@{
        DriveLetter = ConvertTo-SubstDriveLetter -DriveLetter $DriveLetter
        TargetPath  = $TargetPath
    }
    $drive.PSObject.TypeNames.Insert(0, 'SubstDrive')
    return $drive
}

function Invoke-SubstCommand {
    [CmdletBinding()]
    param(
        [string[]]$ArgumentList = @()
    )

    $substPath = Join-Path $env:SystemRoot 'System32\subst.exe'
    if (-not (Test-Path -LiteralPath $substPath -PathType Leaf)) {
        $substPath = (Get-Command subst.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    }

    $output = & $substPath @ArgumentList 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $message = ($output | Out-String).Trim()
        if (-not $message) {
            $message = "subst.exe exited with code $exitCode."
        }

        throw $message
    }

    return $output
}

function ConvertFrom-SubstOutputLine {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline)]
        [string]$Line
    )

    process {
        if ($Line -match '^\s*(?<DriveLetter>[A-Za-z]):(?:\\)?:\s*=>\s*(?<TargetPath>.+?)\s*$' -or
            $Line -match '^\s*(?<DriveLetter>[A-Za-z]):(?:\\)?\s*=>\s*(?<TargetPath>.+?)\s*$') {
            [PSCustomObject]@{
                DriveLetter = "$($Matches.DriveLetter.ToUpperInvariant()):"
                TargetPath  = $Matches.TargetPath.TrimEnd()
            }
        }
    }
}

function Get-SubstDriveMapping {
    [CmdletBinding()]
    param()

    Invoke-SubstCommand | ConvertFrom-SubstOutputLine
}

function New-SubstDriveMapping {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Z]:$')]
        [string]$DriveLetter,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$TargetPath
    )

    Invoke-SubstCommand -ArgumentList @($DriveLetter, $TargetPath) | Out-Null
}

function Remove-SubstDriveMapping {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Z]:$')]
        [string]$DriveLetter
    )

    Invoke-SubstCommand -ArgumentList @($DriveLetter, '/D') | Out-Null
}

function Test-SubstDriveLetterInUse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Z]:$')]
        [string]$DriveLetter
    )

    $letter = $DriveLetter.Substring(0, 1)
    $existingDrive = Get-PSDrive -Name $letter -PSProvider FileSystem -ErrorAction SilentlyContinue
    if ($existingDrive) {
        return $true
    }

    return [bool](Get-SubstDriveMapping | Where-Object DriveLetter -EQ $DriveLetter | Select-Object -First 1)
}

function Get-SubstDrive {
    <#
    .SYNOPSIS
        Gets Windows subst virtual drive mappings.
    .DESCRIPTION
        Enumerates current subst drive mappings and returns typed SubstDrive objects
        containing DriveLetter and TargetPath properties.
    .PARAMETER DriveLetter
        Optional drive letter filter. Specify a single letter, with or without a colon.
    .EXAMPLE
        Get-SubstDrive
        Lists all current subst drive mappings.
    .EXAMPLE
        Get-SubstDrive -DriveLetter S
        Gets the subst mapping for drive S:.
    .NOTES
        Windows only.
    #>
    [CmdletBinding()]
    param(
        [ValidateNotNullOrEmpty()]
        [string]$DriveLetter
    )

    begin {
        Assert-WindowsOnly -CommandName $MyInvocation.MyCommand.Name
        $normalizedDriveLetter = if ($PSBoundParameters.ContainsKey('DriveLetter')) {
            ConvertTo-SubstDriveLetter -DriveLetter $DriveLetter
        }
    }

    process {
        foreach ($mapping in Get-SubstDriveMapping) {
            $mappingDriveLetter = ConvertTo-SubstDriveLetter -DriveLetter $mapping.DriveLetter
            if ($normalizedDriveLetter -and $mappingDriveLetter -ne $normalizedDriveLetter) {
                continue
            }

            New-SubstDriveObject -DriveLetter $mappingDriveLetter -TargetPath $mapping.TargetPath
        }
    }
}

function New-SubstDrive {
    <#
    .SYNOPSIS
        Creates a Windows subst virtual drive mapping.
    .DESCRIPTION
        Maps a drive letter to an existing local FileSystem directory by using the
        Windows subst capability.
    .PARAMETER DriveLetter
        The virtual drive letter to create. Specify a single letter, with or without a colon.
    .PARAMETER TargetPath
        The existing local directory that the virtual drive should point to.
    .EXAMPLE
        New-SubstDrive -DriveLetter S -TargetPath C:\Source
        Creates S: as a virtual drive pointing to C:\Source.
    .NOTES
        Windows only.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$DriveLetter,

        [Parameter(Mandatory, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string]$TargetPath
    )

    process {
        Assert-WindowsOnly -CommandName $MyInvocation.MyCommand.Name

        $normalizedDriveLetter = ConvertTo-SubstDriveLetter -DriveLetter $DriveLetter
        $resolvedTargetPath = Resolve-SubstTargetDirectory -TargetPath $TargetPath

        if (Test-SubstDriveLetterInUse -DriveLetter $normalizedDriveLetter) {
            throw [System.InvalidOperationException]::new("Drive letter $normalizedDriveLetter is already in use.")
        }

        if ($PSCmdlet.ShouldProcess($normalizedDriveLetter, "Map to $resolvedTargetPath")) {
            New-SubstDriveMapping -DriveLetter $normalizedDriveLetter -TargetPath $resolvedTargetPath
            New-SubstDriveObject -DriveLetter $normalizedDriveLetter -TargetPath $resolvedTargetPath
        }
    }
}

function Remove-SubstDrive {
    <#
    .SYNOPSIS
        Removes a Windows subst virtual drive mapping.
    .DESCRIPTION
        Removes an existing subst mapping by drive letter. Accepts DriveLetter from
        Get-SubstDrive output through the pipeline by property name.
    .PARAMETER DriveLetter
        The virtual drive letter to remove. Specify a single letter, with or without a colon.
    .EXAMPLE
        Remove-SubstDrive -DriveLetter S
        Removes the S: subst mapping.
    .EXAMPLE
        Get-SubstDrive -DriveLetter S | Remove-SubstDrive
        Removes the S: subst mapping returned by Get-SubstDrive.
    .NOTES
        Windows only.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string]$DriveLetter
    )

    process {
        Assert-WindowsOnly -CommandName $MyInvocation.MyCommand.Name

        $normalizedDriveLetter = ConvertTo-SubstDriveLetter -DriveLetter $DriveLetter
        $mapping = Get-SubstDriveMapping |
            Where-Object DriveLetter -EQ $normalizedDriveLetter |
            Select-Object -First 1

        if (-not $mapping) {
            throw [System.InvalidOperationException]::new("No subst mapping exists for drive letter $normalizedDriveLetter.")
        }

        if ($PSCmdlet.ShouldProcess($normalizedDriveLetter, 'Remove subst mapping')) {
            Remove-SubstDriveMapping -DriveLetter $normalizedDriveLetter
        }
    }
}
