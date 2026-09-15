using Windows.ApplicationModel.Store.Preview.InstallControl;

namespace Shmuelie.Windows.AppInstall;

internal interface IAppInstallInventoryManager
{
    AppInstallInventoryTracker InventoryTracker { get; }
    IReadOnlyList<IAppInstallInventoryItem> GetItems(bool includeChildren);
}

internal interface IAppInstallInventoryItem
{
    object IdentityKey { get; }
    AppInstallUserScope UserScope { get; }
    string ProductId { get; }
    string PackageFamilyName { get; }
    int InstallType { get; }
    bool IsUserInitiated { get; }
    bool ItemOperationsMightAffectOtherItems { get; }
    IReadOnlyList<IAppInstallInventoryItem> Children { get; }
    IAppInstallInventoryStatus GetCurrentStatus();
}

internal interface IAppInstallInventoryStatus
{
    int InstallState { get; }
    ulong BytesDownloaded { get; }
    ulong DownloadSizeInBytes { get; }
    double PercentComplete { get; }
    bool IsStaged { get; }
    bool ReadyForLaunch { get; }
    Exception? ErrorCode { get; }
}

internal sealed partial class AppInstallManagerAdapter : IAppInstallInventoryManager
{
    public AppInstallInventoryTracker InventoryTracker { get; } = new();

    public IReadOnlyList<IAppInstallInventoryItem> GetItems(bool includeChildren) =>
        WrapItems(includeChildren ? Manager.AppInstallItemsWithGroupSupport : Manager.AppInstallItems);

    internal static IReadOnlyList<IAppInstallInventoryItem> WrapItems(IReadOnlyList<AppInstallItem> items)
    {
        ArgumentNullException.ThrowIfNull(items);
        if (items.Count > AppInstallInventoryReader.MaximumItems)
            throw new InvalidDataException("The inventory collection exceeds the bounded item limit.");
        return items.Select(item => (IAppInstallInventoryItem)new WinRtAppInstallInventoryItem(item)).ToArray();
    }
}

internal sealed class WinRtAppInstallInventoryItem(AppInstallItem item) : IAppInstallInventoryItem
{
    // AppInstallItem overrides Equals/GetHashCode in the supported projection.
    // Keep projection identities alive only in the bounded active-snapshot cache.
    public object IdentityKey => item;
    public AppInstallUserScope UserScope => AppInstallUserScope.Caller;
    public string ProductId => item.ProductId;
    public string PackageFamilyName => item.PackageFamilyName;
    public int InstallType => (int)item.InstallType;
    public bool IsUserInitiated => item.IsUserInitiated;
    public bool ItemOperationsMightAffectOtherItems => item.ItemOperationsMightAffectOtherItems;
    public IReadOnlyList<IAppInstallInventoryItem> Children => AppInstallManagerAdapter.WrapItems(item.Children);
    public IAppInstallInventoryStatus GetCurrentStatus() => new WinRtAppInstallInventoryStatus(item.GetCurrentStatus());
}

internal sealed class WinRtAppInstallInventoryStatus(AppInstallStatus status) : IAppInstallInventoryStatus
{
    public int InstallState => (int)status.InstallState;
    public ulong BytesDownloaded => status.BytesDownloaded;
    public ulong DownloadSizeInBytes => status.DownloadSizeInBytes;
    public double PercentComplete => status.PercentComplete;
    public bool IsStaged => status.IsStaged;
    public bool ReadyForLaunch => status.ReadyForLaunch;
    public Exception? ErrorCode => status.ErrorCode;
}
