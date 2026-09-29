namespace Shmuelie.Windows.AppInstall;

public sealed partial class AppInstallContext
{
    private readonly HashSet<AppInstallObservationLease> observations = [];
    private bool managerReleased;

    internal AppInstallObservationLease AcquireObservation(Guid localItemId)
    {
        lock (sync)
        {
            EnsureUsable();
            if (localItemId == Guid.Empty) throw new ArgumentException("An exact local item ID is required.", nameof(localItemId));
            if (!manager.IsValueCreated || manager.Value is not IAppInstallInventoryManager inventory)
                throw new InvalidOperationException("The context has no captured item with this local ID.");
            if (observations.Count != 0)
                throw new InvalidOperationException("Only one observation can be active on a context.");
            var item = inventory.InventoryTracker.Resolve(localItemId);
            if (item.Identity.ContextId != ContextId || item.Identity.UserScope != AppInstallUserScope.Caller)
                throw new InvalidDataException("The retained item does not belong to this caller context.");
            foreach (var name in new[] { "ItemStatusChanged", "ItemCompleted" })
            {
                var member = new AppInstallMember(AppInstallMember.ManagerType, name, AppInstallMemberKind.Event);
                if (!availability.IsTypePresent(member.TypeName) || !availability.IsMemberPresent(member))
                    throw new MissingMemberException(member.TypeName, member.Name);
            }
            if (manager.Value is not IAppInstallMonitoringManager events)
                throw new NotSupportedException("The manager adapter does not provide manager-event observation.");
            var lease = new AppInstallObservationLease(this, events, inventory.InventoryTracker, item);
            observations.Add(lease);
            return lease;
        }
    }

    internal void ReleaseObservation(AppInstallObservationLease lease)
    {
        IAppInstallManagerAdapter? release;
        lock (sync)
        {
            observations.Remove(lease);
            release = TakeManagerForRelease();
        }
        release?.Dispose();
    }

    private IAppInstallManagerAdapter? TakeManagerForRelease()
    {
        if (!disposed || observations.Count != 0 || managerReleased || !manager.IsValueCreated) return null;
        managerReleased = true;
        return manager.Value;
    }
}

internal sealed class AppInstallObservationLease(
    AppInstallContext context, IAppInstallMonitoringManager events,
    AppInstallInventoryTracker tracker, AppInstallTrackedItem item) : IDisposable
{
    private readonly object sync = new();
    private readonly ManualResetEvent stopped = new(false);
    private bool disposed;
    internal IAppInstallMonitoringManager Events { get; } = events;
    internal AppInstallInventoryTracker Tracker { get; } = tracker;
    internal AppInstallTrackedItem Item { get; } = item;
    internal WaitHandle Stopped => stopped;

    internal void RequestStop()
    {
        lock (sync) { if (!disposed) stopped.Set(); }
    }

    public void Dispose()
    {
        lock (sync)
        {
            if (disposed) return;
            disposed = true;
            stopped.Dispose();
        }
        context.ReleaseObservation(this);
    }
}
