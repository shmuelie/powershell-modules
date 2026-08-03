function Start-VsCode {
    <#
    .SYNOPSIS
        Opens Visual Studio Code with typed PowerShell parameters.
    .DESCRIPTION
        Wraps the `code` CLI with discoverable, tab-completable parameters.
        Supports opening files/folders, profiles, diff, goto, extension management,
        and more. Niche options can be passed via -RemainingArgs.
    .PARAMETER Path
        One or more files or folders to open.
    .PARAMETER Profile
        Open with the specified VS Code profile name. Tab-completes from
        profiles defined in VS Code's globalStorage/storage.json.
    .PARAMETER NewWindow
        Force opening in a new window.
    .PARAMETER ReuseWindow
        Force opening in an existing window.
    .PARAMETER Diff
        Compare two files. Provide exactly two file paths.
    .PARAMETER Goto
        Open a file at a specific line and character (file:line[:character]).
    .PARAMETER Add
        Add folder(s) to the last active window.
    .PARAMETER Wait
        Wait for the files to be closed before returning.
    .PARAMETER Agents
        Open the agents window.
    .PARAMETER DisableExtensions
        Disable all installed extensions for this window.
    .PARAMETER DisableExtension
        Disable specific extensions by ID for this window.
    .PARAMETER Log
        Set the log level.
    .PARAMETER InstallExtension
        Install or update extensions by ID or VSIX path.
    .PARAMETER UninstallExtension
        Uninstall extensions by ID.
    .PARAMETER ListExtensions
        List installed extensions.
    .PARAMETER ShowVersions
        Show versions when listing extensions. Only valid with -ListExtensions.
    .PARAMETER AddMcp
        Add an MCP server definition (JSON string).
    .PARAMETER RemainingArgs
        Additional arguments passed through to the code CLI.
    .EXAMPLE
        Start-VsCode .
        Opens the current directory in VS Code.
    .EXAMPLE
        Start-VsCode -Profile 'Backend'
        Opens VS Code with the Backend profile.
    .EXAMPLE
        Start-VsCode -Diff file1.cs file2.cs
        Compares two files in the VS Code diff editor.
    .EXAMPLE
        Start-VsCode -Goto 'src\main.cs:42'
        Opens main.cs at line 42.
    .EXAMPLE
        Start-VsCode -ListExtensions -ShowVersions
        Lists installed extensions with version numbers.
    .EXAMPLE
        Start-VsCode -Agents
        Opens the VS Code agents window.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Position = 0)]
        [string[]]$Path,

        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete)
            $storageFile = Join-Path $env:APPDATA 'Code\User\globalStorage\storage.json'
            if (Test-Path $storageFile) {
                $profiles = (Get-Content $storageFile -Raw | ConvertFrom-Json).userDataProfiles
                @($profiles | ForEach-Object { $_.name }) |
                    Where-Object { $_ -like "$wordToComplete*" } |
                    ForEach-Object { if ($_ -match '\s') { "'$_'" } else { $_ } }
            }
        })]
        [string]$Profile,

        [switch]$NewWindow,

        [switch]$ReuseWindow,

        [ValidateCount(2, 2)]
        [string[]]$Diff,

        [string]$Goto,

        [string[]]$Add,

        [switch]$Wait,

        [switch]$Agents,

        [switch]$DisableExtensions,

        [string[]]$DisableExtension,

        [ValidateSet('critical', 'error', 'warn', 'info', 'debug', 'trace', 'off')]
        [string]$Log,

        [string[]]$InstallExtension,

        [string[]]$UninstallExtension,

        [switch]$ListExtensions,

        [switch]$ShowVersions,

        [string]$AddMcp,

        [Parameter(ValueFromRemainingArguments)]
        [string[]]$RemainingArgs
    )

    $codeExe = (Get-Command code -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $codeArgs = @()

    if ($Profile) { $codeArgs += '--profile', $Profile }
    if ($NewWindow) { $codeArgs += '--new-window' }
    if ($ReuseWindow) { $codeArgs += '--reuse-window' }
    if ($Diff) { $codeArgs += '--diff', $Diff[0], $Diff[1] }
    if ($Goto) { $codeArgs += '--goto', $Goto }
    if ($Add) { foreach ($a in $Add) { $codeArgs += '--add', $a } }
    if ($Wait) { $codeArgs += '--wait' }
    if ($Agents) { $codeArgs += '--agents' }
    if ($DisableExtensions) { $codeArgs += '--disable-extensions' }
    if ($DisableExtension) { foreach ($e in $DisableExtension) { $codeArgs += '--disable-extension', $e } }
    if ($Log) { $codeArgs += '--log', $Log }
    if ($InstallExtension) { foreach ($e in $InstallExtension) { $codeArgs += '--install-extension', $e } }
    if ($UninstallExtension) { foreach ($e in $UninstallExtension) { $codeArgs += '--uninstall-extension', $e } }
    if ($ListExtensions) { $codeArgs += '--list-extensions' }
    if ($ShowVersions) { $codeArgs += '--show-versions' }
    if ($AddMcp) { $codeArgs += '--add-mcp', $AddMcp }

    if ($Path) { $codeArgs += $Path }

    if ($RemainingArgs) { $codeArgs += $RemainingArgs }

    if ($PSCmdlet.ShouldProcess("$codeExe $($codeArgs -join ' ')", 'Execute')) {
        & $codeExe @codeArgs
    }
}

function Start-VsCodeChat {
    <#
    .SYNOPSIS
        Starts a VS Code chat session with typed PowerShell parameters.
    .DESCRIPTION
        Wraps `code chat [options] [prompt]` with discoverable parameters.
    .PARAMETER Prompt
        The prompt to run in the chat session.
    .PARAMETER Mode
        The chat mode: ask, edit, agent, or a custom mode identifier.
        Defaults to agent.
    .PARAMETER AddFile
        Add files as context to the chat session.
    .PARAMETER Maximize
        Maximize the chat session view.
    .PARAMETER ReuseWindow
        Force using the last active window.
    .PARAMETER NewWindow
        Force opening an empty window.
    .PARAMETER Profile
        Open with the specified VS Code profile name.
    .PARAMETER RemainingArgs
        Any additional arguments are passed through to the `code chat` command.
    .EXAMPLE
        Start-VsCodeChat 'Fix the bug in main.cs'
        Starts an agent chat session with the given prompt.
    .EXAMPLE
        Start-VsCodeChat -Mode edit 'Refactor the auth module'
        Starts an edit-mode chat session.
    .EXAMPLE
        Start-VsCodeChat 'Add tests' -AddFile src\auth.cs, src\auth.test.cs
        Starts a chat session with context files attached.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Position = 0)]
        [string]$Prompt,

        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete)
            @('ask', 'edit', 'agent') |
                Where-Object { $_ -like "$wordToComplete*" }
        })]
        [string]$Mode,

        [string[]]$AddFile,

        [switch]$Maximize,

        [switch]$ReuseWindow,

        [switch]$NewWindow,

        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete)
            $storageFile = Join-Path $env:APPDATA 'Code\User\globalStorage\storage.json'
            if (Test-Path $storageFile) {
                $profiles = (Get-Content $storageFile -Raw | ConvertFrom-Json).userDataProfiles
                @($profiles | ForEach-Object { $_.name }) |
                    Where-Object { $_ -like "$wordToComplete*" } |
                    ForEach-Object { if ($_ -match '\s') { "'$_'" } else { $_ } }
            }
        })]
        [string]$Profile,

        [Parameter(ValueFromRemainingArguments)]
        [string[]]$RemainingArgs
    )

    $codeExe = (Get-Command code -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $chatArgs = @('chat')

    if ($Mode) { $chatArgs += '--mode', $Mode }
    if ($AddFile) { foreach ($f in $AddFile) { $chatArgs += '--add-file', $f } }
    if ($Maximize) { $chatArgs += '--maximize' }
    if ($ReuseWindow) { $chatArgs += '--reuse-window' }
    if ($NewWindow) { $chatArgs += '--new-window' }
    if ($Profile) { $chatArgs += '--profile', $Profile }

    if ($Prompt) { $chatArgs += $Prompt }

    if ($RemainingArgs) { $chatArgs += $RemainingArgs }

    if ($PSCmdlet.ShouldProcess("$codeExe $($chatArgs -join ' ')", 'Execute')) {
        & $codeExe @chatArgs
    }
}

function Get-VsCodeExtension {
    <#
    .SYNOPSIS
        List installed VS Code extensions.
    .DESCRIPTION
        Parses the output of 'code --list-extensions --show-versions' into typed
        VsCodeExtension objects with Publisher, Name, FullId, and Version properties.
    .PARAMETER Name
        Filter by extension ID. Supports wildcards.
    .PARAMETER Category
        Filter by extension category (e.g., 'themes', 'linters').
    .PARAMETER Profile
        List extensions for a specific VS Code profile.
    .EXAMPLE
        Get-VsCodeExtension
        Lists all installed extensions.
    .EXAMPLE
        Get-VsCodeExtension -Name ms-python*
        Lists extensions matching the filter.
    .EXAMPLE
        Get-VsCodeExtension -Profile 'Backend'
        Lists extensions in a specific profile.
    #>
    [OutputType('VsCodeExtension')]
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Name = '*',

        [string]$Category,

        [string]$Profile
    )
    $codeExe = (Get-Command code -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $listArgs = @('--list-extensions', '--show-versions')
    if ($Category) { $listArgs += '--category', $Category }
    if ($Profile) { $listArgs += '--profile', $Profile }

    & $codeExe @listArgs 2>$null | ForEach-Object {
        if ($_ -match '^(.+?)\.(.+?)@(.+)$') {
            $ext = [PSCustomObject]@{
                PSTypeName = 'VsCodeExtension'
                Publisher  = $Matches[1]
                Name       = $Matches[2]
                FullId     = "$($Matches[1]).$($Matches[2])"
                Version    = $Matches[3]
            }
            if ($ext.FullId -like $Name -or $ext.Name -like $Name) { $ext }
        }
    }
}

function Install-VsCodeExtension {
    <#
    .SYNOPSIS
        Install a VS Code extension.
    .DESCRIPTION
        Wraps 'code --install-extension'. Idempotent — installs or updates.
        Accepts pipeline input from Get-VsCodeExtension or string IDs.
    .PARAMETER Id
        The extension ID (publisher.name) or path to a .vsix file.
    .PARAMETER InputObject
        A VsCodeExtension object from Get-VsCodeExtension.
    .PARAMETER PreRelease
        Install the pre-release version.
    .PARAMETER Profile
        Install into a specific VS Code profile.
    .EXAMPLE
        Install-VsCodeExtension -Id ms-python.python
        Installs the Python extension.
    .EXAMPLE
        Install-VsCodeExtension -Id ms-python.python -PreRelease
        Installs the pre-release version.
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'ById')]
    param(
        [Parameter(ParameterSetName = 'ById', Position = 0, Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Id,

        [Parameter(ParameterSetName = 'ByObject', Mandatory, ValueFromPipeline)]
        [PSObject]$InputObject,

        [switch]$PreRelease,

        [string]$Profile
    )
    process {
        $extId = if ($PSCmdlet.ParameterSetName -eq 'ById') { $Id } else { $InputObject.FullId }
        $codeExe = (Get-Command code -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        if ($PSCmdlet.ShouldProcess($extId, 'code --install-extension')) {
            $installArgs = @('--install-extension', $extId)
            if ($PreRelease) { $installArgs += '--pre-release' }
            if ($Profile) { $installArgs += '--profile', $Profile }
            & $codeExe @installArgs 2>&1 | ForEach-Object { Write-Verbose $_ }
        }
    }
}

function Uninstall-VsCodeExtension {
    <#
    .SYNOPSIS
        Uninstall a VS Code extension.
    .DESCRIPTION
        Wraps 'code --uninstall-extension'. Accepts pipeline from Get-VsCodeExtension.
    .PARAMETER Id
        The extension ID (publisher.name).
    .PARAMETER InputObject
        A VsCodeExtension object from Get-VsCodeExtension.
    .EXAMPLE
        Uninstall-VsCodeExtension -Id ms-python.python
    .EXAMPLE
        Get-VsCodeExtension old-ext* | Uninstall-VsCodeExtension
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'ByObject')]
    param(
        [Parameter(ParameterSetName = 'ById', Position = 0, Mandatory)]
        [string]$Id,

        [Parameter(ParameterSetName = 'ByObject', Mandatory, ValueFromPipeline)]
        [PSObject]$InputObject
    )
    process {
        $extId = if ($PSCmdlet.ParameterSetName -eq 'ById') { $Id } else { $InputObject.FullId }
        $codeExe = (Get-Command code -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        if ($PSCmdlet.ShouldProcess($extId, 'code --uninstall-extension')) {
            & $codeExe '--uninstall-extension' $extId 2>&1 | ForEach-Object { Write-Verbose $_ }
        }
    }
}

function Update-VsCodeExtension {
    <#
    .SYNOPSIS
        Update all installed VS Code extensions to the latest version.
    .DESCRIPTION
        Wraps 'code --update-extensions'. VS Code's CLI only supports bulk update,
        not per-extension update.
    .EXAMPLE
        Update-VsCodeExtension
        Updates all installed extensions.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $codeExe = (Get-Command code -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    if ($PSCmdlet.ShouldProcess('all extensions', 'code --update-extensions')) {
        & $codeExe '--update-extensions' 2>&1 | ForEach-Object { Write-Verbose $_ }
    }
}
