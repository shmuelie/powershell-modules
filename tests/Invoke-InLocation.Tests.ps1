#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.2.0' }

Describe 'Invoke-InLocation <Implementation>' -ForEach @(
    @{ Implementation = 'Utilities'; Module = 'Shmuelie.Utilities'; HelperFile = 'Utilities.ps1' }
    @{ Implementation = 'DotNet private helper'; Module = 'Shmuelie.DotNet'; HelperFile = 'PrivateHelpers.ps1' }
) {
    BeforeAll {
        $repoRoot = Split-Path $PSScriptRoot -Parent
        $source = Join-Path $repoRoot 'modules' $Module $HelperFile
        # Load only helper definitions, not either module's package/tool bootstrap.
        $helperModule = New-Module -Name ("LocationContract_" + $Module) -ArgumentList $source -ScriptBlock {
            param($Source)
            . $Source
            Export-ModuleMember -Function Invoke-InLocation
        }
        Import-Module $helperModule -Scope Local -Force -ErrorAction Stop
        $invokeLocation = $helperModule.ExportedFunctions['Invoke-InLocation']
    }

    AfterAll {
        Remove-Module -ModuleInfo $helperModule -Force -ErrorAction Stop
    }

    BeforeEach {
        $fixtureEntered = $false
        $fixtureCreated = $false
        $fixtureStack = 'LocationFixture_' + [guid]::NewGuid().ToString('N')
        $initialStack = @((Get-Location -Stack).Path)
        $testRoot = (Resolve-Path -LiteralPath $TestDrive -ErrorAction Stop).ProviderPath
        $caseRoot = Join-Path $testRoot ([guid]::NewGuid().ToString('N'))
        $casePrefix = $caseRoot + [IO.Path]::DirectorySeparatorChar
        $caller = Join-Path $caseRoot 'caller'
        $target = Join-Path $caller 'target folder'
        $file = Join-Path $caller 'existing.txt'
        Push-Location -LiteralPath $testRoot -StackName $fixtureStack -ErrorAction Stop
        $fixtureEntered = $true
        if ((Get-Location).ProviderPath -cne $testRoot) { throw 'Test root entry failed.' }
        $null = New-Item -ItemType Directory -Path $caseRoot -ErrorAction Stop
        $fixtureCreated = $true
        $null = New-Item -ItemType Directory -Path $caller, $target -ErrorAction Stop
        Set-Content -LiteralPath $file -Value 'location fixture' -ErrorAction Stop
        Set-Location -LiteralPath $caller -ErrorAction Stop
        if ((Get-Location).ProviderPath -cne $caller) { throw 'Caller fixture entry failed.' }
        $callerStack = @((Get-Location -Stack).Path)
        $state = [pscustomobject]@{ Calls = 0 }
    }

    AfterEach {
        try {
            # A failed assertion may leave an owned frame; never pop caller-owned frames.
            while (@(Get-Location -Stack).Count -gt $initialStack.Count) {
                $top = @(Get-Location -Stack)[0]
                if (-not $top.ProviderPath.StartsWith($casePrefix, [StringComparison]::OrdinalIgnoreCase)) {
                    throw 'Refusing to clean an unowned location-stack frame.'
                }
                Pop-Location -ErrorAction Stop
            }
        } finally {
            if ($fixtureEntered) { Pop-Location -StackName $fixtureStack -ErrorAction Stop }
            if ($fixtureCreated) {
                if ((Get-Location).ProviderPath.StartsWith($casePrefix, [StringComparison]::OrdinalIgnoreCase)) {
                    throw 'Refusing fixture cleanup before leaving the owned directory.'
                }
                Remove-Item -LiteralPath $caseRoot -Recurse -Force -ErrorAction Stop
            }
        }
    }

    It 'rejects a <Kind> before entry or callback under Continue' -ForEach @(
        @{ Kind = 'file' }
        @{ Kind = 'missing directory' }
    ) {
        $ErrorActionPreference = 'Continue'
        $invalid = if ($Kind -eq 'file') { $file } else { Join-Path $caller 'missing' }
        Mock Push-Location -ModuleName $helperModule.Name { throw 'Unexpected location entry.' }
        Mock Pop-Location -ModuleName $helperModule.Name { throw 'Unexpected location cleanup.' }
        $failure = $null
        try {
            & $invokeLocation -Location $invalid -ScriptBlock { $state.Calls++; Get-Location } -ErrorAction Continue
        } catch {
            $failure = $_
        }
        $failure.FullyQualifiedErrorId | Should -Match '^ParameterArgumentValidationError'
        $state.Calls | Should -Be 0
        Should -Invoke Push-Location -ModuleName $helperModule.Name -Times 0 -Exactly
        Should -Invoke Pop-Location -ModuleName $helperModule.Name -Times 0 -Exactly
        (Get-Location).ProviderPath | Should -BeExactly $caller
        @((Get-Location -Stack).Path) | Should -Be $callerStack
    }

    It 'stops a failed push before the callback and does not pop under Continue' {
        $ErrorActionPreference = 'Continue'
        Mock Push-Location -ModuleName $helperModule.Name {
            # Pester does not apply the command's ErrorAction to the mock body.
            $action = if ($PesterBoundParameters.ContainsKey('ErrorAction')) {
                $PesterBoundParameters.ErrorAction
            } else {
                'Continue'
            }
            Write-Error 'Controlled location-entry failure.' -ErrorAction $action
        } -ParameterFilter { $Path -ceq $target }
        Mock Pop-Location -ModuleName $helperModule.Name {}
        {
            & $invokeLocation -Location $target -ScriptBlock { $state.Calls++; Get-Location } -ErrorAction Continue
        } | Should -Throw '*Controlled location-entry failure*'
        $state.Calls | Should -Be 0
        Should -Invoke Push-Location -ModuleName $helperModule.Name -Times 1 -Exactly -ParameterFilter {
            $Path -ceq $target -and $ErrorAction -eq 'Stop'
        }
        Should -Invoke Pop-Location -ModuleName $helperModule.Name -Times 0 -Exactly
        (Get-Location).ProviderPath | Should -BeExactly $caller
        @((Get-Location -Stack).Path) | Should -Be $callerStack
    }

    It 'does not run the callback when a wildcard resolves to multiple containers' {
        $ErrorActionPreference = 'Continue'
        $null = New-Item -ItemType Directory -Path (Join-Path $caller 'target other') -ErrorAction Stop
        {
            & $invokeLocation -Location (Join-Path $caller 'target*') -ScriptBlock {
                $state.Calls++
                Get-Location
            } -ErrorAction Continue
        } | Should -Throw
        $state.Calls | Should -Be 0
        (Get-Location).ProviderPath | Should -BeExactly $caller
        @((Get-Location -Stack).Path) | Should -Be $callerStack
    }

    It 'preserves <Kind> path semantics and restores the caller after success' -ForEach @(
        @{ Kind = 'absolute' }
        @{ Kind = 'relative' }
        @{ Kind = 'wildcard' }
        @{ Kind = 'provider-qualified' }
        @{ Kind = 'escaped wildcard characters' }
    ) {
        $location = switch ($Kind) {
            'absolute' { $target }
            'relative' { Join-Path '.' 'target folder' }
            'wildcard' { Join-Path $caller 'target*' }
            'provider-qualified' { "FileSystem::$target" }
            'escaped wildcard characters' {
                $target = Join-Path $caller 'target [literal]'
                $null = New-Item -ItemType Directory -Path $target -ErrorAction Stop
                [WildcardPattern]::Escape($target)
            }
        }
        $seen = & $invokeLocation -Location $location -ScriptBlock { (Get-Location).ProviderPath }
        $seen | Should -BeExactly $target
        (Get-Location).ProviderPath | Should -BeExactly $caller
        @((Get-Location -Stack).Path) | Should -Be $callerStack
    }

    It 'preserves parameter types, aliases and positional binding' {
        $invokeLocation.Parameters['Location'].ParameterType | Should -Be ([string])
        $invokeLocation.Parameters['Location'].Aliases | Should -Contain 'Path'
        $invokeLocation.Parameters['ScriptBlock'].ParameterType | Should -Be ([scriptblock])
        $invokeLocation.Parameters['ScriptBlock'].Aliases | Should -Contain 'Process'
        (& $invokeLocation $target { (Get-Location).ProviderPath }) | Should -BeExactly $target
        (& $invokeLocation -Path $target -Process { (Get-Location).ProviderPath }) | Should -BeExactly $target
        (Get-Location).ProviderPath | Should -BeExactly $caller
    }

    It 'preserves output objects and ordering without emitting cleanup output' {
        $first = [pscustomobject]@{ Value = 1 }
        $second = [pscustomobject]@{ Value = 2 }
        $output = @(& $invokeLocation -Location $target -ScriptBlock { $first; $second })
        $output | Should -HaveCount 2
        [object]::ReferenceEquals($output[0], $first) | Should -BeTrue
        [object]::ReferenceEquals($output[1], $second) | Should -BeTrue
        (Get-Location).ProviderPath | Should -BeExactly $caller
        @((Get-Location -Stack).Path) | Should -Be $callerStack
    }

    It 'restores the caller and stack when the callback throws' {
        {
            & $invokeLocation -Location $target -ScriptBlock {
                $state.Calls++
                throw 'Controlled callback failure.'
            }
        } | Should -Throw '*Controlled callback failure*'
        $state.Calls | Should -Be 1
        (Get-Location).ProviderPath | Should -BeExactly $caller
        @((Get-Location -Stack).Path) | Should -Be $callerStack
    }

    It 'preserves nonterminating callback errors and restores the caller' {
        $output = @(& $invokeLocation -Location $target -ScriptBlock {
            Write-Error 'Controlled callback error.' -ErrorAction Continue
            Get-Location
        } -ErrorAction Continue 2>&1)
        @($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) | Should -HaveCount 1
        ($output | Where-Object { $_ -is [System.Management.Automation.PathInfo] }).ProviderPath | Should -BeExactly $target
        (Get-Location).ProviderPath | Should -BeExactly $caller
        @((Get-Location -Stack).Path) | Should -Be $callerStack
    }

    It 'streams output and cleans up after early downstream termination' {
        $output = @(& $invokeLocation -Location $target -ScriptBlock {
            $state.Calls++
            Get-Location
            throw 'Downstream should stop before this statement.'
        } | Select-Object -First 1)
        $output | Should -HaveCount 1
        $output[0].ProviderPath | Should -BeExactly $target
        $state.Calls | Should -Be 1
        (Get-Location).ProviderPath | Should -BeExactly $caller
        @((Get-Location -Stack).Path) | Should -Be $callerStack
    }

    It 'preserves a pre-existing caller stack frame' {
        Push-Location -LiteralPath $caller -ErrorAction Stop
        try {
            $before = @((Get-Location -Stack).Path)
            & $invokeLocation -Location $target -ScriptBlock { $state.Calls++ }
            $state.Calls | Should -Be 1
            (Get-Location).ProviderPath | Should -BeExactly $caller
            @((Get-Location -Stack).Path) | Should -Be $before
        } finally {
            Pop-Location -ErrorAction Stop
        }
    }

    It 'pairs nested successful entries with their own cleanup' {
        $output = @(& $invokeLocation -Location $target -ScriptBlock {
            (Get-Location).ProviderPath
            & $invokeLocation -Location $caller -ScriptBlock { (Get-Location).ProviderPath }
            (Get-Location).ProviderPath
        })
        $output | Should -Be @($target, $caller, $target)
        (Get-Location).ProviderPath | Should -BeExactly $caller
        @((Get-Location -Stack).Path) | Should -Be $callerStack
    }
}
