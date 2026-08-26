using System.Collections.Generic;
using Windows.ApplicationModel;
using Windows.Management.Deployment;

namespace Shmuelie.Windows.Cmdlets;

/// <summary>
/// Wraps the in-process WinRT <see cref="PackageManager"/> APIs used to
/// enumerate apps installed from <c>.appinstaller</c> files and to trigger their
/// update checks. The WinRT interaction lives here so the cmdlets stay thin and
/// the pure logic (see <see cref="AppInstallerHelpers"/>) stays testable.
/// </summary>
internal static class AppInstallerService
{
    /// <summary>
    /// Enumerates the current user's packages that were installed from a
    /// <c>.appinstaller</c> file and carry an update URI.
    /// </summary>
    /// <returns>One <see cref="AppInstallerApplication"/> per discovered app.</returns>
    public static IReadOnlyList<AppInstallerApplication> GetApplications()
    {
        var manager = new PackageManager();
        var results = new List<AppInstallerApplication>();

        foreach (Package package in manager.FindPackagesForUser(string.Empty))
        {
            AppInstallerInfo? info;
            try
            {
                info = package.GetAppInstallerInfo();
            }
            catch
            {
                info = null;
            }

            if (info is null)
            {
                continue;
            }

            string? uri = info.Uri?.AbsoluteUri;
            if (string.IsNullOrWhiteSpace(uri))
            {
                continue;
            }

            PackageId identity = package.Id;
            PackageVersion version = identity.Version;

            results.Add(new AppInstallerApplication
            {
                Name = identity.Name,
                PackageFullName = identity.FullName,
                PackageFamilyName = identity.FamilyName,
                Publisher = identity.Publisher,
                Version = AppInstallerHelpers.FormatVersion(version.Major, version.Minor, version.Build, version.Revision),
                Architecture = identity.Architecture.ToString(),
                AppInstallerUri = uri,
            });
        }

        return results;
    }

    /// <summary>
    /// Re-registers an App Installer file to trigger an update check, the
    /// in-process equivalent of <c>Add-AppxPackage -AppInstallerFile &lt;uri&gt;</c>.
    /// Blocks until the deployment operation completes and surfaces any failure
    /// as an exception.
    /// </summary>
    /// <param name="appInstallerUri">The App Installer update URI.</param>
    public static void Update(string appInstallerUri)
    {
        var manager = new PackageManager();
        var uri = new Uri(appInstallerUri);

        DeploymentResult result = manager
            .AddPackageByAppInstallerFileAsync(uri, AddPackageByAppInstallerOptions.None, targetVolume: null)
            .AsTask()
            .GetAwaiter()
            .GetResult();

        if (result.ExtendedErrorCode is not null)
        {
            throw result.ExtendedErrorCode;
        }
    }
}
