using System;
using System.Collections.Generic;
using System.Management.Automation;
using System.Runtime.Versioning;
using Shmuelie.Windows.Cmdlets;

/// <summary>
/// Fake <see cref="IHiveOperations"/> implementation for unit testing.
/// Records load/unload call counts and simulates success or failure
/// without touching the real Windows registry.
/// </summary>
[SupportedOSPlatform("windows")]
public sealed class FakeHiveOperations : IHiveOperations
{
    private readonly List<UserProfile> _profiles = new();

    public int LoadCallCount;
    public int UnloadCallCount;

    /// <summary>Set to non-zero to simulate a failed <c>RegLoadKey</c>.</summary>
    public int LoadReturnValue;

    /// <summary>
    /// Set to <see langword="true"/> to have <see cref="ReadMountedUserHive"/> throw,
    /// exercising the <c>finally</c>-unload guarantee after a successful load.
    /// </summary>
    public bool ThrowInRead;

    /// <summary>Registers an offline (unmounted) user profile for enumeration.</summary>
    public void AddOfflineProfile(string sid, string localPath) =>
        _profiles.Add(new UserProfile(sid, localPath, false));

    /// <summary>Installs this instance as the test seam.</summary>
    public void Install() =>
        GetInstalledApplicationsCommand.TestHiveOperations = this;

    /// <summary>Removes the test seam, restoring the real implementation.</summary>
    public static void Uninstall() =>
        GetInstalledApplicationsCommand.TestHiveOperations = null;

    // IHiveOperations ----------------------------------------------------------
    public bool IsElevated() => true;
    public void EnableHivePrivileges() { }
    // Explicit implementation hides the internal UserProfile return type from the
    // public surface, avoiding an accessibility inconsistency (CS0050).
    IReadOnlyList<UserProfile> IHiveOperations.GetUserProfiles() => _profiles;

    public int LoadHive(string subKey, string filePath)
    {
        LoadCallCount++;
        return LoadReturnValue;
    }

    public int UnloadHive(string subKey)
    {
        UnloadCallCount++;
        return 0;
    }

    public IReadOnlyList<PSObject> ReadMountedUserHive(string subKey)
    {
        if (ThrowInRead)
            throw new InvalidOperationException("Fake read failure injected by FakeHiveOperations.");
        return new List<PSObject>();
    }
}
