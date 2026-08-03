# Agency marketplace cmdlets. The native `agency marketplace` command only
# provides `add` (it installs marketplace(s) into the copilot/claude engines);
# there is no native `agency marketplace list / remove / browse`, so only
# Register-AgencyMarketplace exists here. To list/remove/browse marketplaces,
# use the Copilot-engine cmdlets (Get-CopilotMarketplace, etc.).

function Register-AgencyMarketplace {
    <#
    .SYNOPSIS
        Install Agency marketplace(s) (native 'agency marketplace add').
    .DESCRIPTION
        Adds one or more marketplaces to the copilot and/or claude engines. Accepts
        built-in presets (curated/company, playground, all) or custom sources
        (GitHub owner/repo, GitHub URL, or ADO URL).
    .PARAMETER Marketplace
        Which marketplace(s) to install (native --marketplace, repeatable).
        Presets: curated (alias company), playground, all. Or a custom source.
        Defaults to 'curated' when omitted. Aliased as -Source.
    .PARAMETER Engine
        Which engine(s) to target: claude and/or copilot (native --engine).
        Defaults to both when omitted.
    .PARAMETER FixGitAuth
        Fix git authentication issues (configures gh as git's credential helper
        and refreshes the gh token for SAML SSO orgs). Native --fix-git-auth.
    .PARAMETER NoConfigCache
        Bypass the on-disk cache for remote_config fetches (native --no-config-cache).
    .EXAMPLE
        Register-AgencyMarketplace -Marketplace dotnet/skills
        Adds the dotnet skills marketplace to both engines.
    .EXAMPLE
        Register-AgencyMarketplace curated, playground -Engine copilot
        Adds the curated and playground presets for the copilot engine.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Position = 0)]
        [Alias('Source')]
        [string[]]$Marketplace,

        [ValidateSet('claude', 'copilot')]
        [string[]]$Engine,

        [switch]$FixGitAuth,

        [switch]$NoConfigCache
    )
    $exe = Resolve-CliExe -Name agency
    $cliArgs = @('marketplace', 'add')
    foreach ($m in $Marketplace) { $cliArgs += '--marketplace', $m }
    foreach ($e in $Engine) { $cliArgs += '--engine', $e }
    if ($FixGitAuth) { $cliArgs += '--fix-git-auth' }
    if ($NoConfigCache) { $cliArgs += '--no-config-cache' }

    $target = if ($Marketplace) { $Marketplace -join ', ' } else { 'curated (default)' }
    if ($PSCmdlet.ShouldProcess($target, 'agency marketplace add')) {
        & $exe @cliArgs 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Error "Failed to add marketplace(s): $target" }
    }
}
