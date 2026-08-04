[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$modules = @('Shmuelie.Git', 'Shmuelie.Copilot', 'Shmuelie.Node', 'Shmuelie.Utilities')

foreach ($module in $modules) {
    Write-Information "Building $module" -InformationAction Continue
    & (Join-Path $PSScriptRoot 'Build-Module.ps1') -Module $module | Out-Null
}

# ---------------------------------------------------------------------------
# Public-content scan.
# Public modules must not reference internal-only tooling, private endpoints,
# organization-specific systems, or credentials. Agency is a Microsoft-internal
# orchestrator and is treated as internal-only.
# The build/ scripts and build artifacts are excluded (this script defines the
# forbidden markers as literals).
# ---------------------------------------------------------------------------
$forbidden = 'dev\.azure\.com/microsoft|msazure\.pkgs\.visualstudio\.com|OS\.Developer|WindowsHiveMind|SFC\.|SFS\.|SFU\.|os\.2020|OSClient|IXPTools|StoreFundementals|user/senglard|SEnglard|\\\\redmond\\|D:\\wsd\\|agency|winpx|bluebird|workiq'

$scanFiles = Get-ChildItem $repoRoot -Recurse -File |
    Where-Object {
        $rel = $_.FullName.Substring($repoRoot.Length).TrimStart('\', '/')
        $rel -notmatch '^(?:\.git|build|artifacts)[\\/]' -and
        $_.FullName -notmatch '[\\/](?:bin|obj)[\\/]' -and
        $_.Extension -in '.ps1', '.psm1', '.psd1', '.ps1xml', '.md', '.json', '.yml', '.yaml', '.cs', '.csproj'
    }

$matches = $scanFiles | Select-String -Pattern $forbidden
if ($matches) {
    $matches | Format-Table Path, LineNumber, Line -AutoSize
    throw 'Internal-only markers were found in public sources.'
}

# ---------------------------------------------------------------------------
# Documentation checks: Markdown-only site with the expected pages and no
# broken local links.
# ---------------------------------------------------------------------------
foreach ($docFile in @('index.md', 'modules.md', 'installation.md', 'contributing.md', '_config.yml')) {
    if (-not (Test-Path (Join-Path $repoRoot "docs\$docFile"))) {
        throw "Missing documentation site file: docs/$docFile"
    }
}

if (Get-ChildItem (Join-Path $repoRoot 'docs') -Filter '*.html' -File -ErrorAction SilentlyContinue) {
    throw 'Documentation must be authored in Markdown; remove HTML files from docs/.'
}

$markdownFiles = @()
$markdownFiles += Get-Item (Join-Path $repoRoot 'README.md')
$markdownFiles += Get-ChildItem (Join-Path $repoRoot 'modules') -Recurse -Filter '*.md' -File
$markdownFiles += Get-ChildItem (Join-Path $repoRoot 'docs') -Filter '*.md' -File
foreach ($markdown in $markdownFiles) {
    $content = Get-Content $markdown.FullName -Raw
    foreach ($match in [regex]::Matches($content, '\[[^\]]*\]\(([^)]+)\)')) {
        $target = $match.Groups[1].Value.Trim()
        if ($target -match '^(?:https?:|mailto:|#)') { continue }
        $localPath = ($target -split '#', 2)[0]
        if ($localPath -and -not (Test-Path (Join-Path $markdown.DirectoryName $localPath))) {
            throw "Broken local link in $($markdown.FullName): $target"
        }
    }
}

# ---------------------------------------------------------------------------
# Version consistency and per-module changelog: each module README header must
# match its manifest, each module must ship its own CHANGELOG.md, and every
# changelog (module + repository) must carry an [Unreleased] section so content
# changes land there instead of forcing a version bump between releases.
# ---------------------------------------------------------------------------
foreach ($module in $modules) {
    $moduleDir = Join-Path $repoRoot "modules\$module"
    $moduleChangelog = Join-Path $moduleDir 'CHANGELOG.md'
    if (-not (Test-Path $moduleChangelog)) {
        throw "Each module must have its own CHANGELOG.md: missing modules/$module/CHANGELOG.md"
    }
    if ((Get-Content $moduleChangelog -Raw) -notmatch '(?m)^##\s*\[Unreleased\]') {
        throw "Changelog is missing an [Unreleased] section: modules/$module/CHANGELOG.md"
    }
    $manifest = Test-ModuleManifest (Join-Path $moduleDir "$module.psd1")
    if ($manifest.ExportedAliases.Count -gt 0) {
        throw "Public modules must not export command aliases: $module exports $($manifest.ExportedAliases.Keys -join ', ')."
    }
    $readme = Get-Content (Join-Path $moduleDir 'README.md') -Raw
    if ($readme -notmatch '\*\*Version:\*\*\s+([0-9]+\.[0-9]+\.[0-9]+)') {
        throw "Missing README version for $module."
    }
    if ($Matches[1] -ne "$($manifest.Version)") {
        throw "README version mismatch for ${module}: README $($Matches[1]), manifest $($manifest.Version)."
    }
}

if ((Get-Content (Join-Path $repoRoot 'CHANGELOG.md') -Raw) -notmatch '(?m)^##\s*\[Unreleased\]') {
    throw 'Repository CHANGELOG.md is missing an [Unreleased] section.'
}
