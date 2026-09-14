using System.Collections;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text.Json;
using Shmuelie.Windows.AppInstall;
using Windows.Foundation;

namespace Shmuelie.Windows.AppInstall.Tests;

public static class ContractScenarios
{
    private static readonly Guid ContextId = Guid.Parse("10000000-0000-0000-0000-000000000001");
    private static readonly Guid RootId = Guid.Parse("20000000-0000-0000-0000-000000000001");
    private static readonly Guid ChildId = Guid.Parse("20000000-0000-0000-0000-000000000002");
    private const string Operation = "AppInstallManager.SyntheticOperation";

    public static void Run(string name)
    {
        switch (name)
        {
            case "ObservationStates":
                Check(AppInstallValue<bool>.Unknown.Value is null, name);
                Check(AppInstallValue<bool>.Unavailable.Value is null, name);
                Check(AppInstallValue<bool>.Unknown.Availability != AppInstallValue<bool>.Unavailable.Availability, name);
                Check(AppInstallValue<bool>.From(false).Value == false &&
                    AppInstallValue<bool>.From(false).Availability == AppInstallValueAvailability.Available, name);
                break;
            case "ObservationValidation":
                Expect<ArgumentException>(() => new AppInstallValue<bool>(AppInstallValueAvailability.Available, null));
                Expect<ArgumentException>(() => new AppInstallValue<bool>(AppInstallValueAvailability.Unknown, false));
                Expect<ArgumentException>(() => new AppInstallValue<int>(AppInstallValueAvailability.Unavailable, 0));
                Expect<ArgumentOutOfRangeException>(() => new AppInstallValue<bool>((AppInstallValueAvailability)99, null));
                break;
            case "Identity":
                var id = Identity(RootId);
                var copy = Identity(RootId);
                Check(id == copy && id.LocalItemId == RootId && id.ContextId == ContextId, name);
                Check(id.ProductId == "synthetic-product" && id.PackageFamilyName == "synthetic-family", name);
                Check(typeof(AppInstallItemIdentity).GetProperties().All(property =>
                    !property.Name.Contains("Sid", StringComparison.OrdinalIgnoreCase) && property.Name != "NativeId"), name);
                break;
            case "IdentityValidation":
                Expect<ArgumentException>(() => Identity(Guid.Empty));
                Expect<ArgumentException>(() => Identity(RootId, RootId));
                Expect<ArgumentException>(() => new AppInstallItemIdentity(ContextId, RootId, null,
                    AppInstallUserScope.Caller, AppInstallValueAvailability.Unknown, "invented", null));
                Expect<ArgumentException>(() => new AppInstallItemIdentity(ContextId, RootId, null,
                    AppInstallUserScope.Caller, AppInstallValueAvailability.Available, null, null));
                break;
            case "ImmutableProperties":
                foreach (var type in new[]
                {
                    typeof(AppInstallValue<bool>), typeof(AppInstallItemIdentity), typeof(AppInstallItemSnapshot),
                    typeof(AppInstallStatusSnapshot), typeof(AppInstallRequestSnapshot),
                    typeof(AppInstallEntitlementSnapshot), typeof(AppInstallError)
                })
                {
                    Check(type.IsSealed && type.GetProperties(BindingFlags.Instance | BindingFlags.Public)
                        .All(property => property.SetMethod is null), type.Name);
                    Check(type.GetFields(BindingFlags.Instance | BindingFlags.Public).Length == 0, type.Name);
                }
                break;
            case "DeepCollectionCopy":
                var children = new List<AppInstallItemSnapshot> { Item(ChildId, RootId) };
                var parent = new AppInstallItemSnapshot(Identity(RootId), Status(),
                    AppInstallValueAvailability.Available, children);
                var input = new List<AppInstallItemSnapshot> { parent };
                var request = Request(input);
                children.Clear();
                input.Clear();
                Check(request.Items.Count == 1 && request.Items[0].Children.Count == 1, name);
                Expect<NotSupportedException>(() => ((IList)request.Items).Clear());
                Expect<NotSupportedException>(() => ((IList)parent.Children)[0] = Item(ChildId, RootId));
                break;
            case "GroupValidation":
                Expect<ArgumentException>(() => new AppInstallItemSnapshot(Identity(RootId), Status(),
                    AppInstallValueAvailability.Available, [Item(ChildId)]));
                Expect<ArgumentException>(() => new AppInstallItemSnapshot(Identity(RootId), Status(),
                    AppInstallValueAvailability.Available, [Item(ChildId, RootId), Item(ChildId, RootId)]));
                Expect<ArgumentException>(() => new AppInstallItemSnapshot(Identity(RootId), Status(),
                    AppInstallValueAvailability.Unavailable, [Item(ChildId, RootId)]));
                Expect<ArgumentException>(() => new AppInstallItemSnapshot(Identity(RootId), Status(),
                    AppInstallValueAvailability.Available, [null!]));
                var repeatedAncestor = new AppInstallItemSnapshot(Identity(ChildId, RootId), Status(),
                    AppInstallValueAvailability.Available, [Item(RootId, ChildId)]);
                Expect<ArgumentException>(() => new AppInstallItemSnapshot(Identity(RootId), Status(),
                    AppInstallValueAvailability.Available, [repeatedAncestor]));
                break;
            case "IndependentCompletionStates":
                var accepted = Request([Item(RootId)]);
                Check(accepted.Acceptance == AppInstallRequestAcceptance.Accepted &&
                    accepted.OperationState == AppInstallOperationState.Completed &&
                    accepted.Items[0].Status.TerminalState == AppInstallTerminalState.Unknown, name);
                Check(accepted.Items[0].Status.ReadyForLaunch.Value == true &&
                    accepted.Items[0].Status.IsStaged.Value == true, name);
                var stopped = new AppInstallRequestSnapshot(ContextId, Operation, AppInstallUserScope.Caller,
                    AppInstallRequestAcceptance.Accepted, AppInstallOperationState.Started,
                    AppInstallWaitState.StoppedLocally, AppInstallValueAvailability.Unknown, [], null);
                Check(stopped.Acceptance == AppInstallRequestAcceptance.Accepted &&
                    stopped.OperationState == AppInstallOperationState.Started, name);
                break;
            case "StatusValidation":
                foreach (double percent in new[] { -0.1, 100.1, double.NaN, double.PositiveInfinity })
                    Expect<ArgumentOutOfRangeException>(() => Status(percent));
                Check(Status(0).PercentComplete.Value == 0 && Status(100).PercentComplete.Value == 100, name);
                Check(Status().NativeInstallState.Value == 123456, name);
                break;
            case "RequestAvailability":
                var empty = Request([]);
                Check(empty.ItemsAvailability == AppInstallValueAvailability.Available && empty.Items.Count == 0, name);
                Expect<ArgumentException>(() => new AppInstallRequestSnapshot(ContextId, Operation,
                    AppInstallUserScope.Caller, AppInstallRequestAcceptance.Unknown, AppInstallOperationState.Unknown,
                    AppInstallWaitState.NotWaiting, AppInstallValueAvailability.Unknown, [Item(RootId)], null));
                Expect<ArgumentException>(() => new AppInstallRequestSnapshot(Guid.NewGuid(), Operation,
                    AppInstallUserScope.Caller, AppInstallRequestAcceptance.Accepted, AppInstallOperationState.Completed,
                    AppInstallWaitState.Completed, AppInstallValueAvailability.Available, [Item(RootId)], null));
                break;
            case "EntitlementObservation":
                var entitlement = new AppInstallEntitlementSnapshot(Operation, AppInstallEntitlementScope.Caller,
                    "synthetic-product", AppInstallValue<int>.From(0), AppInstallValue<bool>.Unknown, null);
                Check(entitlement.IsGranted.Availability == AppInstallValueAvailability.Unknown, name);
                var detached = RoundTrip(entitlement);
                Check(detached.NativeStatus.Value == 0 && detached.IsGranted.Value is null, name);
                break;
            case "SnapshotSerialization":
                var original = Request([new AppInstallItemSnapshot(Identity(RootId), Status(),
                    AppInstallValueAvailability.Available, [Item(ChildId, RootId)])]);
                var restored = RoundTrip(original);
                Check(restored.Items[0].Identity == original.Items[0].Identity, name);
                Check(restored.Items[0].Children[0].Identity.ParentLocalItemId == RootId, name);
                Check(restored.Items[0].Status.NativeInstallState.Value == 123456 &&
                    restored.Items[0].Status.TerminalState == AppInstallTerminalState.Unknown, name);
                Expect<NotSupportedException>(() => ((IList)restored.Items).Clear());
                Check(RoundTrip(AppInstallValue<bool>.Unavailable).Value is null, name);
                break;
            case "ErrorRecord":
                var originalError = NativeError();
                var error = AppInstallError.Capture(Operation, AppInstallErrorPhase.Activation, originalError);
                var record = error.ToErrorRecord();
                Check(ReferenceEquals(record.Exception, originalError) && ReferenceEquals(record.TargetObject, error), name);
                Check(error.HResult == originalError.HResult && error.SourceOperation == Operation &&
                    error.Phase == AppInstallErrorPhase.Activation && error.Kind == AppInstallErrorKind.AccessDenied, name);
                break;
            case "ErrorCollectionCopy":
                var cleanupList = new List<AppInstallError> {
                    AppInstallError.Capture(Operation, AppInstallErrorPhase.Cleanup, NativeError())
                };
                var metadata = new AppInstallError(Operation, AppInstallErrorPhase.Invocation,
                    AppInstallErrorKind.NativeFailure, -1, "synthetic", typeof(COMException).FullName!, cleanupList);
                cleanupList.Clear();
                Check(metadata.CleanupErrors.Count == 1, name);
                Expect<NotSupportedException>(() => ((IList)metadata.CleanupErrors).Clear());
                break;
            case "ErrorSerialization":
                var serializedError = AppInstallError.Capture(Operation, AppInstallErrorPhase.AsyncResult, NativeError())
                    .WithCleanup(AppInstallError.Capture(Operation, AppInstallErrorPhase.Cleanup, NativeError()));
                var restoredError = RoundTrip(serializedError);
                Check(restoredError.Exception is null && restoredError.HResult == serializedError.HResult &&
                    restoredError.ExceptionType == serializedError.ExceptionType && restoredError.CleanupErrors.Count == 1, name);
                Expect<InvalidOperationException>(() => restoredError.ToErrorRecord());
                break;
            case "CapturedErrorMetadata":
                var mutable = new MutableException("original", -1);
                var captured = AppInstallError.Capture(Operation, AppInstallErrorPhase.Invocation, mutable);
                mutable.Change("changed", -2);
                var withCleanup = captured.WithCleanup(
                    AppInstallError.Capture(Operation, AppInstallErrorPhase.Cleanup, NativeError()));
                Check(captured.Message == "original" && withCleanup.Message == "original" &&
                    withCleanup.HResult == -1 && ReferenceEquals(withCleanup.Exception, mutable), name);
                break;
            case "GateErrorKinds":
                Check(AppInstallError.Capture(Operation, AppInstallErrorPhase.Availability,
                    new MissingMemberException()).Kind == AppInstallErrorKind.MemberUnavailable, name);
                Check(AppInstallError.Capture(Operation, AppInstallErrorPhase.Availability,
                    new PlatformNotSupportedException()).Kind == AppInstallErrorKind.PlatformUnavailable, name);
                Check(AppInstallError.Capture(Operation, AppInstallErrorPhase.Invocation,
                    new ObjectDisposedException("synthetic")).Kind == AppInstallErrorKind.ContextUnavailable, name);
                break;
            case "ProjectedAsyncSuccess":
            case "ProjectedAsyncPendingCompletion":
            case "ProjectedNativeCancellation":
            case "ProjectedResultAndCloseFailure":
            case "ProjectedArgumentAndCloseFailure":
            case "ProjectedStatusAndCleanupFailure":
            case "ProjectedCleanupOnlyFailure":
            case "ProjectedLocalCancellation":
                ProjectedAsync(name);
                break;
            case "MappedInvalidCastAndCleanup":
            case "MappedNullReferenceAndCleanup":
            case "OperationalPrimaryAndUnclassifiedCleanup":
            case "UnclassifiedPrimaryAndCleanup":
            case "BothFailuresUnclassified":
            case "UnclassifiedFailureWithoutCleanup":
            case "UnclassifiedCleanupOnly":
            case "OperationalFailureWithoutCleanup":
            case "UnclassifiedStatusAndCleanup":
                ReviewFailurePreservation(name);
                break;
            default: throw new ArgumentOutOfRangeException(nameof(name), name, "Unknown scenario; no live fallback.");
        }
    }

    private static void ReviewFailurePreservation(string name)
    {
        var native = new FakeNativeOperation { State = AsyncStatus.Error };
        Exception primary = new UnclassifiedTestException("Synthetic unclassified primary.", unchecked((int)0x80131500));
        Exception? cleanup = new COMException("Synthetic operational cleanup.", unchecked((int)0x80004005));
        var expectedPhase = AppInstallErrorPhase.AsyncResult;
        switch (name)
        {
            case "MappedInvalidCastAndCleanup":
                primary = new InvalidCastException("Synthetic mapped E_NOINTERFACE.");
                Check(primary.HResult == unchecked((int)0x80004002), name);
                break;
            case "MappedNullReferenceAndCleanup":
                primary = new NullReferenceException("Synthetic mapped E_POINTER.");
                Check(primary.HResult == unchecked((int)0x80004003), name);
                break;
            case "OperationalPrimaryAndUnclassifiedCleanup":
                primary = NativeError();
                cleanup = new UnclassifiedTestException("Synthetic unexpected cleanup.", unchecked((int)0x80131501));
                break;
            case "BothFailuresUnclassified":
                cleanup = new UnclassifiedTestException("Synthetic unexpected cleanup.", unchecked((int)0x80131501));
                break;
            case "UnclassifiedFailureWithoutCleanup":
                cleanup = null;
                break;
            case "UnclassifiedCleanupOnly":
                native.State = AsyncStatus.Completed;
                cleanup = new UnclassifiedTestException("Synthetic unexpected cleanup.", unchecked((int)0x80131501));
                break;
            case "OperationalFailureWithoutCleanup":
                primary = NativeError();
                cleanup = null;
                break;
            case "UnclassifiedStatusAndCleanup":
                expectedPhase = AppInstallErrorPhase.AsyncStatus;
                break;
        }
        if (name == "UnclassifiedStatusAndCleanup")
            native.StatusErrors = [primary, cleanup!];
        else
        {
            if (name != "UnclassifiedCleanupOnly") native.ResultError = primary;
            native.CloseError = cleanup;
        }

        var adapter = new WinRtAppInstallAsyncOperation<string>(native);
        var actual = Expect<Exception>(() =>
            AppInstallOperationWaiter.WaitAndDispose(Operation, adapter, CancellationToken.None));
        if (name is "OperationalPrimaryAndUnclassifiedCleanup" or "OperationalFailureWithoutCleanup")
        {
            Check(actual is AppInstallOperationException, name);
            var translated = ((AppInstallOperationException)actual).Error;
            Check(ReferenceEquals(translated.Exception, primary) && translated.HResult == primary.HResult &&
                actual.HResult == primary.HResult && translated.SourceOperation == Operation &&
                translated.Phase == expectedPhase, name);
            Check(ReferenceEquals(translated.ToErrorRecord().Exception, primary), name);
            if (cleanup is null)
                Check(translated.CleanupErrors.Count == 0, name);
            else
            {
                var secondary = translated.CleanupErrors.Single();
                Check(ReferenceEquals(secondary.Exception, cleanup) && secondary.HResult == cleanup.HResult &&
                    secondary.SourceOperation == Operation && secondary.Phase == AppInstallErrorPhase.Cleanup &&
                    secondary.Kind == AppInstallErrorKind.UnclassifiedFailure, name);
            }
        }
        else if (name is "UnclassifiedFailureWithoutCleanup" or "UnclassifiedCleanupOnly")
        {
            Exception expected = name == "UnclassifiedCleanupOnly" ? cleanup! : primary;
            Check(ReferenceEquals(actual, expected) && actual.HResult == expected.HResult, name);
            Check(actual.StackTrace?.Contains(name == "UnclassifiedCleanupOnly" ? ".Close()" : ".GetResults()",
                StringComparison.Ordinal) == true, name);
        }
        else
        {
            Check(actual is AppInstallCleanupException, name);
            var aggregate = (AppInstallCleanupException)actual;
            Check(aggregate.InnerExceptions.Count == 2 && ReferenceEquals(aggregate.PrimaryException, primary) &&
                ReferenceEquals(aggregate.CleanupException, cleanup), name);
            Check(aggregate.HResult == primary.HResult && aggregate.PrimaryException.HResult == primary.HResult &&
                aggregate.CleanupException.HResult == cleanup!.HResult &&
                aggregate.SourceOperation == Operation && aggregate.PrimaryPhase == expectedPhase &&
                aggregate.CleanupPhase == AppInstallErrorPhase.Cleanup, name);
            Check(!AppInstallError.IsOperational(primary), name);
        }
        adapter.Dispose();
        Check(native.CancelCount == 0 && native.CompletedAssignments == 0, name);
        Check(native.CloseCount == (name == "UnclassifiedStatusAndCleanup" ? 0 : 1), name);
        Expect<ObjectDisposedException>(() => adapter.GetResult());
    }

    private static void ProjectedAsync(string name)
    {
        using var stop = new CancellationTokenSource();
        var native = new FakeNativeOperation();
        Exception primary = NativeError();
        var cleanup = new COMException("Synthetic cleanup failure.", unchecked((int)0x80004005));
        switch (name)
        {
            case "ProjectedAsyncPendingCompletion":
                int pendingReads = 0;
                native.State = AsyncStatus.Started;
                native.OnStatusRead = () => { if (++pendingReads == 3) native.State = AsyncStatus.Completed; };
                break;
            case "ProjectedNativeCancellation":
                native.State = AsyncStatus.Canceled;
                native.ResultError = primary;
                break;
            case "ProjectedResultAndCloseFailure":
                native.State = AsyncStatus.Error;
                native.ResultError = primary;
                native.CloseError = cleanup;
                break;
            case "ProjectedArgumentAndCloseFailure":
                primary = new ArgumentException("Synthetic mapped native invalid argument.");
                native.State = AsyncStatus.Error;
                native.ResultError = primary;
                native.CloseError = cleanup;
                break;
            case "ProjectedStatusAndCleanupFailure":
                native.StatusErrors = [primary, cleanup];
                break;
            case "ProjectedCleanupOnlyFailure":
                native.CloseError = cleanup;
                break;
            case "ProjectedLocalCancellation":
                native.State = AsyncStatus.Started;
                native.OnStatusRead = stop.Cancel;
                break;
        }
        var adapter = new WinRtAppInstallAsyncOperation<string>(native);
        if (name is "ProjectedAsyncSuccess" or "ProjectedAsyncPendingCompletion")
        {
            Check(AppInstallOperationWaiter.WaitAndDispose(Operation, adapter, stop.Token) == "synthetic", name);
            Check(native.CloseCount == 1, name);
        }
        else
        {
            var exception = Expect<AppInstallOperationException>(() =>
                AppInstallOperationWaiter.WaitAndDispose(Operation, adapter, stop.Token));
            var error = exception.Error;
            if (name == "ProjectedLocalCancellation")
            {
                Check(error.Kind == AppInstallErrorKind.LocalWaitCancellation &&
                    error.Exception is OperationCanceledException canceled && canceled.CancellationToken == stop.Token &&
                    native.CloseCount == 0 && native.ResultCount == 0, name);
            }
            else if (name == "ProjectedCleanupOnlyFailure")
                Check(ReferenceEquals(error.Exception, cleanup) && error.Phase == AppInstallErrorPhase.Cleanup, name);
            else
            {
                Check(ReferenceEquals(error.Exception, primary) && ReferenceEquals(exception.InnerException, primary) &&
                    error.HResult == primary.HResult, name);
                if (name == "ProjectedNativeCancellation")
                    Check(error.Kind == AppInstallErrorKind.NativeCancellation, name);
                else
                    Check(error.CleanupErrors.Count == 1 &&
                        ReferenceEquals(error.CleanupErrors[0].Exception, cleanup), name);
            }
        }
        adapter.Dispose();
        Check(native.CancelCount == 0 && native.CompletedAssignments == 0, name);
        Expect<ObjectDisposedException>(() => adapter.GetResult());
    }

    internal static AppInstallRequestSnapshot Request(IReadOnlyList<AppInstallItemSnapshot> items) => new(
        ContextId, Operation, AppInstallUserScope.Caller, AppInstallRequestAcceptance.Accepted,
        AppInstallOperationState.Completed, AppInstallWaitState.Completed, AppInstallValueAvailability.Available, items, null);

    private static AppInstallItemIdentity Identity(Guid id, Guid? parent = null) => new(ContextId, id, parent,
        AppInstallUserScope.Caller, AppInstallValueAvailability.Available, "synthetic-product", "synthetic-family");
    private static AppInstallItemSnapshot Item(Guid id, Guid? parent = null) => new(Identity(id, parent), Status(),
        AppInstallValueAvailability.Available, []);
    private static AppInstallStatusSnapshot Status(double percent = 75) => new(
        AppInstallValue<int>.From(123456), AppInstallValue<ulong>.From(75), AppInstallValue<ulong>.From(100),
        AppInstallValue<double>.From(percent), AppInstallValue<bool>.From(true), AppInstallValue<bool>.From(true),
        AppInstallTerminalState.Unknown, null);
    private static COMException NativeError() => new("Synthetic native access failure.", unchecked((int)0x80070005));
    private static T RoundTrip<T>(T value) => JsonSerializer.Deserialize<T>(JsonSerializer.Serialize(value)) ??
        throw new InvalidOperationException("Serialization produced no value.");
    private static void Check(bool condition, string scenario)
    {
        if (!condition) throw new InvalidOperationException($"Assertion failed in {scenario}.");
    }
    private static T Expect<T>(Action action) where T : Exception
    {
        try { action(); }
        catch (T error) { return error; }
        throw new InvalidOperationException($"Expected {typeof(T).Name}.");
    }

    private sealed class MutableException : Exception
    {
        private string message;
        internal MutableException(string message, int hResult) { this.message = message; HResult = hResult; }
        public override string Message => message;
        internal void Change(string value, int hResult) { message = value; HResult = hResult; }
    }

    private sealed class UnclassifiedTestException : Exception
    {
        internal UnclassifiedTestException(string message, int hResult) : base(message) => HResult = hResult;
    }

    private sealed class FakeNativeOperation : IAsyncOperation<string>
    {
        internal AsyncStatus State = AsyncStatus.Completed;
        internal Exception? ResultError;
        internal Exception? CloseError;
        internal Exception[] StatusErrors = [];
        internal Action? OnStatusRead;
        internal int CloseCount, CancelCount, ResultCount, CompletedAssignments;
        private int statusReads;
        private readonly int executionThread = Environment.CurrentManagedThreadId;
        public uint Id => 1;
        public Exception ErrorCode => ResultError ?? throw new InvalidOperationException("Unexpected ErrorCode read.");
        public AsyncStatus Status
        {
            get
            {
                Check(Environment.CurrentManagedThreadId == executionThread, "Status execution thread");
                OnStatusRead?.Invoke();
                int read = statusReads++;
                if (read < StatusErrors.Length) throw StatusErrors[read];
                return State;
            }
        }
        [MethodImpl(MethodImplOptions.NoInlining)]
        public string GetResults()
        {
            Check(Environment.CurrentManagedThreadId == executionThread, "GetResults execution thread");
            ResultCount++;
            if (ResultError is not null) throw ResultError;
            if (State != AsyncStatus.Completed) throw new InvalidOperationException("Unexpected GetResults call.");
            return "synthetic";
        }
        public AsyncOperationCompletedHandler<string> Completed
        {
            get => throw new InvalidOperationException("Unexpected Completed read.");
            set { CompletedAssignments++; throw new InvalidOperationException("Unexpected Completed handler."); }
        }
        public void Cancel() { CancelCount++; throw new InvalidOperationException("Native cancellation is prohibited."); }
        [MethodImpl(MethodImplOptions.NoInlining)]
        public void Close()
        {
            Check(Environment.CurrentManagedThreadId == executionThread, "Close execution thread");
            CloseCount++;
            if (CloseError is not null) throw CloseError;
        }
    }
}
