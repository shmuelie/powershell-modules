#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent
    Import-Module (Join-Path $repoRoot 'modules\Shmuelie.Utilities\Shmuelie.Utilities.psd1') -Force
}

Describe 'Test-IsElevated' {
    It 'returns a boolean' {
        Test-IsElevated | Should -BeOfType [bool]
    }
}

Describe 'Get-SessionTitle' {
    It 'includes the PowerShell moniker' {
        Get-SessionTitle | Should -Match 'PowerShell'
    }

    It 'includes the running version' {
        Get-SessionTitle | Should -Match ([regex]::Escape("$($PSVersionTable.PSVersion)"))
    }
}

Describe 'New-GlobalConstant' {
    It 'creates a global constant with the supplied value' {
        $name = 'ShmuelieTest_' + [guid]::NewGuid().ToString('N')
        New-GlobalConstant $name 42
        (Get-Variable -Name $name -Scope Global -ValueOnly) | Should -Be 42
    }

    It 'makes the variable read-only' {
        $name = 'ShmuelieTest_' + [guid]::NewGuid().ToString('N')
        New-GlobalConstant $name 'locked'
        { Set-Variable -Name $name -Value 'other' -Scope Global } | Should -Throw
    }
}

Describe 'New-PathVariable' {
    It 'creates the variable when the path exists' {
        $name = 'ShmuelieTest_' + [guid]::NewGuid().ToString('N')
        New-PathVariable $name $TestDrive
        (Get-Variable -Name $name -Scope Global -ValueOnly) | Should -Be "$TestDrive"
    }

    It 'does not create the variable when the path is missing' {
        $name = 'ShmuelieTest_' + [guid]::NewGuid().ToString('N')
        New-PathVariable $name (Join-Path $TestDrive 'does-not-exist')
        { Get-Variable -Name $name -Scope Global -ErrorAction Stop } | Should -Throw
    }
}

Describe 'Import-ModuleSafe' {
    It 'does nothing when the path is missing' {
        { Import-ModuleSafe -Path (Join-Path $TestDrive 'missing.psd1') } | Should -Not -Throw
    }
}

Describe 'Format-Duration' {
    $durationCases = @(
        # sub-minute: fractional TotalSeconds with no trailing label punctuation
        @{ Seconds = 45;     Expected = '45 seconds' }
        @{ Seconds = 0.5;    Expected = '0.5 seconds' }
        @{ Seconds = 5.3;    Expected = '5.3 seconds' }
        # fractional rounding to three decimals
        @{ Seconds = 1.2344; Expected = '1.234 seconds' }
        @{ Seconds = 2.5678; Expected = '2.568 seconds' }
        # just under the one-minute boundary
        @{ Seconds = 59.999; Expected = '59.999 seconds' }
        # exact one-minute boundary switches to M:SS.mmm
        @{ Seconds = 60;     Expected = '1:00.000' }
        @{ Seconds = 90.25;  Expected = '1:30.250' }
        @{ Seconds = 3599;   Expected = '59:59.000' }
        # exact one-hour boundary switches to H:MM:SS.mmm
        @{ Seconds = 3600;   Expected = '1:00:00.000' }
        @{ Seconds = 3661.5; Expected = '1:01:01.500' }
    )

    It 'formats <Seconds>s as <Expected>' -ForEach $durationCases {
        Format-Duration ([TimeSpan]::FromSeconds($Seconds)) | Should -BeExactly $Expected
    }

    It 'folds days into the hours field' {
        Format-Duration ([TimeSpan]::FromHours(25)) | Should -BeExactly '25:00:00.000'
    }

    It 'accepts pipeline input' {
        [TimeSpan]::FromSeconds(5.3) | Format-Duration | Should -BeExactly '5.3 seconds'
    }
}

Describe 'Invoke-InLocation' {
    It 'runs the script block in the requested location' {
        $target = Join-Path $TestDrive 'work'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        $seen = Invoke-InLocation -Location $target -ScriptBlock { (Get-Location).Path }
        $seen | Should -Be (Resolve-Path $target).Path
    }

    It 'restores the original location afterward' {
        $target = Join-Path $TestDrive 'work'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        $before = (Get-Location).Path
        Invoke-InLocation -Location $target -ScriptBlock { $null } | Out-Null
        (Get-Location).Path | Should -Be $before
    }
}
