namespace Shmuelie.Windows.Cmdlets;

/// <summary>
/// Evidence that an App Installer update-check request completed without a
/// service error. Does not report an installed version or a version change.
/// </summary>
public sealed class AppInstallerUpdateRequestResult
{
    internal AppInstallerUpdateRequestResult(AppInstallerApplication application)
    {
        Name = application.Name;
        PackageFullName = application.PackageFullName;
        PackageFamilyName = application.PackageFamilyName;
        AppInstallerUri = application.AppInstallerUri;
    }

    /// <summary>Gets the package identity name.</summary>
    public string? Name { get; }

    /// <summary>Gets the package full name observed before the request.</summary>
    public string? PackageFullName { get; }

    /// <summary>Gets the package family name.</summary>
    public string? PackageFamilyName { get; }

    /// <summary>Gets the App Installer URI used for the request.</summary>
    public string? AppInstallerUri { get; }

    /// <summary>Gets the operation represented by this result.</summary>
    public string Operation => "UpdateCheck";

    /// <summary>Gets whether the request completed without a service error.</summary>
    public bool RequestCompleted => true;
}
