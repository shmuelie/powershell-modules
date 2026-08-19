#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.2.0' }

BeforeAll {
    $repoRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent
    $script:ModuleManifest = [System.IO.Path]::Combine($repoRoot, 'modules', 'Shmuelie.Node', 'Shmuelie.Node.psd1')
    Import-Module $script:ModuleManifest -Force

    function ConvertTo-SingleQuotedLiteral {
        param([Parameter(Mandatory)][string]$Value)

        "'" + ($Value -replace "'", "''") + "'"
    }
}

AfterAll {
    Remove-Module Shmuelie.Node -Force -ErrorAction SilentlyContinue
}

Describe 'Get-NvmRoot' {
    BeforeEach {
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
