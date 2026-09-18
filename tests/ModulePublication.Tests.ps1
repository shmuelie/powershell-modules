#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.2.0' }

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $policy = Join-Path $repoRoot 'build' 'Assert-ModulePublishable.ps1'
    $publishScript = Join-Path $repoRoot 'build' 'Publish-Module.ps1'
    function Publish-PSResource {
        [CmdletBinding()]
        param($Path, $Repository, $ApiKey)
        throw 'Real publication is forbidden in these tests.'
    }
}

Describe 'Module publication boundary' {
    BeforeEach {
        $artifact = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $artifact -ErrorAction Stop | Out-Null
        $manifestPath = Join-Path $artifact 'Shmuelie.Windows.psd1'
        $scriptDirectory = New-Item -ItemType Directory -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        Copy-Item -LiteralPath $publishScript, $policy -Destination $scriptDirectory.FullName
        Set-Content -LiteralPath (Join-Path $scriptDirectory.FullName 'Build-Module.ps1') -Value "throw 'Unexpected build: publication tests must fail closed.'"
        $scriptUnderTest = Join-Path $scriptDirectory.FullName 'Publish-Module.ps1'
        Set-Content -LiteralPath $manifestPath -Value @'
@{
    ModuleVersion = '0.2.0'
    FunctionsToExport = @()
    CmdletsToExport = @('Get-AppInstallerApp', 'Update-AppInstallerApp')
}
'@
        Mock Publish-PSResource { throw 'Publication must not run.' }
    }

    It 'rejects experimental publication before building, including preview' -ForEach @(
        @{ Preview = $false }; @{ Preview = $true }
    ) {
        { & $scriptUnderTest -Module Shmuelie.AppInstall.Experimental -ApiKey 'synthetic-test-key' -WhatIf:$Preview -Confirm:$false } |
            Should -Throw '*not publishable*'
        Should -Invoke Publish-PSResource -Times 0 -Exactly
    }

    It 'rejects unsupported module identities' -ForEach @(
        @{ Name = 'Other.Module' }; @{ Name = '../Shmuelie.Windows' }; @{ Name = 'Shmuelie.*' }
    ) {
        { & $policy -Module $Name } | Should -Throw '*not publishable*'
    }

    It 'accepts supported AppInstaller assets without loading them' {
        $bin = New-Item -ItemType Directory -Path (Join-Path $artifact 'bin')
        foreach ($name in 'Shmuelie.Windows.AppInstaller.dll', 'Microsoft.Windows.SDK.NET.dll', 'WinRT.Runtime.dll') {
            Set-Content -LiteralPath (Join-Path $bin.FullName $name) -Value 'not an assembly'
        }
        { & $policy -Module Shmuelie.Windows -Path $artifact } | Should -Not -Throw
        Should -Invoke Publish-PSResource -Times 0 -Exactly
    }

    It 'rejects a manifest that explicitly prohibits publication' {
        Set-Content -LiteralPath $manifestPath -Value '@{ PrivateData = @{ Publishable = $false } }'
        { & $policy -Module Shmuelie.Windows -Path $artifact } | Should -Throw '*prohibits publication*'
    }

    It 'rejects experimental and wildcard exports' -ForEach @(
        @{ Command = 'New-AppInstallContext' }; @{ Command = 'Get-AppInstallItem' }
        @{ Command = 'Get-AppInstallSettings' }; @{ Command = 'Request-AppInstallUpdateSearch' }
        @{ Command = 'Wait-AppInstallItem' }; @{ Command = '*' }
    ) {
        Set-Content -LiteralPath $manifestPath -Value "@{ CmdletsToExport = @('$Command') }"
        { & $policy -Module Shmuelie.Windows -Path $artifact } | Should -Throw '*export*'
    }

    It 'rejects experimental assets, even in nested stale outputs' -ForEach @(
        @{ Asset = 'Shmuelie.Windows.AppInstall.dll' }
        @{ Asset = 'Shmuelie.Windows.AppInstall.dll-Help.xml' }
        @{ Asset = 'AppInstall.format.ps1xml' }
    ) {
        $nested = New-Item -ItemType Directory -Path (Join-Path $artifact 'bin' 'en-US') -Force
        Set-Content -LiteralPath (Join-Path $nested.FullName $Asset) -Value 'stale experimental asset'
        { & $policy -Module Shmuelie.Windows -Path $artifact } | Should -Throw '*experimental AppInstall content*'
    }

    It 'rejects renamed runtime assets that reference the experimental contract' {
        Set-Content -LiteralPath (Join-Path $artifact 'Windows.format.ps1xml') -Value '<TypeName>Shmuelie.Windows.AppInstall.AppInstallMonitorResult</TypeName>'
        { & $policy -Module Shmuelie.Windows -Path $artifact } | Should -Throw '*references experimental AppInstall behavior*'
    }

    It 'keeps experimental development explicitly non-publishable' {
        $manifest = Import-PowerShellDataFile -LiteralPath (Join-Path $repoRoot 'experimental' 'Shmuelie.AppInstall.Experimental' 'Shmuelie.AppInstall.Experimental.psd1')
        $manifest.PrivateData.Publishable | Should -BeFalse
        $manifest.RequiredModules | Should -BeNullOrEmpty
        $manifest.CmdletsToExport | Should -HaveCount 5
    }
}
