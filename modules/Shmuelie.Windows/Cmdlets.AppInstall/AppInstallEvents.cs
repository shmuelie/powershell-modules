namespace Shmuelie.Windows.AppInstall;

internal interface IAppInstallEvents
{
    IDisposable Subscribe(Action changed);
}

// Monitoring adapters will subscribe to version-gated native events and signal
// invalidation only. Snapshots and pipeline writes belong on the cmdlet thread.
internal sealed class AppInstallChangeSignal : IDisposable
{
    private readonly object sync = new();
    private readonly AutoResetEvent changed = new(false);
    private readonly IDisposable subscription;
    private bool disposed;

    internal AppInstallChangeSignal(IAppInstallEvents events)
    {
        ArgumentNullException.ThrowIfNull(events);
        try
        {
            subscription = events.Subscribe(OnChanged) ??
                throw new InvalidOperationException("AppInstall event subscription returned no resource.");
        }
        finally
        {
            if (subscription is null) changed.Dispose();
        }
    }

    internal WaitHandle WaitHandle => changed;

    private void OnChanged()
    {
        lock (sync)
        {
            if (!disposed) changed.Set();
        }
    }

    public void Dispose()
    {
        lock (sync)
        {
            if (disposed) return;
            disposed = true;
        }
        // Unsubscribe outside the callback lock: a native unsubscribe may wait
        // for an in-flight callback. Never wait while holding its lock.
        try { subscription.Dispose(); }
        finally { changed.Dispose(); }
    }
}
