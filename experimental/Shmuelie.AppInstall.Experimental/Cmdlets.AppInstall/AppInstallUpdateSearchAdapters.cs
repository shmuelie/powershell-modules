using Windows.ApplicationModel.Store.Preview.InstallControl;

namespace Shmuelie.Windows.AppInstall;

internal interface IAppInstallUpdateSearchOptions
{
    bool AutomaticallyDownloadAndInstallUpdateIfFound { set; }
    bool AllowForcedAppRestart { set; }
}

internal interface IAppInstallUpdateSearchManager
{
    AppInstallInventoryTracker InventoryTracker { get; }
    IAppInstallUpdateSearchOptions CreateUpdateOptions();
    IAppInstallAsyncOperation<IReadOnlyList<IAppInstallInventoryItem>> SearchPausedUpdates(
        string correlationVector, string clientId, IAppInstallUpdateSearchOptions options);
}

internal sealed partial class AppInstallManagerAdapter : IAppInstallUpdateSearchManager
{
    public IAppInstallUpdateSearchOptions CreateUpdateOptions() => new WinRtAppInstallUpdateSearchOptions(new AppUpdateOptions());

    public IAppInstallAsyncOperation<IReadOnlyList<IAppInstallInventoryItem>> SearchPausedUpdates(
        string correlationVector, string clientId, IAppInstallUpdateSearchOptions options)
    {
        if (options is not WinRtAppInstallUpdateSearchOptions configured)
            throw new ArgumentException("The native manager requires native update options.", nameof(options));
        return new UpdateSearchOperation(new WinRtAppInstallAsyncOperation<IReadOnlyList<AppInstallItem>>(
            Manager.SearchForAllUpdatesAsync(correlationVector, clientId, configured.Native)));
    }

    private sealed class UpdateSearchOperation(
        IAppInstallAsyncOperation<IReadOnlyList<AppInstallItem>> operation) :
        IAppInstallAsyncOperation<IReadOnlyList<IAppInstallInventoryItem>>
    {
        public AppInstallAsyncState State => operation.State;
        public IReadOnlyList<IAppInstallInventoryItem> GetResult() => WrapItems(operation.GetResult());
        public void Dispose() => operation.Dispose();
    }
}

internal sealed class WinRtAppInstallUpdateSearchOptions(AppUpdateOptions options) : IAppInstallUpdateSearchOptions
{
    internal AppUpdateOptions Native { get; } = options;
    public bool AutomaticallyDownloadAndInstallUpdateIfFound { set => Native.AutomaticallyDownloadAndInstallUpdateIfFound = value; }
    public bool AllowForcedAppRestart { set => Native.AllowForcedAppRestart = value; }
}
