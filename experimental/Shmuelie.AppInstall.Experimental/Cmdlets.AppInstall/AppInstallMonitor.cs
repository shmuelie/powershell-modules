using System.Diagnostics;

namespace Shmuelie.Windows.AppInstall;

internal sealed class AppInstallObservationSignal : IDisposable
{
    private readonly object sync = new();
    private readonly AutoResetEvent changed = new(false);
    private long generation;
    private AppInstallObservationReason reason;
    private bool closed;
    private bool disposed;
    private bool overflow;
    internal WaitHandle Changed => changed;

    internal void Invalidate(AppInstallObservationReason value)
    {
        lock (sync)
        {
            if (closed) return;
            if (generation == long.MaxValue) overflow = true;
            else generation++;
            reason |= value;
            changed.Set();
        }
    }

    internal (long Generation, AppInstallObservationReason Reason) Drain()
    {
        lock (sync)
        {
            if (overflow) throw new InvalidDataException("The observation notification generation overflowed.");
            var batch = (generation, reason);
            reason = AppInstallObservationReason.None;
            return batch;
        }
    }

    internal bool Fence(long observed, bool finish)
    {
        lock (sync)
        {
            if (overflow) throw new InvalidDataException("The observation notification generation overflowed.");
            if (observed != generation) return false;
            if (finish) closed = true;
            return true;
        }
    }

    public void Dispose()
    {
        lock (sync)
        {
            if (disposed) return;
            closed = true;
            disposed = true;
            changed.Dispose();
        }
    }
}

internal interface IAppInstallObservationWait
{
    TimeSpan Elapsed { get; }
    void Wait(WaitHandle[] signals, TimeSpan remaining);
}

internal sealed class AppInstallObservationWait : IAppInstallObservationWait
{
    private readonly Stopwatch clock = Stopwatch.StartNew();
    public TimeSpan Elapsed => clock.Elapsed;
    public void Wait(WaitHandle[] signals, TimeSpan remaining) => WaitHandle.WaitAny(signals, remaining);
}

internal static class AppInstallMonitor
{
    internal static AppInstallMonitorResult Wait(AppInstallContext context, Guid localItemId,
        TimeSpan timeout, CancellationToken stop, IAppInstallObservationWait? wait = null)
    {
        ArgumentNullException.ThrowIfNull(context);
        if (timeout < TimeSpan.FromSeconds(1) || timeout > TimeSpan.FromSeconds(30))
            throw new ArgumentOutOfRangeException(nameof(timeout));
        var clock = wait ?? new AppInstallObservationWait();
        var signal = new AppInstallObservationSignal();
        AppInstallObservationLease? lease = null;
        var subscriptions = new List<IDisposable>(2);
        var observations = new List<AppInstallObservation>(64);
        AppInstallError? failure = null;
        AppInstallMonitorResult? result = null;
        var phase = AppInstallErrorPhase.LocalWait;
        var operation = "Wait-AppInstallItem";
        try
        {
            stop.ThrowIfCancellationRequested();
            phase = AppInstallErrorPhase.Availability;
            lease = context.AcquireObservation(localItemId);
            EnsureRunning();
            phase = AppInstallErrorPhase.Invocation;
            operation = $"{AppInstallMember.ManagerType}.ItemStatusChanged";
            subscriptions.Add(lease.Events.SubscribeStatusChanged(
                () => signal.Invalidate(AppInstallObservationReason.ManagerStatusInvalidated)) ??
                throw new InvalidDataException("The manager event returned no unsubscribe resource."));
            EnsureRunning();
            phase = AppInstallErrorPhase.Invocation;
            operation = $"{AppInstallMember.ManagerType}.ItemCompleted";
            subscriptions.Add(lease.Events.SubscribeCompleted(
                () => signal.Invalidate(AppInstallObservationReason.ManagerCompletionInvalidated)) ??
                throw new InvalidDataException("The manager event returned no unsubscribe resource."));
            var reader = new AppInstallInventoryReader(context, EnsureRunning);
            var pending = AppInstallObservationReason.Initial;
            while (true)
            {
                operation = "Wait-AppInstallItem";
                phase = AppInstallErrorPhase.LocalWait;
                EnsureRunning();
                if (clock.Elapsed >= timeout)
                {
                    result = new(context.ContextId, localItemId, AppInstallObservationOutcome.TimedOut, observations);
                    break;
                }
                var batch = signal.Drain();
                pending |= batch.Reason;
                if (pending != AppInstallObservationReason.None)
                {
                    var snapshot = reader.ReadObservedItem(lease.Tracker, lease.Item);
                    EnsureRunning();
                    if (clock.Elapsed >= timeout) continue;
                    var terminal = snapshot.Status.TerminalState is AppInstallTerminalState.Succeeded or
                        AppInstallTerminalState.Failed or AppInstallTerminalState.Canceled;
                    if (!signal.Fence(batch.Generation, terminal)) continue;
                    if (observations.Count == 64) throw new InvalidDataException("The observation limit of 64 snapshots was exceeded.");
                    observations.Add(new(observations.Count + 1, clock.Elapsed, pending, snapshot));
                    pending = AppInstallObservationReason.None;
                    if (terminal)
                    {
                        result = new(context.ContextId, localItemId, AppInstallObservationOutcome.TargetTerminal, observations);
                        break;
                    }
                }
                var remaining = timeout - clock.Elapsed;
                if (remaining > TimeSpan.Zero)
                    clock.Wait([signal.Changed, stop.WaitHandle, lease.Stopped], remaining);
            }
        }
        catch (AppInstallOperationException error) { failure = error.Error; }
        catch (Exception error) { failure = AppInstallError.Capture(operation, phase, error); }
        finally
        {
            signal.Dispose();
            for (int index = subscriptions.Count - 1; index >= 0; index--)
                Cleanup(subscriptions[index], index == 0 ? "ItemStatusChanged.Unsubscribe" : "ItemCompleted.Unsubscribe");
            if (lease is not null) Cleanup(lease, "ObservationLease.Dispose");
        }
        if (failure is not null) throw new AppInstallOperationException(failure);
        return result ?? throw new InvalidOperationException("Observation ended without an outcome.");

        void EnsureRunning()
        {
            phase = AppInstallErrorPhase.LocalWait;
            operation = "Wait-AppInstallItem";
            stop.ThrowIfCancellationRequested();
            if (context.IsDisposed) throw new ObjectDisposedException(nameof(AppInstallContext));
        }
        void Cleanup(IDisposable resource, string source)
        {
            try { resource.Dispose(); }
            catch (Exception error)
            {
                var cleanup = AppInstallError.Capture(source, AppInstallErrorPhase.Cleanup, error);
                failure = failure is null ? cleanup : failure.WithCleanup(cleanup);
            }
        }
    }
}
