global using System;
global using System.Collections.Generic;
global using System.IO;

using System.Management.Automation;

namespace Shmuelie.Windows.Cmdlets;

// The isolated fixture excludes both production registry services entirely.
internal readonly record struct UserProfile(string Sid, string LocalPath, bool Loaded);

internal static class RegistryHiveService
{
    public static bool IsElevated() => throw new InvalidOperationException("The hive fake must be installed.");
    public static void EnableHivePrivileges() => throw new InvalidOperationException("The hive fake must be installed.");
    public static IReadOnlyList<UserProfile> GetUserProfiles() => throw new InvalidOperationException("The hive fake must be installed.");
    public static int LoadHive(string subKey, string filePath) => throw new InvalidOperationException("Native hive loading is forbidden.");
    public static int UnloadHive(string subKey) => throw new InvalidOperationException("Native hive unloading is forbidden.");
}

internal static class InstalledApplicationsService
{
    public static List<PSObject> ReadLocalMachine()
    {
        InstalledApplicationsScopeFixture.GlobalReads++;
        return InstalledApplicationsScopeFixture.Application("Global");
    }

    public static List<PSObject> ReadCurrentUser()
    {
        InstalledApplicationsScopeFixture.CurrentReads++;
        return InstalledApplicationsScopeFixture.Application("CurrentUser");
    }

    public static List<PSObject> ReadMountedUserHive(string subKey) =>
        throw new InvalidOperationException("The hive fake must be installed.");
}

internal sealed class ScopeHiveOperations : IHiveOperations
{
    private bool _privilegesEnabled;
    private bool _loaded;

    public bool IsElevated()
    {
        InstalledApplicationsScopeFixture.ElevationChecks++;
        return InstalledApplicationsScopeFixture.Elevated;
    }

    public void EnableHivePrivileges()
    {
        if (!InstalledApplicationsScopeFixture.Elevated)
            throw new InvalidOperationException("Unelevated fixture cannot enable privileges.");
        InstalledApplicationsScopeFixture.PrivilegeCalls++;
        _privilegesEnabled = true;
    }

    public IReadOnlyList<UserProfile> GetUserProfiles()
    {
        InstalledApplicationsScopeFixture.ProfileReads++;
        return new[]
        {
            new UserProfile("S-1-5-21-loaded-fixture", "", true),
            new UserProfile("S-1-5-21-offline-fixture", InstalledApplicationsScopeFixture.OfflinePath, false),
        };
    }

    public int LoadHive(string subKey, string filePath)
    {
        if (!_privilegesEnabled || subKey != "temp" ||
            filePath != Path.Combine(InstalledApplicationsScopeFixture.OfflinePath, "NTUSER.DAT"))
            throw new InvalidOperationException("Unexpected fixture load.");
        InstalledApplicationsScopeFixture.LoadCalls++;
        _loaded = InstalledApplicationsScopeFixture.LoadStatus == 0;
        return InstalledApplicationsScopeFixture.LoadStatus;
    }

    public int UnloadHive(string subKey)
    {
        if (!_loaded || subKey != "temp") throw new InvalidOperationException("Unexpected fixture unload.");
        InstalledApplicationsScopeFixture.UnloadCalls++;
        _loaded = false;
        return 0;
    }

    public IReadOnlyList<PSObject> ReadMountedUserHive(string subKey)
    {
        if (subKey == "S-1-5-21-loaded-fixture")
        {
            InstalledApplicationsScopeFixture.MountedReads++;
            return InstalledApplicationsScopeFixture.Application("MountedUser");
        }
        if (!_loaded || subKey != "temp") throw new InvalidOperationException("Unexpected fixture hive read.");
        InstalledApplicationsScopeFixture.OfflineReads++;
        if (InstalledApplicationsScopeFixture.ThrowOfflineRead)
            throw new InvalidOperationException("Synthetic offline hive read failure.");
        return InstalledApplicationsScopeFixture.Application("OfflineUser");
    }
}

public static class InstalledApplicationsScopeFixture
{
    public static string OfflinePath = "";
    public static bool Elevated;
    public static bool ThrowOfflineRead;
    public static int LoadStatus;
    public static int GlobalReads, CurrentReads, ProfileReads, MountedReads, OfflineReads;
    public static int ElevationChecks, PrivilegeCalls, LoadCalls, UnloadCalls;

    internal static List<PSObject> Application(string name)
    {
        var result = new PSObject();
        result.Properties.Add(new PSNoteProperty("DisplayName", name));
        return new List<PSObject> { result };
    }

    public static void Reset(string offlinePath)
    {
        OfflinePath = offlinePath;
        Elevated = true;
        ThrowOfflineRead = false;
        LoadStatus = 0;
        GlobalReads = CurrentReads = ProfileReads = MountedReads = OfflineReads = 0;
        ElevationChecks = PrivilegeCalls = LoadCalls = UnloadCalls = 0;
        GetInstalledApplicationsCommand.TestHiveOperations = new ScopeHiveOperations();
    }

    public static void Uninstall() => GetInstalledApplicationsCommand.TestHiveOperations = null;
}
