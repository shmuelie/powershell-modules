# Private helpers -------------------------------------------------------------
# Thin wrappers around the external CLIs the resources depend on. The resource
# classes call these instead of invoking the tools directly so the classes stay
# unit-testable (tests mock these functions). They are intentionally not
# exported (FunctionsToExport is empty in the manifest).

function Invoke-DscCopilot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $output = & copilot @Arguments 2>&1
    [pscustomobject]@{
        Output   = $output
        ExitCode = $LASTEXITCODE
    }
}

function Invoke-DscUv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $output = & uv @Arguments 2>&1
    [pscustomobject]@{
        Output   = $output
        ExitCode = $LASTEXITCODE
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
    matching the module name exists under Path. Uses Save-PSResource with
    -TrustRepository, -IncludeXml, -AcceptLicense, and -SkipDependencyCheck so
    it runs non-interactively.

    Depends only on the public Microsoft.PowerShell.PSResourceGet module.

.PROPERTY Name
    The name of the PowerShell module to save. This is the key property.

.PROPERTY Path
    The directory to save the module into (e.g. a local modules directory).

.PROPERTY Repository
    The PSResourceRepository to save from. Defaults to 'PSGallery'.

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

    [SavePSResource] Get() {
        return [SavePSResource]@{
            Name       = $this.Name
            Path       = $this.Path
            Repository = $this.Repository
        }
    }

    [bool] Test() {
        return (Test-Path -LiteralPath (Join-Path $this.Path $this.Name))
    }

    [void] Set() {
        Save-PSResource -Name $this.Name -Path $this.Path -Repository $this.Repository -TrustRepository -IncludeXml -AcceptLicense -SkipDependencyCheck
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
    The target path the symbolic link should point to.

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
    checking whether the plugin name appears in 'copilot plugin list' output.
    Supports the owner/repo, plugin@marketplace, and URL source formats accepted
    by the Copilot CLI.

    Depends only on the public GitHub Copilot CLI (copilot) on PATH.

.PROPERTY Source
    The plugin source to install (owner/repo, plugin@marketplace, or a URL).
    This is the key property.

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

    [CopilotPlugin] Get() {
        return [CopilotPlugin]@{
            Source = $this.Source
        }
    }

    [bool] Test() {
        # Match on the plugin name portion: strip a trailing @marketplace and
        # take the last path segment of an owner/repo source.
        $name = ($this.Source -split '@')[0] -split '/' | Select-Object -Last 1
        $result = Invoke-DscCopilot -Arguments @('plugin', 'list')
        return [bool]($result.Output -match [regex]::Escape($name))
    }

    [void] Set() {
        $result = Invoke-DscCopilot -Arguments @('plugin', 'install', $this.Source)
        if ($result.ExitCode -ne 0) {
            throw "Failed to install Copilot plugin: $($this.Source)"
        }
    }
}

<#
.SYNOPSIS
    Registers a GitHub Copilot CLI plugin marketplace.

.DESCRIPTION
    DSC resource that ensures a Copilot CLI plugin marketplace is registered.
    Tests by checking whether the marketplace name appears in
    'copilot plugin marketplace list' output.

    Depends only on the public GitHub Copilot CLI (copilot) on PATH.

.PROPERTY Name
    The name to register the marketplace under. This is the key property.

.PROPERTY Repository
    The GitHub repository hosting the marketplace (owner/repo format).

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

    [CopilotMarketplace] Get() {
        return [CopilotMarketplace]@{
            Name       = $this.Name
            Repository = $this.Repository
        }
    }

    [bool] Test() {
        $result = Invoke-DscCopilot -Arguments @('plugin', 'marketplace', 'list')
        return [bool]($result.Output -match [regex]::Escape($this.Name))
    }

    [void] Set() {
        $result = Invoke-DscCopilot -Arguments @('plugin', 'marketplace', 'add', $this.Name, $this.Repository)
        if ($result.ExitCode -ne 0) {
            throw "Failed to register Copilot marketplace: $($this.Name)"
        }
    }
}

<#
.SYNOPSIS
    Installs a Python tool via uv.

.DESCRIPTION
    DSC resource that ensures a Python tool is installed via 'uv tool install'.
    Tests by checking whether the tool name appears in 'uv tool list' output.

    Depends only on the public uv CLI on PATH.

.PROPERTY Name
    The name of the Python tool to install. This is the key property.

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

    [UvTool] Get() {
        return [UvTool]@{
            Name = $this.Name
        }
    }

    [bool] Test() {
        $result = Invoke-DscUv -Arguments @('tool', 'list')
        return [bool]($result.Output -match [regex]::Escape($this.Name))
    }

    [void] Set() {
        $result = Invoke-DscUv -Arguments @('tool', 'install', $this.Name)
        if ($result.ExitCode -ne 0) {
            throw "Failed to install uv tool: $($this.Name)"
        }
    }
}
