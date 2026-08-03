# Agency plugin profile cmdlets.
#
# Profiles let you load a different set of Agency plugins for different work
# (core / development / data). They are authored in a tracked
# agency-profiles.toml and merged into the global agency.toml
# (~/AppData/Local/agency/agency.toml) by Update-AgencyProfile. Start-Copilot
# activates one via `agency copilot --profile-only <name>` (see -AgencyProfile).

# Sentinel comments delimiting the managed [profiles.*] block in the global toml.
$script:AgencyProfileBeginMarker = '# >>> shmuelie agency-profiles (managed by Update-AgencyProfile) >>>'
$script:AgencyProfileEndMarker = '# <<< shmuelie agency-profiles <<<'

function Get-AgencyProfilePath {
    <#
    .SYNOPSIS
        Resolve the path to the tracked agency-profiles.toml (source of truth).
    #>
    [CmdletBinding()]
    param()
    if ($env:SHMUELIE_AGENCY_PROFILES_PATH -and (Test-Path $env:SHMUELIE_AGENCY_PROFILES_PATH)) {
        return (Resolve-Path $env:SHMUELIE_AGENCY_PROFILES_PATH).Path
    }
    $candidate = Join-Path (Get-Location) 'agency-profiles.toml'
    if (Test-Path $candidate) { return (Resolve-Path $candidate).Path }
    $userPath = Join-Path $HOME '.config\shmuelie\agency-profiles.toml'
    if (Test-Path $userPath) { return (Resolve-Path $userPath).Path }
    throw 'Could not locate agency-profiles.toml. Set SHMUELIE_AGENCY_PROFILES_PATH or pass an explicit -Path.'
}

function Get-AgencyGlobalConfigPath {
    <#
    .SYNOPSIS
        Resolve the path to the global agency.toml.
    #>
    [CmdletBinding()]
    param()
    Join-Path $env:USERPROFILE 'AppData\Local\agency\agency.toml'
}

function Get-AgencyProfile {
    <#
    .SYNOPSIS
        List Agency plugin profiles and their plugins.
    .DESCRIPTION
        Parses the tracked Configuration/agency-profiles.toml into typed
        AgencyProfile objects (Name, PluginCount, Plugins). Also reports the
        virtual 'full' profile (= the base plugins.default, i.e. every installed
        plugin; activated by NOT passing --profile-only).
    .PARAMETER Name
        Filter by profile name. Supports wildcards.
    .PARAMETER Path
        Override the tracked profiles file path.
    .EXAMPLE
        Get-AgencyProfile
        Lists all profiles with their plugin counts.
    .EXAMPLE
        (Get-AgencyProfile development).Plugins
        Shows the plugin specs in the 'development' profile.
    #>
    [OutputType('AgencyProfile')]
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Name = '*',

        [string]$Path
    )
    if (-not $Path) { $Path = Get-AgencyProfilePath }
    $content = Get-Content $Path -Raw

    $profiles = [ordered]@{}
    $current = $null
    foreach ($line in ($content -split "\r?\n")) {
        if ($line -match '^\s*\[\[profiles\.([^.\]]+)\.plugins\.default\]\]') {
            $current = $Matches[1]
            if (-not $profiles.Contains($current)) { $profiles[$current] = [System.Collections.Generic.List[string]]::new() }
        }
        elseif ($current -and $line -match '^\s*plugin\s*=\s*"(.+?)"') {
            $profiles[$current].Add($Matches[1])
        }
        elseif ($line -match '^\s*\[') {
            # Any other table header ends the current plugins.default array.
            if ($line -notmatch '^\s*\[\[profiles\.') { $current = $null }
        }
    }

    # Real profiles + the virtual 'full'.
    $emit = @()
    foreach ($k in $profiles.Keys) {
        $emit += [PSCustomObject]@{
            PSTypeName  = 'AgencyProfile'
            Name        = $k
            PluginCount = $profiles[$k].Count
            Plugins     = $profiles[$k].ToArray()
        }
    }
    $emit += [PSCustomObject]@{
        PSTypeName  = 'AgencyProfile'
        Name        = 'full'
        PluginCount = $null
        Plugins     = @('(all installed plugins — base plugins.default)')
    }

    $emit | Where-Object { $_.Name -like $Name } | Sort-Object Name
}

function Update-AgencyProfile {
    <#
    .SYNOPSIS
        Sync the tracked Agency profiles into the global agency.toml.
    .DESCRIPTION
        Merges the [profiles.*] tables from Configuration/agency-profiles.toml into
        the global agency.toml, replacing any previously-synced block (delimited by
        sentinel comments). The global [[plugins.default]] block (managed by
        `agency plugin install`) is never touched. Validates the result with
        `agency config check`.
    .PARAMETER Path
        Override the tracked profiles file path.
    .PARAMETER GlobalConfigPath
        Override the global agency.toml path.
    .EXAMPLE
        Update-AgencyProfile
        Writes the tracked profiles into the global agency.toml.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Path,
        [string]$GlobalConfigPath
    )
    if (-not $Path) { $Path = Get-AgencyProfilePath }
    if (-not $GlobalConfigPath) { $GlobalConfigPath = Get-AgencyGlobalConfigPath }

    if (-not (Test-Path $GlobalConfigPath)) {
        # Create a minimal global config if Agency hasn't generated one yet.
        $parent = Split-Path $GlobalConfigPath -Parent
        if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Set-Content -Path $GlobalConfigPath -Value '' -Encoding UTF8
    }

    $tracked = (Get-Content $Path -Raw).TrimEnd()
    $globalLines = Get-Content $GlobalConfigPath

    # Drop any previously-synced sentinel block.
    $kept = [System.Collections.Generic.List[string]]::new()
    $inBlock = $false
    foreach ($line in $globalLines) {
        if ($line -eq $script:AgencyProfileBeginMarker) { $inBlock = $true; continue }
        if ($line -eq $script:AgencyProfileEndMarker) { $inBlock = $false; continue }
        if (-not $inBlock) { $kept.Add($line) }
    }

    # Defensive: also strip any stray un-sentineled [profiles.*] tables.
    $cleaned = [System.Collections.Generic.List[string]]::new()
    $inProfiles = $false
    foreach ($line in $kept) {
        if ($line -match '^\s*\[\[?profiles\.') { $inProfiles = $true; continue }
        if ($inProfiles -and $line -match '^\s*\[') {
            # A new non-profiles table ends the stray profiles region.
            if ($line -notmatch '^\s*\[\[?profiles\.') { $inProfiles = $false } else { continue }
        }
        if (-not $inProfiles) { $cleaned.Add($line) }
    }

    $body = ($cleaned -join "`n").TrimEnd()
    $new = $body + "`n`n" + $script:AgencyProfileBeginMarker + "`n" + $tracked + "`n" + $script:AgencyProfileEndMarker + "`n"

    if ($PSCmdlet.ShouldProcess($GlobalConfigPath, 'Sync agency profiles')) {
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($GlobalConfigPath, $new, $utf8NoBom)

        # Validate.
        $exe = Resolve-CliExe -Name agency
        $check = & $exe config check 2>&1 | ForEach-Object { $_.ToString() }
        if (($check -join "`n") -notmatch 'config is valid') {
            Write-Warning "agency config check did not report valid after sync:`n$($check -join "`n")"
        } else {
            Write-Verbose 'Agency profiles synced and validated.'
        }
    }
}

function Add-AgencyProfilePlugin {
    <#
    .SYNOPSIS
        Add a plugin to an Agency profile.
    .DESCRIPTION
        Adds a [[profiles.<Profile>.plugins.default]] entry to the tracked
        Configuration/agency-profiles.toml and re-syncs to the global agency.toml.
        Does NOT install the plugin (use Install-AgencyPlugin -Profile for that).
    .PARAMETER Profile
        The profile to add the plugin to.
    .PARAMETER Plugin
        A plugin spec ('market:name@location') or, with -Marketplace, a plugin name.
    .PARAMETER Marketplace
        The marketplace location for -Plugin when a bare name is given (composes
        'market:<Plugin>@<Marketplace>').
    .PARAMETER Engine
        Engines for the entry (default: copilot).
    .PARAMETER Path
        Override the tracked profiles file path.
    .EXAMPLE
        Add-AgencyProfilePlugin -Profile development -Plugin market:my-plugin@https://github.com/myorg/plugins
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Position = 0, Mandatory)]
        [string]$Profile,

        [Parameter(Position = 1, Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Plugin,

        [string]$Marketplace,

        [ValidateSet('claude', 'copilot')]
        [string[]]$Engine = @('copilot'),

        [string]$Path
    )
    if (-not $Path) { $Path = Get-AgencyProfilePath }
    $spec = if ($Marketplace) { "market:$Plugin@$Marketplace" } else { $Plugin }

    $content = Get-Content $Path -Raw
    if ($content -match [regex]::Escape("plugin = `"$spec`"")) {
        # Already present somewhere; only skip if it's under this profile.
        $already = Get-AgencyProfile -Path $Path | Where-Object Name -eq $Profile | ForEach-Object { $_.Plugins }
        if ($already -contains $spec) {
            Write-Verbose "Plugin '$spec' is already in profile '$Profile'."
            return
        }
    }

    $enginesToml = '[' + (($Engine | ForEach-Object { "`"$_`"" }) -join ', ') + ']'
    $entry = "`n[[profiles.$Profile.plugins.default]]`nplugin = `"$spec`"`nengines = $enginesToml`n"

    if ($PSCmdlet.ShouldProcess("$spec -> profile '$Profile'", 'Add to agency-profiles.toml + sync')) {
        Add-Content -Path $Path -Value $entry -Encoding UTF8
        Update-AgencyProfile -Path $Path
    }
}

function Remove-AgencyProfilePlugin {
    <#
    .SYNOPSIS
        Remove a plugin from an Agency profile.
    .DESCRIPTION
        Removes the matching [[profiles.<Profile>.plugins.default]] entry from the
        tracked Configuration/agency-profiles.toml and re-syncs to the global toml.
    .PARAMETER Profile
        The profile to remove the plugin from.
    .PARAMETER Plugin
        The plugin spec ('market:name@location') to remove. Substring match on the
        plugin name is also accepted.
    .PARAMETER Path
        Override the tracked profiles file path.
    .EXAMPLE
        Remove-AgencyProfilePlugin -Profile development -Plugin diagnostics
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Position = 0, Mandatory)]
        [string]$Profile,

        [Parameter(Position = 1, Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Plugin,

        [string]$Path
    )
    if (-not $Path) { $Path = Get-AgencyProfilePath }
    $lines = Get-Content $Path

    # Find the [[profiles.<Profile>.plugins.default]] block whose plugin line
    # matches $Plugin, and drop the header + its body lines.
    $out = [System.Collections.Generic.List[string]]::new()
    $i = 0
    $removed = $false
    while ($i -lt $lines.Count) {
        $line = $lines[$i]
        if ($line -match "^\s*\[\[profiles\.$([regex]::Escape($Profile))\.plugins\.default\]\]") {
            # Collect this block (until blank line / next table / EOF).
            $block = @($line)
            $j = $i + 1
            while ($j -lt $lines.Count -and $lines[$j] -notmatch '^\s*\[' -and $lines[$j].Trim() -ne '') {
                $block += $lines[$j]; $j++
            }
            $matchesPlugin = ($block | Where-Object { $_ -match '^\s*plugin\s*=\s*"(.+?)"' -and ($Matches[1] -eq $Plugin -or $Matches[1] -like "*$Plugin*") })
            if ($matchesPlugin -and -not $removed) {
                $removed = $true
                $i = $j
                # also swallow a single trailing blank separator
                if ($i -lt $lines.Count -and $lines[$i].Trim() -eq '') { $i++ }
                continue
            }
            else {
                $block | ForEach-Object { $out.Add($_) }
                $i = $j
                continue
            }
        }
        $out.Add($line)
        $i++
    }

    if (-not $removed) {
        Write-Warning "No entry for plugin '$Plugin' found in profile '$Profile'."
        return
    }

    if ($PSCmdlet.ShouldProcess("$Plugin from profile '$Profile'", 'Remove from agency-profiles.toml + sync')) {
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($Path, (($out -join "`n").TrimEnd() + "`n"), $utf8NoBom)
        Update-AgencyProfile -Path $Path
    }
}
