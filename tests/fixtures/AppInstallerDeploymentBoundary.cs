global using System;
global using System.Collections.Generic;

using System.Management.Automation;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using Shmuelie.Windows.Cmdlets;

// Managed substitutes compiled with the unchanged production service. No WinRT
// projection is referenced; unexpected inventory/option access fails closed.
namespace Windows.ApplicationModel
{
    public sealed class Package
    {
        public AppInstallerInfo GetAppInstallerInfo() => throw new NotSupportedException("Inventory is forbidden.");
        public PackageId Id => throw new NotSupportedException("Inventory is forbidden.");
    }

    public sealed class AppInstallerInfo
    {
        public Uri Uri => throw new NotSupportedException("Inventory is forbidden.");
    }

    public sealed class PackageId
    {
        public string Name => throw new NotSupportedException();
        public string FullName => throw new NotSupportedException();
        public string FamilyName => throw new NotSupportedException();
        public string Publisher => throw new NotSupportedException();
        public string Architecture => throw new NotSupportedException();
        public PackageVersion Version => throw new NotSupportedException();
    }

    public struct PackageVersion
    {
        public ushort Major, Minor, Build, Revision;
    }
}

namespace Windows.Management.Deployment
{
    public enum AddPackageByAppInstallerOptions { None = 0, ForceTargetAppShutdown = 64 }
    public sealed class PackageVolume { }

    public sealed class AddPackageOptions
    {
        public AddPackageOptions()
        {
            AppInstallerDeploymentFixture.OptionsCount++;
            throw new InvalidOperationException("Generic deployment options are forbidden for App Installer updates.");
        }
        public bool DeferRegistrationWhenPackagesAreInUse { get; set; }
        public bool ForceAppShutdown { get; set; }
        public bool ForceTargetAppShutdown { get; set; }
        public PackageVolume TargetVolume
        {
            get => throw new NotSupportedException("Volume overrides are forbidden.");
            set => throw new NotSupportedException("Volume overrides are forbidden.");
        }
        public IList<Uri> DependencyPackageUris => throw new NotSupportedException("Dependency rewrites are forbidden.");
        public IList<Uri> OptionalPackageUris => throw new NotSupportedException("Optional package rewrites are forbidden.");
        public IList<Uri> RelatedPackageUris => throw new NotSupportedException("Related package rewrites are forbidden.");
        public IList<string> OptionalPackageFamilyNames => throw new NotSupportedException("Identity rewrites are forbidden.");
    }

    public sealed class DeploymentResult
    {
        public Exception? ExtendedErrorCode { get; init; }
        public bool IsRegistered
        {
            get
            {
                AppInstallerDeploymentFixture.RegistrationReads++;
                return AppInstallerDeploymentFixture.Registered;
            }
        }
    }

    public sealed class FakeDeploymentOperation
    {
        private readonly Task<DeploymentResult> _task;
        public FakeDeploymentOperation(Task<DeploymentResult> task) => _task = task;
        public Task<DeploymentResult> AsTask()
        {
            AppInstallerDeploymentFixture.AwaitCount++;
            AppInstallerDeploymentFixture.Awaiting.Set();
            return _task;
        }
    }

    public sealed class PackageManager
    {
        public PackageManager() => AppInstallerDeploymentFixture.ManagerCount++;
        public IEnumerable<ApplicationModel.Package> FindPackagesForUser(string user) =>
            throw new NotSupportedException("Native inventory is forbidden.");

        public FakeDeploymentOperation AddPackageByUriAsync(Uri uri, AddPackageOptions options) =>
            throw new COMException("App Installer URI deferral is not supported.", unchecked((int)0x80070057));

        public FakeDeploymentOperation AddPackageByAppInstallerFileAsync(
            Uri uri, AddPackageByAppInstallerOptions options, PackageVolume? targetVolume) =>
            AppInstallerDeploymentFixture.Submit(uri, options, targetVolume);
    }
}

public static class AppInstallerDeploymentFixture
{
    public const string OriginalUri = "https://example.com/Original%20Source.appinstaller?channel=stable&item=One%2FTwo";
    public static readonly List<string> Requests = new();
    public static readonly ManualResetEventSlim Awaiting = new();
    public static Version WindowsVersion = new(10, 0, 22556);
    public static bool Registered;
    public static int ManagerCount, OptionsCount, AwaitCount, RegistrationReads, DiscoveryCount;
    public static string FailureKind = "";
    public static Exception? Failure;
    public static TaskCompletionSource<Windows.Management.Deployment.DeploymentResult>? Pending;

    public static void Reset(Version version, bool registered, string failureKind)
    {
        WindowsVersion = version;
        Registered = registered;
        FailureKind = failureKind;
        Failure = failureKind.Length == 0 ? null : new COMException(
            $"Synthetic {failureKind} failure.", failureKind == "InUse" ? unchecked((int)0x80073D02) : unchecked((int)0x80070057));
        Requests.Clear();
        ManagerCount = OptionsCount = AwaitCount = RegistrationReads = DiscoveryCount = 0;
        Pending = null;
        Awaiting.Reset();
    }

    public static Windows.Management.Deployment.FakeDeploymentOperation Submit(
        Uri uri, Windows.Management.Deployment.AddPackageByAppInstallerOptions options,
        Windows.Management.Deployment.PackageVolume? volume)
    {
        Requests.Add(uri.OriginalString);
        if (Requests.Count != 1 || uri.OriginalString != OriginalUri || volume is not null)
            throw new InvalidOperationException("Unexpected route, rewritten source, volume, or retry.");
        if (options != Windows.Management.Deployment.AddPackageByAppInstallerOptions.None)
            throw new InvalidOperationException("App Installer deployment must remain non-forcing None.");

        if (FailureKind == "Submission")
            throw Failure!;

        Task<Windows.Management.Deployment.DeploymentResult> task = Pending?.Task ??
            (FailureKind == "Async"
                ? Task.FromException<Windows.Management.Deployment.DeploymentResult>(Failure!)
                : Task.FromResult(new Windows.Management.Deployment.DeploymentResult
                {
                    ExtendedErrorCode = Failure,
                }));
        return new Windows.Management.Deployment.FakeDeploymentOperation(task);
    }

    public static void Update() => AppInstallerService.Update(OriginalUri, WindowsVersion);

    public static IReadOnlyList<AppInstallerApplication> GetApplications()
    {
        DiscoveryCount++;
        return new[]
        {
            new AppInstallerApplication
            {
                Name = "Example.App", PackageFullName = "Example.App_1.2.3.4_x64__publisher",
                PackageFamilyName = "Example.App_publisher", Version = "1.2.3.4", AppInstallerUri = OriginalUri,
            },
            new AppInstallerApplication
            {
                Name = "Example.App", PackageFullName = "Example.App_9.0.0.0_x64__publisher",
                PackageFamilyName = "Example.App_publisher", Version = "9.0.0.0",
                AppInstallerUri = "https://example.com/must-not-submit.appinstaller",
            },
        };
    }

    public static UpdateAppInstallerAppCommand CreateCommand(ICommandRuntime runtime) =>
        new(GetApplications, uri => AppInstallerService.Update(uri, WindowsVersion))
        {
            CommandRuntime = runtime,
            Name = new[] { "Example.App_1.2.3.4_x64__publisher" },
        };

    public static void VerifyPendingRequest(bool fail)
    {
        Pending = new(TaskCreationOptions.RunContinuationsAsynchronously);
        Task request = Task.Run(Update);
        try
        {
            if (!Awaiting.Wait(TimeSpan.FromSeconds(5)))
                throw new InvalidOperationException("The deployment operation was not awaited.");
            if (request.Wait(TimeSpan.FromMilliseconds(100)))
                throw new InvalidOperationException("The service returned before request completion.");
            if (fail)
            {
                Failure = new COMException("Synthetic pending async failure.", unchecked((int)0x80070057));
                Pending.SetException(Failure);
                try
                {
                    request.GetAwaiter().GetResult();
                    throw new InvalidOperationException("The asynchronous error was swallowed.");
                }
                catch (COMException exception) when (ReferenceEquals(exception, Failure)) { }
            }
            else
            {
                Pending.SetResult(new Windows.Management.Deployment.DeploymentResult());
                request.GetAwaiter().GetResult();
            }
        }
        finally
        {
            Pending.TrySetCanceled();
            // Observe/finish the owned task even if a fixture assertion failed.
            if (!request.IsCompleted)
                Task.WhenAny(request, Task.Delay(TimeSpan.FromSeconds(5))).GetAwaiter().GetResult();
            if (!request.IsCompleted)
                throw new InvalidOperationException("The fixture request did not stop.");
            _ = request.Exception;
            Pending = null;
        }
    }
}
