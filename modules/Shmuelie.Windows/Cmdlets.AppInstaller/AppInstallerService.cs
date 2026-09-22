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
    /// Submits the original App Installer file for an update check without
    /// forcing applications to close. On Windows build 22556 and later, in-use
    /// package registration is deferred until the application's next activation.
    /// Blocks until the request completes and surfaces any failure as an exception.
    /// </summary>
    /// <param name="appInstallerUri">The App Installer update URI.</param>
    public static void Update(string appInstallerUri)
        => Update(appInstallerUri, Environment.OSVersion.Version);

    internal static void Update(string appInstallerUri, Version windowsVersion)
    {
        if (windowsVersion < new Version(10, 0, 19041))
        {
            throw new PlatformNotSupportedException("App Installer updates require Windows build 19041 or later.");
        }

        var manager = new PackageManager();
        var uri = new Uri(appInstallerUri);

        // The API exists at 19041, but accepts App Installer URIs only at 22556+.
        // https://learn.microsoft.com/uwp/api/windows.management.deployment.packagemanager.addpackagebyuriasync
        var operation = windowsVersion >= new Version(10, 0, 22556)
            ? manager.AddPackageByUriAsync(uri, new AddPackageOptions
            {
                DeferRegistrationWhenPackagesAreInUse = true,
                ForceAppShutdown = false,
                ForceTargetAppShutdown = false,
            })
            : manager.AddPackageByAppInstallerFileAsync(uri, AddPackageByAppInstallerOptions.None, targetVolume: null);

        DeploymentResult result = operation.AsTask().GetAwaiter().GetResult();

        if (result.ExtendedErrorCode is not null)
        {
            throw result.ExtendedErrorCode;
        }
    }
}
