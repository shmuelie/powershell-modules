using System.Collections.Generic;
using System.Management.Automation;
using System.Runtime.Versioning;

namespace Shmuelie.Windows.Cmdlets;

/// <summary>
/// Lists apps installed from App Installer (<c>.appinstaller</c>) files.
/// </summary>
/// <remarks>
/// Enumerates the current user's MSIX/AppX packages that have an associated
/// <c>.appinstaller</c> file and returns their package identity plus the
/// configured App Installer update URI. This reads the App Installer metadata
/// in-process through the WinRT <c>PackageManager</c> API; earlier versions
/// shelled out to Windows PowerShell 5.1. Returns nothing (no error) when no
/// such apps are installed. Windows only.
/// </remarks>
[Cmdlet(VerbsCommon.Get, "AppInstallerApp")]
[OutputType(typeof(AppInstallerApplication))]
[SupportedOSPlatform("windows10.0.19041.0")]
public sealed class GetAppInstallerAppCommand : AppInstallerCommandBase
{
    /// <inheritdoc/>
    protected override void BeginProcessing()
    {
        EnsureWindows();
    }

    /// <inheritdoc/>
    protected override void ProcessRecord()
    {
        IReadOnlyList<AppInstallerApplication> apps = AppInstallerService.GetApplications();
        foreach (AppInstallerApplication app in apps)
        {
            WriteObject(AsTypedObject(app));
        }
    }
}
