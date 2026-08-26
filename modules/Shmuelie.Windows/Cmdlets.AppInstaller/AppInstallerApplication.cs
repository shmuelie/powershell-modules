namespace Shmuelie.Windows.Cmdlets;

/// <summary>
/// Describes an app installed from a <c>.appinstaller</c> file, as emitted by
/// <c>Get-AppInstallerApp</c>. The property shape mirrors the previous
/// script-based cmdlet so downstream consumers (and the
/// <c>Shmuelie.Windows.AppInstallerApplication</c> type name) are preserved.
/// </summary>
public sealed class AppInstallerApplication
{
    /// <summary>
    /// Gets the package identity name.
    /// </summary>
    public string? Name { get; init; }

    /// <summary>
    /// Gets the package full name.
    /// </summary>
    public string? PackageFullName { get; init; }

    /// <summary>
    /// Gets the package family name.
    /// </summary>
    public string? PackageFamilyName { get; init; }

    /// <summary>
    /// Gets the package publisher.
    /// </summary>
    public string? Publisher { get; init; }

    /// <summary>
    /// Gets the package version, formatted as <c>Major.Minor.Build.Revision</c>.
    /// </summary>
    public string? Version { get; init; }

    /// <summary>
    /// Gets the package processor architecture.
    /// </summary>
    public string? Architecture { get; init; }

    /// <summary>
    /// Gets the configured App Installer update URI.
    /// </summary>
    public string? AppInstallerUri { get; init; }
}
