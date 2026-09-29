<#
.SYNOPSIS
    Build one independently versioned module into a publishable staging directory.
.PARAMETER Module
    Published module directory name under modules/, or the explicit unpublished
    Shmuelie.AppInstall.Experimental module under experimental/. The latter is
    not part of ordinary Windows builds or the supported validation catalog.
.PARAMETER OutputPath
    Literal filesystem artifact root. Defaults to artifacts/.
    Only the selected module's version directory is replaced.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Shmuelie.Git', 'Shmuelie.Copilot', 'Shmuelie.Node', 'Shmuelie.DotNet', 'Shmuelie.Utilities', 'Shmuelie.Dsc', 'Shmuelie.VisualStudio', 'Shmuelie.Windows', 'Shmuelie.PackageManagement', 'Shmuelie.AppInstall.Experimental')]
    [string]$Module,

    [string]$OutputPath
)

function Invoke-RetryingDelete {
    # Safety net for transient lock errors (e.g. antivirus briefly holding a
    # file).  Only catches IO/access-denied errors; other errors still propagate.
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$MaxAttempts = 3,
        [int]$DelayMs = 300
    )
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            return
        }
        catch [System.IO.IOException], [System.UnauthorizedAccessException] {
            if ($attempt -ge $MaxAttempts) { throw }
            Start-Sleep -Milliseconds $DelayMs
        }
    }
}

function Test-BuildModuleManifest {
    param([Parameter(Mandatory)][string]$LiteralPath)

    if ([System.Management.Automation.WildcardPattern]::Escape($LiteralPath) -ceq $LiteralPath) {
        return Test-ModuleManifest -Path $LiteralPath -ErrorAction Stop
    }

    # Test-ModuleManifest also wildcard-resolves files referenced by the manifest.
    # Escaping just -Path is insufficient; validate an isolated copy, never a link.
    $directory = [System.IO.Path]::GetDirectoryName($LiteralPath)
    $items = @((Get-Item -LiteralPath $directory -Force)) +
        @(Get-ChildItem -LiteralPath $directory -Recurse -Force)
    foreach ($item in $items) {
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw "Cannot create a manifest validation view from a linked item: '$($item.FullName)'."
        }
    }

    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if ([System.Management.Automation.WildcardPattern]::Escape($tempRoot) -cne $tempRoot) {
        throw "Manifest validation requires a temporary directory without wildcard or escape characters: '$tempRoot'."
    }
    $viewRoot = Join-Path $tempRoot "psmod-validate-$([guid]::NewGuid().ToString('N'))"
    $created = $false
    try {
        New-Item -Path $viewRoot -ItemType Directory -ErrorAction Stop | Out-Null
        $created = $true
        # Preserve the module/version directory names for framework validation.
        $parentName = [System.IO.Path]::GetFileName([System.IO.Path]::GetDirectoryName($directory))
        $viewParent = Join-Path $viewRoot $parentName
        New-Item -Path $viewParent -ItemType Directory -ErrorAction Stop | Out-Null
        $viewDirectory = Join-Path $viewParent ([System.IO.Path]::GetFileName($directory))
        Copy-Item -LiteralPath $directory -Destination $viewDirectory -Recurse -Force -ErrorAction Stop
        $viewManifest = Join-Path $viewDirectory ([System.IO.Path]::GetFileName($LiteralPath))
        Test-ModuleManifest -Path $viewManifest -ErrorAction Stop
    } finally {
        if ($created) {
            Remove-Item -LiteralPath $viewRoot -Recurse -Force -ErrorAction Stop
        }
    }
}

function Get-OwnedBuildDirectory {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$RelativePath
    )

    $path = [System.IO.Path]::GetFullPath((Join-Path $Root $RelativePath))
    $relative = [System.IO.Path]::GetRelativePath($Root, $path)
    if ($relative -cne $RelativePath -or [System.IO.Path]::IsPathRooted($relative) -or
        $relative -in '.', '..' -or $relative.StartsWith("..$([System.IO.Path]::DirectorySeparatorChar)")) {
        throw "Build directory must be exactly '$RelativePath' beneath '$Root'."
    }
    $current = $path
    while ($true) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (-not $item.PSIsContainer -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                throw "Build directory must be an ordinary filesystem directory: '$current'."
            }
        }
        if ($current -eq $Root) { break }
        $current = [System.IO.Path]::GetDirectoryName($current)
    }
    return $path
}

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetDirectoryName($PSScriptRoot)
$sourceRoot = if ($Module -eq 'Shmuelie.AppInstall.Experimental') { 'experimental' } else { 'modules' }
$source = Join-Path $repoRoot $sourceRoot $Module
$manifestPath = Join-Path $source "$Module.psd1"
$manifest = Test-BuildModuleManifest -LiteralPath $manifestPath

if (-not $OutputPath) {
    $OutputPath = Join-Path $repoRoot 'artifacts'
}

$provider = $null
$drive = $null
$OutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath, [ref]$provider, [ref]$drive)
if ($provider.Name -ne 'FileSystem') {
    throw 'OutputPath must refer to the filesystem.'
}
$OutputPath = [System.IO.Path]::TrimEndingDirectorySeparator([System.IO.Path]::GetFullPath($OutputPath))
$stage = Get-OwnedBuildDirectory -Root $OutputPath -RelativePath (Join-Path $Module $manifest.Version.ToString())
if (Test-Path -LiteralPath $stage) {
    Invoke-RetryingDelete $stage
}
New-Item -Path $stage -ItemType Directory -Force | Out-Null

foreach ($name in @("$Module.psd1", "$Module.psm1", 'README.md', 'CHANGELOG.md')) {
    Copy-Item -LiteralPath (Join-Path $source $name) -Destination (Join-Path $stage $name)
}
$scripts = @(Get-ChildItem -LiteralPath $source -Filter '*.ps1' -File)
foreach ($script in $scripts) {
    Copy-Item -LiteralPath $script.FullName -Destination (Join-Path $stage $script.Name)
}
if ($manifest.ExportedFunctions.Count -gt 0 -and $scripts.Count -eq 0) {
    throw "$Module declares FunctionsToExport but has no root-level script files to stage."
}
$classes = Join-Path $source 'Classes'
if (Test-Path -LiteralPath $classes) {
    Copy-Item -LiteralPath $classes -Destination (Join-Path $stage 'Classes') -Recurse
}
foreach ($format in Get-ChildItem -LiteralPath $source -Filter '*.format.ps1xml') {
    Copy-Item -LiteralPath $format.FullName -Destination (Join-Path $stage $format.Name)
}

if ($Module -eq 'Shmuelie.Git') {
    $bin = Join-Path $stage 'bin'
    $predictorBuild = Get-OwnedBuildDirectory -Root $OutputPath -RelativePath '.predictor-build'
    if (Test-Path -LiteralPath $predictorBuild) {
        Remove-Item -LiteralPath $predictorBuild -Recurse -Force
    }
    New-Item -Path $bin -ItemType Directory -Force | Out-Null
    dotnet build (Join-Path $source 'Predictor' 'WorktreePredictor.csproj') `
        --configuration Release `
        --output $predictorBuild `
        --nologo
    if ($LASTEXITCODE -ne 0) {
        throw 'WorktreePredictor build failed.'
    }
    Copy-Item -LiteralPath (Join-Path $predictorBuild 'WorktreePredictor.dll') -Destination (Join-Path $bin 'WorktreePredictor.dll')
    Remove-Item -LiteralPath $predictorBuild -Recurse -Force
}

if ($Module -eq 'Shmuelie.Windows') {
    $bin = Join-Path $stage 'bin'
    $cmdletsBuild = Get-OwnedBuildDirectory -Root $OutputPath -RelativePath '.windows-cmdlets-build'
    if (Test-Path -LiteralPath $cmdletsBuild) {
        Remove-Item -LiteralPath $cmdletsBuild -Recurse -Force
    }
    New-Item -Path $bin -ItemType Directory -Force | Out-Null
    dotnet build (Join-Path $source 'Cmdlets' 'Shmuelie.Windows.Cmdlets.csproj') `
        --configuration Release `
        --output $cmdletsBuild `
        "-bl:$(Join-Path $OutputPath "windows-cmdlets-$([guid]::NewGuid()).binlog")" `
        --nologo
    if ($LASTEXITCODE -ne 0) {
        throw 'Shmuelie.Windows.Cmdlets build failed.'
    }
    Copy-Item -LiteralPath (Join-Path $cmdletsBuild 'Shmuelie.Windows.Cmdlets.dll') -Destination (Join-Path $bin 'Shmuelie.Windows.Cmdlets.dll')
    Remove-Item -LiteralPath $cmdletsBuild -Recurse -Force

    $appInstallerBuild = Get-OwnedBuildDirectory -Root $OutputPath -RelativePath '.windows-appinstaller-build'
    if (Test-Path -LiteralPath $appInstallerBuild) {
        Remove-Item -LiteralPath $appInstallerBuild -Recurse -Force
    }
    # Publish (not build) so the WinRT projection runtime assemblies
    # (Microsoft.Windows.SDK.NET.dll / WinRT.Runtime.dll) are emitted alongside
    # the cmdlet assembly; a plain build leaves them out and the WinRT calls fail
    # to load at runtime.
    dotnet publish (Join-Path $source 'Cmdlets.AppInstaller' 'Shmuelie.Windows.AppInstaller.csproj') `
        --configuration Release `
        --output $appInstallerBuild `
        "-bl:$(Join-Path $OutputPath "windows-appinstaller-$([guid]::NewGuid()).binlog")" `
        --nologo
    if ($LASTEXITCODE -ne 0) {
        throw 'Shmuelie.Windows.AppInstaller publish failed.'
    }
    foreach ($dll in 'Shmuelie.Windows.AppInstaller.dll', 'Microsoft.Windows.SDK.NET.dll', 'WinRT.Runtime.dll') {
        Copy-Item -LiteralPath (Join-Path $appInstallerBuild $dll) -Destination (Join-Path $bin $dll)
    }
    Copy-Item -LiteralPath (Join-Path $appInstallerBuild 'en-US') -Destination (Join-Path $bin 'en-US') -Recurse
    Remove-Item -LiteralPath $appInstallerBuild -Recurse -Force
}

if ($Module -eq 'Shmuelie.AppInstall.Experimental') {
    $bin = Join-Path $stage 'bin'
    New-Item -Path $bin -ItemType Directory -Force | Out-Null
    $appInstallBuild = Get-OwnedBuildDirectory -Root $OutputPath -RelativePath '.experimental-appinstall-build'
    if (Test-Path -LiteralPath $appInstallBuild) {
        Remove-Item -LiteralPath $appInstallBuild -Recurse -Force
    }
    dotnet publish (Join-Path $source 'Cmdlets.AppInstall' 'Shmuelie.Windows.AppInstall.csproj') `
        --configuration Release `
        --output $appInstallBuild `
        "-bl:$(Join-Path $OutputPath "windows-appinstall-$([guid]::NewGuid()).binlog")" `
        --nologo
    if ($LASTEXITCODE -ne 0) {
        throw 'Shmuelie.Windows.AppInstall publish failed.'
    }
    foreach ($dependency in 'Shmuelie.Windows.AppInstall.dll', 'Microsoft.Windows.SDK.NET.dll', 'WinRT.Runtime.dll') {
        Copy-Item -LiteralPath (Join-Path $appInstallBuild $dependency) -Destination (Join-Path $bin $dependency)
    }
    Copy-Item -LiteralPath (Join-Path $appInstallBuild 'en-US') -Destination (Join-Path $bin 'en-US') -Recurse
    Remove-Item -LiteralPath $appInstallBuild -Recurse -Force
}

if ($Module -eq 'Shmuelie.Windows') {
    & (Join-Path $PSScriptRoot 'Assert-ModulePublishable.ps1') -Module $Module -Path $stage
}

# Validate the staged module in a short-lived child pwsh process so that every
# DLL file handle is released when the child exits.  The stage directory is
# never locked in the parent process, allowing a same-process rebuild to delete
# it freely. Manifest validation views are removed before importing the actual stage.
# The manifest path is forwarded through an environment variable rather than
# interpolated into the command string, eliminating any path-injection risk.
$stagedManifest = Join-Path $stage "$Module.psd1"
$envKey = 'PSMOD_VALIDATE_MANIFEST'
$savedEnv = [System.Environment]::GetEnvironmentVariable($envKey)
try {
    [System.Environment]::SetEnvironmentVariable($envKey, $stagedManifest)
    $childCommand = [scriptblock]::Create("function Test-BuildModuleManifest {`n${function:Test-BuildModuleManifest}`n}`n" + {
        $ErrorActionPreference = 'Stop'
        Test-BuildModuleManifest -LiteralPath $env:PSMOD_VALIDATE_MANIFEST | Out-Null
        $imported = Import-Module -Name $env:PSMOD_VALIDATE_MANIFEST -Force -PassThru -ErrorAction Stop
        Remove-Module -ModuleInfo $imported -Force -ErrorAction Stop
    }.ToString())
    $childOut = & pwsh -NoProfile -NonInteractive -Command $childCommand 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Staged module validation failed (exit $LASTEXITCODE):`n$($childOut -join [System.Environment]::NewLine)"
    }
} finally {
    [System.Environment]::SetEnvironmentVariable($envKey, $savedEnv)
}

Get-Item -LiteralPath $stage