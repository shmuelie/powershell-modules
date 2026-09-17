#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.2.0' }

BeforeAll {
    $moduleRoot = Split-Path $PSScriptRoot -Parent
    $repoRoot = Split-Path (Split-Path $moduleRoot -Parent) -Parent
    $binlogRoot = Join-Path $repoRoot 'artifacts' 'experimental-appinstall-tests'
    if ($IsWindows) {
        New-Item -ItemType Directory -Path $binlogRoot -Force | Out-Null
        $project = Join-Path $moduleRoot 'Cmdlets.AppInstall' 'Shmuelie.Windows.AppInstall.csproj'
        dotnet publish $project --configuration Release --output (Join-Path $moduleRoot 'bin') --nologo "-bl:$(Join-Path $binlogRoot "source-$([guid]::NewGuid()).binlog")"
        if ($LASTEXITCODE -ne 0) { throw 'Experimental AppInstall publish failed; no live fallback is allowed.' }
    }
    Import-Module (Join-Path $moduleRoot 'Shmuelie.AppInstall.Experimental.psd1') -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module Shmuelie.AppInstall.Experimental -Force -ErrorAction SilentlyContinue
}

Describe 'AppInstall foundation (hermetic)' -Tag AppInstallFoundation -Skip:(-not $IsWindows) {
    BeforeAll {
        $helperProject = Join-Path $PSScriptRoot 'AppInstall.TestHelpers' 'AppInstall.TestHelpers.csproj'
        $helperOutput = Join-Path $PSScriptRoot 'AppInstall.TestHelpers' 'bin' 'testhelpers'
        dotnet build $helperProject --configuration Release --output $helperOutput --nologo "-bl:$(Join-Path $binlogRoot "appinstall-testhelpers-$([guid]::NewGuid()).binlog")"
        if ($LASTEXITCODE -ne 0) {
            throw 'AppInstall.TestHelpers build failed; no live adapter fallback is allowed.'
        }
        [System.Reflection.Assembly]::LoadFrom(
            (Join-Path $helperOutput 'Shmuelie.Windows.AppInstall.Tests.dll')) | Out-Null
        $packaged = & (Join-Path $repoRoot 'build' 'Build-Module.ps1') `
            -Module Shmuelie.AppInstall.Experimental -OutputPath (Join-Path $TestDrive 'packaged')
        $packagedDirectory = @($packaged | Where-Object { $_ -is [System.IO.DirectoryInfo] })
        if ($packagedDirectory.Count -ne 1) { throw 'Expected one staged module directory.' }
        $importManifests = @{
            Source = Join-Path $moduleRoot 'Shmuelie.AppInstall.Experimental.psd1'
            Packaged = Join-Path $packagedDirectory[0].FullName 'Shmuelie.AppInstall.Experimental.psd1'
        }
    }

    It 'stages only the experimental assembly and its dependencies without Windows module assets' {
        $manifest = Import-PowerShellDataFile -LiteralPath $importManifests.Packaged
        $manifest.PrivateData.Publishable | Should -BeFalse
        @($manifest.RequiredModules) | Should -HaveCount 0
        foreach ($name in 'Shmuelie.Windows.AppInstall.dll', 'Microsoft.Windows.SDK.NET.dll', 'WinRT.Runtime.dll') {
            Test-Path -LiteralPath (Join-Path $packagedDirectory[0].FullName 'bin' $name) -PathType Leaf | Should -BeTrue
        }
        foreach ($name in 'Shmuelie.Windows.Cmdlets.dll', 'Shmuelie.Windows.AppInstaller.dll') {
            Test-Path -LiteralPath (Join-Path $packagedDirectory[0].FullName 'bin' $name) | Should -BeFalse
        }
        Test-Path -LiteralPath (Join-Path $packagedDirectory[0].FullName 'Windows.format.ps1xml') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $packagedDirectory[0].FullName 'AppInstall.format.ps1xml') -PathType Leaf | Should -BeTrue
    }

    It 'observes exactly one caller item through compiled fail-closed fakes: <_>' -ForEach @(
        'AlreadyTerminal', 'FailedTerminal', 'CanceledTerminal', 'Timeout', 'Unknown',
        'CompletedMissingHResult', 'CompletionEventNotSuccess', 'SubscribeRace', 'InitialSnapshotRace',
        'DuplicateBound', 'GenerationOverflow', 'PartialAddFailure', 'PartialAddCleanupFailure',
        'ObservationLimit', 'OutOfOrderInvalidation',
        'DirtyLoopDeadline', 'SynchronousOverrun', 'Stale', 'WrongItem', 'MissingEvent',
        'LeaseSurvivesPruning', 'OneLeasePerContext', 'ContextShutdownLease', 'RunspaceShutdownLease',
        'GroupNotEvaluated', 'FirstSubscribeFailure', 'SecondSubscribeFailure', 'GetterAndCleanupFailure',
        'DisappearedGetter', 'CleanupOnly', 'LateCallback', 'CancelBefore', 'CancelDuringRead',
        'DisposeDuringRead', 'Json', 'CommandSuccess', 'CommandFailure', 'CommandCleanupOnly',
        'CommandInvalidTimeout', 'CommandWrongRunspace', 'CommandStopProcessing', 'CommandContextDispose'
    ) {
        { [Shmuelie.Windows.AppInstall.Tests.MonitoringScenarios]::Run($_) } | Should -Not -Throw
    }

    It 'documents bounded passive monitoring and mandatory exact selectors' {
        $help = Get-Help Wait-AppInstallItem -Full
        ($help.description.Text -join ' ') | Should -Match 'private capability restricted to Microsoft-developed apps'
        ($help.description.Text -join ' ') | Should -Match 'Other-item notifications'
        ($help.description.Text -join ' ') | Should -Match 'never cancel installation'
        $command = Get-Command Wait-AppInstallItem
        foreach ($name in 'Context', 'LocalItemId', 'TimeoutSeconds') {
            $command.Parameters[$name].Attributes.Mandatory | Should -Contain $true
            ($help.parameters.parameter | Where-Object Name -EQ $name).required | Should -BeTrue
        }
        foreach ($name in 'ForUser', 'ProductId', 'PackageFamilyName', 'IncludeChildren', 'WhatIf') {
            $command.Parameters.ContainsKey($name) | Should -BeFalse
        }
        $command.OutputType.Name | Should -Contain 'Shmuelie.Windows.AppInstall.AppInstallMonitorResult'
    }

    It 'executes exported fake monitoring and protects default output from <_>' -ForEach @('Source', 'Packaged') {
        $result = [Shmuelie.Windows.AppInstall.Tests.MonitoringScenarios]::VerifyCommand($importManifests[$_])
        $result.GetType().FullName | Should -Be 'Shmuelie.Windows.AppInstall.AppInstallMonitorResult'
        $result.Outcome.ToString() | Should -Be 'TargetTerminal'
        $result.Observations[0].Snapshot.Status.TerminalState.ToString() | Should -Be 'Failed'
        $default = $result | Out-String
        $copy = [System.Management.Automation.PSSerializer]::Deserialize(
            [System.Management.Automation.PSSerializer]::Serialize($result))
        foreach ($display in $default, ($copy | Out-String)) {
            $display | Should -Not -Match 'synthetic-private|Observations\s*:'
            $display | Should -Match 'ObservationCount\s*:\s*1'
            $display | Should -Match 'GroupOutcome\s*:\s*NotEvaluated'
        }
        $json = [System.Text.Json.JsonSerializer]::Serialize($result, $result.GetType(), [System.Text.Json.JsonSerializerOptions]$null)
        $json | Should -Match 'synthetic-private-product'
        $json | Should -Match 'synthetic-private-native-error'
    }

    It 'satisfies the fake-adapter contract: <_>' -ForEach @(
        'LazyCreation', 'Reuse', 'IndependentContexts', 'PlatformGate', 'TypeGate', 'MemberGate',
        'AccessDenied', 'WrongRunspace', 'Dispose', 'RunspaceClose',
        'AsyncSuccess', 'AsyncFailure', 'NativeCancellation', 'StopWaiting', 'EventCleanup'
        'DisposeBeforeActivation', 'ClosedRunspace', 'ClosingRunspace', 'MemberGateAfterActivation',
        'FailedActivationDispose', 'ActivatedContextSurvivesModuleRemoval'
    ) {
        { [Shmuelie.Windows.AppInstall.Tests.ContextScenarios]::Run($_) } | Should -Not -Throw
    }

    It 'preserves the immutable snapshot/native error contract: <_>' -ForEach @(
        'ObservationStates', 'ObservationValidation', 'Identity', 'IdentityValidation', 'ImmutableProperties',
        'DeepCollectionCopy', 'GroupValidation', 'IndependentCompletionStates', 'StatusValidation',
        'RequestAvailability', 'EntitlementObservation', 'SnapshotSerialization', 'ErrorRecord',
        'ErrorCollectionCopy', 'ErrorSerialization', 'GateErrorKinds', 'ProjectedAsyncSuccess',
        'CapturedErrorMetadata',
        'ProjectedAsyncPendingCompletion', 'ProjectedArgumentAndCloseFailure',
        'MappedInvalidCastAndCleanup', 'MappedNullReferenceAndCleanup',
        'OperationalPrimaryAndUnclassifiedCleanup', 'UnclassifiedPrimaryAndCleanup', 'BothFailuresUnclassified',
        'UnclassifiedFailureWithoutCleanup', 'UnclassifiedCleanupOnly', 'OperationalFailureWithoutCleanup',
        'UnclassifiedStatusAndCleanup',
        'ProjectedNativeCancellation', 'ProjectedResultAndCloseFailure', 'ProjectedStatusAndCleanupFailure',
        'ProjectedCleanupOnlyFailure', 'ProjectedLocalCancellation'
    ) {
        { [Shmuelie.Windows.AppInstall.Tests.ContractScenarios]::Run($_) } | Should -Not -Throw
    }

    It 'reads caller inventory through fail-closed adapters: <_>' -ForEach @(
        'Empty', 'ObservedFields', 'ExactFilters', 'ProjectionIdentity', 'DuplicateReferences', 'DuplicateNativeNames',
        'GroupsAndAliases', 'DeepGroup', 'Cycle', 'ConflictingParents', 'ScopeMismatch', 'BoundedDepth', 'BoundedItems',
        'CachePruning', 'UnavailableFields', 'MissingCollection', 'ActivationDenied', 'CollectionDenied',
        'ItemDisappeared', 'StatusDenied', 'FieldDenied', 'InstallFailureIsData', 'TerminalStates',
        'Serialization', 'DisposedContext'
        'FailedCapturePreservesCache', 'UnavailableCompletionEvidence', 'GetterMissingMemberIsError',
        'OlderSnapshotSerialization', 'WrongRunspace'
    ) {
        { [Shmuelie.Windows.AppInstall.Tests.InventoryScenarios]::Run($_) } | Should -Not -Throw
    }

    It 'executes compiled fake inventory from <_> in a fresh process' -ForEach @('Source', 'Packaged') {
        $output = & pwsh -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'fixtures' 'Test-AppInstallInventory.ps1') `
            -ManifestPath $importManifests[$_] -HelperPath (Join-Path $helperOutput 'Shmuelie.Windows.AppInstall.Tests.dll')
        $LASTEXITCODE | Should -Be 0
        $output | Should -Contain 'Fake inventory command passed.'
    }

    It 'loads inventory help without executing the queue command' {
        $help = Get-Help Get-AppInstallItem -Full
        ($help.description.Text -join ' ') | Should -Match 'private capability restricted to Microsoft-developed apps'
        ($help.parameters.parameter | Where-Object Name -EQ 'Context').required | Should -BeTrue
    }

    It 'reads only approved settings through the explicit fake context: <_>' -ForEach @(
        'DefaultPrivacy', 'ExplicitIdentityOnly', 'ExplicitAll', 'DuplicateSelection',
        'FalseAndZero', 'FutureEnum', 'ReuseAndRefresh', 'IndependentScopes',
        'MemberUnavailable', 'IdentityUnavailable', 'TypeUnavailable', 'RecheckAvailability',
        'DisposedBeforeRead', 'DisposedAfterRead', 'WrongRunspace', 'PlatformFailure',
        'ActivationDenied', 'ActivationMissingMember', 'GetterDenied', 'GetterComFailure',
        'GetterMissingMember', 'PartialReadFailure', 'IdentityFailurePrivacy',
        'MappedNullReferenceFailure', 'MappedInvalidCastFailure',
        'NullIdentityFailure', 'EmptyIdentityAvailable', 'UnclassifiedFailure',
        'ImmutableJson', 'SchemaValidation', 'SdkSignatures', 'InvalidSelector', 'PipelineContext'
    ) {
        { [Shmuelie.Windows.AppInstall.Tests.SettingsScenarios]::Run($_) } | Should -Not -Throw
    }

    It 'exports only the context factory, approved readers, paused search and bounded observation from the assembly' {
        $commands = @(Get-Command -Module Shmuelie.AppInstall.Experimental -CommandType Cmdlet |
            Where-Object { $_.ImplementingType.Assembly.GetName().Name -eq 'Shmuelie.Windows.AppInstall' })
        @($commands.Name | Sort-Object) | Should -Be @('Get-AppInstallItem', 'Get-AppInstallSettings', 'New-AppInstallContext', 'Request-AppInstallUpdateSearch', 'Wait-AppInstallItem')
        $factory = $commands | Where-Object Name -EQ 'New-AppInstallContext'
        $factory.OutputType.Name | Should -Contain 'Shmuelie.Windows.AppInstall.AppInstallContext'
        $factory.Parameters.ContainsKey('WhatIf') | Should -BeTrue
        $reader = $commands | Where-Object Name -EQ 'Get-AppInstallSettings'
        $reader.OutputType.Name | Should -Contain 'Shmuelie.Windows.AppInstall.AppInstallSettingsSnapshot'
        $reader.Parameters['Context'].ParameterType.FullName | Should -BeExactly 'Shmuelie.Windows.AppInstall.AppInstallContext'
        $reader.Parameters['Context'].Attributes.Mandatory | Should -Contain $true
        $reader.Parameters['Property'].ParameterType | Should -Be ([string[]])
        $reader.Parameters.ContainsKey('WhatIf') | Should -BeFalse
        $reader.Parameters.ContainsKey('ForUser') | Should -BeFalse
        ([Shmuelie.Windows.AppInstall.GetAppInstallSettingsCommand]::new().Property | ForEach-Object ToString) |
            Should -Be @('AutoUpdateSetting', 'CanInstallForAllUsers')
        $inventory = $commands | Where-Object Name -EQ 'Get-AppInstallItem'
        $inventory.OutputType.Name | Should -Contain 'Shmuelie.Windows.AppInstall.AppInstallItemSnapshot'
        $inventory.Parameters.ContainsKey('WhatIf') | Should -BeFalse
        $inventory.Parameters.ContainsKey('User') | Should -BeFalse
        $search = $commands | Where-Object Name -EQ 'Request-AppInstallUpdateSearch'
        $search.OutputType.Name | Should -Contain 'Shmuelie.Windows.AppInstall.AppInstallRequestSnapshot'
        foreach ($parameter in 'Context', 'CorrelationVector', 'ClientId') {
            $search.Parameters[$parameter].Attributes.Mandatory | Should -Contain $true
        }
        $search.Parameters.ContainsKey('WhatIf') | Should -BeTrue
        $search.Parameters.ContainsKey('Confirm') | Should -BeTrue
        foreach ($parameter in 'User', 'ForUser', 'ProductId', 'PackageFamilyName', 'CatalogId', 'AutomaticallyDownloadAndInstallUpdateIfFound', 'AllowForcedAppRestart') {
            $search.Parameters.ContainsKey($parameter) | Should -BeFalse
        }
    }

    It 'preserves paused search request semantics through fakes: <_>' -ForEach @(
        'EmptyPausedSearch', 'UnsupportedFixedOption', 'WrongRunspaceBeforeSubmission',
        'SubmissionFailureIsUnknown', 'AcceptedResultFailure', 'LocalCancelDoesNotCancelNative',
        'EmptySearchDoesNotPrune', 'CorrelationSerialization', 'OlderRequestSerialization'
        'GroupedMultipleAndIdentityMerge', 'MergeCapacityRollback', 'CaptureFailurePreservesCache', 'CaptureCancellation'
        'DisposedBeforeSearch', 'DisposedAfterAcceptance', 'ActivationFailure',
        'OptionsConstructorFailure', 'DownloadSetterFailure', 'RestartSetterFailure',
        'NativeCancellation', 'NativeFailure', 'StatusAndCleanupFailure', 'CleanupOnlyFailure',
        'CanceledBeforeSubmission', 'SdkSignature'
        'Missing:AppInstallManager', 'Missing:AppUpdateOptions', 'Missing:AppInstallItem', 'Missing:AppInstallStatus'
        'Missing:SearchForAllUpdatesAsync', 'Missing:AutomaticallyDownloadAndInstallUpdateIfFound',
        'Missing:AllowForcedAppRestart', 'Missing:ProductId', 'Missing:PackageFamilyName', 'Missing:GetCurrentStatus'
        'CommandSuccess', 'CommandGrouped', 'CommandPipelineContext', 'CommandWhatIf', 'CommandDecline', 'CommandStopProcessing'
        'CommandFailure', 'CommandDisposed', 'CommandWrongRunspace', 'CommandInvalidInput'
    ) {
        { [Shmuelie.Windows.AppInstall.Tests.UpdateSearchScenarios]::Run($_) } | Should -Not -Throw
    }

    It 'executes compiled fake update search from <_> in a fresh process' -ForEach @('Source', 'Packaged') {
        $output = & pwsh -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'fixtures' 'Test-AppInstallUpdateSearch.ps1') `
            -ManifestPath $importManifests[$_] -HelperPath (Join-Path $helperOutput 'Shmuelie.Windows.AppInstall.Tests.dll')
        $LASTEXITCODE | Should -Be 0
        $output | Should -Contain 'Fake update search command passed.'
    }

    It 'documents the mutating search and its required caller inputs in compiled help' {
        $help = Get-Help Request-AppInstallUpdateSearch -Full
        ($help.description.Text -join ' ') | Should -Match 'private capability restricted to Microsoft-developed apps'
        ($help.description.Text -join ' ') | Should -Match 'queue mutation'
        ($help.description.Text -join ' ') | Should -Match 'not installation completion'
        foreach ($parameter in 'Context', 'CorrelationVector', 'ClientId') {
            ($help.parameters.parameter | Where-Object Name -EQ $parameter).required | Should -BeTrue
        }
    }

    It 'hides request correlation only in default formatting from <_>' -ForEach @('Source', 'Packaged') {
        $output = & pwsh -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'fixtures' 'Test-AppInstallUpdateSearch.ps1') `
            -ManifestPath $importManifests[$_] -HelperPath (Join-Path $helperOutput 'Shmuelie.Windows.AppInstall.Tests.dll') -ReportFormatting
        $LASTEXITCODE | Should -Be 0
        $display = $output | ConvertFrom-Json
        $display.CorrelationVector | Should -BeExactly 'SYNTHETIC-PRIVATE-VECTOR-244-7F3A'
        $display.ClientId | Should -BeExactly 'SYNTHETIC-PRIVATE-CLIENT-244-9C2B'
        foreach ($marker in $display.CorrelationVector, $display.ClientId) {
            $display.DefaultOutput | Should -Not -Match ([regex]::Escape($marker))
            $display.DeserializedDefaultOutput | Should -Not -Match ([regex]::Escape($marker))
            $display.ExplicitOutput | Should -Match ([regex]::Escape($marker))
        }
        $display.DefaultOutput | Should -Not -Match 'CorrelationVector|ClientId'
        $display.DefaultOutput | Should -Match 'Acceptance\s*:\s*Accepted'
        $display.DefaultOutput | Should -Match 'OperationState\s*:\s*Completed'
        $display.DefaultOutput | Should -Match 'ItemsAvailability\s*:\s*Available'
        $display.DefaultOutput | Should -Match 'ItemCount\s*:\s*0'
        $display.DeserializedDefaultOutput | Should -Match 'ItemCount\s*:\s*0'
        $json = $display.Json | ConvertFrom-Json
        $json.CorrelationVector | Should -BeExactly $display.CorrelationVector
        $json.ClientId | Should -BeExactly $display.ClientId
    }

    It 'returns a typed lazy context without native activation' {
        $context = New-AppInstallContext
        try {
            $context.GetType().FullName | Should -BeExactly 'Shmuelie.Windows.AppInstall.AppInstallContext'
            $context.IsActivated | Should -BeFalse
            $context.IsDisposed | Should -BeFalse
            $context.UserScope.ToString() | Should -BeExactly 'Caller'
            $context.RunspaceId | Should -Be ([System.Management.Automation.Runspaces.Runspace]::DefaultRunspace.InstanceId)
        }
        finally { $context.Dispose() }
        $context.IsDisposed | Should -BeTrue
    }

    It 'creates no context under WhatIf' {
        New-AppInstallContext -WhatIf | Should -BeNullOrEmpty
    }

    It 'loads compiled command help with the documented support restriction' {
        $help = Get-Help New-AppInstallContext -Full
        ($help.description.Text -join ' ') | Should -Match 'private capability restricted to Microsoft-developed apps'
        ($help.description.Text -join ' ') | Should -Match 'does not check or grant native authorization'
        $settingsHelp = Get-Help Get-AppInstallSettings -Full
        ($settingsHelp.description.Text -join ' ') | Should -Match 'private capability restricted to Microsoft-developed apps'
        ($settingsHelp.description.Text -join ' ') | Should -Match 'AcquisitionIdentity is not read by default'
        ($settingsHelp.parameters.parameter | Where-Object Name -EQ 'Property').description.Text -join ' ' |
            Should -Match 'AutoUpdateSetting and CanInstallForAllUsers'
    }

    It 'documents the complete <Section> matrix without treating plans as exports' -ForEach @(
        @{ Section = 'Manager properties \(5\)'; Names = @(
            'AppInstallItems', 'AppInstallItemsWithGroupSupport', 'AcquisitionIdentity', 'AutoUpdateSetting', 'CanInstallForAllUsers'
        ) }
        @{ Section = 'Manager methods \(23 families\)'; Names = @(
            'Cancel', 'GetFreeDeviceEntitlementAsync', 'GetFreeUserEntitlementAsync', 'GetFreeUserEntitlementForUserAsync',
            'GetIsAppAllowedToInstallAsync', 'GetIsAppAllowedToInstallForUserAsync', 'GetIsApplicableAsync',
            'GetIsApplicableForUserAsync', 'GetIsPackageIdentityAllowedToInstallAsync',
            'GetIsPackageIdentityAllowedToInstallForUserAsync', 'IsStoreBlockedByPolicyAsync',
            'MoveToFrontOfDownloadQueue', 'Pause', 'Restart', 'SearchForAllUpdatesAsync',
            'SearchForAllUpdatesForUserAsync', 'SearchForUpdatesAsync', 'SearchForUpdatesForUserAsync',
            'StartAppInstallAsync', 'StartProductInstallAsync', 'StartProductInstallForUserAsync',
            'UpdateAppByPackageFamilyNameAsync', 'UpdateAppByPackageFamilyNameForUserAsync'
        ) }
        @{ Section = 'Manager events \(2\)'; Names = @('ItemCompleted', 'ItemStatusChanged') }
        @{ Section = 'AppUpdateOptions \(3\)'; Names = @(
            'AutomaticallyDownloadAndInstallUpdateIfFound', 'AllowForcedAppRestart', 'CatalogId'
        ) }
        @{ Section = 'AppInstallOptions \(15\)'; Names = @(
            'AllowForcedAppRestart', 'CampaignId', 'CatalogId', 'CompletedInstallToastNotificationMode',
            'ExtendedCampaignId', 'ForceUseOfNonRemovableStorage', 'InstallForAllUsers',
            'InstallInProgressToastNotificationMode', 'LaunchAfterInstall', 'PinToDesktopAfterInstall',
            'PinToStartAfterInstall', 'PinToTaskbarAfterInstall', 'Repair', 'StageButDoNotInstall', 'TargetVolume'
        ) }
    ) {
        $document = Get-Content (Join-Path $repoRoot 'docs' 'appinstall.md') -Raw
        $table = [regex]::Match($document, "(?ms)^### $Section\r?`n(.*?)(?=^##|\z)").Groups[1].Value
        $actual = @([regex]::Matches($table, '(?m)^\| `(\w+)` \|') |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object)
        $actual | Should -Be @($Names | Sort-Object)
    }

    It 'loads <Layout> safely in a fresh process (simulated non-Windows: <Portable>)' -ForEach @(
        @{ Layout = 'Source'; Portable = $false }
        @{ Layout = 'Packaged'; Portable = $false }
        @{ Layout = 'Source'; Portable = $true }
        @{ Layout = 'Packaged'; Portable = $true }
    ) {
        $fixture = Join-Path $PSScriptRoot 'fixtures' 'Test-AppInstallModuleImport.ps1'
        $output = & pwsh -NoProfile -NonInteractive -File $fixture `
            -ManifestPath $importManifests[$Layout] -SimulateNonWindows:$Portable
        $LASTEXITCODE | Should -Be 0
        $result = $output | ConvertFrom-Json
        $result.SimulatedPlatform | Should -Be $Portable
        $result.AssemblyLoaded | Should -Be (-not $Portable)
        if ($Portable) {
            $result.CommandCount | Should -Be 0
        } else {
            $result.CommandCount | Should -Be 5
            $result.SearchHelpAvailable | Should -BeTrue
            $result.SettingsHelpAvailable | Should -BeTrue
            $result.IsActivated | Should -BeFalse
            $result.HelpAvailable | Should -BeTrue
            $result.SurvivesModuleRemoval | Should -BeTrue
        }
    }

    It 'fails explicitly when shipped projection dependency <_> is missing' -ForEach @(
        'Microsoft.Windows.SDK.NET.dll', 'WinRT.Runtime.dll'
    ) {
        $broken = Join-Path $TestDrive "missing-$_"
        Copy-Item $packagedDirectory[0].FullName $broken -Recurse
        Remove-Item -LiteralPath (Join-Path $broken 'bin' $_) -Force
        $output = & pwsh -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'fixtures' 'Test-AppInstallModuleImport.ps1') `
            -ManifestPath (Join-Path $broken 'Shmuelie.AppInstall.Experimental.psd1') -ExpectedMissingDependency $_
        $LASTEXITCODE | Should -Be 0
        ($output | ConvertFrom-Json).MissingDependency | Should -BeExactly $_
    }
}
