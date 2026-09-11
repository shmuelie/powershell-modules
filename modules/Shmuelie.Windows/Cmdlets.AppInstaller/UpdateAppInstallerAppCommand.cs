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
/// With <c>-PassThru</c>, emits a request-completion result only after the
/// App Installer operation completes. This does not establish that an
/// installed package version changed. Without <c>-PassThru</c>, emits nothing.
/// </remarks>
[Cmdlet(VerbsData.Update, "AppInstallerApp", SupportsShouldProcess = true)]
[OutputType(typeof(AppInstallerUpdateRequestResult))]
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

    /// <summary>
    /// Emits package identity and update-check request completion, not an
    /// installation or version-change result. Unmatched, skipped, and failed
    /// requests emit no completion result.
    /// </summary>
    [Parameter]
    public SwitchParameter PassThru { get; set; }

    private readonly List<string> _requestedNames = new();
    private readonly Func<IReadOnlyList<AppInstallerApplication>> _getApplications;
    private readonly Action<string> _update;

    /// <summary>
    /// Creates the cmdlet using the in-process App Installer service.
    /// </summary>
    public UpdateAppInstallerAppCommand()
        : this(AppInstallerService.GetApplications, AppInstallerService.Update)
    {
    }

    internal UpdateAppInstallerAppCommand(
        Func<IReadOnlyList<AppInstallerApplication>> getApplications,
        Action<string> update)
    {
        _getApplications = getApplications;
        _update = update;
    }

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
        IReadOnlyList<AppInstallerApplication> apps = _getApplications();

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
                _update(uri);
                if (PassThru)
                {
                    PSObject output = PSObject.AsPSObject(new AppInstallerUpdateRequestResult(app));
                    output.TypeNames.Insert(0, "Shmuelie.Windows.AppInstallerUpdateRequestResult");
                    WriteObject(output);
                }
            }
        }
    }
}
