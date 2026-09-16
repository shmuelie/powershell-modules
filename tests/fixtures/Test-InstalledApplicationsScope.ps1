$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'The compiled inventory scope fixture requires Windows.' }
if ('Shmuelie.Windows.Cmdlets.GetInstalledApplicationsCommand' -as [type]) {
    throw 'Run this fixture in a fresh no-profile process, without a loaded native Windows module.'
}

$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$source = Join-Path $repoRoot 'modules' 'Shmuelie.Windows' 'Cmdlets'
# Compile unchanged command/base/interface code, but no registry or Win32 implementation.
Add-Type -Path @(
    Join-Path $PSScriptRoot 'InstalledApplicationsScopeFixture.cs'
    Join-Path $source 'InstalledApplicationsCommandBase.cs'
    Join-Path $source 'GetInstalledApplicationsCommand.cs'
    Join-Path $source 'IHiveOperations.cs'
) -CompilerOptions '/nullable:enable' -ErrorAction Stop

$scopes = @(
    @{ Scope = 'Global'; Global = 1; Current = 0; All = 0 }
    @{ Scope = 'GlobalAndCurrentUser'; Global = 1; Current = 1; All = 0 }
    @{ Scope = 'GlobalAndAllUsers'; Global = 1; Current = 0; All = 1 }
    @{ Scope = 'CurrentUser'; Global = 0; Current = 1; All = 0 }
    @{ Scope = 'AllUsers'; Global = 0; Current = 0; All = 1 }
)
$cases = foreach ($scope in $scopes) {
    $mixed = -join $(for ($i = 0; $i -lt $scope.Scope.Length; $i++) {
        if ($i % 2) { [char]::ToUpperInvariant($scope.Scope[$i]) } else { [char]::ToLowerInvariant($scope.Scope[$i]) }
    })
    foreach ($value in $scope.Scope, $scope.Scope.ToLowerInvariant(), $scope.Scope.ToUpperInvariant(), $mixed) {
        $modes = @('Standard')
        if ($scope.All) { $modes += 'NotElevated', 'WhatIf', 'InheritedWhatIf', 'ExplicitWhatIfFalse', 'ReadFailure', 'LoadFailure' }
        foreach ($mode in $modes) {
            @{ Name = "$value / $mode"; Value = $value; Scope = $scope; Mode = $mode }
        }
    }
}
$cases += @{ Name = 'default scope'; Scope = $scopes[2]; Mode = 'Standard'; OmitScope = $true }
foreach ($invalid in @('', ' ', 'Global*', 'GlobalAndAllUser', 'Global,CurrentUser', $null)) {
    $cases += @{ Name = "invalid scope '$invalid'"; Value = $invalid; Mode = 'Invalid' }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('ShmuelieScopeFixture-' + [guid]::NewGuid().ToString('N'))
$hive = Join-Path $root 'NTUSER.DAT'
$results = [System.Collections.Generic.List[object]]::new()
try {
    $null = [IO.Directory]::CreateDirectory($root)
    [IO.File]::WriteAllBytes($hive, [byte[]]@())
    foreach ($case in $cases) {
        [Shmuelie.Windows.Cmdlets.InstalledApplicationsScopeFixture]::Reset($root)
        $preview = $case.Mode -in @('WhatIf', 'InheritedWhatIf')
        [Shmuelie.Windows.Cmdlets.InstalledApplicationsScopeFixture]::Elevated = $case.Mode -ne 'NotElevated' -and -not $preview
        [Shmuelie.Windows.Cmdlets.InstalledApplicationsScopeFixture]::ThrowOfflineRead = $case.Mode -eq 'ReadFailure'
        if ($case.Mode -eq 'LoadFailure') { [Shmuelie.Windows.Cmdlets.InstalledApplicationsScopeFixture]::LoadStatus = 5 }

        $initial = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2()
        $initial.Commands.Add([System.Management.Automation.Runspaces.SessionStateCmdletEntry]::new(
            'Get-InstalledApplications', [Shmuelie.Windows.Cmdlets.GetInstalledApplicationsCommand], $null))
        $runspace = [runspacefactory]::CreateRunspace($initial)
        $ps = [powershell]::Create()
        try {
            $runspace.Open()
            $ps.Runspace = $runspace
            if ($case.Mode -in @('InheritedWhatIf', 'ExplicitWhatIfFalse')) {
                $runspace.SessionStateProxy.SetVariable('WhatIfPreference', $true)
            }
            $invocation = 'param($scope) Get-InstalledApplications -Confirm:$false'
            if (-not $case.OmitScope) { $invocation += ' -Scope $scope' }
            if ($case.Mode -eq 'WhatIf') { $invocation += ' -WhatIf' }
            if ($case.Mode -eq 'ExplicitWhatIfFalse') { $invocation += ' -WhatIf:$false' }
            $null = $ps.AddScript($invocation).AddArgument($case.Value)
            $output = $ps.Invoke()

            $blocked = $case.Mode -in @('Invalid', 'NotElevated')
            $all = if ($blocked) { 0 } else { $case.Scope.All }
            $global = if ($blocked) { 0 } else { $case.Scope.Global }
            $current = if ($blocked) { 0 } else { $case.Scope.Current }
            $load = if ($preview) { 0 } else { $all }
            $unload = if ($case.Mode -eq 'LoadFailure') { 0 } else { $load }
            $elevation = if ($case.Mode -eq 'Invalid' -or $preview) { 0 } else { $case.Scope.All }
            $expectedCounts = @{
                GlobalReads = $global; CurrentReads = $current
                ProfileReads = $all; MountedReads = $all; OfflineReads = $unload
                ElevationChecks = $elevation; PrivilegeCalls = $load; LoadCalls = $load; UnloadCalls = $unload
            }
            foreach ($counter in $expectedCounts.Keys) {
                $actual = [Shmuelie.Windows.Cmdlets.InstalledApplicationsScopeFixture]::($counter)
                if ($actual -ne $expectedCounts[$counter]) {
                    throw "$($case.Name): $counter was $actual, expected $($expectedCounts[$counter]). $($ps.Streams.Error -join '; ')"
                }
            }
            $expectedErrors = if ($blocked -or $case.Mode -eq 'ReadFailure') { 1 } else { 0 }
            $expectedWarnings = if ($case.Mode -eq 'LoadFailure') { 1 } else { 0 }
            if ($ps.Streams.Error.Count -ne $expectedErrors -or $ps.Streams.Warning.Count -ne $expectedWarnings) {
                throw "$($case.Name): errors=$($ps.Streams.Error.Count), warnings=$($ps.Streams.Warning.Count). $($ps.Streams.Error -join '; ')"
            }
            if ($case.Mode -eq 'NotElevated' -and $ps.Streams.Error[0].FullyQualifiedErrorId -notlike 'ElevationRequired*') {
                throw "$($case.Name): elevation error was not preserved."
            }
            if ($case.Mode -eq 'Invalid' -and $ps.Streams.Error[0].FullyQualifiedErrorId -notlike 'ParameterArgumentValidationError*') {
                throw "$($case.Name): invalid scope was not rejected during binding."
            }
            if ($case.Mode -eq 'ReadFailure' -and ($ps.Streams.Error -join '; ') -notlike '*Synthetic offline hive read failure*') {
                throw "$($case.Name): original read failure was not preserved."
            }
            $expectedNames = @()
            if (-not $blocked -and $case.Mode -ne 'ReadFailure') {
                if ($global) { $expectedNames += 'Global' }
                if ($current) { $expectedNames += 'CurrentUser' }
                if ($all) { $expectedNames += 'MountedUser' }
                if ($unload) { $expectedNames += 'OfflineUser' }
            }
            if (($output.DisplayName -join ',') -cne ($expectedNames -join ',')) {
                throw "$($case.Name): unexpected application output '$($output.DisplayName -join ',')'."
            }
            $results.Add([pscustomobject]@{ Name = $case.Name; Passed = $true })
        }
        finally {
            $ps.Dispose()
            $runspace.Dispose()
            [Shmuelie.Windows.Cmdlets.InstalledApplicationsScopeFixture]::Uninstall()
        }
    }
    [pscustomobject]@{ Passed = $results.Count; Failed = 0; Cases = $results } | ConvertTo-Json -Depth 4
}
finally {
    [IO.File]::Delete($hive)
    if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root, $false) }
}
