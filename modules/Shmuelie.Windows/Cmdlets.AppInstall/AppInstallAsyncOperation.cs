using Windows.Foundation;

namespace Shmuelie.Windows.AppInstall;

internal enum AppInstallAsyncState { Started, Completed, Canceled, Error }

internal interface IAppInstallAsyncOperation<T> : IDisposable
{
    AppInstallAsyncState State { get; }
    T GetResult();
}

internal sealed class WinRtAppInstallAsyncOperation<T>(IAsyncOperation<T> operation) : IAppInstallAsyncOperation<T>
{
    private IAsyncOperation<T>? operation = operation;
    private IAsyncOperation<T> Operation => operation ??
        throw new ObjectDisposedException(nameof(WinRtAppInstallAsyncOperation<T>));

    public AppInstallAsyncState State => Operation.Status switch
    {
        AsyncStatus.Started => AppInstallAsyncState.Started,
        AsyncStatus.Completed => AppInstallAsyncState.Completed,
        AsyncStatus.Canceled => AppInstallAsyncState.Canceled,
        AsyncStatus.Error => AppInstallAsyncState.Error,
        _ => throw new InvalidOperationException("The native operation returned an unknown async status.")
    };

    public T GetResult() => Operation.GetResults();

    public void Dispose()
    {
        var owned = Interlocked.Exchange(ref operation, null);
        // IAsyncInfo.Close is invalid while Started. Releasing this reference
        // must not cancel a request that may already have queued remote work.
        if (owned is not null && owned.Status != AsyncStatus.Started) owned.Close();
    }
}

internal static class AppInstallOperationWaiter
{
    internal static T Wait<T>(IAppInstallAsyncOperation<T> operation, CancellationToken stopWaiting)
    {
        ArgumentNullException.ThrowIfNull(operation);
        // Poll only native completion state on the execution thread. No worker,
        // WinRT Completed handler, or task is left behind when waiting stops.
        while (true)
        {
            stopWaiting.ThrowIfCancellationRequested();
            if (operation.State != AppInstallAsyncState.Started)
                return operation.GetResult();
            stopWaiting.WaitHandle.WaitOne(50);
        }
    }
}
