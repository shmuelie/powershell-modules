using System.Collections.Generic;
using System.Management.Automation;
using System.Runtime.Versioning;
using Microsoft.Win32;

namespace Shmuelie.Windows.Cmdlets;

/// <summary>
/// Reads the Windows "uninstall" registry keys and shapes each application
/// subkey into a <see cref="PSObject"/> whose note properties mirror the values
/// produced by <c>Get-ItemProperty</c>, preserving the public object contract of
/// the original script (<c>DisplayName</c>, <c>DisplayVersion</c>, and so on).
/// </summary>
[SupportedOSPlatform("windows")]
internal static class InstalledApplicationsService
{
    private const string Wow6432Path = @"SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall";
    private const string NativePath = @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall";
    private const string RegistryProviderId = @"Microsoft.PowerShell.Core\Registry";

    /// <summary>
    /// Reads machine-wide (HKLM) installed applications from both the 32-bit
    /// (<c>Wow6432Node</c>) and native uninstall paths.
    /// </summary>
    public static List<PSObject> ReadLocalMachine()
    {
        using RegistryKey baseKey = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64);
        return ReadUninstallPaths(baseKey, "HKEY_LOCAL_MACHINE");
    }

    /// <summary>
    /// Reads the current user's (HKCU) installed applications from both the
    /// 32-bit and native uninstall paths.
    /// </summary>
    public static List<PSObject> ReadCurrentUser()
    {
        using RegistryKey baseKey = RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, RegistryView.Registry64);
        return ReadUninstallPaths(baseKey, "HKEY_CURRENT_USER");
    }

    /// <summary>
    /// Reads installed applications from a user hive that is already mounted
    /// under <c>HKEY_USERS</c> (either a live profile SID or the temporary
    /// mount point used for an offline hive).
    /// </summary>
    /// <param name="subKey">The mounted subkey, for example a SID or <c>temp</c>.</param>
    public static List<PSObject> ReadMountedUserHive(string subKey)
    {
        using RegistryKey usersBase = RegistryKey.OpenBaseKey(RegistryHive.Users, RegistryView.Registry64);
        using RegistryKey? hiveKey = usersBase.OpenSubKey(subKey);
        if (hiveKey is null)
        {
            return new List<PSObject>();
        }

        return ReadUninstallPaths(hiveKey, $"HKEY_USERS\\{subKey}");
    }

    private static List<PSObject> ReadUninstallPaths(RegistryKey baseKey, string basePathLabel)
    {
        var applications = new List<PSObject>();

        // Match the script's ordering: 32-bit (Wow6432Node) first, then native.
        foreach (string uninstallPath in new[] { Wow6432Path, NativePath })
        {
            using RegistryKey? uninstallKey = baseKey.OpenSubKey(uninstallPath);
            if (uninstallKey is null)
            {
                continue;
            }

            string parentPath = $"{RegistryProviderId}::{basePathLabel}\\{uninstallPath}";
            foreach (string appName in uninstallKey.GetSubKeyNames())
            {
                using RegistryKey? appKey = uninstallKey.OpenSubKey(appName);
                if (appKey is null)
                {
                    continue;
                }

                applications.Add(BuildApplicationObject(appKey, appName, parentPath));
            }
        }

        return applications;
    }

    private static PSObject BuildApplicationObject(RegistryKey appKey, string childName, string parentPath)
    {
        var application = new PSObject();

        foreach (string valueName in appKey.GetValueNames())
        {
            string propertyName = string.IsNullOrEmpty(valueName) ? "(default)" : valueName;
            if (application.Properties[propertyName] is not null)
            {
                continue;
            }

            application.Properties.Add(new PSNoteProperty(propertyName, appKey.GetValue(valueName)));
        }

        AddIfMissing(application, "PSPath", $"{parentPath}\\{childName}");
        AddIfMissing(application, "PSParentPath", parentPath);
        AddIfMissing(application, "PSChildName", childName);
        AddIfMissing(application, "PSProvider", RegistryProviderId);

        return application;
    }

    private static void AddIfMissing(PSObject target, string name, object value)
    {
        if (target.Properties[name] is null)
        {
            target.Properties.Add(new PSNoteProperty(name, value));
        }
    }
}
