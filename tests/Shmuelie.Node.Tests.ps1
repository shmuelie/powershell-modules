#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.2.0' }

BeforeAll {
    $repoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent
    $script:ModuleManifest = [System.IO.Path]::Combine($repoRoot, 'modules', 'Shmuelie.Node', 'Shmuelie.Node.psd1')
    Import-Module $script:ModuleManifest -Force

    # Provide a stub so 'nvm' is mockable on machines where nvm is not installed
    # (e.g. CI). Without an existing command, Pester's Mock throws
    # CommandNotFoundException. The stub also shadows any real nvm for determinism.
    function global:nvm { }
    function global:npm { }

    function ConvertTo-SingleQuotedLiteral {
        param([Parameter(Mandatory)][string]$Value)

        "'" + ($Value -replace "'", "''") + "'"
    }
}

AfterAll {
    Remove-Item -Path Function:\nvm -ErrorAction SilentlyContinue
    Remove-Item -Path Function:\npm -ErrorAction SilentlyContinue
    Remove-Module Shmuelie.Node -Force -ErrorAction SilentlyContinue
}

Describe 'Get-NvmRoot' {
    BeforeEach {
        Mock -CommandName Test-IsWindowsPlatform -ModuleName Shmuelie.Node -MockWith { $true }
        Mock -CommandName nvm -ModuleName Shmuelie.Node -MockWith {
            if ($args.Count -eq 1 -and $args[0] -eq 'root') {
                'C:\nvm'
            }
        }
    }

    It 'does not set the root when WhatIf is specified and reports the action' {
        $path = Join-Path $TestDrive 'nvm-root'

        Get-NvmRoot -Path $path -WhatIf

        Should -Invoke -CommandName nvm -ModuleName Shmuelie.Node -Times 0 -Exactly -ParameterFilter {
            $args.Count -eq 2 -and $args[0] -eq 'root' -and $args[1] -eq $path
        }

        $whatIfScript = @"
Import-Module $(ConvertTo-SingleQuotedLiteral $script:ModuleManifest) -Force
Get-NvmRoot -Path $(ConvertTo-SingleQuotedLiteral $path) -WhatIf
"@
        $whatIfOutput = & (Get-Process -Id $PID).Path -NoLogo -NoProfile -NonInteractive -Command $whatIfScript 2>&1
        ($whatIfOutput | Out-String) | Should -Match ([regex]::Escape("Set to '$path'"))
    }

    It 'sets the root when confirmed' {
        $path = Join-Path $TestDrive 'nvm-root'

        Get-NvmRoot -Path $path -Confirm:$false

        Should -Invoke -CommandName nvm -ModuleName Shmuelie.Node -Times 1 -Exactly -ParameterFilter {
            $args.Count -eq 2 -and $args[0] -eq 'root' -and $args[1] -eq $path
        }
    }

    It 'reads the current root without ShouldProcess gating' {
        Get-NvmRoot | Should -BeExactly 'C:\nvm'

        Should -Invoke -CommandName nvm -ModuleName Shmuelie.Node -Times 1 -Exactly -ParameterFilter {
            $args.Count -eq 1 -and $args[0] -eq 'root'
        }
    }
}

Describe 'Get-NpmPackage' {
    BeforeAll {
        $listJson = @'
{
  "dependencies": {
    "typescript": {
      "version": "5.9.2",
      "description": "TypeScript is a language for application-scale JavaScript"
    },
    "@scope/tool": {
      "version": "1.2.3"
    }
  }
}
'@

        $outdatedJson = @'
{
  "typescript": {
    "current": "5.8.3",
    "wanted": "5.9.2",
    "latest": "5.9.2"
  },
  "@scope/tool": {
    "current": "1.0.0",
    "wanted": "1.5.0",
    "latest": "2.0.0"
  }
}
'@
    }

    BeforeEach {
        $script:NpmOutput = $null
        Mock -CommandName npm -ModuleName Shmuelie.Node -MockWith { $script:NpmOutput }
    }

    It 'parses packages from clean npm list JSON' {
        $script:NpmOutput = $listJson

        $packages = @(Get-NpmPackage)

        $packages | Should -HaveCount 2
        $packages[0].PSTypeNames[0] | Should -BeExactly 'NpmPackage'
        $packages[0].Name | Should -BeExactly 'typescript'
        $packages[0].Version | Should -BeExactly '5.9.2'
        $packages[0].Description | Should -BeExactly 'TypeScript is a language for application-scale JavaScript'
        $packages[0].Global | Should -BeFalse
        $packages[1].Name | Should -BeExactly '@scope/tool'
        $packages[1].Version | Should -BeExactly '1.2.3'

        Should -Invoke -CommandName npm -ModuleName Shmuelie.Node -Times 1 -Exactly -ParameterFilter {
            $args.Count -eq 3 -and $args[0] -eq 'list' -and $args[1] -eq '--json' -and $args[2] -eq '--depth=0'
        }
    }

    It 'parses packages when npm list JSON is surrounded by stdout warnings' {
        $script:NpmOutput = @"
npm warn config global ``--global``, ``--local`` are deprecated
$listJson
npm warn deprecated left-pad@1.3.0: use String.prototype.padStart()
"@

        $packages = @(Get-NpmPackage -Global)

        $packages | Should -HaveCount 2
        $packages[0].Name | Should -BeExactly 'typescript'
        $packages[0].Version | Should -BeExactly '5.9.2'
        $packages[0].Global | Should -BeTrue
        $packages[1].Name | Should -BeExactly '@scope/tool'

        Should -Invoke -CommandName npm -ModuleName Shmuelie.Node -Times 1 -Exactly -ParameterFilter {
            $args.Count -eq 4 -and $args[0] -eq 'list' -and $args[1] -eq '--json' -and $args[2] -eq '--depth=0' -and $args[3] -eq '--global'
        }
    }

    It 'returns no packages for empty npm list output' -ForEach @(
        @{ Output = '' }
        @{ Output = '{}' }
    ) {
        $script:NpmOutput = $Output

        @(Get-NpmPackage) | Should -HaveCount 0
    }

    It 'parses packages from clean npm outdated JSON' {
        $script:NpmOutput = $outdatedJson

        $packages = @(Get-NpmPackage -Outdated)

        $packages | Should -HaveCount 2
        $packages[0].PSTypeNames[0] | Should -BeExactly 'NpmPackage'
        $packages[0].Name | Should -BeExactly 'typescript'
        $packages[0].Version | Should -BeExactly '5.8.3'
        $packages[0].Latest | Should -BeExactly '5.9.2'
        $packages[0].Global | Should -BeFalse
        $packages[1].Name | Should -BeExactly '@scope/tool'
        $packages[1].Version | Should -BeExactly '1.0.0'
        $packages[1].Latest | Should -BeExactly '2.0.0'

        Should -Invoke -CommandName npm -ModuleName Shmuelie.Node -Times 1 -Exactly -ParameterFilter {
            $args.Count -eq 2 -and $args[0] -eq 'outdated' -and $args[1] -eq '--json'
        }
    }

    It 'parses packages when npm outdated JSON is surrounded by stdout warnings' {
        $script:NpmOutput = @"
npm warn config global ``--global``, ``--local`` are deprecated
$outdatedJson
npm warn deprecated request@2.88.2: request has been deprecated
"@

        $packages = @(Get-NpmPackage -Outdated -Global)

        $packages | Should -HaveCount 2
        $packages[0].Name | Should -BeExactly 'typescript'
        $packages[0].Version | Should -BeExactly '5.8.3'
        $packages[0].Latest | Should -BeExactly '5.9.2'
        $packages[0].Global | Should -BeTrue
        $packages[1].Name | Should -BeExactly '@scope/tool'

        Should -Invoke -CommandName npm -ModuleName Shmuelie.Node -Times 1 -Exactly -ParameterFilter {
            $args.Count -eq 3 -and $args[0] -eq 'outdated' -and $args[1] -eq '--json' -and $args[2] -eq '--global'
        }
    }

    It 'returns no packages for empty npm outdated output' -ForEach @(
        @{ Output = '' }
        @{ Output = '{}' }
    ) {
        $script:NpmOutput = $Output

        @(Get-NpmPackage -Outdated) | Should -HaveCount 0
    }
}

Describe 'nvm wrapper cmdlets' {
    BeforeEach {
        $script:NvmOutput = $null
        Mock -CommandName Test-IsWindowsPlatform -ModuleName Shmuelie.Node -MockWith { $true }
        Mock -CommandName nvm -ModuleName Shmuelie.Node -MockWith { $script:NvmOutput }
    }

    It 'throws a Windows-only error before invoking nvm for <Name>' -ForEach @(
        @{ Name = 'Get-NodeVersion'; Command = 'Get-NodeVersion'; Parameters = @{} }
        @{ Name = 'Get-NodeVersion -Current'; Command = 'Get-NodeVersion'; Parameters = @{ Current = $true }; ExpectedCommand = 'Get-NodeVersion' }
        @{ Name = 'Get-NodeVersion -Available'; Command = 'Get-NodeVersion'; Parameters = @{ Available = $true }; ExpectedCommand = 'Get-NodeVersion' }
        @{ Name = 'Install-NodeVersion'; Command = 'Install-NodeVersion'; Parameters = @{ Version = '20.11.1'; Architecture = '64'; Confirm = $false } }
        @{ Name = 'Uninstall-NodeVersion'; Command = 'Uninstall-NodeVersion'; Parameters = @{ Version = '18.19.1'; Confirm = $false } }
        @{ Name = 'Set-NodeVersion'; Command = 'Set-NodeVersion'; Parameters = @{ Version = '20.11.1'; Architecture = '64'; Confirm = $false } }
        @{ Name = 'Set-NodeVersion -Latest'; Command = 'Set-NodeVersion'; Parameters = @{ Latest = $true; Confirm = $false }; ExpectedCommand = 'Set-NodeVersion' }
        @{ Name = 'Set-NodeAlias'; Command = 'Set-NodeAlias'; Parameters = @{ Name = 'default'; Version = '20.11.1'; Confirm = $false } }
        @{ Name = 'Remove-NodeAlias'; Command = 'Remove-NodeAlias'; Parameters = @{ Name = 'default'; Confirm = $false } }
        @{ Name = 'Enable-Nvm'; Command = 'Enable-Nvm'; Parameters = @{ Confirm = $false } }
        @{ Name = 'Disable-Nvm'; Command = 'Disable-Nvm'; Parameters = @{ Confirm = $false } }
        @{ Name = 'Set-NvmProxy'; Command = 'Set-NvmProxy'; Parameters = @{ Url = 'http://proxy.example:8080'; Confirm = $false } }
        @{ Name = 'Set-NvmProxy -Read'; Command = 'Set-NvmProxy'; Parameters = @{}; ExpectedCommand = 'Set-NvmProxy' }
        @{ Name = 'Set-NvmNodeMirror'; Command = 'Set-NvmNodeMirror'; Parameters = @{ Url = 'https://nodejs.example/dist/'; Confirm = $false } }
        @{ Name = 'Set-NvmNodeMirror -Read'; Command = 'Set-NvmNodeMirror'; Parameters = @{}; ExpectedCommand = 'Set-NvmNodeMirror' }
        @{ Name = 'Set-NvmNpmMirror'; Command = 'Set-NvmNpmMirror'; Parameters = @{ Url = 'https://npm.example/cli/'; Confirm = $false } }
        @{ Name = 'Set-NvmNpmMirror -Read'; Command = 'Set-NvmNpmMirror'; Parameters = @{}; ExpectedCommand = 'Set-NvmNpmMirror' }
        @{ Name = 'Get-NvmRoot'; Command = 'Get-NvmRoot'; Parameters = @{} }
        @{ Name = 'Get-NvmRoot -Path'; Command = 'Get-NvmRoot'; Parameters = @{ Path = 'C:\nvm'; Confirm = $false }; ExpectedCommand = 'Get-NvmRoot' }
        @{ Name = 'Get-NvmVersion'; Command = 'Get-NvmVersion'; Parameters = @{} }
        @{ Name = 'Test-NvmInstalled'; Command = 'Test-NvmInstalled'; Parameters = @{} }
    ) {
        $expectedCommand = if ($ExpectedCommand) { $ExpectedCommand } else { $Command }

        InModuleScope Shmuelie.Node -Parameters @{
            Command = $Command
            CommandParameters = $Parameters
            ExpectedCommand = $expectedCommand
        } {
            param($Command, $CommandParameters, $ExpectedCommand)

            Mock -CommandName Test-IsWindowsPlatform -MockWith { $false }
            Mock -CommandName nvm -MockWith { throw 'nvm should not be invoked' }
            Mock -CommandName Get-Command -MockWith { throw 'Get-Command should not be invoked' }

            { & $Command @CommandParameters } | Should -Throw -ExpectedMessage "$ExpectedCommand is only supported on Windows (nvm-windows)."

            Should -Invoke -CommandName nvm -Times 0 -Exactly
            Should -Invoke -CommandName Get-Command -Times 0 -Exactly
        }
    }

    It 'gets installed Node.js versions' {
        $script:NvmOutput = @('  * 20.11.1 (Currently using 64-bit executable)', '    18.19.1')

        Get-NodeVersion | Should -Be $script:NvmOutput

        Should -Invoke -CommandName nvm -ModuleName Shmuelie.Node -Times 1 -Exactly -ParameterFilter {
            $args.Count -eq 1 -and $args[0] -eq 'list'
        }
    }

    It 'gets the current Node.js version' {
        $script:NvmOutput = 'v20.11.1'

        Get-NodeVersion -Current | Should -BeExactly 'v20.11.1'

        Should -Invoke -CommandName nvm -ModuleName Shmuelie.Node -Times 1 -Exactly -ParameterFilter {
            $args.Count -eq 1 -and $args[0] -eq 'current'
        }
    }

    It 'gets available Node.js versions' {
        $script:NvmOutput = @('20.11.1', '18.19.1')

        Get-NodeVersion -Available | Should -Be $script:NvmOutput

        Should -Invoke -CommandName nvm -ModuleName Shmuelie.Node -Times 1 -Exactly -ParameterFilter {
            $args.Count -eq 2 -and $args[0] -eq 'list' -and $args[1] -eq 'available'
        }
    }

    It 'gets the nvm version' {
        $script:NvmOutput = '1.1.12'

        Get-NvmVersion | Should -BeExactly '1.1.12'

        Should -Invoke -CommandName nvm -ModuleName Shmuelie.Node -Times 1 -Exactly -ParameterFilter {
            $args.Count -eq 1 -and $args[0] -eq 'version'
        }
    }

    It 'reports that nvm is installed when the command is available' {
        Test-NvmInstalled | Should -BeTrue
    }

    It 'reports that nvm is not installed when the command is unavailable' {
        Mock -CommandName Get-Command -ModuleName Shmuelie.Node -MockWith {
            throw [System.Management.Automation.CommandNotFoundException]::new('nvm')
        }

        Test-NvmInstalled -WarningAction SilentlyContinue | Should -BeFalse
    }

    It 'invokes the expected nvm arguments for <Name>' -ForEach @(
        @{ Name = 'Install-NodeVersion'; Command = 'Install-NodeVersion'; Parameters = @{ Version = '20.11.1'; Architecture = '64'; Confirm = $false }; ExpectedArgs = @('install', '20.11.1', '64') }
        @{ Name = 'Uninstall-NodeVersion'; Command = 'Uninstall-NodeVersion'; Parameters = @{ Version = '18.19.1'; Confirm = $false }; ExpectedArgs = @('uninstall', '18.19.1') }
        @{ Name = 'Set-NodeVersion'; Command = 'Set-NodeVersion'; Parameters = @{ Version = '20.11.1'; Architecture = '64'; Confirm = $false }; ExpectedArgs = @('use', '20.11.1', '64') }
        @{ Name = 'Set-NodeVersion -Latest'; Command = 'Set-NodeVersion'; Parameters = @{ Latest = $true; Confirm = $false }; ExpectedArgs = @('use', 'newest') }
        @{ Name = 'Set-NodeAlias'; Command = 'Set-NodeAlias'; Parameters = @{ Name = 'default'; Version = '20.11.1'; Confirm = $false }; ExpectedArgs = @('alias', 'default', '20.11.1') }
        @{ Name = 'Remove-NodeAlias'; Command = 'Remove-NodeAlias'; Parameters = @{ Name = 'default'; Confirm = $false }; ExpectedArgs = @('unalias', 'default') }
        @{ Name = 'Enable-Nvm'; Command = 'Enable-Nvm'; Parameters = @{ Confirm = $false }; ExpectedArgs = @('on') }
        @{ Name = 'Disable-Nvm'; Command = 'Disable-Nvm'; Parameters = @{ Confirm = $false }; ExpectedArgs = @('off') }
        @{ Name = 'Set-NvmProxy'; Command = 'Set-NvmProxy'; Parameters = @{ Url = 'http://proxy.example:8080'; Confirm = $false }; ExpectedArgs = @('proxy', 'http://proxy.example:8080') }
        @{ Name = 'Set-NvmNodeMirror'; Command = 'Set-NvmNodeMirror'; Parameters = @{ Url = 'https://nodejs.example/dist/'; Confirm = $false }; ExpectedArgs = @('node_mirror', 'https://nodejs.example/dist/') }
        @{ Name = 'Set-NvmNpmMirror'; Command = 'Set-NvmNpmMirror'; Parameters = @{ Url = 'https://npm.example/cli/'; Confirm = $false }; ExpectedArgs = @('npm_mirror', 'https://npm.example/cli/') }
    ) {
        $expectedArgs = $ExpectedArgs

        & $Command @Parameters

        Should -Invoke -CommandName nvm -ModuleName Shmuelie.Node -Times 1 -Exactly -ParameterFilter {
            $args.Count -eq $expectedArgs.Count -and (Compare-Object -ReferenceObject $expectedArgs -DifferenceObject $args -SyncWindow 0).Count -eq 0
        }
    }

    It 'does not invoke nvm for WhatIf on <Name>' -ForEach @(
        @{ Name = 'Install-NodeVersion'; Command = 'Install-NodeVersion'; Parameters = @{ Version = '20.11.1'; WhatIf = $true } }
        @{ Name = 'Uninstall-NodeVersion'; Command = 'Uninstall-NodeVersion'; Parameters = @{ Version = '18.19.1'; WhatIf = $true } }
        @{ Name = 'Set-NodeVersion'; Command = 'Set-NodeVersion'; Parameters = @{ Version = '20.11.1'; WhatIf = $true } }
        @{ Name = 'Set-NodeVersion -Latest'; Command = 'Set-NodeVersion'; Parameters = @{ Latest = $true; WhatIf = $true } }
        @{ Name = 'Set-NodeAlias'; Command = 'Set-NodeAlias'; Parameters = @{ Name = 'default'; Version = '20.11.1'; WhatIf = $true } }
        @{ Name = 'Remove-NodeAlias'; Command = 'Remove-NodeAlias'; Parameters = @{ Name = 'default'; WhatIf = $true } }
        @{ Name = 'Enable-Nvm'; Command = 'Enable-Nvm'; Parameters = @{ WhatIf = $true } }
        @{ Name = 'Disable-Nvm'; Command = 'Disable-Nvm'; Parameters = @{ WhatIf = $true } }
        @{ Name = 'Set-NvmProxy'; Command = 'Set-NvmProxy'; Parameters = @{ Url = 'http://proxy.example:8080'; WhatIf = $true } }
        @{ Name = 'Set-NvmNodeMirror'; Command = 'Set-NvmNodeMirror'; Parameters = @{ Url = 'https://nodejs.example/dist/'; WhatIf = $true } }
        @{ Name = 'Set-NvmNpmMirror'; Command = 'Set-NvmNpmMirror'; Parameters = @{ Url = 'https://npm.example/cli/'; WhatIf = $true } }
    ) {
        & $Command @Parameters

        Should -Invoke -CommandName nvm -ModuleName Shmuelie.Node -Times 0 -Exactly
    }

    It 'reads nvm proxy and mirror values without ShouldProcess gating' -ForEach @(
        @{ Command = 'Set-NvmProxy'; ExpectedArgs = @('proxy'); Output = 'none' }
        @{ Command = 'Set-NvmNodeMirror'; ExpectedArgs = @('node_mirror'); Output = 'https://nodejs.org/dist/' }
        @{ Command = 'Set-NvmNpmMirror'; ExpectedArgs = @('npm_mirror'); Output = 'https://github.com/npm/cli/archive/' }
    ) {
        $script:NvmOutput = $Output
        $expectedArgs = $ExpectedArgs

        & $Command | Should -BeExactly $Output

        Should -Invoke -CommandName nvm -ModuleName Shmuelie.Node -Times 1 -Exactly -ParameterFilter {
            $args.Count -eq $expectedArgs.Count -and (Compare-Object -ReferenceObject $expectedArgs -DifferenceObject $args -SyncWindow 0).Count -eq 0
        }
    }
}

Describe 'Update-AdoNpmToken' {
    BeforeAll {
        function global:node { }
    }

    AfterAll {
        Remove-Item -Path Function:\node -ErrorAction SilentlyContinue
    }

    BeforeEach {
        $script:CredentialProviderRoot = Join-Path $TestDrive 'global-node-modules'
        $script:CredentialProviderBin = Join-Path $script:CredentialProviderRoot '@microsoft\artifacts-npm-credprovider\bin\index.js'
        $script:TokenTempDir = Join-Path $TestDrive 'ado-npm-temp'
        $script:NodeInvocationNpmrc = $null
        $script:NodeInvocationArgs = $null
        $env:ADO_NPM_TOKEN = $null
        $env:ADO_NPM_TOKEN_SECOND = $null

        Remove-Item -LiteralPath $script:TokenTempDir -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType File -Path $script:CredentialProviderBin -Force | Out-Null

        Mock -CommandName npm -ModuleName Shmuelie.Node -MockWith {
            if ($args.Count -eq 2 -and $args[0] -eq 'root' -and $args[1] -eq '-g') {
                $script:CredentialProviderRoot
            }
        }

        Mock -CommandName New-Item -ModuleName Shmuelie.Node -MockWith {
            param(
                [string]$ItemType,
                [string]$Path,
                [switch]$Force
            )

            if ($ItemType -eq 'Directory' -and (Split-Path -Leaf $Path).StartsWith('ado-npm-')) {
                Microsoft.PowerShell.Management\New-Item -ItemType Directory -Path $script:TokenTempDir -Force
            }
            else {
                $parameters = @{ ItemType = $ItemType; Path = $Path }
                if ($Force) { $parameters.Force = $true }
                Microsoft.PowerShell.Management\New-Item @parameters
            }
        }

        Mock -CommandName node -ModuleName Shmuelie.Node -MockWith {
            $script:NodeInvocationArgs = @($args)
            $configIndex = [array]::IndexOf($script:NodeInvocationArgs, '-c')
            $script:NodeInvocationNpmrc = $script:NodeInvocationArgs[$configIndex + 1]

            $content = (Get-Content -LiteralPath $script:NodeInvocationNpmrc -Raw).TrimEnd()
            Set-Content -LiteralPath $script:NodeInvocationNpmrc -Value ($content + 'token-from-provider') -NoNewline
        }
    }

    It 'writes a token to the default environment variable and removes the plaintext npmrc' {
        Update-AdoNpmToken -Feed 'https://pkgs.dev.azure.com/example/_packaging/feed/npm/registry/' -Confirm:$false

        $env:ADO_NPM_TOKEN | Should -BeExactly 'token-from-provider'
        $script:NodeInvocationArgs | Should -Contain '-c'
        $script:NodeInvocationArgs | Should -Not -Contain '--force'
        $script:NodeInvocationNpmrc | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $script:TokenTempDir | Should -BeFalse
        @(Get-ChildItem -LiteralPath $TestDrive -Filter '.npmrc' -Recurse -Force) | Should -HaveCount 0

        Should -Invoke -CommandName npm -ModuleName Shmuelie.Node -Times 1 -Exactly -ParameterFilter {
            $args.Count -eq 2 -and $args[0] -eq 'root' -and $args[1] -eq '-g'
        }
        Should -Invoke -CommandName node -ModuleName Shmuelie.Node -Times 1 -Exactly -ParameterFilter {
            $args.Count -eq 3 -and $args[0] -eq $script:CredentialProviderBin -and $args[1] -eq '-c' -and $args[2] -eq $script:NodeInvocationNpmrc
        }
    }

    It 'writes tokens for explicitly named feed variables' -ForEach @(
        @{ Feed = 'https://pkgs.dev.azure.com/example/_packaging/first/npm/registry/'; Name = 'ADO_NPM_TOKEN'; ExpectedToken = 'token-from-provider' }
        @{ Feed = 'https://pkgs.dev.azure.com/example/_packaging/second/npm/registry/'; Name = 'ADO_NPM_TOKEN_SECOND'; ExpectedToken = 'token-from-provider' }
    ) {
        Update-AdoNpmToken -Feed $Feed -Name $Name -Force -Confirm:$false

        [System.Environment]::GetEnvironmentVariable($Name, 'Process') | Should -BeExactly $ExpectedToken
        $script:NodeInvocationArgs | Should -Contain '--force'
        Test-Path -LiteralPath $script:TokenTempDir | Should -BeFalse
        @(Get-ChildItem -LiteralPath $TestDrive -Filter '.npmrc' -Recurse -Force) | Should -HaveCount 0
    }

    It 'does not create a temporary npmrc when WhatIf is specified' {
        Update-AdoNpmToken -Feed 'https://pkgs.dev.azure.com/example/_packaging/feed/npm/registry/' -WhatIf

        $env:ADO_NPM_TOKEN | Should -BeNullOrEmpty
        Test-Path -LiteralPath $script:TokenTempDir | Should -BeFalse
        @(Get-ChildItem -LiteralPath $TestDrive -Filter '.npmrc' -Recurse -Force) | Should -HaveCount 0
        Should -Invoke -CommandName node -ModuleName Shmuelie.Node -Times 0 -Exactly
        Should -Invoke -CommandName New-Item -ModuleName Shmuelie.Node -Times 0 -Exactly
    }

    It 'restricts token scratch file ACLs to the current owner on Windows' -Skip:(-not $IsWindows) {
        InModuleScope Shmuelie.Node {
            $directory = Join-Path $TestDrive 'secure-token'
            $file = Join-Path $directory '.npmrc'
            New-Item -ItemType Directory -Path $directory | Out-Null
            New-Item -ItemType File -Path $file | Out-Null

            Set-AdoNpmTokenOwnerOnlyAcl -Path $directory -Directory
            Set-AdoNpmTokenOwnerOnlyAcl -Path $file

            $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
            # A file created by an elevated process (e.g. the CI runner) is owned by
            # BUILTIN\Administrators rather than the invoking user. The cmdlet locks down the
            # DACL (asserted below) and does not reassign the owner, so accept either trusted
            # owner and compare by SID to avoid NTAccount translation differences across hosts.
            $acceptableOwnerSids = @(
                $identity.Value
                [System.Security.Principal.SecurityIdentifier]::new([System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null).Value
            )
            foreach ($path in @($directory, $file)) {
                $acl = Get-Acl -LiteralPath $path
                $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value | Should -BeIn $acceptableOwnerSids
                @($acl.Access) | Should -HaveCount 1
                $acl.Access[0].IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value | Should -BeExactly $identity.Value
                $acl.Access[0].FileSystemRights.HasFlag([System.Security.AccessControl.FileSystemRights]::FullControl) | Should -BeTrue
                $acl.Access[0].AccessControlType | Should -Be ([System.Security.AccessControl.AccessControlType]::Allow)
            }
        }
    }
}
