using Windows.ApplicationModel.Store.Preview.InstallControl;
using Windows.Foundation;

namespace Shmuelie.Windows.AppInstall;

internal interface IAppInstallMonitoringManager
{
    IDisposable SubscribeStatusChanged(Action changed);
    IDisposable SubscribeCompleted(Action changed);
}

internal sealed partial class AppInstallManagerAdapter : IAppInstallMonitoringManager
{
    public IDisposable SubscribeStatusChanged(Action changed)
    {
        var source = Manager;
        TypedEventHandler<AppInstallManager, AppInstallManagerItemEventArgs> handler = (_, _) => changed();
        return AppInstallSubscription.Create("ItemStatusChanged",
            () => source.ItemStatusChanged += handler, () => source.ItemStatusChanged -= handler);
    }

    public IDisposable SubscribeCompleted(Action changed)
    {
        var source = Manager;
        TypedEventHandler<AppInstallManager, AppInstallManagerItemEventArgs> handler = (_, _) => changed();
        return AppInstallSubscription.Create("ItemCompleted",
            () => source.ItemCompleted += handler, () => source.ItemCompleted -= handler);
    }
}

internal sealed class AppInstallSubscription(Action unsubscribe) : IDisposable
{
    private Action? unsubscribe = unsubscribe;
    public void Dispose() => Interlocked.Exchange(ref unsubscribe, null)?.Invoke();

    internal static IDisposable Create(string member, Action subscribe, Action unsubscribe)
    {
        try { subscribe(); }
        catch (Exception primary)
        {
            var failure = AppInstallError.Capture($"{AppInstallMember.ManagerType}.{member}",
                AppInstallErrorPhase.Invocation, primary);
            // A failed add is not proof that no registration was made.
            try { unsubscribe(); }
            catch (Exception cleanup)
            {
                failure = failure.WithCleanup(AppInstallError.Capture($"{member}.Unsubscribe",
                    AppInstallErrorPhase.Cleanup, cleanup));
            }
            throw new AppInstallOperationException(failure);
        }
        return new AppInstallSubscription(unsubscribe);
    }
}
