using System.Collections.Generic;
using System.IO;
using System.Management.Automation;
using System.Runtime.Versioning;

namespace Shmuelie.Windows.Cmdlets;

/// <summary>
/// Retrieves installed applications from the Windows registry uninstall keys.
/// </summary>
/// <remarks>
/// Supports machine-wide (HKLM), current-user, and all-user scopes. The all-user
/// scope mounts each offline profile's <c>NTUSER.DAT</c> hive with the Win32
/// <c>RegLoadKey</c>/<c>RegUnLoadKey</c> APIs (which require elevation), reads its
/// uninstall keys, and always unmounts the hive again. Use <c>-WhatIf</c> to
/// preview the offline mount operations without changing the registry.
/// </remarks>
[Cmdlet(VerbsCommon.Get, "InstalledApplications", SupportsShouldProcess = true)]
[OutputType(typeof(PSObject))]
[SupportedOSPlatform("windows")]
public sealed class GetInstalledApplicationsCommand : InstalledApplicationsCommandBase
{
    /// <summary>
    /// Test injection point: when set, hive operations are delegated to this
    /// instance instead of the real Win32 API. Always <see langword="null"/>
    /// in production.
    /// </summary>
    internal static IHiveOperations? TestHiveOperations;

    private IHiveOperations HiveOps => TestHiveOperations ?? DefaultHiveOperations.Instance;

    /// <summary>
    /// The scope of applications to query. Defaults to <c>GlobalAndAllUsers</c>.
    /// </summary>
    [Parameter(Position = 0)]
    [ValidateSet("Global", "GlobalAndCurrentUser", "GlobalAndAllUsers", "CurrentUser", "AllUsers")]
    public string Scope { get; set; } = "GlobalAndAllUsers";

    /// <inheritdoc/>
    protected override void BeginProcessing()
    {
        EnsureWindows();
    }

    /// <inheritdoc/>
    protected override void ProcessRecord()
    {
        bool wantsGlobal = Scope is "Global" or "GlobalAndAllUsers" or "GlobalAndCurrentUser";
        bool wantsCurrentUser = Scope is "CurrentUser" or "GlobalAndCurrentUser";
        bool wantsAllUsers = Scope is "AllUsers" or "GlobalAndAllUsers";

        // Mounting offline hives requires elevation. The preview (-WhatIf) path
        // performs no mount, so it does not require an elevated session.
        if (wantsAllUsers && !IsWhatIf() && !HiveOps.IsElevated())
        {
            ThrowTerminatingError(new ErrorRecord(
                new InvalidOperationException("Finding all user applications requires an elevated (Administrator) PowerShell session."),
                "ElevationRequired",
                ErrorCategory.PermissionDenied,
                Scope));
        }

        var applications = new List<PSObject>();

        if (wantsGlobal)
        {
            WriteVerbose("Processing global hive");
            applications.AddRange(InstalledApplicationsService.ReadLocalMachine());
        }

        if (wantsCurrentUser)
        {
            WriteVerbose("Processing current user hive");
            applications.AddRange(InstalledApplicationsService.ReadCurrentUser());
        }

        if (wantsAllUsers)
        {
            CollectAllUsers(applications);
        }

        // The original script emits the accumulated collection at the very end,
        // so a failure while reading an offline hive yields no partial output.
        WriteObject(applications, enumerateCollection: true);
    }

    private void CollectAllUsers(List<PSObject> applications)
    {
        WriteVerbose("Collecting hive data for all users");
        IReadOnlyList<UserProfile> profiles = HiveOps.GetUserProfiles();

        WriteVerbose("Processing mounted hives");
        foreach (UserProfile profile in profiles)
        {
            if (profile.Loaded)
            {
                applications.AddRange(HiveOps.ReadMountedUserHive(profile.Sid));
            }
        }

        WriteVerbose("Processing unmounted hives");
        bool privilegesEnabled = false;
        foreach (UserProfile profile in profiles)
        {
            if (profile.Loaded)
            {
                continue;
            }

            string hive = Path.Combine(profile.LocalPath, "NTUSER.DAT");
            WriteVerbose($" -> Mounting hive at {hive}");

            if (!File.Exists(hive))
            {
                WriteWarning($"Unable to access registry hive at {hive}");
                continue;
            }

            if (!ShouldProcess($"HKU\\temp from {hive}", "REG LOAD"))
            {
                continue;
            }

            if (!privilegesEnabled)
            {
                HiveOps.EnableHivePrivileges();
                privilegesEnabled = true;
            }

            int loadStatus = HiveOps.LoadHive("temp", hive);
            if (loadStatus != 0)
            {
                WriteWarning($"Failed to load registry hive '{hive}' into HKU\\temp. RegLoadKey returned {loadStatus}; skipping this profile.");
                continue;
            }

            try
            {
                applications.AddRange(HiveOps.ReadMountedUserHive("temp"));
            }
            finally
            {
                // Release any handles the reads opened so the hive can unmount.
                GC.Collect();
                GC.WaitForPendingFinalizers();

                // Unload is unconditional cleanup: once a load succeeds, the hive
                // must always be unmounted regardless of user confirmation state.
                int unloadStatus = HiveOps.UnloadHive("temp");
                if (unloadStatus != 0)
                {
                    WriteWarning($"Failed to unload registry hive HKU\\temp after reading '{hive}'. RegUnLoadKey returned {unloadStatus}.");
                }
            }
        }
    }
}
