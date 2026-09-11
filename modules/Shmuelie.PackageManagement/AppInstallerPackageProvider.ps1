function Assert-AppInstallerPackageIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Application)

    foreach ($property in 'Name', 'PackageFullName', 'PackageFamilyName', 'AppInstallerUri') {
        if ($Application.$property -isnot [string] -or [string]::IsNullOrWhiteSpace($Application.$property)) {
            throw "Shmuelie.Windows returned an invalid AppInstaller $property."
        }
    }
}

function Get-AppInstallerPackageProvider {
    [CmdletBinding()]
    param()

    [pscustomobject]@{
        Name             = 'AppInstaller'
        Platforms        = @('Windows')
        RequiredModules  = @('Shmuelie.Windows')
        RequiredCommands = @('Shmuelie.Windows\Get-AppInstallerApp', 'Shmuelie.Windows\Update-AppInstallerApp')
        OptionNames      = @()
        TestAvailable    = {
            param([hashtable]$Options)
            foreach ($name in 'Get-AppInstallerApp', 'Update-AppInstallerApp') {
                $dependency = Get-Command "Shmuelie.Windows\$name" -ListImported -ErrorAction Stop
                if ($dependency.CommandType -ne 'Cmdlet') {
                    return [pscustomobject]@{
                        Available = $false
                        Reason = "Install the compiled Shmuelie.Windows $name cmdlet to use AppInstaller."
                    }
                }
            }
            $command = Get-Command 'Shmuelie.Windows\Update-AppInstallerApp' -ListImported -ErrorAction Stop
            if (-not $command.Parameters.ContainsKey('PassThru')) {
                return [pscustomobject]@{
                    Available = $false
                    Reason = 'Upgrade Shmuelie.Windows and start a new PowerShell session: AppInstaller requires Update-AppInstallerApp -PassThru request-completion results.'
                }
            }
            [pscustomobject]@{ Available = $true; Reason = $null }
        }
        GetTargets       = {
            param([hashtable]$Options)
            $apps = @(Shmuelie.Windows\Get-AppInstallerApp -ErrorAction Stop)
            $identities = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($app in $apps) {
                Assert-AppInstallerPackageIdentity -Application $app
                if ($app.PSTypeNames -notcontains 'Shmuelie.Windows.AppInstallerApplication' -or
                    -not $app.PSObject.Properties['Version'] -or
                    ($null -ne $app.Version -and $app.Version -isnot [string]) -or
                    -not $identities.Add($app.PackageFullName)) {
                    throw 'Shmuelie.Windows returned invalid or duplicate AppInstaller application output.'
                }
            }
            foreach ($app in $apps) {
                New-PackageUpdateTarget -Target "update-check:$($app.PackageFullName)" -PreviousVersion $app.Version -Data $app
            }
        }
        Update           = {
            param($Target, [hashtable]$Options)
            # Select the exact registration, not Name (which takes precedence
            # over aliases when piping the complete application object).
            $identity = [pscustomobject]@{ PackageFullName = $Target.Data.PackageFullName }
            $results = @($identity | Shmuelie.Windows\Update-AppInstallerApp -PassThru -Confirm:$false -ErrorAction Stop)
            if ($results.Count -ne 1 -or
                $results[0].PSTypeNames -notcontains 'Shmuelie.Windows.AppInstallerUpdateRequestResult' -or
                $results[0].Operation -cne 'UpdateCheck' -or
                $results[0].RequestCompleted -isnot [bool] -or -not $results[0].RequestCompleted) {
                throw "Shmuelie.Windows returned no valid completed update-check request for '$($Target.Target)'; the outcome is unknown."
            }
            $request = $results[0]
            Assert-AppInstallerPackageIdentity -Application $request
            foreach ($property in 'Name', 'PackageFullName', 'PackageFamilyName') {
                if (-not [string]::Equals($request.$property, $Target.Data.$property, [System.StringComparison]::OrdinalIgnoreCase)) {
                    throw "Shmuelie.Windows returned a completed request for a different AppInstaller identity than '$($Target.Target)'."
                }
            }
            $result = New-PackageUpdateResult -Provider AppInstaller -Target $Target.Target -PreviousVersion $Target.PreviousVersion -Status Updated -Reason 'App Installer update-check request completed. This does not establish an installation or installed-version change.'
            $result | Add-Member -NotePropertyMembers @{
                Operation = $request.Operation
                RequestCompleted = $request.RequestCompleted
                PackageFullName = $request.PackageFullName
                PackageFamilyName = $request.PackageFamilyName
                AppInstallerUri = $request.AppInstallerUri
            }
            $result
        }
    }
}
