$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'The compiled subst target fixture requires Windows.' }
if ('Shmuelie.Windows.Cmdlets.NewSubstDriveCommand' -as [type]) {
    throw 'Run this fixture in a fresh no-profile process without a native Windows module.'
}
$modulePath = Join-Path $PSHOME 'Modules'
$env:PSModulePath = $modulePath
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$source = Join-Path $repoRoot 'modules' 'Shmuelie.Windows' 'Cmdlets'
# Only the fake service is compiled; provider resolution and cmdlet behavior remain real.
Add-Type -Path @(
    Join-Path $PSScriptRoot 'SubstTargetFixture.cs'
    Join-Path $source 'SubstDriveCommandBase.cs'
    Join-Path $source 'SubstDrive.cs'
    Join-Path $source 'NewSubstDriveCommand.cs'
) -CompilerOptions '/nullable:enable' -ErrorAction Stop

$root = Join-Path ([IO.Path]::GetTempPath()) ('ShmuelieSubstTarget-' + [guid]::NewGuid().ToString('N'))
$directories = @('TargetOne', 'TargetTwo', 'UniqueDirectory', 'MixedDirectory') |
    ForEach-Object { Join-Path $root $_ }
$files = @('SingleFile.txt', 'MixedFile.txt', 'FilesOne.txt', 'FilesTwo.txt') |
    ForEach-Object { Join-Path $root $_ }
$unique = Join-Path $root 'UniqueDirectory'
$cases = @(
    @{ Name = 'multiple directories'; Path = (Join-Path $root 'Target*'); Error = 'AmbiguousTargetPath'; Category = 'InvalidArgument' }
    @{ Name = 'absolute directory'; Path = $unique; Mappings = 1; Expected = $unique }
    @{ Name = 'relative directory'; Path = 'UniqueDirectory'; Mappings = 1; Expected = $unique }
    @{ Name = 'provider-qualified directory'; Path = "FileSystem::$unique"; Mappings = 1; Expected = $unique }
    @{ Name = 'single wildcard directory'; Path = (Join-Path $root 'Unique*'); Mappings = 1; Expected = $unique }
    @{ Name = 'relative single wildcard'; Path = 'Unique*'; Mappings = 1; Expected = $unique }
    @{ Name = 'zero wildcard matches'; Path = (Join-Path $root 'Missing*'); Error = 'TargetNotDirectory'; Category = 'ObjectNotFound' }
    @{ Name = 'missing literal directory'; Path = (Join-Path $root 'Missing'); Error = 'TargetNotDirectory'; Category = 'ObjectNotFound' }
    @{ Name = 'file target'; Path = (Join-Path $root 'SingleFile.txt'); Error = 'TargetNotDirectory'; Category = 'ObjectNotFound' }
    @{ Name = 'single wildcard file'; Path = (Join-Path $root 'Single*'); Error = 'TargetNotDirectory'; Category = 'ObjectNotFound' }
    @{ Name = 'mixed directory and file'; Path = (Join-Path $root 'Mixed*'); Error = 'AmbiguousTargetPath'; Category = 'InvalidArgument' }
    @{ Name = 'multiple files'; Path = (Join-Path $root 'Files*'); Error = 'AmbiguousTargetPath'; Category = 'InvalidArgument' }
    @{ Name = 'ambiguous WhatIf'; Path = (Join-Path $root 'Target*'); WhatIf = $true; Error = 'AmbiguousTargetPath'; Category = 'InvalidArgument' }
    @{ Name = 'ambiguous Confirm'; Path = (Join-Path $root 'Target*'); Confirm = $true; Error = 'AmbiguousTargetPath'; Category = 'InvalidArgument' }
    @{ Name = 'non-filesystem provider'; Path = 'Variable:OwnedSubstTarget'; Error = 'TargetNotFileSystem'; Category = 'InvalidArgument' }
    @{ Name = 'non-filesystem multiple matches'; Path = 'Variable:OwnedSubst*'; Error = 'TargetNotFileSystem'; Category = 'InvalidArgument' }
    @{ Name = 'non-filesystem WhatIf'; Path = 'Variable:OwnedSubstTarget'; WhatIf = $true; Error = 'TargetNotFileSystem'; Category = 'InvalidArgument' }
    @{ Name = 'single target WhatIf'; Path = $unique; WhatIf = $true; Checks = 1 }
    @{ Name = 'inherited WhatIf'; Path = $unique; InheritedWhatIf = $true; Checks = 1 }
    @{ Name = 'explicit WhatIf false'; Path = $unique; InheritedWhatIf = $true; WhatIf = $false; Mappings = 1; Expected = $unique }
    @{ Name = 'approved confirmation'; Path = $unique; Confirm = $true; Approve = $true; Prompts = 1; Mappings = 1; Expected = $unique }
    @{ Name = 'declined confirmation'; Path = $unique; Confirm = $true; Prompts = 1; Checks = 1 }
    @{ Name = 'declined single wildcard'; Path = (Join-Path $root 'Unique*'); Confirm = $true; Prompts = 1; Checks = 1 }
    @{ Name = 'drive in use'; Path = $unique; DriveInUse = $true; Checks = 1; Error = 'DriveLetterInUse'; Category = 'ResourceExists'; ErrorTarget = 'S:' }
    @{ Name = 'ambiguity precedes drive check'; Path = (Join-Path $root 'Target*'); DriveInUse = $true; Error = 'AmbiguousTargetPath'; Category = 'InvalidArgument' }
    @{ Name = 'mapping failure preserved'; Path = $unique; FailMapping = $true; Checks = 1; Attempts = 1; Error = 'CreateMappingFailed'; Category = 'NotSpecified'; ErrorTarget = 'S:' }
    @{ Name = 'relative multiple matches'; Path = 'Target*'; Error = 'AmbiguousTargetPath'; Category = 'InvalidArgument' }
    @{ Name = 'provider-qualified multiple matches'; Path = "FileSystem::$(Join-Path $root 'Target*')"; Error = 'AmbiguousTargetPath'; Category = 'InvalidArgument' }
)
$results = [System.Collections.Generic.List[object]]::new()
if ([IO.Directory]::Exists($root)) { throw 'Owned fixture root already exists.' }
try {
    $null = [IO.Directory]::CreateDirectory($root)
    foreach ($directory in $directories) {
        $null = [IO.Directory]::CreateDirectory($directory)
        $null = [Shmuelie.Windows.Cmdlets.SubstTargetFixture]::AllowedTargets.Add($directory)
    }
    foreach ($file in $files) { [IO.File]::WriteAllText($file, '') }
    foreach ($case in $cases) {
        [Shmuelie.Windows.Cmdlets.SubstTargetFixture]::Reset()
        [Shmuelie.Windows.Cmdlets.SubstTargetFixture]::DriveInUse = [bool]$case.DriveInUse
        [Shmuelie.Windows.Cmdlets.SubstTargetFixture]::FailMapping = [bool]$case.FailMapping
        $testHost = [Shmuelie.Windows.Cmdlets.SubstTargetHost]::new()
        $testHost.TestUI.Approve = [bool]$case.Approve
        $initial = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2()
        $initial.EnvironmentVariables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new(
            'PSModulePath', $modulePath, $null))
        $initial.ImportPSModule(@(Join-Path $modulePath 'Microsoft.PowerShell.Management' 'Microsoft.PowerShell.Management.psd1'))
        $initial.Commands.Add([System.Management.Automation.Runspaces.SessionStateCmdletEntry]::new(
            'New-SubstDrive', [Shmuelie.Windows.Cmdlets.NewSubstDriveCommand], $null))
        $runspace = [runspacefactory]::CreateRunspace($testHost, $initial)
        $ps = [powershell]::Create()
        try {
            $runspace.Open()
            if ($env:PSModulePath -cne $modulePath) { throw 'The target fixture module path is not isolated.' }
            $location = $runspace.SessionStateProxy.Path.SetLocation($root)
            if ($location.Provider.Name -cne 'FileSystem' -or $location.ProviderPath -cne $root) {
                throw 'The fixture could not enter its exact owned filesystem location.'
            }
            $runspace.SessionStateProxy.SetVariable('OwnedSubstTarget', $unique)
            $runspace.SessionStateProxy.SetVariable('OwnedSubstOther', $unique)
            if ($case.InheritedWhatIf) { $runspace.SessionStateProxy.SetVariable('WhatIfPreference', $true) }
            $ps.Runspace = $runspace
            $null = $ps.AddCommand('New-SubstDrive').AddParameter('DriveLetter', 'S').
                AddParameter('TargetPath', $case.Path).AddParameter('Confirm', [bool]$case.Confirm)
            if ($case.ContainsKey('WhatIf')) { $null = $ps.AddParameter('WhatIf', $case.WhatIf) }
            $terminatingError = $null
            try { $output = $ps.Invoke() }
            catch [System.Management.Automation.MethodInvocationException] {
                if ($_.Exception.InnerException -isnot [System.Management.Automation.RuntimeException]) { throw }
                $terminatingError = $_.Exception.InnerException.ErrorRecord
                $output = @()
            }
            $errors = @($ps.Streams.Error)
            if ($errors.Count -eq 0 -and $terminatingError) { $errors = @($terminatingError) }
            $expectedMappings = [int]$case.Mappings
            $expectedChecks = if ($case.ContainsKey('Checks')) { $case.Checks } else { $expectedMappings }
            $expectedAttempts = if ($case.ContainsKey('Attempts')) { $case.Attempts } else { $expectedMappings }
            $expectedErrors = if ($case.Error) { 1 } else { 0 }
            if ($errors.Count -ne $expectedErrors -or $output.Count -ne $expectedMappings -or
                [Shmuelie.Windows.Cmdlets.SubstTargetFixture]::DriveChecks -ne $expectedChecks -or
                [Shmuelie.Windows.Cmdlets.SubstTargetFixture]::MappingAttempts -ne $expectedAttempts -or
                [Shmuelie.Windows.Cmdlets.SubstTargetFixture]::Mappings.Count -ne $expectedMappings -or
                $testHost.TestUI.PromptCount -ne [int]$case.Prompts) {
                throw "$($case.Name): errors=$($errors.Count), output=$($output.Count), checks=$([Shmuelie.Windows.Cmdlets.SubstTargetFixture]::DriveChecks), attempts=$([Shmuelie.Windows.Cmdlets.SubstTargetFixture]::MappingAttempts), mappings=$([Shmuelie.Windows.Cmdlets.SubstTargetFixture]::Mappings.Count), prompts=$($testHost.TestUI.PromptCount). $($errors -join '; ')"
            }
            if ($case.Error) {
                $target = if ($case.ContainsKey('ErrorTarget')) { $case.ErrorTarget } else { $case.Path }
                if ($errors[0].FullyQualifiedErrorId -notlike "$($case.Error),*" -or
                    $errors[0].CategoryInfo.Category.ToString() -cne $case.Category -or
                    $errors[0].TargetObject -cne $target) {
                    throw "$($case.Name): incorrect error identity/category/target: $($errors[0] | Out-String)"
                }
                if ($case.Error -eq 'AmbiguousTargetPath' -and
                    $errors[0].Exception.Message -notlike '*exactly one*') {
                    throw 'Ambiguous target error did not explain the single-target requirement.'
                }
            }
            if ($expectedMappings) {
                if ($output[0] -isnot [Shmuelie.Windows.Cmdlets.SubstDrive] -or
                    $output[0].DriveLetter -cne 'S:' -or $output[0].TargetPath -cne $case.Expected -or
                    [Shmuelie.Windows.Cmdlets.SubstTargetFixture]::Mappings[0].TargetPath -cne $case.Expected) {
                    throw "$($case.Name): mapping output changed."
                }
            }
            $results.Add([pscustomobject]@{
                Name = $case.Name
                Passed = $true
                ErrorId = if ($errors.Count) { $errors[0].FullyQualifiedErrorId } else { $null }
                OutputCount = $output.Count
                DriveChecks = [Shmuelie.Windows.Cmdlets.SubstTargetFixture]::DriveChecks
                MappingAttempts = [Shmuelie.Windows.Cmdlets.SubstTargetFixture]::MappingAttempts
                Mappings = [Shmuelie.Windows.Cmdlets.SubstTargetFixture]::Mappings.Count
                Prompts = $testHost.TestUI.PromptCount
            })
        }
        finally {
            $ps.Dispose()
            $runspace.Dispose()
        }
    }
}
finally {
    [Shmuelie.Windows.Cmdlets.SubstTargetFixture]::Reset()
    [Shmuelie.Windows.Cmdlets.SubstTargetFixture]::AllowedTargets.Clear()
    foreach ($file in $files) { [IO.File]::Delete($file) }
    foreach ($directory in $directories) {
        if ([IO.Directory]::Exists($directory)) { [IO.Directory]::Delete($directory, $false) }
    }
    if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root, $false) }
}
[pscustomobject]@{
    Passed = $results.Count
    Failed = 0
    Cases = $results
    OwnedRoot = $root
    OwnedRootRemoved = -not [IO.Directory]::Exists($root)
} | ConvertTo-Json -Depth 4
