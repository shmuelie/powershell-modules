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
        var phase = AppInstallErrorPhase.LocalWait;
        AppInstallAsyncState? state = null;
        return WaitCore(operation, stopWaiting, ref phase, ref state);
    }

    internal static T WaitAndDispose<T>(string sourceOperation, IAppInstallAsyncOperation<T> operation,
        CancellationToken stopWaiting)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sourceOperation);
        ArgumentNullException.ThrowIfNull(operation);
        var phase = AppInstallErrorPhase.LocalWait;
        AppInstallAsyncState? state = null;
        Exception? primary = null;
        AppInstallError? translatedPrimary = null;
        try
        {
            return WaitCore(operation, stopWaiting, ref phase, ref state);
        }
        catch (Exception error)
        {
            // Preserve every failure across cleanup; translation is a separate policy.
            primary = error;
            if (AppInstallError.IsOperational(error))
            {
                translatedPrimary = AppInstallError.Capture(sourceOperation, phase, error, state == AppInstallAsyncState.Canceled);
                throw new AppInstallOperationException(translatedPrimary);
            }
            throw;
        }
        finally
        {
            try { operation.Dispose(); }
            catch (Exception cleanup)
            {
                if (translatedPrimary is not null)
                {
                    var secondary = AppInstallError.Capture(sourceOperation, AppInstallErrorPhase.Cleanup, cleanup);
                    throw new AppInstallOperationException(translatedPrimary.WithCleanup(secondary));
                }
                if (primary is not null)
                    throw new AppInstallCleanupException(sourceOperation, phase, primary, cleanup);
                if (AppInstallError.IsOperational(cleanup))
                    throw new AppInstallOperationException(
                        AppInstallError.Capture(sourceOperation, AppInstallErrorPhase.Cleanup, cleanup));
                throw;
            }
        }
    }

    private static T WaitCore<T>(IAppInstallAsyncOperation<T> operation, CancellationToken stopWaiting,
        ref AppInstallErrorPhase phase, ref AppInstallAsyncState? state)
    {
        ArgumentNullException.ThrowIfNull(operation);
        // Poll only native completion state on the execution thread. No worker,
        // WinRT Completed handler, or task is left behind when waiting stops.
        while (true)
        {
            phase = AppInstallErrorPhase.LocalWait;
            stopWaiting.ThrowIfCancellationRequested();
            phase = AppInstallErrorPhase.AsyncStatus;
            state = operation.State;
            if (state != AppInstallAsyncState.Started)
            {
                phase = AppInstallErrorPhase.AsyncResult;
                T result = operation.GetResult();
                if (state != AppInstallAsyncState.Completed)
                    throw new InvalidOperationException("A non-completed native operation returned a result.");
                return result;
            }
            stopWaiting.WaitHandle.WaitOne(50);
        }
    }
}
