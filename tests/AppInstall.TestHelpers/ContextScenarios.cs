using System.Management.Automation.Runspaces;
using System.Runtime.InteropServices;
using Shmuelie.Windows.AppInstall;

namespace Shmuelie.Windows.AppInstall.Tests;

public static class ContextScenarios
{
    private static readonly AppInstallMember Getter = new(
        AppInstallMember.ManagerType, "AutoUpdateSetting", AppInstallMemberKind.PropertyGet);

    public static string[] Names =>
    [
        "LazyCreation", "Reuse", "IndependentContexts", "PlatformGate", "TypeGate", "MemberGate",
        "AccessDenied", "WrongRunspace", "Dispose", "RunspaceClose",
        "AsyncSuccess", "AsyncFailure", "NativeCancellation", "StopWaiting", "EventCleanup"
    ];

    public static void Run(string name)
    {
        using var owner = RunspaceFactory.CreateRunspace();
        owner.Open();
        var previous = Runspace.DefaultRunspace;
        Runspace.DefaultRunspace = owner;
        try { RunCore(name, owner); }
        finally { Runspace.DefaultRunspace = previous; }
    }

    private static void RunCore(string name, Runspace owner)
    {
        var availability = new FakeAvailability();
        var activation = new FakeActivation();
        using var context = new AppInstallContext(owner, availability, activation);
        switch (name)
        {
            case "LazyCreation":
                Check(!context.IsActivated && activation.Count == 0 && availability.NativeChecks == 0, name);
                Check(context.UserScope == AppInstallUserScope.Caller && context.RunspaceId == owner.InstanceId, name);
                break;
            case "Reuse":
                var first = context.Use(Getter, manager => manager);
                Check(ReferenceEquals(first, context.Use(Getter, manager => manager)) && activation.Count == 1, name);
                break;
            case "IndependentContexts":
                using (var other = new AppInstallContext(owner, availability, activation))
                {
                    Check(!ReferenceEquals(context.Use(Getter, manager => manager),
                        other.Use(Getter, manager => manager)), name);
                    Check(context.ContextId != other.ContextId && activation.Count == 2, name);
                }
                break;
            case "PlatformGate":
                availability.IsSupportedPlatform = false;
                Expect<PlatformNotSupportedException>(() => context.Use(Getter, _ => true));
                Expect<PlatformNotSupportedException>(() => new AppInstallContext(owner, availability, activation));
                Check(activation.Count == 0 && availability.NativeChecks == 0, name);
                break;
            case "TypeGate":
                availability.TypePresent = false;
                Expect<MissingMemberException>(() => context.Use(Getter, _ => true));
                Check(activation.Count == 0, name);
                break;
            case "MemberGate":
                availability.MemberPresent = false;
                Expect<MissingMemberException>(() => context.Use(Getter, _ => true));
                Check(activation.Count == 0, name);
                break;
            case "AccessDenied":
                var denied = new COMException("Synthetic native access denial.", unchecked((int)0x80070005));
                activation.Failure = denied;
                Check(ReferenceEquals(denied, Expect<COMException>(() => context.Use(Getter, _ => true))), name);
                Check(ReferenceEquals(denied, Expect<COMException>(() => context.Use(Getter, _ => true))), name);
                Check(activation.Count == 1 && !context.IsActivated, name);
                break;
            case "WrongRunspace":
                Runspace.DefaultRunspace = null;
                try { Expect<InvalidOperationException>(() => context.Use(Getter, _ => true)); }
                finally { Runspace.DefaultRunspace = owner; }
                Check(activation.Count == 0, name);
                break;
            case "Dispose":
                var resource = (FakeManager)context.Use(Getter, manager => manager);
                context.Dispose();
                context.Dispose();
                Check(context.IsDisposed && resource.DisposeCount == 1, name);
                Expect<ObjectDisposedException>(() => context.Use(Getter, _ => true));
                break;
            case "RunspaceClose":
                var owned = (FakeManager)context.Use(Getter, manager => manager);
                owner.Close();
                Check(context.IsDisposed && owned.DisposeCount == 1, name);
                break;
            case "DisposeBeforeActivation":
                context.Dispose();
                Expect<ObjectDisposedException>(() => context.Use(Getter, _ => true));
                Check(activation.Count == 0 && availability.NativeChecks == 0, name);
                break;
            case "ClosedRunspace":
                owner.Close();
                Expect<InvalidOperationException>(() => new AppInstallContext(owner, availability, activation));
                Expect<ObjectDisposedException>(() => context.Use(Getter, _ => true));
                Check(activation.Count == 0, name);
                break;
            case "ClosingRunspace":
                bool rejectedWhileClosing = false;
                EventHandler<RunspaceStateEventArgs> onClosing = (_, args) =>
                {
                    if (args.RunspaceStateInfo.State == RunspaceState.Closing)
                    {
                        Expect<InvalidOperationException>(() => new AppInstallContext(owner, availability, activation));
                        rejectedWhileClosing = true;
                    }
                };
                owner.StateChanged += onClosing;
                try { owner.Close(); }
                finally { owner.StateChanged -= onClosing; }
                Check(rejectedWhileClosing && context.IsDisposed && activation.Count == 0, name);
                break;
            case "MemberGateAfterActivation":
                context.Use(Getter, _ => true);
                availability.MemberPresent = false;
                Expect<MissingMemberException>(() => context.Use(Getter, _ => true));
                Check(activation.Count == 1, name);
                break;
            case "FailedActivationDispose":
                activation.Failure = new COMException("Synthetic activation failure.");
                Expect<COMException>(() => context.Use(Getter, _ => true));
                context.Dispose();
                Check(context.IsDisposed && !context.IsActivated && activation.Count == 1, name);
                break;
            case "ActivatedContextSurvivesModuleRemoval":
                var retained = (FakeManager)context.Use(Getter, manager => manager);
                using (var pipeline = System.Management.Automation.PowerShell.Create())
                {
                    pipeline.Runspace = owner;
                    pipeline.AddCommand("Import-Module").AddParameter("Name", typeof(AppInstallContext).Assembly.Location);
                    pipeline.Invoke();
                    Check(!pipeline.HadErrors, name);
                    pipeline.Commands.Clear();
                    pipeline.AddCommand("Remove-Module").AddParameter("Name", "Shmuelie.Windows.AppInstall").AddParameter("Force");
                    pipeline.Invoke();
                    Check(!pipeline.HadErrors, name);
                    Check(!context.IsDisposed && ReferenceEquals(retained, context.Use(Getter, manager => manager)) &&
                        retained.DisposeCount == 0, name);
                }
                owner.Close();
                Check(context.IsDisposed && retained.DisposeCount == 1, name);
                break;
            case "AsyncSuccess":
                using (var operation = new FakeOperation(AppInstallAsyncState.Completed))
                    Check(AppInstallOperationWaiter.Wait(operation, CancellationToken.None) == "synthetic result", name);
                break;
            case "AsyncFailure":
                using (var operation = new FakeOperation(AppInstallAsyncState.Error))
                {
                    operation.Failure = new COMException("Synthetic native async error.", unchecked((int)0x80004005));
                    Check(ReferenceEquals(operation.Failure,
                        Expect<COMException>(() => AppInstallOperationWaiter.Wait(operation, CancellationToken.None))), name);
                }
                break;
            case "NativeCancellation":
                using (var operation = new FakeOperation(AppInstallAsyncState.Canceled))
                {
                    operation.Failure = new OperationCanceledException("Synthetic native cancellation.");
                    Check(ReferenceEquals(operation.Failure,
                        Expect<OperationCanceledException>(() => AppInstallOperationWaiter.Wait(operation, CancellationToken.None))), name);
                }
                break;
            case "StopWaiting":
                using (var stop = new CancellationTokenSource())
                using (var operation = new FakeOperation(AppInstallAsyncState.Started))
                {
                    operation.OnStateRead = stop.Cancel;
                    var canceled = Expect<OperationCanceledException>(() => AppInstallOperationWaiter.Wait(operation, stop.Token));
                    Check(canceled.CancellationToken == stop.Token && operation.ResultCount == 0 &&
                        operation.DisposeCount == 0, name);
                }
                break;
            case "EventCleanup":
                var events = new FakeEvents();
                using (var signal = new AppInstallChangeSignal(events))
                {
                    events.Raise();
                    Check(signal.WaitHandle.WaitOne(0) && !signal.WaitHandle.WaitOne(0), name);
                    signal.Dispose();
                    signal.Dispose();
                    events.RaiseLateCallback();
                    Check(events.SubscriptionCount == 1 && events.UnsubscribeCount == 1, name);
                }
                break;
            default: throw new ArgumentOutOfRangeException(nameof(name), name, "Unknown scenario; no live fallback.");
        }
    }

    private static T Expect<T>(Action action) where T : Exception
    {
        try { action(); }
        catch (T error) { return error; }
        throw new InvalidOperationException($"Expected {typeof(T).Name}.");
    }

    private static void Check(bool condition, string scenario)
    {
        if (!condition) throw new InvalidOperationException($"Assertion failed in {scenario}.");
    }

    private sealed class FakeAvailability : IAppInstallAvailability
    {
        public bool IsSupportedPlatform { get; set; } = true;
        internal bool TypePresent = true;
        internal bool MemberPresent = true;
        internal int NativeChecks;
        public bool IsTypePresent(string name) { NativeChecks++; return TypePresent; }
        public bool IsMemberPresent(AppInstallMember member) { NativeChecks++; return MemberPresent; }
    }

    private sealed class FakeActivation : IAppInstallActivation
    {
        internal int Count;
        internal Exception? Failure;
        public IAppInstallManagerAdapter Activate()
        {
            Count++;
            if (Failure is not null) throw Failure;
            return new FakeManager();
        }
    }

    private sealed class FakeManager : IAppInstallManagerAdapter
    {
        internal int DisposeCount;
        public void Dispose() => DisposeCount++;
    }

    private sealed class FakeOperation(AppInstallAsyncState state) : IAppInstallAsyncOperation<string>
    {
        internal Exception? Failure;
        internal Action? OnStateRead;
        internal int ResultCount;
        internal int DisposeCount;
        public AppInstallAsyncState State { get { OnStateRead?.Invoke(); return state; } }
        public string GetResult()
        {
            ResultCount++;
            if (Failure is not null) throw Failure;
            if (state != AppInstallAsyncState.Completed) throw new InvalidOperationException("Unexpected GetResult.");
            return "synthetic result";
        }
        public void Dispose() => DisposeCount++;
    }

    private sealed class FakeEvents : IAppInstallEvents, IDisposable
    {
        private Action? callback;
        private Action? lateCallback;
        internal int SubscriptionCount;
        internal int UnsubscribeCount;
        public IDisposable Subscribe(Action changed)
        {
            SubscriptionCount++;
            if (callback is not null) throw new InvalidOperationException("Duplicate subscription.");
            callback = lateCallback = changed;
            return this;
        }
        internal void Raise() => (callback ?? throw new InvalidOperationException("No subscription."))();
        internal void RaiseLateCallback() => lateCallback?.Invoke();
        public void Dispose() { UnsubscribeCount++; callback = null; }
    }
}
