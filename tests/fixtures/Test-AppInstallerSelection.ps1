$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'The compiled AppInstaller selection fixture requires Windows.' }
if ('Shmuelie.Windows.Cmdlets.UpdateAppInstallerAppCommand' -as [type]) {
    throw 'Run this fixture in a fresh no-profile process; never reuse a loaded native AppInstaller module.'
}

$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$source = Join-Path $repoRoot 'modules' 'Shmuelie.Windows' 'Cmdlets.AppInstaller'
# The production WinRT service is deliberately excluded. All command and
# matching/result code is compiled unchanged against the fail-closed fixture.
Add-Type -Path @(
    Join-Path $PSScriptRoot 'AppInstallerSelectionService.cs'
    Join-Path $source 'AppInstallerApplication.cs'
    Join-Path $source 'AppInstallerHelpers.cs'
    Join-Path $source 'AppInstallerCommandBase.cs'
    Join-Path $source 'AppInstallerUpdateRequestResult.cs'
    Join-Path $source 'UpdateAppInstallerAppCommand.cs'
) -CompilerOptions '/nullable:enable' -ErrorAction Stop
Add-Type -Path (Join-Path $PSScriptRoot 'AppInstallerTestRuntime.cs') -ErrorAction Stop

$cases = @(
    @{ Name = 'standalone all remains void'; Script = 'Update-AppInstallerApp'; Requests = 'one,two'; Output = 0 }
    @{ Name = 'standalone all PassThru'; Script = 'Update-AppInstallerApp -PassThru'; Requests = 'one,two'; Output = 2 }
    @{ Name = 'explicit PassThru false'; Script = 'Update-AppInstallerApp -Name Example.One -PassThru:$false'; Requests = 'one'; Output = 0 }
    @{ Name = 'exact case-insensitive name'; Script = 'Update-AppInstallerApp -Name EXAMPLE.ONE -PassThru'; Requests = 'one'; Output = 1 }
    @{ Name = 'multiple explicit names'; Script = 'Update-AppInstallerApp -Name Example.One,Example.Two -PassThru'; Requests = 'one,two'; Output = 2 }
    @{ Name = 'duplicate identities'; Script = 'Update-AppInstallerApp -Name Example.One,Example.One -PassThru'; Requests = 'one'; Output = 1 }
    @{ Name = 'unmatched exact name'; Script = 'Update-AppInstallerApp -Name Missing.App -PassThru'; Requests = ''; Output = 0 }
    @{ Name = 'wildcard is not expanded'; Script = "Update-AppInstallerApp -Name 'Example.*' -PassThru"; Requests = ''; Output = 0 }
    @{ Name = 'empty pipeline'; Script = '@() | Update-AppInstallerApp -PassThru'; Requests = ''; Output = 0; Discovery = 0 }
    @{ Name = 'filtered empty pipeline'; Script = "[pscustomobject]@{Name='Example.One'} | Where-Object { `$false } | Update-AppInstallerApp -PassThru"; Requests = ''; Output = 0; Discovery = 0 }
    @{ Name = 'empty pipeline with explicit name'; Script = '@() | Update-AppInstallerApp -Name Example.One -PassThru'; Requests = ''; Output = 0; Discovery = 0 }
    @{ Name = 'empty pipeline WhatIf'; Script = '@() | Update-AppInstallerApp -PassThru -WhatIf'; Requests = ''; Output = 0; Discovery = 0 }
    @{ Name = 'invalid property binding'; Script = "[pscustomobject]@{Unrelated='x'} | Update-AppInstallerApp -PassThru"; Requests = ''; Output = 0; Discovery = 0; Errors = 1 }
    @{ Name = 'strings do not bind by value'; Script = "'Example.One' | Update-AppInstallerApp -PassThru"; Requests = ''; Output = 0; Discovery = 0; Errors = 1 }
    @{ Name = 'explicit whitespace'; Script = "Update-AppInstallerApp -Name ' ' -PassThru"; Requests = ''; Output = 0; Discovery = 0; Errors = 1 }
    @{ Name = 'explicit empty string'; Script = "Update-AppInstallerApp -Name '' -PassThru"; Requests = ''; Output = 0; Discovery = 0; Errors = 1 }
    @{ Name = 'explicit null'; Script = 'Update-AppInstallerApp -Name $null -PassThru'; Requests = ''; Output = 0; Discovery = 0; Errors = 1 }
    @{ Name = 'explicit empty array'; Script = 'Update-AppInstallerApp -Name @() -PassThru'; Requests = ''; Output = 0; Discovery = 0; Errors = 1 }
    @{ Name = 'whitespace in name array'; Script = "Update-AppInstallerApp -Name @('Example.One', ' ') -PassThru"; Requests = ''; Output = 0; Discovery = 0; Errors = 1 }
    @{ Name = 'null in name array'; Script = "Update-AppInstallerApp -Name @('Example.One', `$null) -PassThru"; Requests = ''; Output = 0; Discovery = 0; Errors = 1 }
    @{ Name = 'empty in name array'; Script = "Update-AppInstallerApp -Name @('Example.One', '') -PassThru"; Requests = ''; Output = 0; Discovery = 0; Errors = 1 }
    @{ Name = 'pipeline whitespace'; Script = "[pscustomobject]@{Name=' '} | Update-AppInstallerApp -PassThru"; Requests = ''; Output = 0; Discovery = 0; Errors = 1 }
    @{ Name = 'pipeline null'; Script = '[pscustomobject]@{Name=$null} | Update-AppInstallerApp -PassThru'; Requests = ''; Output = 0; Discovery = 0; Errors = 1 }
    @{ Name = 'pipeline empty name array'; Script = '[pscustomobject]@{Name=@()} | Update-AppInstallerApp -PassThru'; Requests = ''; Output = 0; Discovery = 0; Errors = 1 }
    @{ Name = 'multiple valid records'; Script = "[pscustomobject]@{Name='Example.One'}, [pscustomobject]@{Name='Example.Two'} | Update-AppInstallerApp -PassThru"; Requests = 'one,two'; Output = 2 }
    @{ Name = 'valid then invalid record'; Script = "[pscustomobject]@{Name='Example.One'}, [pscustomobject]@{Unrelated='x'} | Update-AppInstallerApp -PassThru"; Requests = 'one'; Output = 1; Errors = 1 }
    @{ Name = 'invalid then valid record'; Script = "[pscustomobject]@{Name=' '}, [pscustomobject]@{Name='Example.Two'} | Update-AppInstallerApp -PassThru"; Requests = 'two'; Output = 1; Errors = 1 }
    @{ Name = 'binding error Stop prevents submission'; Script = "[pscustomobject]@{Name='Example.One'}, [pscustomobject]@{Name=' '} | Update-AppInstallerApp -PassThru -ErrorAction Stop"; Requests = ''; Output = 0; Discovery = 0; Errors = 1; Terminating = $true }
    @{ Name = 'Name property has precedence'; Script = "[pscustomobject]@{Name='Example.One'; PackageFullName='Example.Two_1.2.3.4_x64__publisher'} | Update-AppInstallerApp -PassThru"; Requests = 'one'; Output = 1 }
    @{ Name = 'standalone WhatIf'; Script = 'Update-AppInstallerApp -PassThru -WhatIf'; Requests = ''; Output = 0 }
    @{ Name = 'selected WhatIf'; Script = 'Update-AppInstallerApp -Name Example.One -PassThru -WhatIf'; Requests = ''; Output = 0 }
    @{ Name = 'inherited WhatIf'; Script = '$WhatIfPreference=$true; Update-AppInstallerApp -PassThru'; Requests = ''; Output = 0 }
    @{ Name = 'request failure'; Script = 'Update-AppInstallerApp -Name Example.One -PassThru'; Requests = 'one'; Output = 0; Errors = 1; SuccessBeforeFailure = 0 }
    @{ Name = 'earlier request completion survives failure'; Script = 'Update-AppInstallerApp -PassThru'; Requests = 'one,two'; Output = 1; Errors = 1; SuccessBeforeFailure = 1 }
)
foreach ($identity in @(
    @{ Field = 'Name'; Value = 'Example.One' }
    @{ Field = 'PackageName'; Value = 'Example.One' }
    @{ Field = 'PackageFullName'; Value = 'Example.One_1.2.3.4_x64__publisher' }
    @{ Field = 'PackageFamilyName'; Value = 'Example.One_publisher' }
)) {
    $cases += @{ Name = "pipeline $($identity.Field)"; Script = "[pscustomobject]@{$($identity.Field)='$($identity.Value.ToUpperInvariant())'} | Update-AppInstallerApp -PassThru"; Requests = 'one'; Output = 1 }
    $cases += @{ Name = "parameter $($identity.Field)"; Script = "Update-AppInstallerApp -$($identity.Field) '$($identity.Value)' -PassThru"; Requests = 'one'; Output = 1 }
    $cases += @{ Name = "invalid alias $($identity.Field)"; Script = "[pscustomobject]@{$($identity.Field)=' '} | Update-AppInstallerApp -PassThru"; Requests = ''; Output = 0; Discovery = 0; Errors = 1 }
}

$results = [System.Collections.Generic.List[object]]::new()
foreach ($case in $cases) {
    [Shmuelie.Windows.Cmdlets.AppInstallerSelectionFixture]::Reset()
    if ($case.ContainsKey('SuccessBeforeFailure')) {
        [Shmuelie.Windows.Cmdlets.AppInstallerSelectionFixture]::SuccessBeforeFailure = $case.SuccessBeforeFailure
    }
    $initial = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2()
    $initial.Commands.Add([System.Management.Automation.Runspaces.SessionStateCmdletEntry]::new(
        'Update-AppInstallerApp', [Shmuelie.Windows.Cmdlets.UpdateAppInstallerAppCommand], $null))
    $runspace = [runspacefactory]::CreateRunspace($initial)
    $ps = [powershell]::Create()
    try {
        $runspace.Open()
        $ps.Runspace = $runspace
        $null = $ps.AddScript($case.Script)
        $terminatingError = $null
        try {
            $output = $ps.Invoke()
        }
        catch [System.Management.Automation.MethodInvocationException] {
            if (-not $case.Terminating -or $_.Exception.InnerException -isnot [System.Management.Automation.RuntimeException]) {
                throw
            }
            $terminatingError = $_.Exception.InnerException.ErrorRecord
            if ($terminatingError.FullyQualifiedErrorId -notlike 'ParameterArgumentValidationError*') { throw }
            $output = @()
        }
        $errors = @($ps.Streams.Error)
        if ($errors.Count -eq 0 -and $terminatingError) { $errors = @($terminatingError) }
        $requests = [Shmuelie.Windows.Cmdlets.AppInstallerSelectionFixture]::Requests
        $actualRequests = ($requests | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension(([uri]$_).AbsolutePath) }) -join ','
        $expectedErrors = if ($case.ContainsKey('Errors')) { $case.Errors } else { 0 }
        $expectedDiscovery = if ($case.ContainsKey('Discovery')) { $case.Discovery } else { 1 }
        if ($actualRequests -cne $case.Requests -or $output.Count -ne $case.Output -or
            $errors.Count -ne $expectedErrors -or
            [Shmuelie.Windows.Cmdlets.AppInstallerSelectionFixture]::DiscoveryCount -ne $expectedDiscovery) {
            throw "$($case.Name): requests='$actualRequests', output=$($output.Count), errors=$($errors.Count), discovery=$([Shmuelie.Windows.Cmdlets.AppInstallerSelectionFixture]::DiscoveryCount). $($errors -join '; ')"
        }
        foreach ($result in $output) {
            if ($result.Operation -cne 'UpdateCheck' -or $result.RequestCompleted -ne $true -or
                $result.PSTypeNames[0] -cne 'Shmuelie.Windows.AppInstallerUpdateRequestResult' -or
                $result.PSObject.Properties.Name -contains 'ResultingVersion' -or
                $result.PSObject.Properties.Name -contains 'Updated' -or
                $result.AppInstallerUri -notin $requests -or
                $result.PackageFullName -cne "$($result.Name)_1.2.3.4_x64__publisher" -or
                $result.PackageFamilyName -cne "$($result.Name)_publisher") {
                throw "$($case.Name): incorrect request-only completion result."
            }
        }
        if ($case.ContainsKey('SuccessBeforeFailure') -and
            ($errors -join '; ') -notlike '*Synthetic AppInstaller request failure*') {
            throw "$($case.Name): original request failure was not preserved."
        }
        $results.Add([pscustomobject]@{ Name = $case.Name; Passed = $true })
    }
    finally {
        $ps.Dispose()
        $runspace.Dispose()
    }
}

# Reuse the existing runtime seam for an explicit declined confirmation.
[Shmuelie.Windows.Cmdlets.AppInstallerSelectionFixture]::Reset()
$runtime = [AppInstallerTestRuntime]::new()
$runtime.Approve = $false
$command = [Shmuelie.Windows.Cmdlets.AppInstallerSelectionFixture]::CreateCommand($runtime)
$command.PassThru = $true
foreach ($phase in 'BeginProcessing', 'ProcessRecord', 'EndProcessing') {
    $method = $command.GetType().GetMethod($phase, [Reflection.BindingFlags]'Instance,NonPublic')
    $null = $method.Invoke($command, $null)
}
if ($runtime.PromptCount -ne 2 -or $runtime.Output.Count -ne 0 -or
    [Shmuelie.Windows.Cmdlets.AppInstallerSelectionFixture]::Requests.Count -ne 0) {
    throw 'Declined confirmation submitted a request or emitted completion.'
}
$results.Add([pscustomobject]@{ Name = 'declined confirmation'; Passed = $true })
[pscustomobject]@{ Passed = $results.Count; Failed = 0; Cases = $results } | ConvertTo-Json -Depth 4
