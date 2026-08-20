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
