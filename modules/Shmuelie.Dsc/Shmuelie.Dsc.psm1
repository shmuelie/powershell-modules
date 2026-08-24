# Private helpers -------------------------------------------------------------
# These support the resource classes and are intentionally not exported
# (FunctionsToExport is empty in the manifest). The CLI wrappers exist so the
# resource classes can be unit-tested by mocking them.

function Remove-DscAnsiEscape {
    # Strip ANSI/VT escape sequences so colorized CLI output does not defeat the
    # presence checks (e.g. uv colorizes `uv tool list` by default).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )

    return ($Text -replace "$([char]27)\[[0-9;]*[A-Za-z]", '')
}

function Test-DscListContainsToken {
    # Whole-token (whitespace-delimited) membership test against CLI list output.
    # Using exact token equality avoids the substring false positives a bare
    # `-match` would produce (e.g. 'mcp' matching 'fast-agent-mcp').
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Lines,

        [Parameter(Mandatory)]
        [string]$Token
    )

    foreach ($line in $Lines) {
        $tokens = $line -split '\s+' | Where-Object { $_ -ne '' }
        if ($tokens -contains $Token) {
            return $true
        }
    }
    return $false
}

function Assert-DscSafeArgument {
    # Reject values containing characters that cmd.exe would re-parse when a CLI
    # resolves to a .cmd/.bat shim on Windows (BatBadBut / CVE-2024-1874 class).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($Value -match '[&|<>^"%!()\x60\r\n]') {
        throw "$Name contains characters that are not allowed for a shell-safe argument: '$Value'"
    }
}

function Invoke-DscCopilot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $previousNoColor = $env:NO_COLOR
    $env:NO_COLOR = '1'
    try {
        $raw = & copilot @Arguments 2>&1
        $exit = $LASTEXITCODE
    } finally {
        if ($null -eq $previousNoColor) {
            Remove-Item Env:NO_COLOR -ErrorAction SilentlyContinue
        } else {
            $env:NO_COLOR = $previousNoColor
        }
    }
    $lines = @($raw | ForEach-Object { Remove-DscAnsiEscape ([string]$_) })
    [pscustomobject]@{
        Output   = $lines
        ExitCode = $exit
    }
}

function Invoke-DscUv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $previousNoColor = $env:NO_COLOR
    $previousUvNoColor = $env:UV_NO_COLOR
    $env:NO_COLOR = '1'
    $env:UV_NO_COLOR = '1'
    try {
        $raw = & uv @Arguments 2>&1
        $exit = $LASTEXITCODE
    } finally {
        if ($null -eq $previousNoColor) {
            Remove-Item Env:NO_COLOR -ErrorAction SilentlyContinue
        } else {
            $env:NO_COLOR = $previousNoColor
        }
        if ($null -eq $previousUvNoColor) {
            Remove-Item Env:UV_NO_COLOR -ErrorAction SilentlyContinue
        } else {
            $env:UV_NO_COLOR = $previousUvNoColor
        }
    }
    $lines = @($raw | ForEach-Object { Remove-DscAnsiEscape ([string]$_) })
    [pscustomobject]@{
        Output   = $lines
        ExitCode = $exit
    }
}

function New-DscSymbolicLink {
    # Wraps New-Item's symbolic-link creation. The -Target parameter is a dynamic
    # provider parameter, so isolating it here keeps the SymbolicLink resource
    # unit-testable (tests mock this function).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Target
    )

    New-Item -ItemType SymbolicLink -Path $Path -Target $Target -Force -ErrorAction Stop | Out-Null
}

# Resources -------------------------------------------------------------------

<#
.SYNOPSIS
    Saves a PowerShell module to a local path using Save-PSResource.

.DESCRIPTION
    DSC resource that ensures a PowerShell module is saved (not installed) to a
    specified directory. Tests for existence by checking whether a subfolder
    matching the module name (and version, when specified) exists under Path.
    Uses Save-PSResource with -TrustRepository, -IncludeXml, -AcceptLicense, and
    -SkipDependencyCheck so it runs non-interactively.

    Depends only on the public Microsoft.PowerShell.PSResourceGet module (which
    ships with PowerShell 7.4+).

.PROPERTY Name
    The name of the PowerShell module to save. This is the key property.

.PROPERTY Path
    The directory to save the module into (e.g. a local modules directory).

.PROPERTY Repository
    The PSResourceRepository to save from. Defaults to 'PSGallery'.

.PROPERTY Version
    Optional specific version to save. When set, Test() checks for that version's
    subfolder and Set() passes it to Save-PSResource -Version.

.PROPERTY Installed
    Read-only. Reports whether the module (and version, if specified) is present.

.EXAMPLE
    - name: Save Pester
      type: Shmuelie.Dsc/SavePSResource
      properties:
        Name: Pester
        Path: C:\Modules
#>
[DscResource()]
class SavePSResource {
    [DscProperty(Key)]
    [string] $Name

    [DscProperty(Mandatory)]
    [string] $Path

    [DscProperty()]
    [string] $Repository = 'PSGallery'

    [DscProperty()]
    [string] $Version = ''

    [DscProperty(NotConfigurable)]
    [bool] $Installed

    [SavePSResource] Get() {
        $state = [SavePSResource]@{
            Name       = $this.Name
            Path       = $this.Path
            Repository = $this.Repository
            Version    = $this.Version
        }
        $state.Installed = $this.Test()
        return $state
    }

    [bool] Test() {
        $modulePath = Join-Path $this.Path $this.Name
        if (-not (Test-Path -LiteralPath $modulePath)) {
            return $false
        }
        if ($this.Version) {
            return (Test-Path -LiteralPath (Join-Path $modulePath $this.Version))
        }
        return $true
    }

    [void] Set() {
        $params = @{
            Name                = $this.Name
            Path                = $this.Path
            Repository          = $this.Repository
            TrustRepository     = $true
            IncludeXml          = $true
            AcceptLicense       = $true
            SkipDependencyCheck = $true
        }
        if ($this.Version) {
            $params['Version'] = $this.Version
        }
        Save-PSResource @params
    }
}

<#
.SYNOPSIS
    Creates or verifies a symbolic link at a specified path.

.DESCRIPTION
    DSC resource that ensures a symbolic link exists pointing to the correct
    target. Creates parent directories if they do not exist and replaces an
    existing item at Path when the link is missing or points elsewhere.

    On Windows, creating symbolic links requires Developer Mode or an elevated
    session.

.PROPERTY Path
    The full path where the symbolic link should exist. This is the key property.

.PROPERTY Target
    The target path the symbolic link should point to. Get() reports the actual
    current target (empty when Path is absent or is not a symbolic link).

.EXAMPLE
    - name: Symlink .gitconfig
      type: Shmuelie.Dsc/SymbolicLink
      properties:
        Path: C:\Users\me\.gitconfig
        Target: C:\dotfiles\.gitconfig
#>
[DscResource()]
class SymbolicLink {
    [DscProperty(Key)]
    [string] $Path

    [DscProperty(Mandatory)]
    [string] $Target

    [SymbolicLink] Get() {
        $item = Get-Item -LiteralPath $this.Path -ErrorAction SilentlyContinue
        $current = if ($item -and $item.LinkType -eq 'SymbolicLink') { [string]$item.Target } else { '' }
        return [SymbolicLink]@{
            Path   = $this.Path
            Target = $current
        }
    }

    [bool] Test() {
        $item = Get-Item -LiteralPath $this.Path -ErrorAction SilentlyContinue
        if ($null -eq $item -or $item.LinkType -ne 'SymbolicLink') {
            return $false
        }
        return ([string]$item.Target -eq $this.Target)
    }

    [void] Set() {
        $parentDir = Split-Path -Path $this.Path -Parent
        if ($parentDir -and -not (Test-Path -LiteralPath $parentDir)) {
            New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
        }
        New-DscSymbolicLink -Path $this.Path -Target $this.Target
    }
}

<#
.SYNOPSIS
    Installs a GitHub Copilot CLI plugin.

.DESCRIPTION
    DSC resource that ensures a Copilot CLI plugin is installed. Tests by
    checking whether the plugin's name appears as a whole token in
    'copilot plugin list' output. Supports the owner/repo, plugin@marketplace,
    and market:plugin@marketplace source formats accepted by the Copilot CLI.

    For a URL source (or any source whose installed plugin name cannot be
    derived from the source spec), set the Name property so Test() can match the
    installed plugin; otherwise the plugin is re-installed on every apply.

    Depends only on the public GitHub Copilot CLI (copilot) on PATH.

.PROPERTY Source
    The plugin source to install (owner/repo, plugin@marketplace,
    market:plugin@marketplace, or a URL). This is the key property.

.PROPERTY Name
    Optional. The installed plugin name used for the presence check. Defaults to
    the name derived from Source. Set this for URL sources.

.PROPERTY Installed
    Read-only. Reports whether the plugin is installed.

.EXAMPLE
    - name: Install a plugin
      type: Shmuelie.Dsc/CopilotPlugin
      properties:
        Source: owner/repo
#>
[DscResource()]
class CopilotPlugin {
    [DscProperty(Key)]
    [string] $Source

    [DscProperty()]
    [string] $Name = ''

    [DscProperty(NotConfigurable)]
    [bool] $Installed

    hidden [string] ResolveName() {
        if ($this.Name) {
            return $this.Name
        }
        $spec = (($this.Source -split '@')[0]) -replace '^market:', ''
        return ($spec -split '/' | Where-Object { $_ -ne '' } | Select-Object -Last 1)
    }

    [CopilotPlugin] Get() {
        $state = [CopilotPlugin]@{
            Source = $this.Source
            Name   = $this.Name
        }
        $state.Installed = $this.Test()
        return $state
    }

    [bool] Test() {
        $result = Invoke-DscCopilot -Arguments @('plugin', 'list')
        return Test-DscListContainsToken -Lines $result.Output -Token $this.ResolveName()
    }

    [void] Set() {
        Assert-DscSafeArgument -Value $this.Source -Name 'Source'
        $result = Invoke-DscCopilot -Arguments @('plugin', 'install', $this.Source)
        if ($result.ExitCode -ne 0) {
            throw "Failed to install Copilot plugin '$($this.Source)': $($result.Output -join '; ')"
        }
    }
}

<#
.SYNOPSIS
    Registers a GitHub Copilot CLI plugin marketplace.

.DESCRIPTION
    DSC resource that ensures a Copilot CLI plugin marketplace is registered.
    Tests by checking whether the marketplace name appears as a whole token in
    'copilot plugin marketplace list' output.

    Depends only on the public GitHub Copilot CLI (copilot) on PATH.

.PROPERTY Name
    The name to register the marketplace under. This is the key property.

.PROPERTY Repository
    The GitHub repository hosting the marketplace (owner/repo format).

.PROPERTY Installed
    Read-only. Reports whether the marketplace is registered.

.EXAMPLE
    - name: Register a marketplace
      type: Shmuelie.Dsc/CopilotMarketplace
      properties:
        Name: dotnet-skills
        Repository: dotnet/skills
#>
[DscResource()]
class CopilotMarketplace {
    [DscProperty(Key)]
    [string] $Name

    [DscProperty(Mandatory)]
    [string] $Repository

    [DscProperty(NotConfigurable)]
    [bool] $Installed

    [CopilotMarketplace] Get() {
        $state = [CopilotMarketplace]@{
            Name       = $this.Name
            Repository = $this.Repository
        }
        $state.Installed = $this.Test()
        return $state
    }

    [bool] Test() {
        $result = Invoke-DscCopilot -Arguments @('plugin', 'marketplace', 'list')
        return Test-DscListContainsToken -Lines $result.Output -Token $this.Name
    }

    [void] Set() {
        Assert-DscSafeArgument -Value $this.Name -Name 'Name'
        Assert-DscSafeArgument -Value $this.Repository -Name 'Repository'
        $result = Invoke-DscCopilot -Arguments @('plugin', 'marketplace', 'add', $this.Name, $this.Repository)
        if ($result.ExitCode -ne 0) {
            throw "Failed to register Copilot marketplace '$($this.Name)': $($result.Output -join '; ')"
        }
    }
}

<#
.SYNOPSIS
    Installs a Python tool via uv.

.DESCRIPTION
    DSC resource that ensures a Python tool is installed via 'uv tool install'.
    Tests by checking whether the tool name appears as a whole token in
    'uv tool list' output.

    Depends only on the public uv CLI on PATH.

.PROPERTY Name
    The name of the Python tool to install. This is the key property.

.PROPERTY Installed
    Read-only. Reports whether the tool is installed.

.EXAMPLE
    - name: Install a tool
      type: Shmuelie.Dsc/UvTool
      properties:
        Name: fast-agent-mcp
#>
[DscResource()]
class UvTool {
    [DscProperty(Key)]
    [string] $Name

    [DscProperty(NotConfigurable)]
    [bool] $Installed

    [UvTool] Get() {
        $state = [UvTool]@{
            Name = $this.Name
        }
        $state.Installed = $this.Test()
        return $state
    }

    [bool] Test() {
        $result = Invoke-DscUv -Arguments @('tool', 'list')
        return Test-DscListContainsToken -Lines $result.Output -Token $this.Name
    }

    [void] Set() {
        Assert-DscSafeArgument -Value $this.Name -Name 'Name'
        $result = Invoke-DscUv -Arguments @('tool', 'install', $this.Name)
        if ($result.ExitCode -ne 0) {
            throw "Failed to install uv tool '$($this.Name)': $($result.Output -join '; ')"
        }
    }
}
