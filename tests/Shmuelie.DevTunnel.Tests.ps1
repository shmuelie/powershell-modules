#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.2.0' }

BeforeDiscovery {
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules' 'Shmuelie.DevTunnel' 'Shmuelie.DevTunnel.psd1') -Force
}

BeforeAll {
    $script:modulePath = Join-Path (Split-Path (Split-Path $PSCommandPath -Parent) -Parent) 'modules' 'Shmuelie.DevTunnel' 'Shmuelie.DevTunnel.psd1'
    Import-Module $script:modulePath -Force
    $script:originalExitCode = $global:LASTEXITCODE
}

AfterAll {
    $global:LASTEXITCODE = $script:originalExitCode
    Remove-Module Shmuelie.DevTunnel -Force -ErrorAction SilentlyContinue
}

Describe 'DevTunnel import and public contract' {
    BeforeDiscovery {
        $exports = @(
            'Get-DevTunnelVersion', 'Connect-DevTunnelAccount', 'Disconnect-DevTunnelAccount',
            'Get-DevTunnelAccount', 'Get-DevTunnel', 'New-DevTunnel', 'Set-DevTunnel',
            'Remove-DevTunnel', 'Start-DevTunnel', 'Connect-DevTunnel',
            'Get-DevTunnelPort', 'New-DevTunnelPort', 'Set-DevTunnelPort', 'Remove-DevTunnelPort',
            'Get-DevTunnelAccess', 'Add-DevTunnelAccess', 'Remove-DevTunnelAccess',
            'Reset-DevTunnelAccess', 'New-DevTunnelToken', 'Set-DevTunnelDefault',
            'Clear-DevTunnelDefault', 'Get-DevTunnelCluster', 'Get-DevTunnelLimit',
            'Start-DevTunnelEcho', 'Test-DevTunnel'
        )
        $helpCases = $exports | ForEach-Object { @{ Command = $_ } }
    }

    It 'exports exactly the documented commands with no aliases or dependencies' {
        $expected = @(
            'Add-DevTunnelAccess', 'Clear-DevTunnelDefault', 'Connect-DevTunnel',
            'Connect-DevTunnelAccount', 'Disconnect-DevTunnelAccount', 'Get-DevTunnel',
            'Get-DevTunnelAccess', 'Get-DevTunnelAccount', 'Get-DevTunnelCluster',
            'Get-DevTunnelLimit', 'Get-DevTunnelPort', 'Get-DevTunnelVersion',
            'New-DevTunnel', 'New-DevTunnelPort', 'New-DevTunnelToken', 'Remove-DevTunnel',
            'Remove-DevTunnelAccess', 'Remove-DevTunnelPort', 'Reset-DevTunnelAccess',
            'Set-DevTunnel', 'Set-DevTunnelDefault', 'Set-DevTunnelPort',
            'Start-DevTunnel', 'Start-DevTunnelEcho', 'Test-DevTunnel'
        )
        $module = Get-Module Shmuelie.DevTunnel
        $manifest = Test-ModuleManifest $script:modulePath
        @($module.ExportedFunctions.Keys | Sort-Object) | Should -Be $expected
        @($manifest.ExportedFunctions.Keys | Sort-Object) | Should -Be $expected
        $module.ExportedAliases.Count | Should -Be 0
        $module.RequiredModules.Count | Should -Be 0
        $module.ExportedCmdlets.Count | Should -Be 0
        $module.ExportedVariables.Count | Should -Be 0
        $module.Version | Should -Be $manifest.Version
    }

    It 'provides synopsis and examples for <Command>' -ForEach $helpCases {
        $help = Get-Help "Shmuelie.DevTunnel\$Command" -Full
        $help.Synopsis | Should -Not -BeNullOrEmpty
        @($help.examples.example).Count | Should -BeGreaterThan 0
    }

    It 'imports in isolation without executing the CLI or loading dependencies' {
        $result = & pwsh -NoLogo -NoProfile -NonInteractive -Command {
            param($Path)
            $ErrorActionPreference = 'Stop'
            function global:devtunnel { throw 'CLI execution during import is forbidden.' }
            $module = Import-Module $Path -Force -PassThru -WarningAction Stop
            $projectModules = @(Get-Module 'Shmuelie.*')
            if ($projectModules.Count -ne 1 -or $projectModules[0].Name -ne 'Shmuelie.DevTunnel') { throw 'Unexpected dependency.' }
            $PSModuleAutoLoadingPreference = 'None'
            if (Get-Command Invoke-DevTunnelProcess -ErrorAction SilentlyContinue) { throw 'Private runner exported.' }
            if (Get-Command Resolve-DevTunnelCli -ErrorAction SilentlyContinue) { throw 'Private resolver exported.' }
            $module.ExportedFunctions.Count
        } -Args $script:modulePath
        $LASTEXITCODE | Should -Be 0
        $result | Should -BeExactly '25'
    }
}

Describe 'DevTunnel exact wrapper arguments' {
    InModuleScope Shmuelie.DevTunnel {
        BeforeDiscovery {
            # Fixture values are intentionally not interpolated into test names.
            $value = 'two words "quoted" & ; $(not-a-command) --switch'
            $wrapperCases = @(
                @{ Case = 'account-microsoft'; Command = 'Connect-DevTunnelAccount'; Parameters = @{}; Expected = @('user', 'login'); Stream = $true; Sensitive = $true }
                @{ Case = 'account-github'; Command = 'Connect-DevTunnelAccount'; Parameters = @{ GitHub = $true }; Expected = @('user', 'login', '--github'); Stream = $true; Sensitive = $true }
                @{ Case = 'account-devicecode'; Command = 'Connect-DevTunnelAccount'; Parameters = @{ DeviceCode = $true }; Expected = @('user', 'login', '--use-device-code-auth'); Stream = $true; Sensitive = $true }
                @{ Case = 'account-combined'; Command = 'Connect-DevTunnelAccount'; Parameters = @{ GitHub = $true; DeviceCode = $true }; Expected = @('user', 'login', '--github', '--use-device-code-auth'); Stream = $true; Sensitive = $true }
                @{ Case = 'account-false-switches'; Command = 'Connect-DevTunnelAccount'; Parameters = @{ GitHub = $false; DeviceCode = $false }; Expected = @('user', 'login'); Stream = $true; Sensitive = $true }
                @{ Case = 'logout'; Command = 'Disconnect-DevTunnelAccount'; Parameters = @{}; Expected = @('user', 'logout', '--json'); Sensitive = $true }
                @{ Case = 'account-show'; Command = 'Get-DevTunnelAccount'; Parameters = @{}; Expected = @('user', 'show', '--json'); Sensitive = $true }
                @{ Case = 'tunnel-list'; Command = 'Get-DevTunnel'; Parameters = @{}; Expected = @('list', '--json') }
                @{ Case = 'tunnel-filter'; Command = 'Get-DevTunnel'; Parameters = @{ Label = @('web', $value); AllLabel = @('team', 'demo'); Limit = 1 }; Expected = @('list', '--labels=web', "--labels=$value", '--all-labels=team', '--all-labels=demo', '--limit=1', '--json') }
                @{ Case = 'tunnel-show'; Command = 'Get-DevTunnel'; Parameters = @{ TunnelId = 'my-tunnel.eu' }; Expected = @('show', 'my-tunnel.eu', '--json') }
                @{ Case = 'tunnel-lastused'; Command = 'Get-DevTunnel'; Parameters = @{ LastUsed = $true }; Expected = @('show', '--json') }
                @{ Case = 'create-authenticated'; Command = 'New-DevTunnel'; Parameters = @{}; Expected = @('create', '--json') }
                @{ Case = 'create-explicit'; Command = 'New-DevTunnel'; Parameters = @{ TunnelId = 'my-tunnel'; Description = $value; Label = @('web', $value); Expiration = '720h' }; Expected = @('create', 'my-tunnel', "--description=$value", '--labels=web', "--labels=$value", '--expiration=720h', '--json') }
                @{ Case = 'update-lastused'; Command = 'Set-DevTunnel'; Parameters = @{ Description = ''; AddLabel = @('one', $value); RemoveLabel = @('old', 'stale'); Expiration = '30d' }; Expected = @('update', '--description=', '--add-labels=one', "--add-labels=$value", '--remove-labels=old', '--remove-labels=stale', '--expiration=30d', '--json') }
                @{ Case = 'update-explicit'; Command = 'Set-DevTunnel'; Parameters = @{ TunnelId = 'my-tunnel'; Description = $value }; Expected = @('update', 'my-tunnel', "--description=$value", '--json') }
                @{ Case = 'delete-explicit'; Command = 'Remove-DevTunnel'; Parameters = @{ TunnelId = 'my-tunnel' }; Expected = @('delete', 'my-tunnel', '--json', '--force') }
                @{ Case = 'delete-lastused'; Command = 'Remove-DevTunnel'; Parameters = @{}; Expected = @('delete', '--json', '--force') }
                @{ Case = 'delete-all'; Command = 'Remove-DevTunnel'; Parameters = @{ All = $true }; Expected = @('delete-all', '--json', '--force') }
                @{ Case = 'default-set'; Command = 'Set-DevTunnelDefault'; Parameters = @{ TunnelId = 'my-tunnel' }; Expected = @('set', 'my-tunnel', '--json') }
                @{ Case = 'default-clear'; Command = 'Clear-DevTunnelDefault'; Parameters = @{}; Expected = @('unset', '--json') }
                @{ Case = 'port-list-lastused'; Command = 'Get-DevTunnelPort'; Parameters = @{}; Expected = @('port', 'list', '--json') }
                @{ Case = 'port-list-explicit'; Command = 'Get-DevTunnelPort'; Parameters = @{ TunnelId = 'my-tunnel' }; Expected = @('port', 'list', 'my-tunnel', '--json') }
                @{ Case = 'port-show'; Command = 'Get-DevTunnelPort'; Parameters = @{ TunnelId = 'my-tunnel'; PortNumber = 65535 }; Expected = @('port', 'show', 'my-tunnel', '--port-number=65535', '--json') }
                @{ Case = 'port-create'; Command = 'New-DevTunnelPort'; Parameters = @{ TunnelId = 'my-tunnel'; PortNumber = 1; Protocol = 'auto'; Description = $value; Label = @('web', $value) }; Expected = @('port', 'create', 'my-tunnel', '--port-number=1', '--protocol=auto', "--description=$value", '--labels=web', "--labels=$value", '--json') }
                @{ Case = 'port-create-lastused'; Command = 'New-DevTunnelPort'; Parameters = @{ PortNumber = 3000 }; Expected = @('port', 'create', '--port-number=3000', '--json') }
                @{ Case = 'port-update'; Command = 'Set-DevTunnelPort'; Parameters = @{ TunnelId = 'my-tunnel'; PortNumber = 3000; Description = ''; AddLabel = @('new', $value); RemoveLabel = @('old') }; Expected = @('port', 'update', 'my-tunnel', '--port-number=3000', '--description=', '--add-labels=new', "--add-labels=$value", '--remove-labels=old', '--json') }
                @{ Case = 'port-update-lastused'; Command = 'Set-DevTunnelPort'; Parameters = @{ PortNumber = 3000; Description = $value }; Expected = @('port', 'update', '--port-number=3000', "--description=$value", '--json') }
                @{ Case = 'port-delete'; Command = 'Remove-DevTunnelPort'; Parameters = @{ TunnelId = 'my-tunnel'; PortNumber = 3000 }; Expected = @('port', 'delete', 'my-tunnel', '--port-number=3000', '--json') }
                @{ Case = 'port-delete-lastused'; Command = 'Remove-DevTunnelPort'; Parameters = @{ PortNumber = 3000 }; Expected = @('port', 'delete', '--port-number=3000', '--json') }
                @{ Case = 'access-list'; Command = 'Get-DevTunnelAccess'; Parameters = @{ TunnelId = 'my-tunnel'; PortNumber = 3000 }; Expected = @('access', 'list', 'my-tunnel', '--port-number=3000', '--json') }
                @{ Case = 'access-list-lastused'; Command = 'Get-DevTunnelAccess'; Parameters = @{}; Expected = @('access', 'list', '--json') }
                @{ Case = 'access-tenant'; Command = 'Add-DevTunnelAccess'; Parameters = @{ TunnelId = 'my-tunnel'; Tenant = $true; PortNumber = 3000; Scope = @('connect', 'inspect'); Expiration = '1d'; Index = 0 }; Expected = @('access', 'create', 'my-tunnel', '--port-number=3000', '--expiration=1d', '--scopes=connect', '--scopes=inspect', '--index=0', '--tenant', '--json') }
                @{ Case = 'access-organization'; Command = 'Add-DevTunnelAccess'; Parameters = @{ Organization = $value; Scope = 'host' }; Expected = @('access', 'create', '--scopes=host', "--organization=$value", '--json') }
                @{ Case = 'access-repository'; Command = 'Add-DevTunnelAccess'; Parameters = @{ Repository = $value; Scope = 'manage:ports' }; Expected = @('access', 'create', '--scopes=manage:ports', "--repo=$value", '--json') }
                @{ Case = 'access-delete-zero'; Command = 'Remove-DevTunnelAccess'; Parameters = @{ TunnelId = 'my-tunnel'; PortNumber = 3000; Index = 0 }; Expected = @('access', 'delete', 'my-tunnel', '--port-number=3000', '--index=0', '--json') }
                @{ Case = 'access-delete-lastused'; Command = 'Remove-DevTunnelAccess'; Parameters = @{ Index = 1 }; Expected = @('access', 'delete', '--index=1', '--json') }
                @{ Case = 'access-reset'; Command = 'Reset-DevTunnelAccess'; Parameters = @{ TunnelId = 'my-tunnel'; PortNumber = 3000 }; Expected = @('access', 'reset', 'my-tunnel', '--port-number=3000', '--json') }
                @{ Case = 'access-reset-lastused'; Command = 'Reset-DevTunnelAccess'; Parameters = @{}; Expected = @('access', 'reset', '--json') }
                @{ Case = 'token'; Command = 'New-DevTunnelToken'; Parameters = @{ TunnelId = 'my-tunnel'; Scope = @('create', 'manage', 'manage:ports', 'host', 'inspect', 'connect') }; Expected = @('token', 'my-tunnel', '--scopes=create', '--scopes=manage', '--scopes=manage:ports', '--scopes=host', '--scopes=inspect', '--scopes=connect', '--json'); Sensitive = $true }
                @{ Case = 'token-lastused'; Command = 'New-DevTunnelToken'; Parameters = @{ Scope = 'connect' }; Expected = @('token', '--scopes=connect', '--json'); Sensitive = $true }
                @{ Case = 'host-temporary'; Command = 'Start-DevTunnel'; Parameters = @{ PortNumber = @(1, 65535); Protocol = 'https'; Description = $value; Label = @('web', $value); Expiration = '1h' }; Expected = @('host', '--port-number=1', '--port-number=65535', '--protocol=https', "--description=$value", '--labels=web', "--labels=$value", '--expiration=1h'); Stream = $true }
                @{ Case = 'host-explicit'; Command = 'Start-DevTunnel'; Parameters = @{ TunnelId = 'my-tunnel' }; Expected = @('host', 'my-tunnel'); Stream = $true }
                @{ Case = 'host-no-options'; Command = 'Start-DevTunnel'; Parameters = @{}; Expected = @('host'); Stream = $true }
                @{ Case = 'connect-explicit'; Command = 'Connect-DevTunnel'; Parameters = @{ TunnelId = 'my-tunnel' }; Expected = @('connect', 'my-tunnel'); Stream = $true }
                @{ Case = 'connect-lastused'; Command = 'Connect-DevTunnel'; Parameters = @{}; Expected = @('connect'); Stream = $true }
                @{ Case = 'echo-loopback'; Command = 'Start-DevTunnelEcho'; Parameters = @{ PortNumber = 8080 }; Expected = @('echo', 'http', '--port=8080', '--interface=127.0.0.1'); Stream = $true }
                @{ Case = 'echo-explicit'; Command = 'Start-DevTunnelEcho'; Parameters = @{ Protocol = 'tcp'; PortNumber = 65535; Interface = '::1' }; Expected = @('echo', 'tcp', '--port=65535', '--interface=::1'); Stream = $true }
                @{ Case = 'diagnostic-ping'; Command = 'Test-DevTunnel'; Parameters = @{ Uri = 'http://localhost:8080/path'; Size = 64; Interval = 1000 }; Expected = @('ping', 'http://localhost:8080/path', '--size=64', '--interval=1000'); Stream = $true }
                @{ Case = 'diagnostic-defaults'; Command = 'Test-DevTunnel'; Parameters = @{ Uri = 'tcp://localhost:8080/' }; Expected = @('ping', 'tcp://localhost:8080/'); Stream = $true }
                @{ Case = 'clusters'; Command = 'Get-DevTunnelCluster'; Parameters = @{}; Expected = @('clusters', '--json') }
                @{ Case = 'clusters-ping'; Command = 'Get-DevTunnelCluster'; Parameters = @{ Ping = $true }; Expected = @('clusters', '--ping', '--json') }
                @{ Case = 'limits'; Command = 'Get-DevTunnelLimit'; Parameters = @{}; Expected = @('limits', '--json') }
            )
            $pipelineCases = @(
                @{ Command = 'Get-DevTunnel'; Parameters = @{}; Prefix = @('show') }
                @{ Command = 'Set-DevTunnel'; Parameters = @{ Description = 'updated' }; Prefix = @('update') }
                @{ Command = 'Remove-DevTunnel'; Parameters = @{}; Prefix = @('delete') }
                @{ Command = 'Set-DevTunnelDefault'; Parameters = @{}; Prefix = @('set') }
                @{ Command = 'Get-DevTunnelPort'; Parameters = @{}; Prefix = @('port', 'list') }
                @{ Command = 'New-DevTunnelPort'; Parameters = @{ PortNumber = 3000 }; Prefix = @('port', 'create') }
                @{ Command = 'Set-DevTunnelPort'; Parameters = @{ PortNumber = 3000 }; Prefix = @('port', 'update') }
                @{ Command = 'Remove-DevTunnelPort'; Parameters = @{ PortNumber = 3000 }; Prefix = @('port', 'delete') }
                @{ Command = 'Get-DevTunnelAccess'; Parameters = @{}; Prefix = @('access', 'list') }
                @{ Command = 'Add-DevTunnelAccess'; Parameters = @{ Tenant = $true }; Prefix = @('access', 'create') }
                @{ Command = 'Remove-DevTunnelAccess'; Parameters = @{ Index = 0 }; Prefix = @('access', 'delete') }
                @{ Command = 'Reset-DevTunnelAccess'; Parameters = @{}; Prefix = @('access', 'reset') }
                @{ Command = 'New-DevTunnelToken'; Parameters = @{ Scope = 'connect' }; Prefix = @('token') }
            )
        }

        BeforeEach {
            $script:calls = [Collections.Generic.List[object]]::new()
            Mock Resolve-DevTunnelCli { 'synthetic-devtunnel.exe' }
            Mock Get-DevTunnelCliVersion { [version]'1.0.2115' }
            Mock Invoke-DevTunnelProcess {
                param($FilePath, $Arguments, $Stream, $Sensitive)
                $script:calls.Add(@{ Path = $FilePath; Arguments = @($Arguments); Stream = [bool]$Stream; Sensitive = [bool]$Sensitive })
                if ($Stream) { 'Open the browser and enter the displayed device code.' }
                else { '{"tunnels":[{"tunnelId":"fixture-tunnel","ports":[{"portNumber":3000}]}],"continuationToken":"fixture-next","token":"fixture-token"}' }
            }
            Mock Write-DevTunnelAnonymousWarning {}
        }

        It 'maps exact arguments and output for <Case>' -ForEach $wrapperCases {
            $parameters = @{} + $Parameters
            if ((Get-Command $Command).Parameters.ContainsKey('Confirm')) { $parameters.Confirm = $false }
            $result = & $Command @parameters
            $script:calls.Count | Should -Be 1
            $script:calls[0].Path | Should -BeExactly 'synthetic-devtunnel.exe'
            $script:calls[0].Arguments | Should -BeExactly $Expected
            $script:calls[0].Stream | Should -Be ([bool]$Stream)
            $script:calls[0].Sensitive | Should -Be ([bool]$Sensitive)
            if ($Stream) {
                $result | Should -BeExactly 'Open the browser and enter the displayed device code.'
                $script:calls[0].Arguments | Should -Not -Contain '--json'
            } else {
                @($result).Count | Should -Be 1
                $result.tunnels[0].tunnelId | Should -BeExactly 'fixture-tunnel'
                $result.tunnels[0].ports[0].portNumber | Should -Be 3000
                $result.continuationToken | Should -BeExactly 'fixture-next'
                $result.token | Should -BeExactly 'fixture-token'
            }
            Should -Invoke Resolve-DevTunnelCli -Times 1 -Exactly
            Should -Invoke Get-DevTunnelCliVersion -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'synthetic-devtunnel.exe' }
            Should -Invoke Write-DevTunnelAnonymousWarning -Times 0 -Exactly
        }

        It 'returns a typed supported version and resolved path' {
            $result = Get-DevTunnelVersion
            $result.Version | Should -Be ([version]'1.0.2115')
            $result.Path | Should -BeExactly 'synthetic-devtunnel.exe'
            $result.PSObject.TypeNames[0] | Should -BeExactly 'Shmuelie.DevTunnel.Version'
            Should -Invoke Invoke-DevTunnelProcess -Times 0 -Exactly
        }

        It 'processes each pipeline ID independently for <Command>' -ForEach $pipelineCases {
            $parameters = @{} + $Parameters
            if ((Get-Command $Command).Parameters.ContainsKey('Confirm')) { $parameters.Confirm = $false }
            # Both canonical property and alias must bind, without reusing the first ID.
            $result = @([pscustomobject]@{ TunnelId = 'first-tunnel' }, [pscustomobject]@{ Id = 'second-tunnel' }) | & $Command @parameters
            $script:calls.Count | Should -Be 2
            @($result).Count | Should -Be 2
            for ($i = 0; $i -lt 2; $i++) {
                $id = @('first-tunnel', 'second-tunnel')[$i]
                $suffix = @()
                if ($Parameters.ContainsKey('PortNumber')) { $suffix += '--port-number=3000' }
                if ($Parameters.ContainsKey('Description')) { $suffix += '--description=updated' }
                if ($Parameters.ContainsKey('Scope')) { $suffix += '--scopes=connect' }
                if ($Parameters.ContainsKey('Index')) { $suffix += '--index=0' }
                if ($Parameters.ContainsKey('Tenant')) { $suffix += '--tenant' }
                $suffix += '--json'
                if ($Command -eq 'Remove-DevTunnel') { $suffix += '--force' }
                $script:calls[$i].Arguments | Should -BeExactly (@($Prefix) + $id + $suffix)
            }
        }
    }
}

Describe 'DevTunnel ShouldProcess and anonymous access' {
    InModuleScope Shmuelie.DevTunnel {
        BeforeDiscovery {
            $mutatorCases = @(
                @{ Command = 'Connect-DevTunnelAccount'; Parameters = @{} }
                @{ Command = 'Disconnect-DevTunnelAccount'; Parameters = @{} }
                @{ Command = 'New-DevTunnel'; Parameters = @{ AllowAnonymous = $true } }
                @{ Command = 'Set-DevTunnel'; Parameters = @{ Description = 'updated' } }
                @{ Command = 'Remove-DevTunnel'; Parameters = @{ TunnelId = 'my-tunnel' } }
                @{ Command = 'Remove-DevTunnel'; Parameters = @{ All = $true }; Case = 'bulk' }
                @{ Command = 'Set-DevTunnelDefault'; Parameters = @{ TunnelId = 'my-tunnel' } }
                @{ Command = 'Clear-DevTunnelDefault'; Parameters = @{} }
                @{ Command = 'New-DevTunnelPort'; Parameters = @{ PortNumber = 3000 } }
                @{ Command = 'Set-DevTunnelPort'; Parameters = @{ PortNumber = 3000 } }
                @{ Command = 'Remove-DevTunnelPort'; Parameters = @{ PortNumber = 3000 } }
                @{ Command = 'Add-DevTunnelAccess'; Parameters = @{ Anonymous = $true } }
                @{ Command = 'Remove-DevTunnelAccess'; Parameters = @{ Index = 0 } }
                @{ Command = 'Reset-DevTunnelAccess'; Parameters = @{} }
                @{ Command = 'New-DevTunnelToken'; Parameters = @{ Scope = 'connect' } }
                @{ Command = 'Start-DevTunnel'; Parameters = @{ AllowAnonymous = $true } }
                @{ Command = 'Connect-DevTunnel'; Parameters = @{} }
                @{ Command = 'Start-DevTunnelEcho'; Parameters = @{ PortNumber = 3000 } }
                @{ Command = 'Test-DevTunnel'; Parameters = @{ Uri = 'http://localhost:8080/' } }
            ) | ForEach-Object { if (-not $_.ContainsKey('Case')) { $_.Case = 'single' }; $_ }
            $anonymousCases = @(
                @{ Command = 'New-DevTunnel'; Flag = 'AllowAnonymous'; Prefix = @('create') }
                @{ Command = 'Start-DevTunnel'; Flag = 'AllowAnonymous'; Prefix = @('host') }
                @{ Command = 'Add-DevTunnelAccess'; Flag = 'Anonymous'; Prefix = @('access', 'create') }
            )
        }

        BeforeEach {
            $script:calls = [Collections.Generic.List[object]]::new()
            Mock Resolve-DevTunnelCli { 'synthetic-devtunnel.exe' }
            Mock Get-DevTunnelCliVersion { [version]'1.0.2115' }
            Mock Invoke-DevTunnelProcess {
                param($Arguments)
                $script:calls.Add(@($Arguments))
                '{"ok":true}'
            }
        }

        It 'performs no discovery version runner or warning under WhatIf for <Command> <Case>' -ForEach $mutatorCases {
            $warnings = @()
            $output = & $Command @Parameters -WhatIf -WarningVariable warnings
            @($output).Count | Should -Be 0
            $warnings.Count | Should -Be 0
            Should -Invoke Resolve-DevTunnelCli -Times 0 -Exactly
            Should -Invoke Get-DevTunnelCliVersion -Times 0 -Exactly
            Should -Invoke Invoke-DevTunnelProcess -Times 0 -Exactly
        }

        It 'warns only for explicit anonymous grant in <Command>' -ForEach $anonymousCases {
            $parameters = @{ Confirm = $false }
            $parameters[$Flag] = $true
            $warnings = @()
            $null = & $Command @parameters -WarningVariable warnings -WarningAction SilentlyContinue
            $warnings.Count | Should -Be 1
            [string]$warnings[0] | Should -BeLike '*anyone on the internet*'
            $switch = if ($Flag -eq 'Anonymous') { '--anonymous' } else { '--allow-anonymous' }
            $expected = @($Prefix) + $switch
            if ($Command -ne 'Start-DevTunnel') { $expected += '--json' }
            $script:calls[0] | Should -BeExactly $expected
        }

        It 'does not warn when denying anonymous access' {
            $warnings = @()
            $result = Add-DevTunnelAccess -Anonymous -Deny -Confirm:$false -WarningVariable warnings
            $result.ok | Should -BeTrue
            $warnings.Count | Should -Be 0
            $script:calls.Count | Should -Be 1
            $script:calls[0] | Should -BeExactly @('access', 'create', '--anonymous', '--deny', '--json')
        }

        It 'keeps false anonymous flags authenticated without a warning' {
            $warnings = @()
            $null = New-DevTunnel -AllowAnonymous:$false -Confirm:$false -WarningVariable warnings
            $null = Start-DevTunnel -AllowAnonymous:$false -Confirm:$false -WarningVariable +warnings
            $warnings.Count | Should -Be 0
            $script:calls[0] | Should -BeExactly @('create', '--json')
            $script:calls[1] | Should -BeExactly @('host')
        }

        It 'uses high impact for every destructive command' -ForEach @(
            @{ Command = 'Remove-DevTunnel' }, @{ Command = 'Remove-DevTunnelPort' },
            @{ Command = 'Remove-DevTunnelAccess' }, @{ Command = 'Reset-DevTunnelAccess' }
        ) {
            $binding = (Get-Command $Command).ScriptBlock.Attributes |
                Where-Object { $_ -is [Management.Automation.CmdletBindingAttribute] }
            $binding.SupportsShouldProcess | Should -BeTrue
            [string]$binding.ConfirmImpact | Should -BeExactly 'High'
        }
    }
}

Describe 'DevTunnel parameter boundaries' {
    InModuleScope Shmuelie.DevTunnel {
        BeforeDiscovery {
            $portCommands = @('Get-DevTunnelPort', 'New-DevTunnelPort', 'Set-DevTunnelPort', 'Remove-DevTunnelPort',
                'Get-DevTunnelAccess', 'Add-DevTunnelAccess', 'Remove-DevTunnelAccess', 'Reset-DevTunnelAccess', 'Start-DevTunnel', 'Start-DevTunnelEcho')
            $portCases = foreach ($command in $portCommands) {
                foreach ($port in @(1, 65535, 0, 65536)) {
                    $parameters = @{ PortNumber = $port }
                    if ($command -eq 'Add-DevTunnelAccess') { $parameters.Tenant = $true }
                    if ($command -eq 'Remove-DevTunnelAccess') { $parameters.Index = 0 }
                    @{ Command = $command; Port = $port; Parameters = $parameters; Valid = $port -in 1, 65535 }
                }
            }
            $expirationCases = foreach ($command in @('New-DevTunnel', 'Set-DevTunnel', 'Start-DevTunnel', 'Add-DevTunnelAccess')) {
                $fixtures = @(
                    @{ Case = 'first-hour'; Value = '1h'; Valid = $true }, @{ Case = 'last-hour'; Value = '720h'; Valid = $true },
                    @{ Case = 'first-day'; Value = '1d'; Valid = $true }, @{ Case = 'last-day'; Value = '30d'; Valid = $true },
                    @{ Case = 'zero-hour'; Value = '0h' }, @{ Case = 'past-hour'; Value = '721h' },
                    @{ Case = 'zero-day'; Value = '0d' }, @{ Case = 'past-day'; Value = '31d' },
                    @{ Case = 'leading-zero'; Value = '01h' }, @{ Case = 'negative'; Value = '-1h' },
                    @{ Case = 'unsupported-unit'; Value = '1m' }, @{ Case = 'fraction'; Value = '1.5h' },
                    @{ Case = 'trailing-text'; Value = '1h extra' }, @{ Case = 'empty'; Value = '' },
                    @{ Case = 'trailing-newline'; Value = "1h`n" }
                )
                foreach ($fixture in $fixtures) {
                    $parameters = @{ Expiration = $fixture.Value }
                    if ($command -eq 'Add-DevTunnelAccess') { $parameters.Tenant = $true }
                    @{ Command = $command; Case = $fixture.Case; Parameters = $parameters; Valid = [bool]$fixture.Valid; Value = $fixture.Value }
                }
            }
            $invalidCases = @(
                @{ Case = 'all-false'; Command = 'Remove-DevTunnel'; Parameters = @{ All = $false } }
                @{ Case = 'all-and-id'; Command = 'Remove-DevTunnel'; Parameters = @{ All = $true; TunnelId = 'my-tunnel' } }
                @{ Case = 'lastused-and-id'; Command = 'Get-DevTunnel'; Parameters = @{ LastUsed = $true; TunnelId = 'my-tunnel' } }
                @{ Case = 'lastused-false'; Command = 'Get-DevTunnel'; Parameters = @{ LastUsed = $false } }
                @{ Case = 'list-label-and-id'; Command = 'Get-DevTunnel'; Parameters = @{ Label = 'web'; TunnelId = 'my-tunnel' } }
                @{ Case = 'anonymous-false'; Command = 'Add-DevTunnelAccess'; Parameters = @{ Anonymous = $false } }
                @{ Case = 'tenant-false'; Command = 'Add-DevTunnelAccess'; Parameters = @{ Tenant = $false } }
                @{ Case = 'index-negative-delete'; Command = 'Remove-DevTunnelAccess'; Parameters = @{ Index = -1 } }
                @{ Case = 'index-negative-create'; Command = 'Add-DevTunnelAccess'; Parameters = @{ Tenant = $true; Index = -1 } }
                @{ Case = 'scope-invalid-access'; Command = 'Add-DevTunnelAccess'; Parameters = @{ Tenant = $true; Scope = 'administrator' } }
                @{ Case = 'scope-invalid-token'; Command = 'New-DevTunnelToken'; Parameters = @{ Scope = @('connect', 'administrator') } }
                @{ Case = 'scope-empty-token'; Command = 'New-DevTunnelToken'; Parameters = @{ Scope = @() } }
                @{ Case = 'limit-zero'; Command = 'Get-DevTunnel'; Parameters = @{ Limit = 0 } }
                @{ Case = 'limit-negative'; Command = 'Get-DevTunnel'; Parameters = @{ Limit = -1 } }
                @{ Case = 'size-zero'; Command = 'Test-DevTunnel'; Parameters = @{ Uri = 'http://localhost/'; Size = 0 } }
                @{ Case = 'size-negative'; Command = 'Test-DevTunnel'; Parameters = @{ Uri = 'http://localhost/'; Size = -1 } }
                @{ Case = 'interval-zero'; Command = 'Test-DevTunnel'; Parameters = @{ Uri = 'http://localhost/'; Interval = 0 } }
                @{ Case = 'interval-negative'; Command = 'Test-DevTunnel'; Parameters = @{ Uri = 'http://localhost/'; Interval = -1 } }
                @{ Case = 'protocol-host'; Command = 'Start-DevTunnel'; Parameters = @{ Protocol = 'tcp' } }
                @{ Case = 'protocol-port'; Command = 'New-DevTunnelPort'; Parameters = @{ PortNumber = 1; Protocol = 'ssh' } }
                @{ Case = 'protocol-echo'; Command = 'Start-DevTunnelEcho'; Parameters = @{ PortNumber = 1; Protocol = 'smtp' } }
                @{ Case = 'interface-invalid'; Command = 'Start-DevTunnelEcho'; Parameters = @{ PortNumber = 1; Interface = 'not-an-ip' } }
                @{ Case = 'uri-relative'; Command = 'Test-DevTunnel'; Parameters = @{ Uri = '/relative' } }
                @{ Case = 'uri-credentials'; Command = 'Test-DevTunnel'; Parameters = @{ Uri = 'http://fixture-user:fixture-password@localhost/' } }
                @{ Case = 'uri-unsupported'; Command = 'Test-DevTunnel'; Parameters = @{ Uri = 'file:///fixture' } }
                @{ Case = 'label-empty'; Command = 'New-DevTunnel'; Parameters = @{ Label = @() } }
                @{ Case = 'description-empty-create'; Command = 'New-DevTunnel'; Parameters = @{ Description = '' } }
                @{ Case = 'ports-empty-host'; Command = 'Start-DevTunnel'; Parameters = @{ PortNumber = @() } }
                @{ Case = 'organization-empty'; Command = 'Add-DevTunnelAccess'; Parameters = @{ Organization = '' } }
                @{ Case = 'repository-empty'; Command = 'Add-DevTunnelAccess'; Parameters = @{ Repository = '' } }
            )
            $subjects = @('Anonymous', 'Tenant', 'Organization', 'Repository')
            for ($i = 0; $i -lt $subjects.Count; $i++) {
                for ($j = $i + 1; $j -lt $subjects.Count; $j++) {
                    $parameters = @{}
                    foreach ($subject in @($subjects[$i], $subjects[$j])) {
                        $parameters[$subject] = if ($subject -in 'Anonymous', 'Tenant') { $true } else { 'fixture' }
                    }
                    $invalidCases += @{ Case = "exclusive-$i-$j"; Command = 'Add-DevTunnelAccess'; Parameters = $parameters }
                }
            }
            $idCases = foreach ($command in @('Get-DevTunnel', 'New-DevTunnel', 'Set-DevTunnel', 'Remove-DevTunnel',
                    'Start-DevTunnel', 'Connect-DevTunnel', 'Get-DevTunnelPort', 'New-DevTunnelPort',
                    'Set-DevTunnelPort', 'Remove-DevTunnelPort', 'Get-DevTunnelAccess', 'Add-DevTunnelAccess',
                    'Remove-DevTunnelAccess', 'Reset-DevTunnelAccess', 'New-DevTunnelToken', 'Set-DevTunnelDefault')) {
                foreach ($fixture in @(
                    @{ Case = 'option'; Value = '--help' }, @{ Case = 'space'; Value = 'two ids' },
                    @{ Case = 'slash'; Value = 'id/path' }, @{ Case = 'metacharacter'; Value = 'id;exit' },
                    @{ Case = 'leading-dot'; Value = '.id' }, @{ Case = 'newline'; Value = "id`n" }
                )) {
                    $parameters = @{ TunnelId = $fixture.Value }
                    if ($command -in 'New-DevTunnelPort', 'Set-DevTunnelPort', 'Remove-DevTunnelPort') { $parameters.PortNumber = 1 }
                    if ($command -eq 'Add-DevTunnelAccess') { $parameters.Tenant = $true }
                    if ($command -eq 'Remove-DevTunnelAccess') { $parameters.Index = 0 }
                    if ($command -eq 'New-DevTunnelToken') { $parameters.Scope = 'connect' }
                    @{ Case = $fixture.Case; Command = $command; Parameters = $parameters }
                }
            }
        }

        BeforeEach {
            $script:arguments = @()
            Mock Resolve-DevTunnelCli { 'synthetic-devtunnel.exe' }
            Mock Get-DevTunnelCliVersion { [version]'1.0.2115' }
            Mock Invoke-DevTunnelProcess { param($Arguments); $script:arguments = @($Arguments); '{"ok":true}' }
        }

        It 'enforces port boundary <Port> for <Command>' -ForEach $portCases {
            $parameters = @{} + $Parameters
            if ((Get-Command $Command).Parameters.ContainsKey('Confirm')) { $parameters.Confirm = $false }
            if ($Valid) {
                $null = & $Command @parameters
                $option = if ($Command -eq 'Start-DevTunnelEcho') { "--port=$Port" } else { "--port-number=$Port" }
                $script:arguments | Should -Contain $option
                Should -Invoke Invoke-DevTunnelProcess -Times 1 -Exactly
            } else {
                { & $Command @parameters } | Should -Throw
                Should -Invoke Resolve-DevTunnelCli -Times 0 -Exactly
                Should -Invoke Get-DevTunnelCliVersion -Times 0 -Exactly
                Should -Invoke Invoke-DevTunnelProcess -Times 0 -Exactly
            }
        }

        It 'enforces expiration partition <Case> for <Command>' -ForEach $expirationCases {
            $parameters = @{} + $Parameters
            $parameters.Confirm = $false
            if ($Valid) {
                $null = & $Command @parameters
                $script:arguments | Should -Contain "--expiration=$Value"
                Should -Invoke Invoke-DevTunnelProcess -Times 1 -Exactly
            } else {
                { & $Command @parameters } | Should -Throw '*Cannot validate argument*Expiration*'
                Should -Invoke Resolve-DevTunnelCli -Times 0 -Exactly
                Should -Invoke Invoke-DevTunnelProcess -Times 0 -Exactly
            }
        }

        It 'rejects invalid binding <Case> before CLI discovery' -ForEach $invalidCases {
            $parameters = @{} + $Parameters
            if ((Get-Command $Command).Parameters.ContainsKey('Confirm')) { $parameters.Confirm = $false }
            { & $Command @parameters } | Should -Throw
            Should -Invoke Resolve-DevTunnelCli -Times 0 -Exactly
            Should -Invoke Get-DevTunnelCliVersion -Times 0 -Exactly
            Should -Invoke Invoke-DevTunnelProcess -Times 0 -Exactly
        }

        It 'rejects malformed ID <Case> for <Command> before CLI discovery' -ForEach $idCases {
            $parameters = @{} + $Parameters
            if ((Get-Command $Command).Parameters.ContainsKey('Confirm')) { $parameters.Confirm = $false }
            { & $Command @parameters } | Should -Throw '*Cannot validate argument*TunnelId*'
            Should -Invoke Resolve-DevTunnelCli -Times 0 -Exactly
            Should -Invoke Invoke-DevTunnelProcess -Times 0 -Exactly
        }

        It 'maps every supported access scope explicitly' {
            foreach ($scope in @('create', 'manage', 'manage:ports', 'host', 'inspect', 'connect')) {
                $result = Add-DevTunnelAccess -Tenant -Scope $scope -Confirm:$false
                $result.ok | Should -BeTrue
                $script:arguments | Should -BeExactly @('access', 'create', "--scopes=$scope", '--tenant', '--json')
            }
            Should -Invoke Invoke-DevTunnelProcess -Times 6 -Exactly
        }

        It 'accepts every supported host and persistent port protocol' {
            foreach ($protocol in @('http', 'https', 'auto')) {
                $null = Start-DevTunnel -PortNumber 3000 -Protocol $protocol -Confirm:$false
                $script:arguments | Should -BeExactly @('host', '--port-number=3000', "--protocol=$protocol")
                $result = New-DevTunnelPort -PortNumber 3000 -Protocol $protocol -Confirm:$false
                $result.ok | Should -BeTrue
                $script:arguments | Should -BeExactly @('port', 'create', '--port-number=3000', "--protocol=$protocol", '--json')
            }
        }

        It 'accepts every supported echo protocol without opening a listener' {
            foreach ($protocol in @('http', 'https', 'ssh', 'tcp', 'udp')) {
                $null = Start-DevTunnelEcho -Protocol $protocol -PortNumber 1 -Confirm:$false
                $script:arguments | Should -BeExactly @('echo', $protocol, '--port=1', '--interface=127.0.0.1')
            }
        }

        It 'accepts every diagnostic scheme without contacting an endpoint' {
            foreach ($scheme in @('http', 'https', 'ws', 'wss', 'tcp', 'udp', 'ssh')) {
                $null = Test-DevTunnel -Uri "${scheme}://localhost:8080/path" -Confirm:$false
                $script:arguments | Should -BeExactly @('ping', "${scheme}://localhost:8080/path")
            }
        }

        It 'retains first and maximum numeric limits sizes intervals and access indexes' {
            foreach ($value in @(1, [int]::MaxValue)) {
                $null = Get-DevTunnel -Limit $value
                $script:arguments | Should -BeExactly @('list', "--limit=$value", '--json')
                $null = Test-DevTunnel -Uri 'http://localhost/' -Size $value -Interval $value -Confirm:$false
                $script:arguments | Should -BeExactly @('ping', 'http://localhost/', "--size=$value", "--interval=$value")
                $null = Remove-DevTunnelAccess -Index $value -Confirm:$false
                $script:arguments | Should -BeExactly @('access', 'delete', "--index=$value", '--json')
            }
            $null = Add-DevTunnelAccess -Tenant -Index ([int]::MaxValue) -Confirm:$false
            $script:arguments | Should -BeExactly @('access', 'create', '--index=2147483647', '--tenant', '--json')
        }
    }
}

    Describe 'DevTunnel actual confirmation decline' {
        BeforeDiscovery {
            $declineCases = @(
                @{ Command = 'Connect-DevTunnelAccount'; Parameters = @{} },
                @{ Command = 'Disconnect-DevTunnelAccount'; Parameters = @{} },
                @{ Command = 'New-DevTunnel'; Parameters = @{ AllowAnonymous = $true } },
                @{ Command = 'Set-DevTunnel'; Parameters = @{} },
                @{ Command = 'Remove-DevTunnel'; Parameters = @{ All = $true } },
                @{ Command = 'Set-DevTunnelDefault'; Parameters = @{ TunnelId = 'my-tunnel' } },
                @{ Command = 'Clear-DevTunnelDefault'; Parameters = @{} },
                @{ Command = 'New-DevTunnelPort'; Parameters = @{ PortNumber = 1 } },
                @{ Command = 'Set-DevTunnelPort'; Parameters = @{ PortNumber = 1 } },
                @{ Command = 'Remove-DevTunnelPort'; Parameters = @{ PortNumber = 1 } },
                @{ Command = 'Add-DevTunnelAccess'; Parameters = @{ Anonymous = $true } },
                @{ Command = 'Remove-DevTunnelAccess'; Parameters = @{ Index = 0 } },
                @{ Command = 'Reset-DevTunnelAccess'; Parameters = @{} },
                @{ Command = 'New-DevTunnelToken'; Parameters = @{ Scope = 'connect' } },
                @{ Command = 'Start-DevTunnel'; Parameters = @{ AllowAnonymous = $true } },
                @{ Command = 'Connect-DevTunnel'; Parameters = @{} },
                @{ Command = 'Start-DevTunnelEcho'; Parameters = @{ PortNumber = 1 } },
                @{ Command = 'Test-DevTunnel'; Parameters = @{ Uri = 'http://localhost/' } }
            )
        }
        BeforeAll {
            if (-not ('DevTunnelTests.DeclineHost' -as [type])) {
                Add-Type -TypeDefinition @'
    using System;
    using System.Collections.Generic;
    using System.Collections.ObjectModel;
    using System.Globalization;
    using System.Management.Automation;
    using System.Management.Automation.Host;
    namespace DevTunnelTests {
        public sealed class DeclineHost : PSHost {
            readonly DeclineUI ui = new DeclineUI();
            public int Prompts => ui.Prompts;
            public override PSHostUserInterface UI => ui;
            public override string Name => "DevTunnel deterministic decline";
            public override Version Version => new Version(1,0);
            public override Guid InstanceId { get; } = Guid.NewGuid();
            public override CultureInfo CurrentCulture => CultureInfo.InvariantCulture;
            public override CultureInfo CurrentUICulture => CultureInfo.InvariantCulture;
            public override void EnterNestedPrompt() { throw new InvalidOperationException(); }
            public override void ExitNestedPrompt() { throw new InvalidOperationException(); }
            public override void NotifyBeginApplication() {}
            public override void NotifyEndApplication() {}
            public override void SetShouldExit(int exitCode) {}
        }
        public sealed class DeclineUI : PSHostUserInterface {
            public int Prompts { get; private set; }
            public override PSHostRawUserInterface RawUI => null;
            public override int PromptForChoice(string caption, string message, Collection<ChoiceDescription> choices, int defaultChoice) {
                Prompts++;
                for (int i=0; i<choices.Count; i++)
                    if (choices[i].Label.Replace("&","") == "No") return i;
                throw new InvalidOperationException("No decline choice.");
            }
            public override Dictionary<string,PSObject> Prompt(string caption,string message,Collection<FieldDescription> descriptions) { throw new InvalidOperationException(); }
            public override PSCredential PromptForCredential(string c,string m,string u,string t) { throw new InvalidOperationException(); }
            public override PSCredential PromptForCredential(string c,string m,string u,string t,PSCredentialTypes a,PSCredentialUIOptions b) { throw new InvalidOperationException(); }
            public override string ReadLine() { throw new InvalidOperationException(); }
            public override System.Security.SecureString ReadLineAsSecureString() { throw new InvalidOperationException(); }
            public override void Write(string value) {}
            public override void Write(ConsoleColor f,ConsoleColor b,string value) {}
            public override void WriteLine(string value) {}
            public override void WriteErrorLine(string value) {}
            public override void WriteDebugLine(string value) {}
            public override void WriteProgress(long id,ProgressRecord r) {}
            public override void WriteVerboseLine(string value) {}
            public override void WriteWarningLine(string value) {}
        }
    }
'@
            }
        }
        It 'declines real PowerShell confirmation without CLI calls for <Command>' -ForEach $declineCases {
            $testHost = [DevTunnelTests.DeclineHost]::new()
            $runspace = [RunspaceFactory]::CreateRunspace($testHost)
            $pipeline = [powershell]::Create()
            try {
                $runspace.Open()
                $pipeline.Runspace = $runspace
                $null = $pipeline.AddScript({
                    param($Path, $Command, $Parameters)
                    $ErrorActionPreference = 'Stop'
                    Import-Module $Path -Force
                    & (Get-Module Shmuelie.DevTunnel) {
                        function script:Resolve-DevTunnelCli { throw 'Declined operation discovered CLI.' }
                        function script:Get-DevTunnelCliVersion { throw 'Declined operation checked version.' }
                        function script:Invoke-DevTunnelProcess { throw 'Declined operation started process.' }
                        function script:Write-DevTunnelAnonymousWarning { throw 'Declined operation warned.' }
                    }
                    & $Command @Parameters -Confirm
                }).AddArgument($script:modulePath).AddArgument($Command).AddArgument($Parameters)
                @($pipeline.Invoke()).Count | Should -Be 0
                $pipeline.HadErrors | Should -BeFalse
                $pipeline.Streams.Error.Count | Should -Be 0
                $testHost.Prompts | Should -Be 1
            } finally {
                $pipeline.Dispose()
                $runspace.Dispose()
            }
        }
    }

    Describe 'DevTunnel safe native process boundary' {
        BeforeAll {
            Import-Module $script:modulePath -Force
        }
        InModuleScope Shmuelie.DevTunnel {
            BeforeAll {
                # Restore private definitions in this captured module session state,
                # not a replacement module object created by Import-Module -Force.
                $sourcePath = Join-Path (Get-Module Shmuelie.DevTunnel).ModuleBase 'PrivateHelpers.ps1'
                $script:privateAst = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$null, [ref]$null)
                foreach ($definition in $script:privateAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
                    Set-Item -Path "Function:script:$($definition.Name)" -Value $definition.Body.GetScriptBlock()
                }
                $script:pwshPath = [Environment]::ProcessPath
                $script:fakePath = Join-Path $TestDrive 'fake CLI with spaces.ps1'
                $script:manifestPath = (Get-Module Shmuelie.DevTunnel).Path -replace '\.psm1$', '.psd1'
                # Only synthetic credentials; fixture text is never expanded into names.
                $script:authFixtures = @(
                    @{ Case = 'jwt'; Text = 'session eyJhbGciOiJub25lIn0.eyJzdWIiOiJmaXh0dXJlIn0.c2lnbmF0dXJl tail'; Expected = 'session [REDACTED] tail'; Secret = 'eyJhbGciOiJub25lIn0.eyJzdWIiOiJmaXh0dXJlIn0.c2lnbmF0dXJl' }
                    @{ Case = 'github-pat'; Text = 'session ghp_FixturePersonalToken123 tail'; Expected = 'session [REDACTED] tail'; Secret = 'ghp_FixturePersonalToken123' }
                    @{ Case = 'github-oauth'; Text = 'session gho_FixtureOAuthToken123 tail'; Expected = 'session [REDACTED] tail'; Secret = 'gho_FixtureOAuthToken123' }
                    @{ Case = 'github-user'; Text = 'session ghu_FixtureUserToken123 tail'; Expected = 'session [REDACTED] tail'; Secret = 'ghu_FixtureUserToken123' }
                    @{ Case = 'github-server'; Text = 'session ghs_FixtureServerToken123 tail'; Expected = 'session [REDACTED] tail'; Secret = 'ghs_FixtureServerToken123' }
                    @{ Case = 'github-refresh'; Text = 'session ghr_FixtureRefreshToken123 tail'; Expected = 'session [REDACTED] tail'; Secret = 'ghr_FixtureRefreshToken123' }
                    @{ Case = 'github-fine-grained'; Text = 'session github_pat_Fixture_123_456 tail'; Expected = 'session [REDACTED] tail'; Secret = 'github_pat_Fixture_123_456' }
                    @{ Case = 'bearer'; Text = 'session Bearer fixtureBearer+/token== tail'; Expected = 'session Bearer [REDACTED] tail'; Secret = 'fixtureBearer+/token==' }
                    @{ Case = 'authorization'; Text = 'Authorization: Bearer fixtureAuthorizationToken'; Expected = 'Authorization: Bearer [REDACTED]'; Secret = 'fixtureAuthorizationToken' }
                    @{ Case = 'access-snake'; Text = 'access_token=fixtureAccessToken'; Expected = 'access_token=[REDACTED]'; Secret = 'fixtureAccessToken' }
                    @{ Case = 'access-camel-case'; Text = "ACCESStoken: 'fixtureQuotedAccess'"; Expected = "ACCESStoken: '[REDACTED]'"; Secret = 'fixtureQuotedAccess' }
                    @{ Case = 'refresh-hyphen'; Text = 'refresh-token = "fixtureRefreshToken"'; Expected = 'refresh-token = "[REDACTED]"'; Secret = 'fixtureRefreshToken' }
                    @{ Case = 'id-json'; Text = '{"id_token":"fixtureIdToken","status":"pending"}'; Expected = '{"id_token":"[REDACTED]","status":"pending"}'; Secret = 'fixtureIdToken' }
                    @{ Case = 'client-secret'; Text = 'clientSecret=fixtureClientSecret; state=pending'; Expected = 'clientSecret=[REDACTED]; state=pending'; Secret = 'fixtureClientSecret' }
                    @{ Case = 'multiple-fields'; Text = 'access-token=fixtureFirst, refresh_token=fixtureSecond'; Expected = 'access-token=[REDACTED], refresh_token=[REDACTED]'; Secret = 'fixtureFirst'; OtherSecret = 'fixtureSecond' }
                    @{ Case = 'ordinary-text'; Text = 'CLI diagnostic text is not a credential.'; Expected = 'CLI diagnostic text is not a credential.' }
                    @{ Case = 'intended-device-code'; Text = 'Enter code ABCD-EFGH at https://microsoft.com/devicelogin.'; Expected = 'Enter code ABCD-EFGH at https://microsoft.com/devicelogin.' }
                )
                $script:authFixturePath = Join-Path $TestDrive 'authentication fixtures.json'
                $script:authFixtures | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:authFixturePath
                Set-Content -LiteralPath $script:fakePath -Value @'
    param(
        [string]$Mode,
        [string]$StatePath,
        [string]$PwshPath,
        [Parameter(ValueFromRemainingArguments)][string[]]$Payload
    )
    $ErrorActionPreference = 'Stop'
    switch ($Mode) {
        'argv' {
            $stdin = [Console]::In.ReadToEnd()
            [ordered]@{ argv = @($Payload); stdin = $stdin; profile = [bool](Test-Path variable:global:DevTunnelProfileMarker) } | ConvertTo-Json -Compress
            exit 0
        }
        'streams' {
            for ($i = 0; $i -lt 256; $i++) {
                [Console]::Out.WriteLine("out-$i-" + ('o' * 512))
                [Console]::Error.WriteLine("err-$i-" + ('e' * 512))
            }
            exit 0
        }
        'many-lines' {
            for ($i = 0; $i -lt 1000; $i++) { [Console]::Out.WriteLine("line-$i") }
            exit 0
        }
        'instructions' {
            [Console]::Out.WriteLine('Open the browser.')
            [Console]::Error.WriteLine('Enter the displayed device code.')
            exit 0
        }
        'failure' {
            [Console]::Out.WriteLine('fixture-sensitive-stdout')
            [Console]::Error.WriteLine('fixture-sensitive-stderr')
            exit 9
        }
        'auth-failure' {
            [Console]::Out.WriteLine('Open the browser.')
            [Console]::Out.WriteLine('access_token=fixture-access-token')
            [Console]::Error.WriteLine('Enter the displayed device code.')
            [Console]::Error.WriteLine('refresh_token=fixture-refresh-token')
            exit 9
        }
        'auth-fixtures' {
            foreach ($fixture in (Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json)) {
                [Console]::Out.WriteLine($fixture.Text)
                [Console]::Error.WriteLine($fixture.Text)
            }
            exit 0
        }
        'live-auth' {
            @{ parent = $PID } | ConvertTo-Json -Compress | Set-Content -LiteralPath $StatePath
            [Console]::Out.WriteLine('Open the browser before login exits.')
            [Console]::Out.WriteLine('Bearer fixture-live-access')
            [Console]::Error.WriteLine('Enter code ABCD-EFGH before login exits.')
            [Console]::Error.WriteLine('refresh_token=fixture-live-refresh')
            [Console]::Out.Flush()
            [Console]::Error.Flush()
            $deadline = [Diagnostics.Stopwatch]::StartNew()
            while (-not (Test-Path -LiteralPath "$StatePath.ack")) {
                if ($deadline.Elapsed.TotalSeconds -ge 10) { exit 124 }
                Start-Sleep -Milliseconds 25
            }
            [Console]::Out.WriteLine('Acknowledged before exit.')
            exit ([int]$Payload[0])
        }
        'slow-stream' {
            Start-Sleep -Milliseconds 1300
            [Console]::Out.WriteLine('foreground completed without timeout')
            exit 0
        }
        'tree' {
            $child = [Diagnostics.Process]::new()
            $child.StartInfo = [Diagnostics.ProcessStartInfo]::new()
            $child.StartInfo.FileName = $PwshPath
            $child.StartInfo.UseShellExecute = $false
            foreach ($arg in @('-NoLogo','-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 60')) {
                $child.StartInfo.ArgumentList.Add($arg)
            }
            $null = $child.Start()
            @{ parent = $PID; child = $child.Id } | ConvertTo-Json -Compress | Set-Content -LiteralPath $StatePath
            try { Start-Sleep -Seconds 60 } finally { $child.Dispose() }
        }
        'wait' {
            Set-Content -LiteralPath $StatePath -Value $PID
            Start-Sleep -Seconds 60
        }
        default { throw 'Unexpected fake mode.' }
    }
'@
                function Get-FakeArguments {
                    param([string]$Mode, [string]$StatePath = 'unused', [string[]]$Payload = @())
                    @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $script:fakePath, $Mode, $StatePath, $script:pwshPath) + $Payload
                }
                function Wait-FakeState {
                    param([string]$Path)
                    $deadline = [Diagnostics.Stopwatch]::StartNew()
                    while ($deadline.Elapsed.TotalSeconds -lt 10) {
                        if (Test-Path -LiteralPath $Path) {
                            try { return Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch {}
                        }
                        Start-Sleep -Milliseconds 25
                    }
                    throw 'Owned fake did not become ready within ten seconds.'
                }
                function Test-OwnedPidAlive {
                    param([int]$OwnedPid)
                    $process = [Diagnostics.Process]::GetProcesses() | Where-Object Id -EQ $OwnedPid
                    if (-not $process) { return $false }
                    try { return -not $process.HasExited } finally { $process.Dispose() }
                }
                function Wait-OwnedPidExit {
                    param([int]$OwnedPid)
                    $deadline = [Diagnostics.Stopwatch]::StartNew()
                    while ($deadline.Elapsed.TotalSeconds -lt 5) {
                        if (-not (Test-OwnedPidAlive $OwnedPid)) { return $true }
                        Start-Sleep -Milliseconds 25
                    }
                    $false
                }
                function Stop-OwnedPid {
                    param([int]$OwnedPid)
                    if ($OwnedPid -gt 0 -and (Test-OwnedPidAlive $OwnedPid)) {
                        Stop-Process -Id $OwnedPid -Force -ErrorAction SilentlyContinue
                    }
                }
                function Start-OwnedPipeline {
                    param([string[]]$Arguments, [switch]$Stream, [switch]$Sensitive, [switch]$ObserveOutput, [int]$TimeoutSeconds = 60)
                    $pipeline = [powershell]::Create()
                    $null = $pipeline.AddScript({
                        param($Path, $Executable, $Arguments, $Stream, $Sensitive, $TimeoutSeconds)
                        $ErrorActionPreference = 'Stop'
                        Import-Module $Path -Force
                        & (Get-Module Shmuelie.DevTunnel) {
                            param($Executable, $Arguments, $Stream, $Sensitive, $TimeoutSeconds)
                            Invoke-DevTunnelProcess -FilePath $Executable -Arguments $Arguments -Stream:$Stream -Sensitive:$Sensitive -TimeoutSeconds $TimeoutSeconds
                        } $Executable $Arguments $Stream $Sensitive $TimeoutSeconds
                    }).AddArgument($script:manifestPath).AddArgument($script:pwshPath).AddArgument($Arguments).AddArgument([bool]$Stream).AddArgument([bool]$Sensitive).AddArgument($TimeoutSeconds)
                    $inputBuffer = $null
                    $outputBuffer = $null
                    if ($ObserveOutput) {
                        $inputBuffer = [Management.Automation.PSDataCollection[psobject]]::new()
                        $inputBuffer.Complete()
                        $outputBuffer = [Management.Automation.PSDataCollection[psobject]]::new()
                        $async = $pipeline.BeginInvoke[psobject, psobject]($inputBuffer, $outputBuffer)
                    } else {
                        $async = $pipeline.BeginInvoke()
                    }
                    [pscustomobject]@{ Pipeline = $pipeline; Async = $async; Input = $inputBuffer; Output = $outputBuffer }
                }
            }

            It 'passes adversarial argument tokens intact and closes standard input' {
                $fixtures = @(
                    'one two', '"quoted value"', '--description=words "quoted" & ; $(literal)',
                    '--labels=label with spaces', 'backslash\path\', '--description=', "line`nfeed", "tab`tvalue"
                )
                $arguments = Get-FakeArguments -Mode argv -Payload $fixtures
                $result = Invoke-DevTunnelProcess -FilePath $script:pwshPath -Arguments $arguments | ConvertFrom-Json
                @($result.argv) | Should -BeExactly $fixtures
                $result.stdin | Should -BeExactly ''
                $result.profile | Should -BeFalse
            }

            It 'drains large stdout and stderr concurrently without deadlock' {
                $warnings = @()
                $output = Invoke-DevTunnelProcess -FilePath $script:pwshPath -Arguments (Get-FakeArguments streams) -TimeoutSeconds 10 -WarningVariable warnings -WarningAction SilentlyContinue
                $stdoutLines = @($output.TrimEnd() -split '\r?\n')
                $stderrLines = @(([string]$warnings[0]).TrimEnd() -split '\r?\n')
                $expectedStdout = @(0..255 | ForEach-Object { "out-$_-" + ('o' * 512) })
                $expectedStderr = @(0..255 | ForEach-Object { "err-$_-" + ('e' * 512) })
                $stdoutLines | Should -BeExactly $expectedStdout
                $stderrLines | Should -BeExactly $expectedStderr
                $warnings.Count | Should -Be 1
            }

            It 'drains one thousand ready output lines within the capture timeout' {
                $output = Invoke-DevTunnelProcess -FilePath $script:pwshPath -Arguments (Get-FakeArguments many-lines) -TimeoutSeconds 5
                $lines = @($output.TrimEnd() -split '\r?\n')
                $lines.Count | Should -Be 1000
                $lines | Should -BeExactly @(0..999 | ForEach-Object { "line-$_" })
            }

            It 'streams foreground instructions as text and information rather than JSON' {
                $information = @()
                $output = @(Invoke-DevTunnelProcess -FilePath $script:pwshPath -Arguments (Get-FakeArguments instructions) -Stream -Sensitive -InformationVariable information)
                $output | Should -Be @('Open the browser.')
                @($information | ForEach-Object { [string]$_.MessageData }) | Should -Be @('Enter the displayed device code.')
            }

            It 'reports nonzero exit as an error without success output' {
                $success = [Collections.Generic.List[object]]::new()
                $failure = $null
                try {
                    Invoke-DevTunnelProcess -FilePath $script:pwshPath -Arguments (Get-FakeArguments failure) |
                        ForEach-Object { $success.Add($_) }
                } catch { $failure = $_ }
                $success.Count | Should -Be 0
                $failure.FullyQualifiedErrorId | Should -BeLike 'DevTunnelCommandFailed*'
                [string]$failure | Should -BeLike '*exit code 9*fixture-sensitive-stderr*'
                [string]$failure | Should -Not -BeLike '*fixture-sensitive-stdout*'
            }

            It 'does not echo sensitive failure content in captured mode' {
                $records = [Collections.Generic.List[object]]::new()
                try {
                    Invoke-DevTunnelProcess -FilePath $script:pwshPath -Arguments (Get-FakeArguments failure) -Sensitive *>&1 |
                        ForEach-Object { $records.Add($_) }
                } catch { $records.Add($_) }
                $records.Count | Should -Be 1
                [string]$records[0] | Should -BeLike '*exit code 9*'
                [string]$records[0] | Should -Not -BeLike '*fixture-sensitive*'
            }

            It 'does not echo sensitive failure content in streamed authentication mode' {
                $records = [Collections.Generic.List[object]]::new()
                try {
                    Invoke-DevTunnelProcess -FilePath $script:pwshPath -Arguments (Get-FakeArguments auth-failure) -Stream -Sensitive *>&1 |
                        ForEach-Object { $records.Add($_) }
                } catch { $records.Add($_) }
                # Safe instructions are irreversible; recognizable credentials
                # must be redacted before emission regardless of eventual exit.
                $stdout = @($records | Where-Object { $_ -is [string] })
                $stderr = @($records | Where-Object { $_ -is [Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData })
                $errors = @($records | Where-Object { $_ -is [Management.Automation.ErrorRecord] })
                $records.Count | Should -Be 5
                $stdout | Should -BeExactly @('Open the browser.', 'access_token=[REDACTED]')
                $stderr | Should -BeExactly @('Enter the displayed device code.', 'refresh_token=[REDACTED]')
                $errors.Count | Should -Be 1
                [string]$errors[0] | Should -BeExactly 'devtunnel failed (exit code 9).'
                $errors[0].FullyQualifiedErrorId | Should -BeLike 'DevTunnelCommandFailed*'
                ($records -join ' ') | Should -Not -Match 'fixture-access-token|fixture-refresh-token'
            }

            It 'redacts recognizable credential partitions on both sensitive streams while preserving instructions' {
                $information = @()
                $output = @(Invoke-DevTunnelProcess -FilePath $script:pwshPath -Arguments (Get-FakeArguments auth-fixtures $script:authFixturePath) -Stream -Sensitive -InformationVariable information)
                $stderr = @($information | ForEach-Object { [string]$_.MessageData })
                $expected = @($script:authFixtures | ForEach-Object { $_.Expected })
                $output | Should -BeExactly $expected
                $stderr | Should -BeExactly $expected
                foreach ($fixture in $script:authFixtures) {
                    foreach ($secret in @($fixture.Secret, $fixture.OtherSecret) | Where-Object { $_ }) {
                        ($output -join ' ') | Should -Not -Match ([regex]::Escape($secret)) -Because "stdout partition $($fixture.Case)"
                        ($stderr -join ' ') | Should -Not -Match ([regex]::Escape($secret)) -Because "stderr partition $($fixture.Case)"
                    }
                }
            }

            It 'leaves ordinary foreground streams unchanged when Sensitive is absent' {
                $information = @()
                $output = @(Invoke-DevTunnelProcess -FilePath $script:pwshPath -Arguments (Get-FakeArguments auth-fixtures $script:authFixturePath) -Stream -InformationVariable information)
                $expected = @($script:authFixtures | ForEach-Object { $_.Text })
                $output | Should -BeExactly $expected
                @($information | ForEach-Object { [string]$_.MessageData }) | Should -BeExactly $expected
            }

            It 'delivers sanitized instructions before the authentication CLI exits for <Case>' -ForEach @(
                @{ Case = 'success'; ExitCode = 0 },
                @{ Case = 'failure'; ExitCode = 9 }
            ) {
                $statePath = Join-Path $TestDrive "live-auth-$Case.json"
                $owner = $null
                $state = $null
                try {
                    $owner = Start-OwnedPipeline -Arguments (Get-FakeArguments -Mode live-auth -StatePath $statePath -Payload @([string]$ExitCode)) -Stream -Sensitive -ObserveOutput
                    $state = Wait-FakeState $statePath
                    $deadline = [Diagnostics.Stopwatch]::StartNew()
                    while ($deadline.Elapsed.TotalSeconds -lt 8 -and -not $owner.Async.IsCompleted -and
                        ($owner.Output.Count -lt 2 -or $owner.Pipeline.Streams.Information.Count -lt 2)) {
                        Start-Sleep -Milliseconds 25
                    }
                    $owner.Async.IsCompleted | Should -BeFalse
                    Test-OwnedPidAlive $state.parent | Should -BeTrue
                    $owner.Output.Count | Should -Be 2
                    $owner.Pipeline.Streams.Information.Count | Should -Be 2
                    @([string]$owner.Output[0], [string]$owner.Output[1]) | Should -BeExactly @('Open the browser before login exits.', 'Bearer [REDACTED]')
                    @([string]$owner.Pipeline.Streams.Information[0].MessageData, [string]$owner.Pipeline.Streams.Information[1].MessageData) | Should -BeExactly @('Enter code ABCD-EFGH before login exits.', 'refresh_token=[REDACTED]')
                    # A buffered implementation cannot receive this acknowledgement:
                    # assertions above require both streams while its PID is alive.
                    Set-Content -LiteralPath "$statePath.ack" -Value 'instruction delivery acknowledged'
                    $owner.Async.AsyncWaitHandle.WaitOne(5000) | Should -BeTrue
                    $failure = $null
                    try { $null = $owner.Pipeline.EndInvoke($owner.Async) } catch { $failure = $_ }
                    @($owner.Output | ForEach-Object { [string]$_ }) | Should -BeExactly @('Open the browser before login exits.', 'Bearer [REDACTED]', 'Acknowledged before exit.')
                    $owner.Pipeline.HadErrors | Should -Be ($ExitCode -ne 0)
                    if ($ExitCode -eq 0) {
                        $failure | Should -BeNullOrEmpty
                        $owner.Pipeline.Streams.Error.Count | Should -Be 0
                    } else {
                        # A terminating error from asynchronous EndInvoke is
                        # carried by InvocationStateInfo.Reason, not Error stream.
                        $failure | Should -Not -BeNullOrEmpty
                        [string]$owner.Pipeline.InvocationStateInfo.State | Should -BeExactly 'Failed'
                        $errorRecord = $owner.Pipeline.InvocationStateInfo.Reason.ErrorRecord
                        $errorRecord.Exception.Message | Should -BeExactly 'devtunnel failed (exit code 9).'
                        $errorRecord.FullyQualifiedErrorId | Should -BeLike 'DevTunnelCommandFailed*'
                    }
                    Wait-OwnedPidExit $state.parent | Should -BeTrue
                } finally {
                    if ($owner) {
                        $owner.Pipeline.Stop()
                        $owner.Pipeline.Dispose()
                        if ($null -ne $owner.Input) { $owner.Input.Dispose() }
                        if ($null -ne $owner.Output) { $owner.Output.Dispose() }
                    }
                    if ($state) { Stop-OwnedPid $state.parent }
                }
            }

            It 'suppresses sensitive stderr warnings while preserving successful stdout' {
                $warnings = @()
                $output = Invoke-DevTunnelProcess -FilePath $script:pwshPath -Arguments (Get-FakeArguments instructions) -Sensitive -WarningVariable warnings
                $output.TrimEnd() | Should -BeExactly 'Open the browser.'
                $warnings.Count | Should -Be 0
            }

            It 'uses a sixty second default timeout and rejects invalid timeout values' {
                $definition = $script:privateAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-DevTunnelProcess' }, $false)
                $parameter = $definition.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'TimeoutSeconds' }
                $parameter.DefaultValue.Value | Should -Be 60
                { Invoke-DevTunnelProcess -FilePath $script:pwshPath -Arguments @('-NoProfile') -TimeoutSeconds 0 } | Should -Throw
                { Invoke-DevTunnelProcess -FilePath $script:pwshPath -Arguments @('-NoProfile') -TimeoutSeconds 3601 } | Should -Throw
            }

            It 'does not apply the capture timeout to foreground stream mode' {
                $output = Invoke-DevTunnelProcess -FilePath $script:pwshPath -Arguments (Get-FakeArguments slow-stream) -Stream -TimeoutSeconds 1
                $output | Should -BeExactly 'foreground completed without timeout'
            }

            It 'rejects null characters before starting the executable' {
                { Invoke-DevTunnelProcess -FilePath (Join-Path $TestDrive 'never-exists.exe') -Arguments @("invalid`0argument") } |
                    Should -Throw '*arguments cannot contain null characters*'
            }

            It 'kills its owned process after a custom capture timeout' {
                $statePath = Join-Path $TestDrive 'timeout-owned.json'
                $owner = $null
                $state = $null
                try {
                    # Starting in a runspace lets readiness be observed without timing
                    # assertions. No fake binds ports or executes devtunnel.
                    $owner = Start-OwnedPipeline -Arguments (Get-FakeArguments wait $statePath) -TimeoutSeconds 1
                    $state = Wait-FakeState $statePath
                    [int]$state | Should -BeGreaterThan 0
                    $owner.Async.AsyncWaitHandle.WaitOne(10000) | Should -BeTrue
                    $failure = $null
                    try { $null = $owner.Pipeline.EndInvoke($owner.Async) } catch { $failure = $_ }
                    $diagnostic = @([string]$failure) + @($owner.Pipeline.Streams.Error | ForEach-Object { [string]$_ })
                    ($diagnostic -join ' ') | Should -BeLike '*timed out after 1 seconds*'
                    Wait-OwnedPidExit $state | Should -BeTrue
                } finally {
                    if ($owner) { $owner.Pipeline.Stop(); $owner.Pipeline.Dispose() }
                    if ($state) { Stop-OwnedPid $state }
                }
            }

            It 'stops only the owned tree on runspace cancellation and preserves an unrelated sentinel' {
                $sentinel = [Diagnostics.Process]::new()
                $sentinel.StartInfo = [Diagnostics.ProcessStartInfo]::new()
                $sentinel.StartInfo.FileName = $script:pwshPath
                $sentinel.StartInfo.UseShellExecute = $false
                $sentinelState = Join-Path $TestDrive 'sentinel.json'
                foreach ($argument in (Get-FakeArguments wait $sentinelState)) { $sentinel.StartInfo.ArgumentList.Add($argument) }
                $owner = $null
                $state = $null
                try {
                    $sentinel.Start() | Should -BeTrue
                    $sentinelPid = Wait-FakeState $sentinelState
                    [int]$sentinelPid | Should -Be $sentinel.Id
                    $statePath = Join-Path $TestDrive 'cancel-owned.json'
                    $owner = Start-OwnedPipeline -Arguments (Get-FakeArguments tree $statePath) -Stream
                    $state = Wait-FakeState $statePath
                    Test-OwnedPidAlive $state.parent | Should -BeTrue
                    Test-OwnedPidAlive $state.child | Should -BeTrue
                    $owner.Pipeline.Stop()
                    $owner.Async.AsyncWaitHandle.WaitOne(5000) | Should -BeTrue
                    [string]$owner.Pipeline.InvocationStateInfo.State | Should -BeExactly 'Stopped'
                    Wait-OwnedPidExit $state.parent | Should -BeTrue
                    Wait-OwnedPidExit $state.child | Should -BeTrue
                    $sentinel.HasExited | Should -BeFalse
                } finally {
                    if ($owner) { $owner.Pipeline.Stop(); $owner.Pipeline.Dispose() }
                    if ($state) { Stop-OwnedPid $state.child; Stop-OwnedPid $state.parent }
                    if (-not $sentinel.HasExited) { $sentinel.Kill($true); $sentinel.WaitForExit() }
                    $sentinel.Dispose()
                }
            }

            It 'pins ArgumentList asynchronous reads and disposal in the clean block' {
                $ast = $script:privateAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-DevTunnelProcess' }, $false).Body
                $ast.CleanBlock | Should -Not -BeNullOrEmpty
                $source = $ast.Extent.Text
                $source | Should -Match '\.ArgumentList\.Add\(\$argument\)'
                $source | Should -Match '\.StandardOutput\.ReadLineAsync\(\)'
                $source | Should -Match '\.StandardError\.ReadLineAsync\(\)'
                $source | Should -Match '\.StandardInput\.Close\(\)'
                $ast.CleanBlock.Extent.Text | Should -Match '\.Kill\(\$true\)'
                $ast.CleanBlock.Extent.Text | Should -Match 'finally\s*\{\s*\$process\.Dispose\(\)'
            }
        }
    }
Describe 'DevTunnel CLI resolution version and JSON boundary' {
    BeforeAll {
        # Restore real helpers after wrapper containers mocked these functions.
        Import-Module $script:modulePath -Force
    }
    InModuleScope Shmuelie.DevTunnel {
        BeforeAll {
            $sourcePath = Join-Path (Get-Module Shmuelie.DevTunnel).ModuleBase 'PrivateHelpers.ps1'
            $ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$null, [ref]$null)
            foreach ($definition in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
                Set-Item -Path "Function:script:$($definition.Name)" -Value $definition.Body.GetScriptBlock()
            }
        }
        BeforeEach {
            Mock Get-Command { throw 'Unexpected discovery; no fallback to real commands.' }
            Mock Invoke-DevTunnelProcess { throw 'Unexpected process; no real CLI allowed.' }
        }

        It 'discovers only native applications and returns their path' {
            Mock Get-Command { [pscustomobject]@{ Source = 'synthetic-devtunnel.exe' } }
            Resolve-DevTunnelCli | Should -BeExactly 'synthetic-devtunnel.exe'
            Should -Invoke Get-Command -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'devtunnel' -and $CommandType -eq 'Application' -and $ErrorAction -eq 'SilentlyContinue'
            }
        }

        It 'reports actionable missing dependency without starting a process' {
            Mock Get-Command { $null }
            { Resolve-DevTunnelCli } | Should -Throw '*not found on PATH*Install*'
            Should -Invoke Invoke-DevTunnelProcess -Times 0 -Exactly
        }

        It 'rejects Windows command shims before starting a process for <Case>' -Skip:(-not $IsWindows) -ForEach @(
            @{ Case = 'cmd'; Path = 'synthetic-devtunnel.cmd' },
            @{ Case = 'bat'; Path = 'synthetic-devtunnel.bat' },
            @{ Case = 'script'; Path = 'synthetic-devtunnel.ps1' }
        ) {
            Mock Get-Command { [pscustomobject]@{ Source = $Path } }
            { Resolve-DevTunnelCli } | Should -Throw '*native .exe*command shim*'
            Should -Invoke Invoke-DevTunnelProcess -Times 0 -Exactly
        }

        It 'uses file metadata without executing a version command' {
            $path = [Management.Automation.PSObject].Assembly.Location
            $metadata = [Diagnostics.FileVersionInfo]::GetVersionInfo($path).ProductVersion
            $metadata | Should -Not -BeNullOrEmpty
            # PowerShell's managed PE has version metadata even when pwsh is ELF.
            { Get-DevTunnelCliVersion -FilePath $path } | Should -Throw '*Unsupported devtunnel CLI version*'
            Should -Invoke Invoke-DevTunnelProcess -Times 0 -Exactly
        }

        It 'accepts supported product metadata without a version subprocess' {
            # A TestDrive-only PE resource fixture; never execute this copy.
            # Copy the loaded managed PE, not the native host (ELF on Linux).
            $path = Join-Path $TestDrive 'metadata-only-never-run.dll'
            $sourcePath = [Management.Automation.PSObject].Assembly.Location
            $original = [Diagnostics.FileVersionInfo]::GetVersionInfo($sourcePath).ProductVersion
            $bytes = [IO.File]::ReadAllBytes($sourcePath)
            $text = [Text.Encoding]::Unicode.GetString($bytes)
            $original.Length | Should -BeGreaterOrEqual 8
            $replacement = [Text.Encoding]::Unicode.GetBytes('1.0.2115'.PadRight($original.Length, [char]0))
            $offset = $text.IndexOf($original, [StringComparison]::Ordinal)
            $offset | Should -BeGreaterOrEqual 0
            while ($offset -ge 0) {
                [array]::Copy($replacement, 0, $bytes, $offset * 2, $replacement.Length)
                $offset = $text.IndexOf($original, $offset + $original.Length, [StringComparison]::Ordinal)
            }
            # Unix FileVersionInfo reads the UTF-8 informational-version
            # attribute, not the UTF-16 Win32 resource. Patch its serialized
            # string length too; NUL padding alone would change the assertion.
            $utf8 = [Text.Encoding]::UTF8.GetBytes($original)
            $utf8.Length | Should -BeLessThan 128
            [byte[]]$originalAttribute = @(1, 0, [byte]$utf8.Length) + $utf8 + @(0, 0)
            $binaryText = [Text.Encoding]::Latin1.GetString($bytes)
            $attributeOffset = $binaryText.IndexOf([Text.Encoding]::Latin1.GetString($originalAttribute), [StringComparison]::Ordinal)
            $attributeOffset | Should -BeGreaterOrEqual 0
            [byte[]]$replacementAttribute = @(1, 0, 8) + [Text.Encoding]::UTF8.GetBytes('1.0.2115') + @(0, 0)
            [array]::Copy($replacementAttribute, 0, $bytes, $attributeOffset, $replacementAttribute.Length)
            [IO.File]::WriteAllBytes($path, $bytes)
            [Diagnostics.FileVersionInfo]::GetVersionInfo($path).ProductVersion | Should -BeExactly '1.0.2115'
            Get-DevTunnelCliVersion -FilePath $path | Should -Be ([version]'1.0.2115')
            Should -Invoke Invoke-DevTunnelProcess -Times 0 -Exactly
        }

        It 'validates fallback version partition <Case>' -ForEach @(
            @{ Case = 'minimum'; Text = '1.0.2115'; Expected = '1.0.2115'; Valid = $true },
            @{ Case = 'banner'; Text = 'Tunnel CLI version: 1.0.2115'; Expected = '1.0.2115'; Valid = $true },
            @{ Case = 'newer-minor'; Text = '1.1.1+build'; Expected = '1.1.1'; Valid = $true },
            @{ Case = 'newer-build'; Text = '1.0.9999-preview'; Expected = '1.0.9999'; Valid = $true },
            @{ Case = 'old'; Text = '1.0.2114' }, @{ Case = 'new-major'; Text = '2.0.2115' },
            @{ Case = 'zero-major'; Text = '0.9.9999' }, @{ Case = 'invalid'; Text = 'not a version' },
            @{ Case = 'empty'; Text = '' }, @{ Case = 'incomplete'; Text = '1.0' }
        ) {
            $path = Join-Path $TestDrive 'metadata-free.exe'
            Set-Content -LiteralPath $path -Value 'fake executable only; never started'
            Mock Invoke-DevTunnelProcess { $Text }
            if ($Valid) { Get-DevTunnelCliVersion -FilePath $path | Should -Be ([version]$Expected) }
            else { { Get-DevTunnelCliVersion -FilePath $path } | Should -Throw '*devtunnel CLI version*' }
            Should -Invoke Invoke-DevTunnelProcess -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq $path -and $Arguments.Count -eq 1 -and $Arguments[0] -eq '--version' -and -not $Stream
            }
        }
    }

}

Describe 'DevTunnel JSON command boundary' {
    InModuleScope Shmuelie.DevTunnel {
        BeforeEach {
            Mock Resolve-DevTunnelCli { 'synthetic-devtunnel.exe' }
            Mock Get-DevTunnelCliVersion { [version]'1.0.2115' }
            Mock Invoke-DevTunnelProcess { throw 'No unspecified process output permitted.' }
        }

        It 'preserves raw JSON envelopes and nested arrays without flattening' {
            Mock Invoke-DevTunnelProcess { '{"value":[{"id":"one"},{"id":"two"}],"count":2,"nextLink":"next","empty":[],"metadata":{"region":"local"}}' }
            $result = @(Invoke-DevTunnelCommand -Arguments list, --json)
            $result.Count | Should -Be 1
            @($result[0].value.id) | Should -Be @('one', 'two')
            $result[0].count | Should -Be 2
            $result[0].nextLink | Should -BeExactly 'next'
            @($result[0].empty).Count | Should -Be 0
            $result[0].metadata.region | Should -BeExactly 'local'
        }

        It 'returns no objects for empty CLI output partition <Case>' -ForEach @(
            @{ Case = 'empty'; Text = '' }, @{ Case = 'whitespace'; Text = " `r`n`t" }
        ) {
            Mock Invoke-DevTunnelProcess { $Text }
            @(Invoke-DevTunnelCommand -Arguments list, --json).Count | Should -Be 0
        }

        It 'sanitizes malformed JSON without echoing sensitive content' {
            Mock Invoke-DevTunnelProcess { 'fixture-secret-invalid-json' }
            $captured = [Collections.Generic.List[object]]::new()
            try { Invoke-DevTunnelCommand -Arguments token, --json -Sensitive *>&1 | ForEach-Object { $captured.Add($_) } }
            catch { $captured.Add($_) }
            $captured.Count | Should -Be 1
            [string]$captured[0] | Should -BeLike '*returned invalid JSON*'
            [string]$captured[0] | Should -Not -BeLike '*fixture-secret*'
        }

        It 'propagates process failure with no success output' {
            Mock Invoke-DevTunnelProcess { throw 'synthetic exit code 9' }
            $success = [Collections.Generic.List[object]]::new()
            { Invoke-DevTunnelCommand -Arguments list, --json | ForEach-Object { $success.Add($_) } } | Should -Throw '*exit code 9*'
            $success.Count | Should -Be 0
        }

        It 'stops before the runner when CLI version validation fails' {
            Mock Get-DevTunnelCliVersion { throw 'Unsupported devtunnel CLI version 2.0.0.' }
            { Invoke-DevTunnelCommand -Arguments list, --json } | Should -Throw '*Unsupported*'
            Should -Invoke Invoke-DevTunnelProcess -Times 0 -Exactly
        }
    }
}
