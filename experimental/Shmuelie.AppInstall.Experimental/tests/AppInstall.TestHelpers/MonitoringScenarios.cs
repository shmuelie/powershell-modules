using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Runtime.InteropServices;
using System.Text.Json;
using Shmuelie.Windows.AppInstall;

namespace Shmuelie.Windows.AppInstall.Tests;

public static class MonitoringScenarios
{
    public static AppInstallMonitorResult VerifyCommand(string manifestPath)
    {
        var state = InitialSessionState.CreateDefault2();
        state.ImportPSModule([manifestPath]);
        using var owner = RunspaceFactory.CreateRunspace(state);
        owner.Open();
        var manager = new Manager();
        using var context = new AppInstallContext(owner, new Availability(), new Activation(manager));
        var previous = Runspace.DefaultRunspace;
        Guid id;
        try
        {
            Runspace.DefaultRunspace = owner;
            id = new AppInstallInventoryReader(context, () => { }).Read(false, null, null).Single().Identity.LocalItemId;
        }
        finally { Runspace.DefaultRunspace = previous; }
        manager.Item.ReadThread = 0;
        manager.Item.State = 9;
        manager.Item.NativeError = new COMException("synthetic-private-native-error", unchecked((int)0x80004005));
        using var pipeline = PowerShell.Create();
        pipeline.Runspace = owner;
        var results = pipeline.AddCommand("Wait-AppInstallItem").AddParameter("Context", context)
            .AddParameter("LocalItemId", id).AddParameter("TimeoutSeconds", 1).Invoke();
        Check(!pipeline.HadErrors && results.Count == 1 && results[0].BaseObject is AppInstallMonitorResult &&
            manager.Active == 0 && manager.StatusRemovals == 1 && manager.CompletionRemovals == 1 &&
            !context.IsDisposed && manager.Disposals == 0, "exported fake monitoring");
        return (AppInstallMonitorResult)results[0].BaseObject;
    }

    public static void Run(string name)
    {
        var state = InitialSessionState.CreateDefault2();
        state.Commands.Add(new SessionStateCmdletEntry("Wait-AppInstallItem", typeof(WaitAppInstallItemCommand), null));
        using var owner = RunspaceFactory.CreateRunspace(state);
        owner.Open();
        var previous = Runspace.DefaultRunspace;
        Runspace.DefaultRunspace = owner;
        var manager = new Manager();
        var availability = new Availability();
        using var context = new AppInstallContext(owner, availability, new Activation(manager));
        try
        {
            var reader = new AppInstallInventoryReader(context, () => { });
            var captured = reader.Read(false, null, null).Single();
            manager.Item.Reads = 0;
            manager.Item.ReadThread = 0;
            var id = captured.Identity.LocalItemId;
            var clock = new Clock();
            AppInstallMonitorResult Wait() => AppInstallMonitor.Wait(context, id, TimeSpan.FromSeconds(1), CancellationToken.None, clock);
            if (name.StartsWith("Command", StringComparison.Ordinal))
            {
                Command(name, context, manager, owner, state, id);
                return;
            }
            switch (name)
            {
                case "AlreadyTerminal":
                case "FailedTerminal":
                case "CanceledTerminal":
                    manager.Item.State = name == "AlreadyTerminal" ? 6 : name == "FailedTerminal" ? 9 : 7;
                    if (name == "FailedTerminal") manager.Item.NativeError = new COMException("private synthetic error", unchecked((int)0x80004005));
                    var result = Wait();
                    Check(result.Outcome == AppInstallObservationOutcome.TargetTerminal &&
                        result.GroupOutcome == AppInstallGroupObservation.NotEvaluated && result.Observations.Count == 1, name);
                    Check(result.Observations[0].Snapshot.Status.TerminalState == (name == "AlreadyTerminal" ?
                        AppInstallTerminalState.Succeeded : name == "FailedTerminal" ? AppInstallTerminalState.Failed : AppInstallTerminalState.Canceled), name);
                    break;
                case "Timeout":
                case "Unknown":
                case "CompletedMissingHResult":
                case "CompletionEventNotSuccess":
                    if (name == "Unknown") manager.Item.State = 9999;
                    if (name == "CompletedMissingHResult")
                    {
                        manager.Item.State = 6;
                        availability.Missing = "ErrorCode";
                    }
                    if (name == "CompletionEventNotSuccess") manager.OnSubscribe = () => manager.Completion?.Invoke();
                    var timed = Wait();
                    Check(timed.Outcome == AppInstallObservationOutcome.TimedOut && timed.Observations.Count == 1, name);
                    if (name is "Unknown" or "CompletedMissingHResult")
                        Check(timed.Observations[0].Snapshot.Status.TerminalState == AppInstallTerminalState.Unknown, name);
                    break;
                case "SubscribeRace":
                    manager.OnSubscribe = () => { manager.Item.State = 6; manager.Status?.Invoke(); };
                    Check(Wait().Observations.Single().Snapshot.Status.TerminalState == AppInstallTerminalState.Succeeded, name);
                    break;
                case "InitialSnapshotRace":
                    manager.Item.OnRead = () =>
                    {
                        if (manager.Item.Reads == 1)
                        {
                            manager.Item.State = 6;
                            var thread = new Thread(() => manager.Completion?.Invoke());
                            thread.Start();
                            thread.Join();
                        }
                    };
                    var raced = Wait();
                    Check(manager.Item.Reads == 2 && raced.Observations.Count == 1 &&
                        raced.Observations[0].Snapshot.Status.TerminalState == AppInstallTerminalState.Succeeded &&
                        raced.Observations[0].Reason.HasFlag(AppInstallObservationReason.ManagerCompletionInvalidated), name);
                    break;
                case "DuplicateBound":
                    using (var signal = new AppInstallObservationSignal())
                    {
                        for (int i = 0; i < 10000; i++)
                            signal.Invalidate(i % 2 == 0 ? AppInstallObservationReason.ManagerStatusInvalidated :
                                AppInstallObservationReason.ManagerCompletionInvalidated);
                        var batch = signal.Drain();
                        Check(batch.Generation == 10000 && batch.Reason ==
                            (AppInstallObservationReason.ManagerStatusInvalidated | AppInstallObservationReason.ManagerCompletionInvalidated), name);
                        Check(signal.Drain().Reason == AppInstallObservationReason.None, name);
                        signal.Dispose();
                        signal.Invalidate(AppInstallObservationReason.ManagerCompletionInvalidated);
                    }
                    return;
                case "GenerationOverflow":
                    using (var signal = new AppInstallObservationSignal())
                    {
                        typeof(AppInstallObservationSignal).GetField("generation",
                            System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance)!.SetValue(signal, long.MaxValue);
                        signal.Invalidate(AppInstallObservationReason.ManagerStatusInvalidated);
                        Expect<InvalidDataException>(() => signal.Drain());
                    }
                    return;
                case "PartialAddFailure":
                case "PartialAddCleanupFailure":
                    int removals = 0;
                    var addError = new COMException("synthetic partial add", unchecked((int)0x80070005));
                    var partial = Expect<AppInstallOperationException>(() =>
                        AppInstallSubscription.Create("ItemStatusChanged", () => throw addError, () =>
                        {
                            removals++;
                            if (name == "PartialAddCleanupFailure") throw new IOException("synthetic remove");
                        })).Error;
                    Check(removals == 1 && ReferenceEquals(partial.Exception, addError) &&
                        partial.CleanupErrors.Count == (name == "PartialAddCleanupFailure" ? 1 : 0), name);
                    return;
                case "ObservationLimit":
                    clock.OnWait = () => manager.Status?.Invoke();
                    var limit = Expect<AppInstallOperationException>(() => Wait()).Error;
                    Check(limit.Exception is InvalidDataException && manager.Item.Reads == 65, name);
                    break;
                case "OutOfOrderInvalidation":
                    clock.OnWait = () =>
                    {
                        if (clock.Waits == 1) manager.Status?.Invoke();
                        else if (clock.Waits == 2) manager.Completion?.Invoke();
                    };
                    var ordered = Wait();
                    Check(ordered.Outcome == AppInstallObservationOutcome.TimedOut &&
                        ordered.Observations.Select(item => item.Sequence).SequenceEqual([1, 2, 3]) &&
                        ordered.Observations.All(item => item.Snapshot.Status.TerminalState == AppInstallTerminalState.NotTerminal), name);
                    break;
                case "DirtyLoopDeadline":
                    manager.Item.OnRead = () =>
                    {
                        clock.Advance(TimeSpan.FromMilliseconds(100));
                        manager.Status?.Invoke();
                    };
                    var dirty = Wait();
                    Check(dirty.Outcome == AppInstallObservationOutcome.TimedOut && dirty.Observations.Count == 0 &&
                        manager.Item.Reads == 10, name);
                    break;
                case "SynchronousOverrun":
                    manager.Item.OnRead = () => clock.Advance(TimeSpan.FromSeconds(2));
                    var overrun = Wait();
                    Check(overrun.Outcome == AppInstallObservationOutcome.TimedOut && overrun.Observations.Count == 0 &&
                        clock.Elapsed == TimeSpan.FromSeconds(2), name);
                    break;
                case "Stale":
                    manager.Empty = true;
                    reader.Read(false, null, null);
                    manager.Empty = false;
                    reader.Read(false, null, null);
                    var stale = Expect<AppInstallOperationException>(() => Wait());
                    Check(stale.Error.Phase == AppInstallErrorPhase.Availability && manager.Subscriptions == 0, name);
                    return;
                case "WrongItem":
                    id = Guid.NewGuid();
                    Expect<AppInstallOperationException>(() => Wait());
                    Check(manager.Subscriptions == 0, name);
                    return;
                case "MissingEvent":
                    availability.Missing = "ItemCompleted";
                    Expect<AppInstallOperationException>(() => Wait());
                    Check(manager.Subscriptions == 0, name);
                    return;
                case "LeaseSurvivesPruning":
                    using (var lease = context.AcquireObservation(id))
                    {
                        manager.Empty = true;
                        reader.Read(false, null, null);
                        var observed = reader.ReadObservedItem(lease.Tracker, lease.Item);
                        Check(observed.Identity.LocalItemId == id && manager.InventoryTracker.Count == 0, name);
                        Expect<InvalidOperationException>(() => manager.InventoryTracker.Resolve(id));
                    }
                    return;
                case "OneLeasePerContext":
                    using (var lease = context.AcquireObservation(id))
                        Expect<InvalidOperationException>(() => context.AcquireObservation(id));
                    return;
                case "ContextShutdownLease":
                case "RunspaceShutdownLease":
                    using (var lease = context.AcquireObservation(id))
                    {
                        if (name == "ContextShutdownLease") context.Dispose();
                        else owner.Close();
                        Check(context.IsDisposed && lease.Stopped.WaitOne(0) && manager.Disposals == 0, name);
                    }
                    Check(manager.Disposals == 1, name);
                    return;
                case "GroupNotEvaluated":
                    manager.Item.State = 6;
                    manager.Item.ChildrenReads = 0;
                    var grouped = Wait();
                    Check(grouped.GroupOutcome == AppInstallGroupObservation.NotEvaluated &&
                        grouped.Observations.Single().Snapshot.ChildrenAvailability == AppInstallValueAvailability.Unknown &&
                        manager.Item.ChildrenReads == 0, name);
                    break;
                case "FirstSubscribeFailure":
                case "SecondSubscribeFailure":
                    manager.FailSubscribe = name == "FirstSubscribeFailure" ? 1 : 2;
                    var failure = Expect<AppInstallOperationException>(() => Wait()).Error;
                    Check(failure.HResult == unchecked((int)0x80070005) &&
                        manager.StatusRemovals == (manager.FailSubscribe == 2 ? 1 : 0) &&
                        manager.CompletionRemovals == 0 && manager.Item.Reads == 0, name);
                    using (context.AcquireObservation(id)) { }
                    return;
                case "GetterAndCleanupFailure":
                case "DisappearedGetter":
                    manager.Item.Failure = new COMException("synthetic private getter", unchecked((int)0x80070490));
                    if (name == "GetterAndCleanupFailure") manager.ThrowOnRemove = true;
                    var failed = Expect<AppInstallOperationException>(() => Wait()).Error;
                    Check(ReferenceEquals(failed.Exception, manager.Item.Failure) &&
                        failed.HResult == manager.Item.Failure.HResult &&
                        failed.CleanupErrors.Count == (manager.ThrowOnRemove ? 2 : 0), name);
                    break;
                case "CleanupOnly":
                    manager.Item.State = 6;
                    manager.ThrowOnRemove = true;
                    var cleanup = Expect<AppInstallOperationException>(() => Wait()).Error;
                    Check(cleanup.Phase == AppInstallErrorPhase.Cleanup && cleanup.CleanupErrors.Count == 1, name);
                    break;
                case "LateCallback":
                    manager.Item.State = 6;
                    manager.CallbackOnRemove = true;
                    Check(Wait().Observations.Count == 1, name);
                    break;
                case "CancelBefore":
                    using (var canceled = new CancellationTokenSource())
                    {
                        canceled.Cancel();
                        var canceledError = Expect<AppInstallOperationException>(() =>
                            AppInstallMonitor.Wait(context, id, TimeSpan.FromSeconds(1), canceled.Token)).Error;
                        Check(canceledError.Kind == AppInstallErrorKind.LocalWaitCancellation && manager.Subscriptions == 0, name);
                    }
                    return;
                case "CancelDuringRead":
                    using (var canceled = new CancellationTokenSource())
                    {
                        manager.Item.OnRead = canceled.Cancel;
                        var canceledError = Expect<AppInstallOperationException>(() =>
                            AppInstallMonitor.Wait(context, id, TimeSpan.FromSeconds(1), canceled.Token)).Error;
                        Check(canceledError.Kind == AppInstallErrorKind.LocalWaitCancellation, name);
                    }
                    break;
                case "DisposeDuringRead":
                    manager.Item.OnRead = context.Dispose;
                    var disposed = Expect<AppInstallOperationException>(() => Wait()).Error;
                    Check(disposed.Kind == AppInstallErrorKind.ContextUnavailable && manager.Disposals == 1, name);
                    break;
                case "Json":
                    manager.Item.State = 6;
                    var original = Wait();
                    var clone = JsonSerializer.Deserialize<AppInstallMonitorResult>(JsonSerializer.Serialize(original))!;
                    Check(clone.ContextId == original.ContextId && clone.LocalItemId == id &&
                        clone.Observations.Single().Snapshot.Identity == original.Observations.Single().Snapshot.Identity, name);
                    break;
                default: throw new ArgumentOutOfRangeException(nameof(name), name, "No live fallback.");
            }
            Check(manager.StatusRemovals == 1 && manager.CompletionRemovals == 1 && manager.Active == 0, name + " cleanup");
            Check(manager.CollectionReads == 1 && manager.Item.ReadThread != manager.WorkerThread, name + " passive exact item");
            if (!context.IsDisposed)
            {
                Check(manager.Disposals == 0, name + " caller ownership");
                using (context.AcquireObservation(id)) { }
            }
        }
        finally { Runspace.DefaultRunspace = previous; }
    }

    private static void Command(string name, AppInstallContext context, Manager manager,
        Runspace owner, InitialSessionState state, Guid id)
    {
        using var pipeline = PowerShell.Create();
        pipeline.Runspace = owner;
        pipeline.AddCommand("Wait-AppInstallItem").AddParameter("Context", context)
            .AddParameter("LocalItemId", id).AddParameter("TimeoutSeconds", name == "CommandInvalidTimeout" ? 31 : 1);
        if (name == "CommandInvalidTimeout")
        {
            Expect<ParameterBindingException>(() => pipeline.Invoke());
            Check(manager.Subscriptions == 0, name);
            return;
        }
        if (name == "CommandWrongRunspace")
        {
            using var other = RunspaceFactory.CreateRunspace(state);
            other.Open();
            pipeline.Runspace = other;
            var wrong = Expect<RuntimeException>(() => pipeline.Invoke()).ErrorRecord;
            Check(wrong.TargetObject is AppInstallError { Kind: AppInstallErrorKind.ContextUnavailable } &&
                manager.Subscriptions == 0, name);
            return;
        }
        if (name is "CommandStopProcessing" or "CommandContextDispose")
        {
            using var read = new ManualResetEventSlim();
            manager.Item.OnRead = read.Set;
            using var output = new PSDataCollection<PSObject>();
            var invoke = pipeline.BeginInvoke<PSObject, PSObject>(null, output);
            try
            {
                Check(read.Wait(TimeSpan.FromSeconds(5)), "command reached fake snapshot read");
                if (name == "CommandStopProcessing")
                {
                    var stopping = pipeline.BeginStop(null, null);
                    Check(stopping.AsyncWaitHandle.WaitOne(TimeSpan.FromSeconds(5)), "compiled StopProcessing ended");
                    pipeline.EndStop(stopping);
                }
                else context.Dispose();
                Check(invoke.AsyncWaitHandle.WaitOne(TimeSpan.FromSeconds(5)), "observation exited");
                try { pipeline.EndInvoke(invoke); }
                catch (RuntimeException) when (pipeline.InvocationStateInfo.State is PSInvocationState.Stopped or PSInvocationState.Failed) { }
                Check(output.Count == 0 && manager.StatusRemovals == 1 && manager.CompletionRemovals == 1 &&
                    manager.Active == 0 && manager.Item.State == 3, name);
                Check(manager.Disposals == (name == "CommandContextDispose" ? 1 : 0), name + " manager lifetime");
            }
            finally { if (!invoke.IsCompleted) pipeline.Stop(); }
            return;
        }
        manager.Item.State = 6;
        if (name == "CommandFailure") manager.Item.Failure = new COMException("private synthetic diagnostic", unchecked((int)0x80070005));
        if (name == "CommandCleanupOnly") manager.ThrowOnRemove = true;
        if (name is "CommandFailure" or "CommandCleanupOnly")
        {
            var failure = Expect<RuntimeException>(() => pipeline.Invoke()).ErrorRecord;
            Check(failure.TargetObject is AppInstallError &&
                !failure.ErrorDetails.Message.Contains("private synthetic", StringComparison.Ordinal), name);
        }
        else
        {
            var result = pipeline.Invoke().Single().BaseObject as AppInstallMonitorResult;
            Check(result?.Outcome == AppInstallObservationOutcome.TargetTerminal &&
                result.Observations.Count == 1 && !context.IsDisposed, name);
        }
        Check(manager.StatusRemovals == 1 && manager.CompletionRemovals == 1 && manager.Active == 0, name);
    }

    private static void Check(bool value, string name)
    {
        if (!value) throw new InvalidOperationException("Monitoring assertion failed: " + name);
    }
    private static T Expect<T>(Action action) where T : Exception
    {
        try { action(); } catch (T error) { return error; }
        throw new InvalidOperationException("Expected " + typeof(T).Name);
    }
    private sealed class Clock : IAppInstallObservationWait
    {
        public TimeSpan Elapsed { get; private set; }
        internal int Waits;
        internal Action? OnWait;
        internal void Advance(TimeSpan duration) => Elapsed += duration;
        public void Wait(WaitHandle[] signals, TimeSpan remaining)
        {
            Waits++;
            Advance(OnWait is null ? remaining : TimeSpan.FromMilliseconds(1));
            OnWait?.Invoke();
        }
    }
    private sealed class Availability : IAppInstallAvailability
    {
        internal string? Missing;
        public bool IsSupportedPlatform => true;
        public bool IsTypePresent(string name) => name is
            "Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallManager" or
            "Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallItem" or
            "Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallStatus";
        public bool IsMemberPresent(AppInstallMember member)
        {
            var allowed = member.TypeName[(member.TypeName.LastIndexOf('.') + 1)..] switch
            {
                "AppInstallManager" => new[] { "AppInstallItems", "ItemStatusChanged", "ItemCompleted" },
                "AppInstallItem" => ["ProductId", "PackageFamilyName", "InstallType", "IsUserInitiated",
                    "ItemOperationsMightAffectOtherItems", "GetCurrentStatus"],
                "AppInstallStatus" => ["InstallState", "ErrorCode", "BytesDownloaded", "DownloadSizeInBytes",
                    "PercentComplete", "IsStaged", "ReadyForLaunch"],
                _ => []
            };
            if (!allowed.Contains(member.Name)) throw new InvalidOperationException("Unexpected fake metadata: " + member.Name);
            return member.Name != Missing;
        }
    }
    private sealed class Activation(Manager manager) : IAppInstallActivation
    {
        public IAppInstallManagerAdapter Activate() => manager;
    }
    private sealed class Manager : IAppInstallManagerAdapter, IAppInstallInventoryManager, IAppInstallMonitoringManager
    {
        internal Item Item = new();
        internal Action? Status, Completion, OnSubscribe;
        internal bool Empty, ThrowOnRemove, CallbackOnRemove;
        internal int CollectionReads, Subscriptions, Active, StatusRemovals, CompletionRemovals, Disposals, FailSubscribe, WorkerThread;
        public AppInstallInventoryTracker InventoryTracker { get; } = new();
        public IReadOnlyList<IAppInstallInventoryItem> GetItems(bool includeChildren)
        {
            if (includeChildren) throw new InvalidOperationException("No grouped enumeration is authorized by these fakes.");
            CollectionReads++;
            return Empty ? [] : [Item];
        }
        public IDisposable SubscribeStatusChanged(Action changed) => Subscribe(changed, false);
        public IDisposable SubscribeCompleted(Action changed) => Subscribe(changed, true);
        private IDisposable Subscribe(Action callback, bool complete)
        {
            Subscriptions++;
            if (FailSubscribe == Subscriptions) throw new COMException("synthetic add failure", unchecked((int)0x80070005));
            Active++;
            if (complete) Completion = callback; else Status = callback;
            if (complete) OnSubscribe?.Invoke();
            return new AppInstallSubscription(() =>
            {
                Check(Disposals == 0, "manager still alive during unsubscribe");
                if (complete) CompletionRemovals++; else StatusRemovals++;
                if (CallbackOnRemove)
                {
                    var worker = new Thread(() => { WorkerThread = Environment.CurrentManagedThreadId; callback(); });
                    worker.Start();
                    worker.Join();
                }
                Active--;
                if (complete) Completion = null; else Status = null;
                if (ThrowOnRemove) throw new IOException(complete ? "completion cleanup" : "status cleanup");
            });
        }
        public void Dispose()
        {
            Check(Active == 0, "subscriptions released before manager disposal");
            Disposals++;
            InventoryTracker.Clear();
        }
    }
    private sealed class Item : IAppInstallInventoryItem
    {
        internal int State = 3, Reads, ReadThread, ChildrenReads;
        internal Exception? Failure, NativeError;
        internal Action? OnRead;
        public object IdentityKey { get; } = new();
        public AppInstallUserScope UserScope => AppInstallUserScope.Caller;
        public string ProductId => "synthetic-private-product";
        public string PackageFamilyName => "synthetic-private-family";
        public int InstallType => 0;
        public bool IsUserInitiated => false;
        public bool ItemOperationsMightAffectOtherItems => true;
        public IReadOnlyList<IAppInstallInventoryItem> Children
        {
            get { ChildrenReads++; throw new InvalidOperationException("No child getter is permitted during exact-item observation."); }
        }
        public IAppInstallInventoryStatus GetCurrentStatus()
        {
            if (ReadThread == 0) ReadThread = Environment.CurrentManagedThreadId;
            Check(ReadThread == Environment.CurrentManagedThreadId, "snapshot reads on one execution thread");
            Reads++;
            var result = new Status(State, NativeError);
            OnRead?.Invoke();
            if (Failure is not null) throw Failure;
            return result;
        }
    }
    private sealed class Status(int state, Exception? error) : IAppInstallInventoryStatus
    {
        public int InstallState => state;
        public ulong BytesDownloaded => 0;
        public ulong DownloadSizeInBytes => 0;
        public double PercentComplete => 100;
        public bool IsStaged => true;
        public bool ReadyForLaunch => true;
        public Exception? ErrorCode => error;
    }
}
