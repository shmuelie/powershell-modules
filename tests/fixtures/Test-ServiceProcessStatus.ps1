$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'The service status fixture requires Windows.' }
if ('Shmuelie.Windows.Cmdlets.GetServiceProcessCommand' -as [type]) {
    throw 'Run this fixture in a fresh no-profile process without a native Windows module loaded.'
}
$env:PSModulePath = Join-Path $PSHOME 'Modules'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$source = Join-Path $repoRoot 'modules' 'Shmuelie.Windows' 'Cmdlets'
$references = @(
    Get-ChildItem -LiteralPath (Join-Path $PSHOME 'ref') -Filter '*.dll' -File |
        Where-Object Name -NotIn @('System.Management.Automation.dll', 'System.ServiceProcess.ServiceController.dll') |
        ForEach-Object FullName
) + @([psobject].Assembly.Location, [System.ServiceProcess.ServiceController].Assembly.Location)
# Do not compile ServiceProcessNativeMethods.cs: every native call is replaced.
Add-Type -Path @(
    Join-Path $PSScriptRoot 'ServiceProcessStatusFixture.cs'
    Join-Path $source 'ServiceProcessService.cs'
    Join-Path $source 'ServiceProcessInfo.cs'
    Join-Path $source 'ServiceProcessCommandBase.cs'
    Join-Path $source 'GetServiceProcessCommand.cs'
) -ReferencedAssemblies $references -CompilerOptions '/nullable:enable' -ErrorAction Stop
Add-Type -Path (Join-Path $PSScriptRoot 'AppInstallerTestRuntime.cs') -ErrorAction Stop

$flags = [Reflection.BindingFlags]'Instance,NonPublic'
$commandType = [Shmuelie.Windows.Cmdlets.GetServiceProcessCommand]
$resolver = $commandType.GetMethod('ResolveProcess', $flags)
$end = $commandType.GetMethod('EndProcessing', $flags)
$resultsField = $commandType.GetField('_results', $flags)
if (-not $resolver -or -not $end -or -not $resultsField) { throw 'The expected compiled lookup/output path is missing.' }

$cases = foreach ($state in [uint32[]]@(1, 2, 3, 4, 5, 6, 7, 0, 8, [uint32]::MaxValue)) {
    foreach ($serviceType in [uint32[]]@(0x10, 0x20)) {
        foreach ($nativeId in [uint32[]]@(4242, 0)) {
            @{ Name = "state=$state, type=$serviceType, pid=$nativeId"; State = $state; ServiceType = $serviceType; NativeId = $nativeId }
        }
    }
}
foreach ($state in [uint32[]]@(4, 5, 6, 7)) {
    $cases += @{ Name = "missing process in state=$state"; State = $state; ServiceType = [uint32]0x20; NativeId = [uint32]4242; Missing = $true }
}
$cases += @{ Name = 'state changes after invalid capture'; State = [uint32]2; ServiceType = [uint32]0x20; NativeId = [uint32]4242; ChangeAfterCapture = $true }
foreach ($failure in 'Manager', 'Service', 'Query') {
    $cases += @{ Name = "$failure failure"; State = [uint32]4; ServiceType = [uint32]0x10; NativeId = [uint32]4242; Failure = $failure }
}
$completed = [System.Collections.Generic.List[object]]::new()
try {
    foreach ($case in $cases) {
        [Shmuelie.Windows.Cmdlets.ServiceProcessStatusFixture]::Reset($case.State, $case.NativeId, $case.ServiceType)
        [Shmuelie.Windows.Cmdlets.ServiceProcessStatusFixture]::ChangeStateAfterCapture = [bool]$case.ChangeAfterCapture
        [Shmuelie.Windows.Cmdlets.ServiceProcessStatusFixture]::Failure = [string]$case.Failure
        $valid = $case.State -in @(4, 5, 6, 7) -and -not $case.Failure
        $expectedId = if ($valid) { [int]$case.NativeId } else { 0 }
        $processId = [Shmuelie.Windows.Cmdlets.ServiceProcessStatusFixture]::ReadProcessId()
        if ($processId -ne $expectedId) { throw "$($case.Name): PID was $processId; expected $expectedId." }
        $expectedCloses = switch ($case.Failure) { Manager { 0 }; Service { 1 }; default { 2 } }
        $expectedQueries = if ($case.Failure -in @('Manager', 'Service')) { 0 } else { 1 }
        if ([Shmuelie.Windows.Cmdlets.ServiceProcessStatusFixture]::OutstandingHandles -ne 0 -or
            [Shmuelie.Windows.Cmdlets.ServiceProcessStatusFixture]::CloseCalls -ne $expectedCloses -or
            [Shmuelie.Windows.Cmdlets.ServiceProcessStatusFixture]::QueryCalls -ne $expectedQueries) {
            throw "$($case.Name): unexpected handle lifecycle or query count."
        }

        [Shmuelie.Windows.Cmdlets.ServiceProcessStatusFixture]::LookupAllowed = $valid -and $expectedId -gt 0
        [Shmuelie.Windows.Cmdlets.ServiceProcessStatusFixture]::ProcessMissing = [bool]$case.Missing
        $runtime = [AppInstallerTestRuntime]::new()
        $command = [Shmuelie.Windows.Cmdlets.ServiceProcessStatusFixture]::CreateCommand($runtime)
        $process = $resolver.Invoke($command, [object[]]@($processId))
        $expectedLookups = if ($valid -and $expectedId -gt 0) { 1 } else { 0 }
        if ([Shmuelie.Windows.Cmdlets.ServiceProcessStatusFixture]::LookupCalls -ne $expectedLookups) {
            throw "$($case.Name): incorrect process lookup count."
        }
        $hasProcess = $expectedLookups -eq 1 -and -not $case.Missing
        if (($null -ne $process) -ne $hasProcess) { throw "$($case.Name): incorrect process availability." }
        $entries = $resultsField.GetValue($command)
        $info = [Shmuelie.Windows.Cmdlets.ServiceProcessStatusFixture]::Result($case.State, $processId, $process, 'FixtureService')
        $entries.Add($info)
        $null = $end.Invoke($command, $null)
        if ($runtime.Output.Count -ne 1) { throw "$($case.Name): expected one output." }
        if ($hasProcess) {
            if (-not [object]::ReferenceEquals($runtime.Output[0], [Shmuelie.Windows.Cmdlets.ServiceProcessStatusFixture]::DetachedProcess)) {
                throw "$($case.Name): single resolved process output changed."
            }
        } else {
            if (-not [object]::ReferenceEquals($runtime.Output[0], $info) -or
                $info.Process -ne $null -or $info.ProcessName -cne '' -or $info.ProcessId -ne $expectedId) {
                throw "$($case.Name): unavailable output is actionable or changed shape."
            }
        }
        # Multiple matches retain per-service descriptors, including shared-host results.
        $runtime.Output.Clear()
        $entries.Add([Shmuelie.Windows.Cmdlets.ServiceProcessStatusFixture]::Result($case.State, $processId, $process, 'OtherFixtureService'))
        $null = $end.Invoke($command, $null)
        if ($runtime.Output.Count -ne 2 -or
            @($runtime.Output | Where-Object { $_ -isnot [Shmuelie.Windows.Cmdlets.ServiceProcessInfo] }).Count -ne 0) {
            throw "$($case.Name): multiple-match output changed."
        }
        $completed.Add([pscustomobject]@{ Name = $case.Name; Passed = $true })
    }

    [Shmuelie.Windows.Cmdlets.ServiceProcessStatusFixture]::Reset(4, 4242)
    [Shmuelie.Windows.Cmdlets.ServiceProcessStatusFixture]::Failure = 'Throw'
    $caught = $false
    try { $null = [Shmuelie.Windows.Cmdlets.ServiceProcessStatusFixture]::ReadProcessId() }
    catch [System.Management.Automation.MethodInvocationException] {
        if ($_.Exception.InnerException.Message -cne 'Synthetic status query failure.') { throw }
        $caught = $true
    }
    if (-not $caught -or [Shmuelie.Windows.Cmdlets.ServiceProcessStatusFixture]::OutstandingHandles -ne 0 -or
        [Shmuelie.Windows.Cmdlets.ServiceProcessStatusFixture]::CloseCalls -ne 2) {
        throw 'Throwing status query did not preserve failure/cleanup.'
    }
    $completed.Add([pscustomobject]@{ Name = 'throwing query cleanup'; Passed = $true })

    [Shmuelie.Windows.Cmdlets.ServiceProcessStatusFixture]::Reset(4, 4242, 0x20)
    [Shmuelie.Windows.Cmdlets.ServiceProcessStatusFixture]::AllowConfiguration = $true
    [Shmuelie.Windows.Cmdlets.ServiceProcessStatusFixture]::SetOwnProcess()
    if ([Shmuelie.Windows.Cmdlets.ServiceProcessStatusFixture]::ConfigurationCalls -ne 1 -or
        [Shmuelie.Windows.Cmdlets.ServiceProcessStatusFixture]::CloseCalls -ne 2 -or
        [Shmuelie.Windows.Cmdlets.ServiceProcessStatusFixture]::OutstandingHandles -ne 0) {
        throw 'Own-process configuration or handle cleanup changed.'
    }
    $completed.Add([pscustomobject]@{ Name = 'own-process configuration unchanged'; Passed = $true })
    [pscustomobject]@{ Passed = $completed.Count; Failed = 0; Cases = $completed } | ConvertTo-Json -Depth 4
}
finally {
    [Shmuelie.Windows.Cmdlets.ServiceProcessStatusFixture]::Cleanup()
}
