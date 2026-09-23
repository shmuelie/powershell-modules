param([string]$AssemblyDirectory)

$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'The compiled AppInstaller lifecycle fixture requires Windows.' }
if ('Shmuelie.Windows.Cmdlets.UpdateAppInstallerAppCommand' -as [type] -or
    'Windows.Management.Deployment.PackageManager' -as [type]) {
    throw 'Run this fixture in a fresh no-profile process without WinRT projections.'
}
$env:PSModulePath = Join-Path $PSHOME 'Modules'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$source = Join-Path $repoRoot 'modules' 'Shmuelie.Windows' 'Cmdlets.AppInstaller'
# Compile the production service itself, including route selection, option
# initialization and await/error handling, against managed-only API substitutes.
$compile = @{
    Path = @(
        Join-Path $PSScriptRoot 'AppInstallerDeploymentBoundary.cs'
        Join-Path $source 'AppInstallerService.cs'
        Join-Path $source 'AppInstallerApplication.cs'
        Join-Path $source 'AppInstallerHelpers.cs'
        Join-Path $source 'AppInstallerCommandBase.cs'
        Join-Path $source 'AppInstallerUpdateRequestResult.cs'
        Join-Path $source 'UpdateAppInstallerAppCommand.cs'
    )
    CompilerOptions = '/nullable:enable'
    ErrorAction = 'Stop'
}
if ($AssemblyDirectory) {
    $null = New-Item -ItemType Directory -Path $AssemblyDirectory -Force
    $compile.OutputAssembly = Join-Path $AssemblyDirectory 'Shmuelie.Windows.AppInstaller.dll'
}
Add-Type @compile
if ($AssemblyDirectory) {
    Copy-Item -LiteralPath (Join-Path $source 'en-US') -Destination (Join-Path $AssemblyDirectory 'en-US') -Recurse
    Import-Module $compile.OutputAssembly -ErrorAction Stop
}
Add-Type -Path (Join-Path $PSScriptRoot 'AppInstallerTestRuntime.cs') -ErrorAction Stop

$results = [System.Collections.Generic.List[object]]::new()
if ($AssemblyDirectory) {
    $help = Get-Help Update-AppInstallerApp -Full -ErrorAction Stop
    $description = $help.description.Text -join "`n"
    foreach ($expected in '22556', '19041', 'next activation', 'in-use errors', 'ForceAppShutdown',
        'ForceTargetAppShutdown', 'ExtendedErrorCode', 'Completion does not establish', 'WhatIf') {
        if ($description -notmatch [regex]::Escape($expected)) { throw "Missing help contract: $expected" }
    }
    if ($help.parameters.parameter.name -notcontains 'PassThru' -or
        [AppInstallerDeploymentFixture]::ManagerCount -ne 0) {
        throw 'Help lookup lacks PassThru documentation or reached deployment.'
    }
    $results.Add([pscustomobject]@{ Name = 'user-facing help from managed-only assembly'; Passed = $true })
}
$platforms = @(
    @{ Build = 19041; Modern = $false }
    @{ Build = 22000; Modern = $false }
    @{ Build = 22555; Modern = $false }
    @{ Build = 22556; Modern = $true }
    @{ Build = 22621; Modern = $true }
    @{ Build = 26100; Modern = $true }
)
$cases = foreach ($platform in $platforms) {
    foreach ($registered in $true, $false) {
        foreach ($passThru in $true, $false) {
            @{
                Name = "build $($platform.Build), registered=$registered, PassThru=$passThru"
                Version = [version]"10.0.$($platform.Build).0"
                Modern = $platform.Modern; Registered = $registered; PassThru = $passThru
                Failure = $(if (-not $registered -and -not $platform.Modern) { 'LegacyInUse' } else { '' })
            }
        }
    }
}
foreach ($modern in $true, $false) {
    foreach ($failure in 'Async', 'Extended', 'UnsupportedOptions') {
        $cases += @{
            Name = "modern=$modern, $failure"; Version = [version]$(if ($modern) { '10.0.22556.0' } else { '10.0.22555.0' })
            Modern = $modern; Registered = $false; PassThru = $true; Failure = $failure
        }
    }
}
foreach ($case in $cases) {
    [AppInstallerDeploymentFixture]::Reset($case.Version, $case.Modern, $case.Registered, $case.Failure)
    $runtime = [AppInstallerTestRuntime]::new()
    $command = [AppInstallerDeploymentFixture]::CreateCommand($runtime)
    $command.PassThru = $case.PassThru
    $caught = $null
    try {
        foreach ($phase in 'BeginProcessing', 'ProcessRecord', 'EndProcessing') {
            $method = $command.GetType().GetMethod($phase, [Reflection.BindingFlags]'Instance,NonPublic')
            $null = $method.Invoke($command, $null)
        }
    }
    catch {
        $caught = $_.Exception
        while ($caught.InnerException) { $caught = $caught.InnerException }
    }
    if ($case.Failure) {
        if (-not [object]::ReferenceEquals($caught, [AppInstallerDeploymentFixture]::Failure)) {
            throw "$($case.Name): did not preserve the original failure: $caught"
        }
    }
    elseif ($caught) { throw $caught }
    $expectedOutput = [int]($case.PassThru -and -not $case.Failure)
    $expectedAwait = [int]($case.Failure -ne 'UnsupportedOptions')
    if ($runtime.Output.Count -ne $expectedOutput -or $runtime.PromptCount -ne 1 -or
        [AppInstallerDeploymentFixture]::Requests.Count -ne 1 -or
        [AppInstallerDeploymentFixture]::ManagerCount -ne 1 -or
        [AppInstallerDeploymentFixture]::OptionsCount -ne [int]$case.Modern -or
        [AppInstallerDeploymentFixture]::AwaitCount -ne $expectedAwait -or
        [AppInstallerDeploymentFixture]::RegistrationReads -ne 0) {
        throw "$($case.Name): wrong request count, option construction, await, confirmation, or output."
    }
    foreach ($output in $runtime.Output) {
        if ($output.PSTypeNames[0] -cne 'Shmuelie.Windows.AppInstallerUpdateRequestResult' -or
            $output.Operation -cne 'UpdateCheck' -or $output.RequestCompleted -ne $true -or
            $output.PackageFullName -cne 'Example.App_1.2.3.4_x64__publisher' -or
            $output.PackageFamilyName -cne 'Example.App_publisher' -or $output.Name -cne 'Example.App' -or
            $output.AppInstallerUri -cne [AppInstallerDeploymentFixture]::OriginalUri -or
            (@($output.PSObject.Properties.Name | Sort-Object) -join ',') -cne
                'AppInstallerUri,Name,Operation,PackageFamilyName,PackageFullName,RequestCompleted') {
            throw "$($case.Name): incorrect identity or non-request-only output."
        }
    }
    $results.Add([pscustomobject]@{ Name = $case.Name; Passed = $true })
}

foreach ($version in '0.0', '10.0', '10.0.19040.0') {
    [AppInstallerDeploymentFixture]::Reset([version]$version, $false, $false, '')
    $caught = $null
    try { [AppInstallerDeploymentFixture]::Update() }
    catch {
        $caught = $_.Exception
        while ($caught.InnerException) { $caught = $caught.InnerException }
    }
    if ($caught -isnot [PlatformNotSupportedException] -or [AppInstallerDeploymentFixture]::ManagerCount -ne 0 -or
        [AppInstallerDeploymentFixture]::Requests.Count -ne 0) {
        throw "Unknown/unsupported platform $version reached a deployment boundary."
    }
    $results.Add([pscustomobject]@{ Name = "unsupported platform $version"; Passed = $true })
}

foreach ($modern in $true, $false) {
    $version = [version]$(if ($modern) { '10.0.22556.0' } else { '10.0.22555.0' })
    foreach ($fail in $true, $false) {
        [AppInstallerDeploymentFixture]::Reset($version, $modern, $false, '')
        [AppInstallerDeploymentFixture]::VerifyPendingRequest($fail)
        if ([AppInstallerDeploymentFixture]::Requests.Count -ne 1 -or [AppInstallerDeploymentFixture]::AwaitCount -ne 1) {
            throw 'Pending request was not awaited exactly once.'
        }
        $results.Add([pscustomobject]@{ Name = "pending modern=$modern fail=$fail"; Passed = $true })
    }
    [AppInstallerDeploymentFixture]::Reset($version, $modern, $false, '')
    $runtime = [AppInstallerTestRuntime]::new()
    $runtime.Approve = $false
    $command = [AppInstallerDeploymentFixture]::CreateCommand($runtime)
    $command.PassThru = $true
    foreach ($phase in 'BeginProcessing', 'ProcessRecord', 'EndProcessing') {
        $null = $command.GetType().GetMethod($phase, [Reflection.BindingFlags]'Instance,NonPublic').Invoke($command, $null)
    }
    if ($runtime.PromptCount -ne 1 -or $runtime.Output.Count -ne 0 -or
        [AppInstallerDeploymentFixture]::ManagerCount -ne 0 -or [AppInstallerDeploymentFixture]::Requests.Count -ne 0) {
        throw 'Declined confirmation reached the deployment boundary.'
    }
    $results.Add([pscustomobject]@{ Name = "declined confirmation modern=$modern"; Passed = $true })
}

if ([AppDomain]::CurrentDomain.GetAssemblies().GetName().Name -contains 'Microsoft.Windows.SDK.NET' -or
    [AppDomain]::CurrentDomain.GetAssemblies().GetName().Name -contains 'WinRT.Runtime') {
    throw 'A real WinRT projection was loaded into the fake-only fixture.'
}
[AppInstallerDeploymentFixture]::Awaiting.Dispose()
[pscustomobject]@{ Passed = $results.Count; Failed = 0; Cases = $results } | ConvertTo-Json -Depth 4
