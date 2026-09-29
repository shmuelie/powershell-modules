global using System;
global using System.Collections.Generic;

using System.Management.Automation;

namespace Shmuelie.Windows.Cmdlets;

// Compiled only in the isolated selection fixture, instead of the WinRT service.
internal static class AppInstallerService
{
    public static IReadOnlyList<AppInstallerApplication> GetApplications()
    {
        AppInstallerSelectionFixture.DiscoveryCount++;
        return AppInstallerSelectionFixture.Applications;
    }

    public static void Update(string uri)
    {
        if (!AppInstallerSelectionFixture.Applications.Exists(app => app.AppInstallerUri == uri))
            throw new InvalidOperationException("Unexpected fixture update URI.");

        AppInstallerSelectionFixture.Requests.Add(uri);
        if (AppInstallerSelectionFixture.Requests.Count > AppInstallerSelectionFixture.SuccessBeforeFailure)
            throw new InvalidOperationException("Synthetic AppInstaller request failure.");
    }
}

public static class AppInstallerSelectionFixture
{
    public static readonly List<AppInstallerApplication> Applications = new();
    public static readonly List<string> Requests = new();
    public static int DiscoveryCount;
    public static int SuccessBeforeFailure;

    public static void Reset()
    {
        Applications.Clear();
        Requests.Clear();
        DiscoveryCount = 0;
        SuccessBeforeFailure = int.MaxValue;
        foreach (string suffix in new[] { "One", "Two" })
        {
            Applications.Add(new AppInstallerApplication
            {
                Name = $"Example.{suffix}",
                PackageFullName = $"Example.{suffix}_1.2.3.4_x64__publisher",
                PackageFamilyName = $"Example.{suffix}_publisher",
                Version = "1.2.3.4",
                AppInstallerUri = $"https://example.com/{suffix.ToLowerInvariant()}.appinstaller",
            });
        }
    }

    public static UpdateAppInstallerAppCommand CreateCommand(ICommandRuntime runtime) =>
        new(AppInstallerService.GetApplications, AppInstallerService.Update) { CommandRuntime = runtime };
}
