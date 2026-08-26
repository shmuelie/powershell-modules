using System.Collections.Generic;
using System.Management.Automation;
using System.Runtime.Versioning;

namespace Shmuelie.Windows.Cmdlets;

/// <summary>
/// Triggers update checks for apps installed from App Installer files.
/// </summary>
/// <remarks>
/// Discovers apps installed from <c>.appinstaller</c> files and re-registers
/// their App Installer URI through the in-process WinRT <c>PackageManager</c>
/// API (the equivalent of <c>Add-AppxPackage -AppInstallerFile</c>) to trigger
/// an update check. Pass one or more package names, full names, or family names
/// to update specific apps; when no name is provided, every discovered App
/// Installer app is updated. Objects from <c>Get-AppInstallerApp</c> can be
/// piped in by property name. Windows only.
/// </remarks>
[Cmdlet(VerbsData.Update, "AppInstallerApp", SupportsShouldProcess = true)]
[SupportedOSPlatform("windows10.0.19041.0")]
public sealed class UpdateAppInstallerAppCommand : AppInstallerCommandBase
{
    /// <summary>
    /// Package identity name, package full name, or package family name to
    /// update. Accepts pipeline input by property name. When omitted, every
    /// discovered App Installer app is updated.
    /// </summary>
    [Parameter(Position = 0, ValueFromPipelineByPropertyName = true)]
    [Alias("PackageName", "PackageFullName", "PackageFamilyName")]
    [ValidateNotNullOrEmpty]
    public string[]? Name { get; set; }

    private readonly List<string> _requestedNames = new();

    /// <inheritdoc/>
    protected override void BeginProcessing()
    {
        EnsureWindows();
    }

    /// <inheritdoc/>
    protected override void ProcessRecord()
    {
        if (Name is null)
        {
            return;
        }

        foreach (string name in Name)
        {
            if (!string.IsNullOrWhiteSpace(name))
            {
                _requestedNames.Add(name);
            }
        }
    }

    /// <inheritdoc/>
    protected override void EndProcessing()
    {
        IReadOnlyList<AppInstallerApplication> apps = AppInstallerService.GetApplications();

        foreach (AppInstallerApplication app in AppInstallerHelpers.FilterByNames(apps, _requestedNames))
        {
            string? uri = app.AppInstallerUri;
            if (string.IsNullOrWhiteSpace(uri))
            {
                continue;
            }

            string target = string.IsNullOrWhiteSpace(app.Name) ? uri : app.Name!;

            if (ShouldProcess(target, $"Add-AppxPackage -AppInstallerFile {uri}"))
            {
                AppInstallerService.Update(uri);
            }
        }
    }
}
