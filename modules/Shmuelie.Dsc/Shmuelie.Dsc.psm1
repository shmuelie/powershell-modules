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

function Assert-DscCliResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Result,
        [Parameter(Mandatory)][string]$Operation,
        [switch]$AllowNonZeroExit
    )

    $exitCode = $null
    $output = $null
    if ($Result -is [System.Collections.IDictionary]) {
        $exitCode = $Result['ExitCode']
        $output = $Result['Output']
    } elseif ($null -ne $Result) {
        $exitProperty = $Result.PSObject.Properties['ExitCode']
        $outputProperty = $Result.PSObject.Properties['Output']
        if ($exitProperty) { $exitCode = $exitProperty.Value }
        if ($outputProperty) { $output = $outputProperty.Value }
    }
    if ($exitCode -is [int] -and ($AllowNonZeroExit -or $exitCode -eq 0)) {
        return
    }
    $knownExit = $exitCode -is [int]
    $message = if ($knownExit) {
        "$Operation failed (exit $exitCode)."
    } else {
        "$Operation did not report a valid native exit code."
    }
    if ($output) { $message += [Environment]::NewLine + ($output -join [Environment]::NewLine) }
    $exception = [System.InvalidOperationException]::new($message)
    $exception.Data['ExitCode'] = $exitCode
    $exception.Data['Output'] = $output
    $errorId = if ($knownExit) { 'DscCliCommandFailed' } else { 'DscCliCompletionUnknown' }
    $PSCmdlet.ThrowTerminatingError([System.Management.Automation.ErrorRecord]::new(
        $exception, $errorId, [System.Management.Automation.ErrorCategory]::InvalidResult, $Result))
}

function Invoke-DscCliCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('copilot', 'uv')][string]$Command,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $previousExitCode = Get-Variable LASTEXITCODE -Scope Global -ErrorAction Ignore
    $previousValue = if ($previousExitCode) { $previousExitCode.Value } else { $null }
    # Native invocation writes the global variable even when a local one exists.
    # Capture diagnostics ourselves, independent of the caller's native error policy.
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        $global:LASTEXITCODE = $null
        $raw = @(& $Command @Arguments 2>&1)
        $exitCode = $global:LASTEXITCODE
    } finally {
        if ($previousExitCode) { $global:LASTEXITCODE = $previousValue }
        else { Remove-Variable LASTEXITCODE -Scope Global -ErrorAction Ignore -WhatIf:$false -Confirm:$false }
    }
    $result = [pscustomobject]@{
        Output = @($raw | ForEach-Object { Remove-DscAnsiEscape ([string]$_) })
        ExitCode = $exitCode
    }
    Assert-DscCliResult -Result $result -Operation $Command -AllowNonZeroExit
    return $result
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
        Invoke-DscCliCommand -Command copilot -Arguments $Arguments
    } finally {
        if ($null -eq $previousNoColor) {
            Remove-Item Env:NO_COLOR -ErrorAction SilentlyContinue -WhatIf:$false -Confirm:$false
        } else {
            $env:NO_COLOR = $previousNoColor
        }
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
        Invoke-DscCliCommand -Command uv -Arguments $Arguments
    } finally {
        if ($null -eq $previousNoColor) {
            Remove-Item Env:NO_COLOR -ErrorAction SilentlyContinue -WhatIf:$false -Confirm:$false
        } else {
            $env:NO_COLOR = $previousNoColor
        }
        if ($null -eq $previousUvNoColor) {
            Remove-Item Env:UV_NO_COLOR -ErrorAction SilentlyContinue -WhatIf:$false -Confirm:$false
        } else {
            $env:UV_NO_COLOR = $previousUvNoColor
        }
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

function Test-DscSavedModuleFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$Entry,
        [ValidateSet('File', 'RootModule', 'NestedModule')]
        [string]$Kind = 'File'
    )

    if ([System.IO.Path]::IsPathRooted($Entry)) {
        Write-Verbose "Saved module entry must be relative to its module directory: '$Entry'."
        return $false
    }
    $suffixes = @('')
    if ($Kind -ne 'File') {
        $moduleExtensions = @('.psm1', '.dll', '.exe', '.cdxml', '.xaml')
        if ($Kind -eq 'NestedModule') { $moduleExtensions += '.psd1' }
        $extension = [System.IO.Path]::GetExtension($Entry)
        if (-not $extension) {
            $suffixes = $moduleExtensions
        } elseif ($extension -notin $moduleExtensions) {
            Write-Verbose "Unsupported saved module entry file: '$Entry'."
            return $false
        }
    }
    foreach ($suffix in $suffixes) {
        try {
            $file = [System.IO.Path]::GetFullPath((Join-Path $Directory "$Entry$suffix"))
        } catch [System.ArgumentException], [System.NotSupportedException] {
            Write-Verbose "Invalid saved module entry '$Entry': $_"
            return $false
        }
        $relative = [System.IO.Path]::GetRelativePath($Directory, $file)
        if ($relative -eq '..' -or $relative.StartsWith("..$([System.IO.Path]::DirectorySeparatorChar)") -or
            [System.IO.Path]::IsPathRooted($relative)) {
            Write-Verbose "Saved module entry is outside its module directory: '$Entry'."
            return $false
        }
        if (Test-Path -LiteralPath $file -PathType Leaf -ErrorAction Stop) {
            return $true
        }
    }
    Write-Verbose "Saved module entry is missing: '$Entry' in '$Directory'."
    return $false
}

function Test-DscSavedModule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$Name,
        [string]$Version
    )

    if (-not (Test-Path -LiteralPath $Directory -PathType Container -ErrorAction Stop)) {
        return $false
    }
    $manifestPath = Join-Path $Directory "$Name.psd1"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf -ErrorAction Stop)) {
        return $false
    }
    try {
        $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath -ErrorAction Stop
    } catch [System.InvalidOperationException] {
        Write-Verbose "Saved module manifest is not readable static data: '$manifestPath': $_"
        return $false
    }
    $manifestVersion = $null
    if ($manifest.ModuleVersion -isnot [string] -or
        -not [version]::TryParse($manifest.ModuleVersion, [ref]$manifestVersion)) {
        Write-Verbose "Saved module manifest has no valid ModuleVersion: '$manifestPath'."
        return $false
    }
    if ($Version) {
        $directoryVersion = $null
        if (-not [version]::TryParse($Version, [ref]$directoryVersion) -or
            $manifestVersion.Major -ne $directoryVersion.Major -or $manifestVersion.Minor -ne $directoryVersion.Minor -or
            [Math]::Max(0, $manifestVersion.Build) -ne [Math]::Max(0, $directoryVersion.Build) -or
            [Math]::Max(0, $manifestVersion.Revision) -ne [Math]::Max(0, $directoryVersion.Revision)) {
            Write-Verbose "Saved module manifest does not match version directory '$Version': '$manifestPath'."
            return $false
        }
    }

    $directoryPath = (Get-Item -LiteralPath $Directory -Force -ErrorAction Stop).FullName
    if ($manifest.ContainsKey('RootModule')) {
        $rootModule = $manifest.RootModule
    } else {
        $rootModule = $manifest.ModuleToProcess
    }
    if ($null -ne $rootModule) {
        if ($rootModule -isnot [string]) {
            Write-Verbose "Saved module manifest has an invalid root module value: '$manifestPath'."
            return $false
        }
        if ($rootModule.Length -gt 0 -and -not (Test-DscSavedModuleFile -Directory $directoryPath -Entry $rootModule -Kind RootModule)) {
            return $false
        }
    }
    # These are local startup files, not dependencies resolved through PSModulePath.
    foreach ($field in 'ScriptsToProcess', 'TypesToProcess', 'FormatsToProcess') {
        foreach ($entry in $manifest[$field]) {
            if ($entry -isnot [string] -or [string]::IsNullOrWhiteSpace($entry)) {
                Write-Verbose "Saved module manifest has an invalid $field entry: '$manifestPath'."
                return $false
            }
            if (-not (Test-DscSavedModuleFile -Directory $directoryPath -Entry $entry)) {
                return $false
            }
        }
    }
    foreach ($field in 'NestedModules', 'RequiredAssemblies') {
        foreach ($reference in $manifest[$field]) {
            $entry = $reference
            if ($field -eq 'NestedModules' -and $reference -is [hashtable]) {
                $entry = $reference.ModuleName
            }
            if ($entry -isnot [string] -or [string]::IsNullOrWhiteSpace($entry)) {
                Write-Verbose "Saved module manifest has an invalid $field entry: '$manifestPath'."
                return $false
            }
            # Bare dependency names remain unresolved, as with -SkipDependencyCheck.
            $localFile = $entry.IndexOfAny([char[]]'\/') -ge 0 -or
                [System.IO.Path]::GetExtension($entry) -in @('.psm1', '.psd1', '.dll', '.exe', '.cdxml', '.xaml')
            if ($localFile) {
                $kind = if ($field -eq 'NestedModules') { 'NestedModule' } else { 'File' }
                if (-not (Test-DscSavedModuleFile -Directory $directoryPath -Entry $entry -Kind $kind)) {
                    return $false
                }
            }
        }
    }
    return $true
}

# Resources -------------------------------------------------------------------

<#
.SYNOPSIS
    Saves a PowerShell module to a local path using Save-PSResource.

.DESCRIPTION
    DSC resource that ensures a PowerShell module is saved (not installed) to a
    specified directory. Tests for a readable, correctly named manifest with a
    valid ModuleVersion and any declared root module and local startup files.
    Accepts a flat module directory or at least one matching version directory.
    Presence checks read data only; they do not import candidate module code or
    resolve dependencies, and do not prove runtime compatibility.
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
    Optional specific version to save. When set, Test() checks only that exact
    subfolder and requires its manifest version to match. Set() passes the value
    unchanged to Save-PSResource -Version; Test() does not resolve version ranges.

.PROPERTY Installed
    Read-only. Reports whether the saved module layout passes the read-only
    presence check (and matches the version directory, if specified).

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
        if (-not (Test-Path -LiteralPath $modulePath -PathType Container -ErrorAction Stop)) {
            return $false
        }
        if ($this.Version) {
            return (Test-DscSavedModule -Directory (Join-Path $modulePath $this.Version) -Name $this.Name -Version $this.Version)
        }
        if (Test-DscSavedModule -Directory $modulePath -Name $this.Name) {
            return $true
        }
        foreach ($directory in Get-ChildItem -LiteralPath $modulePath -Directory -ErrorAction Stop) {
            if (Test-DscSavedModule -Directory $directory.FullName -Name $this.Name -Version $directory.Name) {
                return $true
            }
        }
        return $false
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
    Failed discovery or unknown native completion raises an error instead of
    reporting the plugin as installed or absent.

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
        Assert-DscCliResult -Result $result -Operation 'Copilot plugin discovery'
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
    Failed discovery or unknown native completion raises an error instead of
    reporting the marketplace as registered or absent.

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
        Assert-DscCliResult -Result $result -Operation 'Copilot marketplace discovery'
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
    Failed discovery or unknown native completion raises an error instead of
    reporting the tool as installed or absent.

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
        Assert-DscCliResult -Result $result -Operation 'uv tool discovery'
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
