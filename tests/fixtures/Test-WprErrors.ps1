$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'The WPR error fixture requires Windows.' }
$modulePath = Join-Path $PSHOME 'Modules'
$env:PSModulePath = $modulePath
$env:PATH = $PSHOME
if ('WprTestHost' -as [type]) { throw 'Run the WPR fixture in a fresh no-profile process.' }
Add-Type -Path (Join-Path $PSScriptRoot 'WprTestHost.cs') -CompilerOptions '/nullable:enable' -ErrorAction Stop
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$source = Join-Path $repoRoot 'modules' 'Shmuelie.Windows'
$exitProgram = Join-Path $PSHOME 'pwsh.exe'

$cases = [System.Collections.Generic.List[hashtable]]::new()
foreach ($operation in 'start', 'stop') {
    foreach ($preference in $false, $true) {
        foreach ($action in 'Continue', 'Stop') {
            foreach ($mode in 'Success', 'Nonzero', 'LaunchFailure', 'MissingCommand', 'LaunchError', 'NoExit') {
                $cases.Add(@{ Name = "$operation/$mode/native=$preference/action=$action"; Operation = $operation; Mode = $mode; NativePreference = $preference; Action = $action; ExitState = 'Nonzero' })
            }
        }
    }
    foreach ($state in 'Absent', 'Null', 'Zero') {
        foreach ($mode in 'Success', 'Nonzero', 'LaunchFailure', 'NoExit') {
            $cases.Add(@{ Name = "$operation/$mode/initial=$state"; Operation = $operation; Mode = $mode; NativePreference = $true; Action = 'Stop'; ExitState = $state })
        }
    }
    foreach ($gate in 'WhatIf', 'InheritedWhatIf', 'OverrideWhatIf', 'Approve', 'Decline', 'UnsupportedPlatform') {
        $cases.Add(@{ Name = "$operation/$gate"; Operation = $operation; Mode = 'Success'; Gate = $gate; NativePreference = $true; Action = 'Stop'; ExitState = 'Absent' })
    }
}
$cases.Add(@{ Name = 'start/profile alias and file mode'; Operation = 'start'; Mode = 'Success'; FileMode = $true; Alias = $true; NativePreference = $true; Action = 'Stop'; ExitState = 'Zero' })
foreach ($invalid in 'Missing', 'Null', 'Empty', 'Whitespace', 'MissingWhatIf', 'WhitespaceWhatIf') {
    $cases.Add(@{ Name = "stop/$invalid"; Operation = 'stop'; Mode = 'Success'; InvalidFile = $invalid; NativePreference = $true; Action = 'Stop'; ExitState = 'Absent' })
}

$invoke = {
    param($case, $source, $exitProgram)
    $global:PSNativeCommandUseErrorActionPreference = $case.NativePreference
    $global:ErrorActionPreference = 'Continue'
    Remove-Variable LASTEXITCODE -Scope Global -ErrorAction Ignore -WhatIf:$false -Confirm:$false
    switch ($case.ExitState) {
        Nonzero { $global:LASTEXITCODE = 73 }
        Zero { $global:LASTEXITCODE = 0 }
        Null { $global:LASTEXITCODE = $null }
    }
    $module = New-Module -Name WprFixtureModule -ArgumentList $case, $source, $exitProgram -ScriptBlock {
        param($case, $source, $exitProgram)
        . (Join-Path $source 'PlatformGuards.ps1')
        . (Join-Path $source 'WprHelpers.ps1')
        $script:Case = $case
        $script:ExitProgram = $exitProgram
        $script:Calls = 0
        $script:NativeChildren = 0
        $script:ExpectedArguments = if ($case.Operation -eq 'start') {
            @('wpr', '-start', 'C:\WPR fixture\custom profile.wprp!Fixture Profile')
        } else { @('wpr', '-stop', 'C:\WPR fixture\trace output.etl') }
        if ($case.FileMode) { $script:ExpectedArguments += '-filemode' }
        function Test-IsWindowsPlatform { $script:Case.Gate -ne 'UnsupportedPlatform' }
        function wpr { throw 'Direct WPR invocation is forbidden.' }
        function sudo {
            $script:Calls++
            if ($args.Count -ne $script:ExpectedArguments.Count) { throw 'Unexpected sudo argument count.' }
            for ($i = 0; $i -lt $args.Count; $i++) {
                if ($args[$i] -cne $script:ExpectedArguments[$i]) { throw "Unexpected sudo argument at index $i." }
            }
            if ($script:Case.InvalidFile -or $script:Case.Gate -in @('WhatIf', 'InheritedWhatIf', 'Decline', 'UnsupportedPlatform')) {
                throw 'The native boundary must not be reached for this case.'
            }
            if ($script:Case.Mode -eq 'LaunchFailure') { throw [System.ComponentModel.Win32Exception]::new(2, 'Synthetic sudo launch failure.') }
            if ($script:Case.Mode -eq 'MissingCommand') { throw [System.Management.Automation.CommandNotFoundException]::new('Synthetic missing sudo.') }
            if ($script:Case.Mode -eq 'LaunchError') { Write-Error 'Synthetic nonterminating launch error.'; return }
            'Synthetic WPR diagnostic output'
            switch ($script:Case.Mode) {
                Success {
                    $script:NativeChildren++
                    & $script:ExitProgram -NoProfile -NonInteractive -Command 'exit 0'
                }
                Nonzero {
                    $script:NativeChildren++
                    & $script:ExitProgram -NoProfile -NonInteractive -Command 'exit 87'
                }
                NoExit { return }
                default { throw 'Unexpected fixture invocation mode.' }
            }
        }
        Export-ModuleMember -Function Start-WindowsPerformanceRecorder, Stop-WindowsPerformanceRecorder
    }
    try {
        $privateHelperExported = $module.ExportedFunctions.Keys -contains 'Invoke-WprNative'
        $result = & $module {
            $PSNativeCommandUseErrorActionPreference = $script:Case.NativePreference
            $ErrorActionPreference = 'Continue'
            $WhatIfPreference = $script:Case.Gate -in @('InheritedWhatIf', 'OverrideWhatIf')
            $LASTEXITCODE = 909
            $parameters = @{ Confirm = $script:Case.Gate -in @('Approve', 'Decline'); ErrorAction = $script:Case.Action }
            if ($script:Case.Operation -eq 'start') {
                $command = 'Start-WindowsPerformanceRecorder'
                $profileParameter = if ($script:Case.Alias) { 'Profile' } else { 'PerformanceProfile' }
                $parameters[$profileParameter] = $script:ExpectedArguments[2]
                $parameters.FileMode = [bool]$script:Case.FileMode
            } else {
                $command = 'Stop-WindowsPerformanceRecorder'
                if ($script:Case.InvalidFile -notin @('Missing', 'MissingWhatIf')) {
                    $parameters.File = switch ($script:Case.InvalidFile) {
                        Null { $null }; Empty { '' }; Whitespace { ' ' }; WhitespaceWhatIf { ' ' }
                        default { $script:ExpectedArguments[2] }
                    }
                }
            }
            if ($script:Case.Gate -eq 'WhatIf' -or $script:Case.InvalidFile -like '*WhatIf') { $parameters.WhatIf = $true }
            if ($script:Case.Gate -eq 'OverrideWhatIf') { $parameters.WhatIf = $false }
            $output = @()
            $caught = $null
            try {
                $output = @(& $command @parameters)
                $succeeded = $?
            }
            catch {
                $caught = $_
                $succeeded = $false
            }
            $globalExit = Get-Variable LASTEXITCODE -Scope Global -ErrorAction Ignore
            [pscustomobject]@{
                Output = $output
                Succeeded = $succeeded
                CaughtError = $caught
                Calls = $script:Calls
                NativeChildren = $script:NativeChildren
                GlobalExitPresent = $null -ne $globalExit
                GlobalExitValue = if ($globalExit) { $globalExit.Value } else { $null }
                LocalExitValue = $LASTEXITCODE
                NativePreference = $PSNativeCommandUseErrorActionPreference
                GlobalNativePreference = $global:PSNativeCommandUseErrorActionPreference
                ErrorPreference = $ErrorActionPreference
                GlobalErrorPreference = $global:ErrorActionPreference
                WhatIfPreference = $WhatIfPreference
                FileMandatory = ((Get-Command Stop-WindowsPerformanceRecorder).Parameters.File.Attributes.Mandatory -contains $true)
            }
        }
        $result | Add-Member -NotePropertyName PrivateHelperExported -NotePropertyValue $privateHelperExported
        $result
    }
    finally { Remove-Module $module -Force -ErrorAction Stop -WhatIf:$false -Confirm:$false }
}

$results = [System.Collections.Generic.List[object]]::new()
$nativeChildren = 0
foreach ($case in $cases) {
    $testHost = [WprTestHost]::new()
    $testHost.TestUI.Approve = $case.Gate -eq 'Approve'
    $initial = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2()
    $initial.EnvironmentVariables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new(
        'PSModulePath', $modulePath, $null))
    $runspace = [runspacefactory]::CreateRunspace($testHost, $initial)
    $ps = [powershell]::Create()
    try {
        $runspace.Open()
        if ($env:PSModulePath -cne $modulePath) { throw 'WPR fixture module path isolation failed.' }
        $ps.Runspace = $runspace
        $null = $ps.AddScript($invoke.ToString()).AddArgument($case).AddArgument($source).AddArgument($exitProgram)
        $records = $ps.Invoke()
        if ($records.Count -ne 1) { throw "$($case.Name): expected one observation. $($ps.Streams.Error -join '; ')" }
        $result = $records[0]
        $blocked = $case.InvalidFile -or $case.Gate -in @('WhatIf', 'InheritedWhatIf', 'Decline', 'UnsupportedPlatform')
        $failed = $case.InvalidFile -or $case.Gate -eq 'UnsupportedPlatform' -or (-not $blocked -and $case.Mode -ne 'Success')
        $expectedCalls = if ($blocked) { 0 } else { 1 }
        $expectedPrompts = if ($case.Gate -in @('Approve', 'Decline')) { 1 } else { 0 }
        $expectedOutput = if (-not $blocked -and -not $failed) { 1 } else { 0 }
        $expectedCaught = $failed -and $case.Action -eq 'Stop'
        $errors = @($ps.Streams.Error)
        if ($result.CaughtError) { $errors += $result.CaughtError }
        if ($result.Calls -ne $expectedCalls -or $result.Succeeded -eq [bool]$failed -or
            @($result.Output).Count -ne $expectedOutput -or
            [bool]$result.CaughtError -ne [bool]$expectedCaught -or
            $errors.Count -ne [int][bool]$failed -or $testHost.TestUI.ConfirmationPrompts -ne $expectedPrompts) {
            throw "$($case.Name): calls=$($result.Calls), success=$($result.Succeeded), output=$(@($result.Output).Count), caught=$([bool]$result.CaughtError), errors=$($errors.Count), prompts=$($testHost.TestUI.ConfirmationPrompts). $($errors -join '; ')"
        }
        if ($expectedOutput -and $result.Output[0] -cne 'Synthetic WPR diagnostic output') {
            throw "$($case.Name): success output changed."
        }
        if ($failed -and -not $blocked) {
            $expectedId = switch ($case.Mode) {
                Nonzero { 'WprCommandFailed' }; NoExit { 'WprExitCodeUnavailable' }; default { 'WprInvocationFailed' }
            }
            if ($errors[0].FullyQualifiedErrorId -notlike "$expectedId,*" -or
                $errors[0].Exception.Message -notlike "WPR $($case.Operation)*") {
                throw "$($case.Name): missing operation/error diagnostics. $($errors[0])"
            }
            if ($case.Mode -eq 'Nonzero' -and $errors[0].Exception.Message -notlike '*exit code 87*Synthetic WPR diagnostic output*') {
                throw "$($case.Name): missing native exit/output diagnostics."
            }
            if ($case.Mode -in @('LaunchFailure', 'MissingCommand', 'LaunchError') -and $errors[0].Exception.Message -notlike '*Synthetic*') {
                throw "$($case.Name): original launch failure was lost."
            }
        }
        $expectedExit = switch ($case.ExitState) { Nonzero { 73 }; Zero { 0 }; default { $null } }
        if ($result.GlobalExitPresent -ne ($case.ExitState -ne 'Absent') -or
            $result.GlobalExitValue -ne $expectedExit -or $result.LocalExitValue -ne 909 -or
            $result.NativePreference -ne $case.NativePreference -or $result.GlobalNativePreference -ne $case.NativePreference -or
            $result.ErrorPreference -cne 'Continue' -or $result.GlobalErrorPreference -cne 'Continue' -or
            $result.WhatIfPreference -ne ($case.Gate -in @('InheritedWhatIf', 'OverrideWhatIf')) -or
            -not $result.FileMandatory -or $result.PrivateHelperExported) {
            throw "$($case.Name): caller state or command metadata changed."
        }
        $nativeChildren += $result.NativeChildren
        $results.Add([pscustomobject]@{
            Name = $case.Name; Passed = $true; NativeCalls = $result.Calls
            Succeeded = $result.Succeeded; Caught = [bool]$result.CaughtError
            ErrorId = if ($errors.Count) { $errors[0].FullyQualifiedErrorId } else { $null }
            OutputCount = @($result.Output).Count; ConfirmationPrompts = $testHost.TestUI.ConfirmationPrompts
            ExitStateRestored = $true; PreferencesUnchanged = $true
        })
    }
    finally { $ps.Dispose(); $runspace.Dispose() }
}
[pscustomobject]@{ Passed = $results.Count; Failed = 0; ExitOnlyChildren = $nativeChildren; Cases = $results } | ConvertTo-Json -Depth 5
