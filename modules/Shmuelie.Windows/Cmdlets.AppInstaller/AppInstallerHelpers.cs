using System.Collections.Generic;

namespace Shmuelie.Windows.Cmdlets;

/// <summary>
/// Pure, WinRT-free helpers for shaping and matching App Installer applications.
/// These are deliberately independent of
/// <see cref="Windows.Management.Deployment.PackageManager"/> so the matching
/// and object-shaping logic can be unit-tested without a live package host.
/// </summary>
public static class AppInstallerHelpers
{
    /// <summary>
    /// The type name attached to every emitted <see cref="AppInstallerApplication"/>
    /// so the object shape matches the previous script-based cmdlet.
    /// </summary>
    public const string TypeName = "Shmuelie.Windows.AppInstallerApplication";

    /// <summary>
    /// Formats a package version as <c>Major.Minor.Build.Revision</c>, matching
    /// the previous script.
    /// </summary>
    public static string FormatVersion(ushort major, ushort minor, ushort build, ushort revision)
    {
        return $"{major}.{minor}.{build}.{revision}";
    }

    /// <summary>
    /// Determines whether an app matches a requested name. The comparison is
    /// case-insensitive and considers the package identity name, the package
    /// full name, and the package family name, mirroring the script's
    /// <c>Test-AppInstallerAppMatch</c>.
    /// </summary>
    /// <param name="app">The candidate application.</param>
    /// <param name="name">The requested name, full name, or family name.</param>
    public static bool NameMatches(AppInstallerApplication app, string name)
    {
        ArgumentNullException.ThrowIfNull(app);

        if (string.IsNullOrWhiteSpace(name))
        {
            return false;
        }

        foreach (string? candidate in new[] { app.Name, app.PackageFullName, app.PackageFamilyName })
        {
            if (!string.IsNullOrEmpty(candidate) &&
                candidate.Equals(name, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
    }

    /// <summary>
    /// Filters a set of apps to those matching any of the requested names. When
    /// no names are supplied, every app is returned (the "update all" path).
    /// </summary>
    /// <param name="apps">The discovered applications.</param>
    /// <param name="names">The requested names, or an empty/absent set for all.</param>
    public static IEnumerable<AppInstallerApplication> FilterByNames(
        IEnumerable<AppInstallerApplication> apps,
        IReadOnlyCollection<string>? names)
    {
        ArgumentNullException.ThrowIfNull(apps);

        if (names is null || names.Count == 0)
        {
            foreach (AppInstallerApplication app in apps)
            {
                yield return app;
            }

            yield break;
        }

        foreach (AppInstallerApplication app in apps)
        {
            foreach (string name in names)
            {
                if (NameMatches(app, name))
                {
                    yield return app;
                    break;
                }
            }
        }
    }
}
