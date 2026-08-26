using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Security.Principal;
using Microsoft.Win32;

namespace Shmuelie.Windows.Cmdlets;

/// <summary>
/// A user profile discovered from the machine's <c>ProfileList</c>, used to
/// decide whether an offline <c>NTUSER.DAT</c> hive must be mounted before its
/// uninstall keys can be read.
/// </summary>
/// <param name="Sid">The profile's security identifier.</param>
/// <param name="LocalPath">The profile directory (<c>ProfileImagePath</c>).</param>
/// <param name="Loaded">Whether the profile hive is already mounted under <c>HKEY_USERS</c>.</param>
internal readonly record struct UserProfile(string Sid, string LocalPath, bool Loaded);

/// <summary>
/// Wraps the Win32 registry-hive APIs (<c>RegLoadKey</c> / <c>RegUnLoadKey</c>)
/// and the token-privilege plumbing they require, plus the profile enumeration
/// used to locate offline user hives. Keeping the P/Invoke surface here lets the
/// cmdlet stay thin, and mirrors the pattern established by the subst cmdlets.
/// </summary>
[SupportedOSPlatform("windows")]
internal static class RegistryHiveService
{
    private static readonly IntPtr HKEY_USERS = new(unchecked((int)0x80000003));

    private const uint SE_PRIVILEGE_ENABLED = 0x00000002;
    private const uint TOKEN_ADJUST_PRIVILEGES = 0x0020;
    private const uint TOKEN_QUERY = 0x0008;

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "RegLoadKeyW")]
    private static extern int RegLoadKey(IntPtr hKey, string lpSubKey, string lpFile);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "RegUnLoadKeyW")]
    private static extern int RegUnLoadKey(IntPtr hKey, string lpSubKey);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool OpenProcessToken(IntPtr processHandle, uint desiredAccess, out IntPtr tokenHandle);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool LookupPrivilegeValue(string? systemName, string name, out LUID luid);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AdjustTokenPrivileges(IntPtr tokenHandle, [MarshalAs(UnmanagedType.Bool)] bool disableAllPrivileges, ref TOKEN_PRIVILEGES newState, uint bufferLength, IntPtr previousState, IntPtr returnLength);

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);

    [StructLayout(LayoutKind.Sequential)]
    private struct LUID
    {
        public uint LowPart;
        public int HighPart;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct LUID_AND_ATTRIBUTES
    {
        public LUID Luid;
        public uint Attributes;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct TOKEN_PRIVILEGES
    {
        public uint PrivilegeCount;
        public LUID_AND_ATTRIBUTES Privilege;
    }

    /// <summary>
    /// Determines whether the current process is running elevated (as a member
    /// of the local Administrators role).
    /// </summary>
    public static bool IsElevated()
    {
        using WindowsIdentity identity = WindowsIdentity.GetCurrent();
        return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
    }

    /// <summary>
    /// Enables the <c>SeBackupPrivilege</c> and <c>SeRestorePrivilege</c>
    /// privileges required to mount an offline hive. A privilege the caller does
    /// not hold is silently left disabled; the subsequent load simply fails.
    /// </summary>
    public static void EnableHivePrivileges()
    {
        EnablePrivilege("SeBackupPrivilege");
        EnablePrivilege("SeRestorePrivilege");
    }

    /// <summary>
    /// Mounts an offline hive file under <c>HKEY_USERS\{subKey}</c>.
    /// </summary>
    /// <param name="subKey">The subkey name to mount the hive as, for example <c>temp</c>.</param>
    /// <param name="filePath">The hive file, for example a profile's <c>NTUSER.DAT</c>.</param>
    /// <returns>The Win32 status (<c>0</c> on success).</returns>
    public static int LoadHive(string subKey, string filePath) => RegLoadKey(HKEY_USERS, subKey, filePath);

    /// <summary>
    /// Unmounts a hive previously mounted under <c>HKEY_USERS\{subKey}</c>.
    /// </summary>
    /// <param name="subKey">The mounted subkey name, for example <c>temp</c>.</param>
    /// <returns>The Win32 status (<c>0</c> on success).</returns>
    public static int UnloadHive(string subKey) => RegUnLoadKey(HKEY_USERS, subKey);

    /// <summary>
    /// Enumerates the machine's real user profiles (<c>S-1-5-21-*</c>) from the
    /// registry <c>ProfileList</c>, reporting whether each hive is already
    /// mounted. This is the registry equivalent of enumerating
    /// <c>Win32_UserProfile</c> and avoids a WMI/CIM dependency.
    /// </summary>
    public static IReadOnlyList<UserProfile> GetUserProfiles()
    {
        var profiles = new List<UserProfile>();
        using RegistryKey machine = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64);
        using RegistryKey? profileList = machine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList");
        if (profileList is null)
        {
            return profiles;
        }

        using RegistryKey users = RegistryKey.OpenBaseKey(RegistryHive.Users, RegistryView.Registry64);
        foreach (string sid in profileList.GetSubKeyNames())
        {
            if (!sid.StartsWith("S-1-5-21-", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            using RegistryKey? profileKey = profileList.OpenSubKey(sid);
            string localPath = profileKey?.GetValue("ProfileImagePath") as string ?? string.Empty;

            bool loaded;
            using (RegistryKey? loadedKey = users.OpenSubKey(sid))
            {
                loaded = loadedKey is not null;
            }

            profiles.Add(new UserProfile(sid, localPath, loaded));
        }

        return profiles;
    }

    private static void EnablePrivilege(string name)
    {
        if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out IntPtr token))
        {
            return;
        }

        try
        {
            if (!LookupPrivilegeValue(null, name, out LUID luid))
            {
                return;
            }

            var privileges = new TOKEN_PRIVILEGES
            {
                PrivilegeCount = 1,
                Privilege = new LUID_AND_ATTRIBUTES { Luid = luid, Attributes = SE_PRIVILEGE_ENABLED },
            };

            AdjustTokenPrivileges(token, false, ref privileges, 0, IntPtr.Zero, IntPtr.Zero);
        }
        finally
        {
            CloseHandle(token);
        }
    }
}
