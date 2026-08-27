using System.Collections.Generic;
using System.Management.Automation;
using System.Runtime.Versioning;

namespace Shmuelie.Windows.Cmdlets;

/// <summary>
/// Seam for hive I/O operations used by <see cref="GetInstalledApplicationsCommand"/>.
/// The default implementation delegates to <see cref="RegistryHiveService"/> and
/// <see cref="InstalledApplicationsService"/>. Unit tests may substitute a fake
/// implementation via <see cref="GetInstalledApplicationsCommand.TestHiveOperations"/>
/// to verify control-flow without mounting a real registry hive.
/// </summary>
[SupportedOSPlatform("windows")]
internal interface IHiveOperations
{
    /// <inheritdoc cref="RegistryHiveService.IsElevated"/>
    bool IsElevated();

    /// <inheritdoc cref="RegistryHiveService.EnableHivePrivileges"/>
    void EnableHivePrivileges();

    /// <inheritdoc cref="RegistryHiveService.GetUserProfiles"/>
    IReadOnlyList<UserProfile> GetUserProfiles();

    /// <inheritdoc cref="RegistryHiveService.LoadHive"/>
    int LoadHive(string subKey, string filePath);

    /// <inheritdoc cref="RegistryHiveService.UnloadHive"/>
    int UnloadHive(string subKey);

    /// <inheritdoc cref="InstalledApplicationsService.ReadMountedUserHive"/>
    IReadOnlyList<PSObject> ReadMountedUserHive(string subKey);
}

/// <summary>
/// Production implementation of <see cref="IHiveOperations"/> backed by the
/// real <see cref="RegistryHiveService"/> and <see cref="InstalledApplicationsService"/>.
/// </summary>
[SupportedOSPlatform("windows")]
internal sealed class DefaultHiveOperations : IHiveOperations
{
    public static readonly DefaultHiveOperations Instance = new();
    private DefaultHiveOperations() { }

    public bool IsElevated() => RegistryHiveService.IsElevated();
    public void EnableHivePrivileges() => RegistryHiveService.EnableHivePrivileges();
    public IReadOnlyList<UserProfile> GetUserProfiles() => RegistryHiveService.GetUserProfiles();
    public int LoadHive(string subKey, string filePath) => RegistryHiveService.LoadHive(subKey, filePath);
    public int UnloadHive(string subKey) => RegistryHiveService.UnloadHive(subKey);
    public IReadOnlyList<PSObject> ReadMountedUserHive(string subKey) => InstalledApplicationsService.ReadMountedUserHive(subKey);
}
