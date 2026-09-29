using System.Management.Automation.Runspaces;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Nodes;
using Shmuelie.Windows.AppInstall;

namespace Shmuelie.Windows.AppInstall.Tests;

public static partial class UpdateSearchScenarios
{
    public static void Run(string scenario)
    {
        if (scenario.StartsWith("Command", StringComparison.Ordinal))
        {
            RunCommand(scenario);
            return;
        }
        using var owner = RunspaceFactory.CreateRunspace();
        owner.Open();
        var previous = Runspace.DefaultRunspace;
        Runspace.DefaultRunspace = owner;
        try
        {
            var availability = new Availability();
            var manager = new Manager();
            var activation = new Activation(manager);
            using var context = new AppInstallContext(owner, availability, activation);
            using var stop = new CancellationTokenSource();
            AppInstallRequestSnapshot Execute() => AppInstallUpdateSearch.Execute(context, "synthetic-vector", "synthetic-client", stop.Token);
            if (scenario.StartsWith("Missing:", StringComparison.Ordinal))
            {
                availability.Missing = scenario["Missing:".Length..];
                var unavailable = Expect<AppInstallUpdateSearchException>(Execute).Request;
                Check(unavailable.Acceptance == AppInstallRequestAcceptance.NotSubmitted &&
                    unavailable.Error?.Phase == AppInstallErrorPhase.Availability &&
                    activation.Count == 0 && manager.Calls.Count == 0, scenario);
                return;
            }
            switch (scenario)
            {
                case "EmptyPausedSearch":
                    var result = Execute();
                    Check(manager.Calls.SequenceEqual(["create", "download:false", "restart:false", "submit"]), scenario);
                    Check(result.Acceptance == AppInstallRequestAcceptance.Accepted &&
                        result.OperationState == AppInstallOperationState.Completed &&
                        result.WaitState == AppInstallWaitState.Completed &&
                        result.ItemsAvailability == AppInstallValueAvailability.Available &&
                        result.Items.Count == 0 && result.RequestId is not null, scenario);
                    Check(manager.Operation.DisposeCount == 1 && activation.Count == 1, scenario);
                    break;
                case "UnsupportedFixedOption":
                    availability.Missing = "AllowForcedAppRestart";
                    var missing = Expect<AppInstallUpdateSearchException>(Execute).Request;
                    Check(missing.Acceptance == AppInstallRequestAcceptance.NotSubmitted && activation.Count == 0 &&
                        manager.Calls.Count == 0 && missing.Error?.Phase == AppInstallErrorPhase.Availability, scenario);
                    break;
                case "WrongRunspaceBeforeSubmission":
                    Runspace.DefaultRunspace = null;
                    try
                    {
                        var invalid = Expect<AppInstallUpdateSearchException>(Execute).Request;
                        Check(invalid.Error?.Kind == AppInstallErrorKind.ContextUnavailable &&
                            invalid.Acceptance == AppInstallRequestAcceptance.NotSubmitted && activation.Count == 0, scenario);
                    }
                    finally { Runspace.DefaultRunspace = owner; }
                    break;
                case "SubmissionFailureIsUnknown":
                    manager.SubmissionError = new COMException("Synthetic submit failure.", unchecked((int)0x80070005));
                    var submission = Expect<AppInstallUpdateSearchException>(Execute).Request;
                    Check(submission.Acceptance == AppInstallRequestAcceptance.Unknown &&
                        submission.OperationState == AppInstallOperationState.Unknown &&
                        ReferenceEquals(submission.Error?.Exception, manager.SubmissionError) &&
                        submission.Error?.Phase == AppInstallErrorPhase.Invocation, scenario);
                    break;
                case "AcceptedResultFailure":
                    manager.Operation.ResultError = new COMException("Synthetic results failure.", unchecked((int)0x80004005));
                    var failed = Expect<AppInstallUpdateSearchException>(Execute);
                    Check(failed.Request.Acceptance == AppInstallRequestAcceptance.Accepted &&
                        failed.Request.OperationState == AppInstallOperationState.Completed &&
                        failed.Request.Error?.Phase == AppInstallErrorPhase.AsyncResult &&
                        ReferenceEquals(failed.ToErrorRecord().Exception, manager.Operation.ResultError) &&
                        ReferenceEquals(failed.ToErrorRecord().TargetObject, failed.Request), scenario);
                    break;
                case "LocalCancelDoesNotCancelNative":
                    manager.Operation.NativeState = AppInstallAsyncState.Started;
                    manager.Operation.OnRead = stop.Cancel;
                    var canceled = Expect<AppInstallUpdateSearchException>(Execute).Request;
                    Check(canceled.Acceptance == AppInstallRequestAcceptance.Accepted &&
                        canceled.OperationState == AppInstallOperationState.Started &&
                        canceled.WaitState == AppInstallWaitState.StoppedLocally &&
                        canceled.Error?.Kind == AppInstallErrorKind.LocalWaitCancellation &&
                        manager.Operation.DisposeCount == 1, scenario);
                    break;
                case "EmptySearchDoesNotPrune":
                    var unrelated = new object();
                    var retainedId = Guid.NewGuid();
                    manager.InventoryTracker.Commit(new Dictionary<object, Guid> { [unrelated] = retainedId });
                    Execute();
                    Check(manager.InventoryTracker.Count == 1 &&
                        manager.InventoryTracker.GetLocalId(unrelated) == retainedId, scenario);
                    break;
                case "CorrelationSerialization":
                    var serialized = JsonSerializer.Deserialize<AppInstallRequestSnapshot>(JsonSerializer.Serialize(Execute()))!;
                    Check(serialized.RequestId is not null && serialized.CorrelationVector == "synthetic-vector" &&
                        serialized.ClientId == "synthetic-client" && serialized.Items.Count == 0, scenario);
                    break;
                case "OlderRequestSerialization":
                    var older = JsonNode.Parse(JsonSerializer.Serialize(Execute()))!.AsObject();
                    older.Remove("RequestId");
                    older.Remove("CorrelationVector");
                    older.Remove("ClientId");
                    var compatible = older.Deserialize<AppInstallRequestSnapshot>()!;
                    Check(compatible.RequestId is null && compatible.CorrelationVector is null &&
                        compatible.ClientId is null && compatible.ContextId == context.ContextId &&
                        compatible.Acceptance == AppInstallRequestAcceptance.Accepted &&
                        compatible.ItemsAvailability == AppInstallValueAvailability.Available &&
                        compatible.Items.Count == 0, scenario);
                    break;
                case "GroupedMultipleAndIdentityMerge":
                    var child = new Item(2);
                    var parent = new Item(1);
                    parent.ChildItems.Add(child);
                    manager.Operation.Items = [parent, child, new Item(3), new Item(3)];
                    var retained = Guid.NewGuid();
                    var parentId = Guid.NewGuid();
                    manager.InventoryTracker.Commit(new Dictionary<object, Guid> { [99] = retained, [1] = parentId });
                    var grouped = Execute();
                    Check(grouped.Items.Count == 2 && grouped.Items[0].Children.Count == 1 &&
                        grouped.Items[0].Identity.LocalItemId == parentId &&
                        grouped.Items[0].Children[0].Identity.ParentLocalItemId == parentId &&
                        grouped.Items.All(i => i.Identity.ContextId == context.ContextId &&
                            i.Identity.UserScope == AppInstallUserScope.Caller) &&
                        grouped.Items[0].Status.TerminalState == AppInstallTerminalState.NotTerminal &&
                        manager.InventoryTracker.Count == 4 && manager.InventoryTracker.GetLocalId(99) == retained, scenario);
                    var detached = JsonSerializer.Deserialize<AppInstallRequestSnapshot>(JsonSerializer.Serialize(grouped))!;
                    Check(detached.Items[0].Children[0].Identity == grouped.Items[0].Children[0].Identity, scenario);
                    Check(!context.IsDisposed && manager.DisposeCount == 0 && manager.Operation.DisposeCount == 1, scenario);
                    break;
                case "MergeCapacityRollback":
                    var full = Enumerable.Range(0, AppInstallInventoryReader.MaximumItems)
                        .ToDictionary(i => (object)i, _ => Guid.NewGuid());
                    manager.InventoryTracker.Commit(full);
                    manager.Operation.Items = [new Item(AppInstallInventoryReader.MaximumItems)];
                    var overflow = Expect<AppInstallUpdateSearchException>(Execute).Request;
                    Check(overflow.Error?.Exception is InvalidDataException &&
                        overflow.Acceptance == AppInstallRequestAcceptance.Accepted &&
                        overflow.ItemsAvailability == AppInstallValueAvailability.Unknown &&
                        manager.InventoryTracker.Count == full.Count &&
                        full.All(p => manager.InventoryTracker.GetLocalId(p.Key) == p.Value), scenario);
                    break;
                case "CaptureFailurePreservesCache":
                case "CaptureCancellation":
                    var originalId = Guid.NewGuid();
                    manager.InventoryTracker.Commit(new Dictionary<object, Guid> { [99] = originalId });
                    var broken = new Item(1);
                    manager.Operation.Items = [broken];
                    if (scenario == "CaptureCancellation") broken.OnStatus = stop.Cancel;
                    else broken.Failure = new COMException("Synthetic disappearing item.", unchecked((int)0x80070490));
                    var capture = Expect<AppInstallUpdateSearchException>(Execute).Request;
                    Check(capture.Acceptance == AppInstallRequestAcceptance.Accepted &&
                        capture.OperationState == AppInstallOperationState.Completed &&
                        capture.Items.Count == 0 && manager.InventoryTracker.Count == 1 &&
                        manager.InventoryTracker.GetLocalId(99) == originalId, scenario);
                    if (scenario == "CaptureCancellation")
                        Check(capture.WaitState == AppInstallWaitState.StoppedLocally &&
                            capture.Error?.Kind == AppInstallErrorKind.LocalWaitCancellation, scenario);
                    else Check(ReferenceEquals(capture.Error?.Exception, broken.Failure) &&
                        capture.Error?.SourceOperation.EndsWith(".GetCurrentStatus") == true, scenario);
                    break;
                case "DisposedBeforeSearch":
                case "DisposedAfterAcceptance":
                    if (scenario == "DisposedBeforeSearch") context.Dispose();
                    else manager.Operation.OnRead = context.Dispose;
                    var disposed = Expect<AppInstallUpdateSearchException>(Execute).Request;
                    Check(disposed.Error?.Kind == AppInstallErrorKind.ContextUnavailable &&
                        disposed.Acceptance == (scenario == "DisposedBeforeSearch"
                            ? AppInstallRequestAcceptance.NotSubmitted : AppInstallRequestAcceptance.Accepted) &&
                        activation.Count == (scenario == "DisposedBeforeSearch" ? 0 : 1), scenario);
                    break;
                case "ActivationFailure":
                    activation.Error = new COMException("Synthetic denial.", unchecked((int)0x80070005));
                    var denied = Expect<AppInstallUpdateSearchException>(Execute).Request;
                    Check(denied.Acceptance == AppInstallRequestAcceptance.NotSubmitted &&
                        denied.Error?.Phase == AppInstallErrorPhase.Activation &&
                        ReferenceEquals(denied.Error.Exception, activation.Error) && manager.Calls.Count == 0, scenario);
                    break;
                case "OptionsConstructorFailure":
                case "DownloadSetterFailure":
                case "RestartSetterFailure":
                    manager.FailAt = scenario == "OptionsConstructorFailure" ? "create" :
                        scenario == "DownloadSetterFailure" ? "download:false" : "restart:false";
                    var optionsFailure = Expect<AppInstallUpdateSearchException>(Execute).Request;
                    Check(optionsFailure.Acceptance == AppInstallRequestAcceptance.NotSubmitted &&
                        optionsFailure.Error?.Phase == AppInstallErrorPhase.Invocation &&
                        ReferenceEquals(optionsFailure.Error.Exception, manager.OptionsError) &&
                        !manager.Calls.Contains("submit"), scenario);
                    break;
                case "NativeCancellation":
                case "NativeFailure":
                    manager.Operation.NativeState = scenario == "NativeCancellation" ? AppInstallAsyncState.Canceled : AppInstallAsyncState.Error;
                    manager.Operation.ResultError = scenario == "NativeCancellation" ? new OperationCanceledException("Synthetic native cancellation.") :
                        new COMException("Synthetic native failure.", unchecked((int)0x80004005));
                    var native = Expect<AppInstallUpdateSearchException>(Execute).Request;
                    Check(native.Acceptance == AppInstallRequestAcceptance.Accepted &&
                        native.OperationState == (scenario == "NativeCancellation" ? AppInstallOperationState.Canceled : AppInstallOperationState.Failed) &&
                        native.WaitState == AppInstallWaitState.Completed && manager.Operation.DisposeCount == 1 &&
                        ReferenceEquals(native.Error?.Exception, manager.Operation.ResultError), scenario);
                    if (scenario == "NativeCancellation") Check(native.Error?.Kind == AppInstallErrorKind.NativeCancellation, scenario);
                    break;
                case "StatusAndCleanupFailure":
                case "CleanupOnlyFailure":
                    var cleanup = new NullReferenceException("Synthetic unclassified cleanup.");
                    manager.Operation.DisposeError = cleanup;
                    if (scenario == "StatusAndCleanupFailure")
                        manager.Operation.StatusError = new InvalidCastException("Synthetic unclassified status.");
                    var cleanupRequest = Expect<AppInstallUpdateSearchException>(Execute).Request;
                    Check(cleanupRequest.Acceptance == AppInstallRequestAcceptance.Accepted &&
                        cleanupRequest.ItemsAvailability == AppInstallValueAvailability.Unknown &&
                        cleanupRequest.Error?.Kind == AppInstallErrorKind.UnclassifiedFailure, scenario);
                    var capturedError = cleanupRequest.Error ?? throw new InvalidOperationException("Missing failure metadata.");
                    if (scenario == "StatusAndCleanupFailure")
                        Check(ReferenceEquals(capturedError.Exception, manager.Operation.StatusError) &&
                            capturedError.Phase == AppInstallErrorPhase.AsyncStatus &&
                            ReferenceEquals(capturedError.CleanupErrors.Single().Exception, cleanup), scenario);
                    else Check(ReferenceEquals(capturedError.Exception, cleanup) &&
                        capturedError.Phase == AppInstallErrorPhase.Cleanup, scenario);
                    break;
                case "CanceledBeforeSubmission":
                    stop.Cancel();
                    var notSubmitted = Expect<AppInstallUpdateSearchException>(Execute).Request;
                    Check(notSubmitted.Acceptance == AppInstallRequestAcceptance.NotSubmitted &&
                        notSubmitted.WaitState == AppInstallWaitState.StoppedLocally &&
                        manager.Calls.Count == 0 && activation.Count == 0, scenario);
                    break;
                case "SdkSignature":
                    var method = typeof(global::Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallManager)
                        .GetMethod("SearchForAllUpdatesAsync", [typeof(string), typeof(string),
                            typeof(global::Windows.ApplicationModel.Store.Preview.InstallControl.AppUpdateOptions)]);
                    Check(method is not null && method.ReturnType == typeof(global::Windows.Foundation.IAsyncOperation<
                        IReadOnlyList<global::Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallItem>>), scenario);
                    Check(manager.Calls.Count == 0 && activation.Count == 0, scenario);
                    break;
                default: throw new ArgumentOutOfRangeException(nameof(scenario), scenario, "No live test fallback.");
            }
        }
        finally { Runspace.DefaultRunspace = previous; }
    }

    private static T Expect<T>(Func<AppInstallRequestSnapshot> action) where T : Exception
    {
        try { action(); }
        catch (T error) { return error; }
        throw new InvalidOperationException($"Expected {typeof(T).Name}.");
    }
    private static void Check(bool valid, string name)
    {
        if (!valid) throw new InvalidOperationException("Failed search scenario: " + name);
    }
    private sealed class Availability : IAppInstallAvailability
    {
        internal string? Missing;
        internal int Checks;
        public bool IsSupportedPlatform => true;
        public bool IsTypePresent(string name)
        {
            Checks++;
            return name.Split('.').Last() != Missing && name is
            "Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallManager" or
            "Windows.ApplicationModel.Store.Preview.InstallControl.AppUpdateOptions" or
            "Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallItem" or
            "Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallStatus";
        }
        public bool IsMemberPresent(AppInstallMember member)
        {
            Checks++;
            bool known = (member.TypeName.Split('.').Last(), member.Name) switch
            {
                ("AppInstallManager", "SearchForAllUpdatesAsync") => member.Kind == AppInstallMemberKind.Method && member.ParameterCount == 3,
                ("AppUpdateOptions", "AutomaticallyDownloadAndInstallUpdateIfFound" or "AllowForcedAppRestart") => member.Kind == AppInstallMemberKind.PropertySet,
                ("AppInstallItem", "ProductId" or "PackageFamilyName" or "Children" or "InstallType" or
                    "IsUserInitiated" or "ItemOperationsMightAffectOtherItems") => member.Kind == AppInstallMemberKind.PropertyGet,
                ("AppInstallItem", "GetCurrentStatus") => member.Kind == AppInstallMemberKind.Method && member.ParameterCount == 0,
                ("AppInstallStatus", "InstallState" or "ErrorCode" or "BytesDownloaded" or "DownloadSizeInBytes" or
                    "PercentComplete" or "IsStaged" or "ReadyForLaunch") => member.Kind == AppInstallMemberKind.PropertyGet,
                _ => throw new InvalidOperationException("Unexpected native member: " + member.Name)
            };
            return known && member.Name != Missing;
        }
    }
    private sealed class Activation(Manager manager) : IAppInstallActivation
    {
        internal int Count;
        internal Exception? Error;
        public IAppInstallManagerAdapter Activate() { Count++; if (Error is not null) throw Error; return manager; }
    }
    private sealed class Manager : IAppInstallManagerAdapter, IAppInstallUpdateSearchManager
    {
        internal List<string> Calls = [];
        internal Operation Operation = new();
        internal Exception? SubmissionError;
        internal string ExpectedCorrelationVector = "synthetic-vector";
        internal string ExpectedClientId = "synthetic-client";
        internal string? FailAt;
        internal readonly Exception OptionsError = new COMException("Synthetic options failure.", unchecked((int)0x80004005));
        internal int DisposeCount;
        public AppInstallInventoryTracker InventoryTracker { get; } = new();
        private void Configure(string call)
        {
            Calls.Add(call);
            if (FailAt == call) throw OptionsError;
        }
        public IAppInstallUpdateSearchOptions CreateUpdateOptions() { Configure("create"); return new Options(Configure); }
        public IAppInstallAsyncOperation<IReadOnlyList<IAppInstallInventoryItem>> SearchPausedUpdates(
            string correlationVector, string clientId, IAppInstallUpdateSearchOptions options)
        {
            Check(options is Options { Download: false, Restart: false } &&
                Calls.SequenceEqual(["create", "download:false", "restart:false"]), "fixed options before submit");
            Check(correlationVector == ExpectedCorrelationVector && clientId == ExpectedClientId, "native correlation forwarding");
            Calls.Add("submit");
            if (SubmissionError is not null) throw SubmissionError;
            return Operation;
        }
        public void Dispose() { DisposeCount++; InventoryTracker.Clear(); }
    }
    private sealed class Options(Action<string> configure) : IAppInstallUpdateSearchOptions
    {
        internal bool Download = true;
        internal bool Restart = true;
        public bool AutomaticallyDownloadAndInstallUpdateIfFound { set { configure("download:" + value.ToString().ToLowerInvariant()); Download = value; } }
        public bool AllowForcedAppRestart { set { configure("restart:" + value.ToString().ToLowerInvariant()); Restart = value; } }
    }
    private sealed class Operation : IAppInstallAsyncOperation<IReadOnlyList<IAppInstallInventoryItem>>
    {
        internal AppInstallAsyncState NativeState = AppInstallAsyncState.Completed;
        internal Exception? ResultError;
        internal Exception? StatusError;
        internal Exception? DisposeError;
        internal IReadOnlyList<IAppInstallInventoryItem> Items = [];
        internal Action? OnRead;
        internal int DisposeCount;
        public AppInstallAsyncState State { get { OnRead?.Invoke(); if (StatusError is not null) throw StatusError; return NativeState; } }
        public IReadOnlyList<IAppInstallInventoryItem> GetResult()
        {
            if (ResultError is not null) throw ResultError;
            Check(NativeState == AppInstallAsyncState.Completed, "GetResult only on completion");
            return Items;
        }
        public void Dispose() { DisposeCount++; if (DisposeError is not null) throw DisposeError; }
    }
    private sealed class Item(int key) : IAppInstallInventoryItem
    {
        internal List<IAppInstallInventoryItem> ChildItems = [];
        internal Exception? Failure;
        internal Action? OnStatus;
        public object IdentityKey => key;
        public AppInstallUserScope UserScope => AppInstallUserScope.Caller;
        public string ProductId => $"product-{key}";
        public string PackageFamilyName => $"family-{key}";
        public int InstallType => 1;
        public bool IsUserInitiated => true;
        public bool ItemOperationsMightAffectOtherItems => ChildItems.Count != 0;
        public IReadOnlyList<IAppInstallInventoryItem> Children => ChildItems;
        public IAppInstallInventoryStatus GetCurrentStatus()
        {
            OnStatus?.Invoke();
            if (Failure is not null) throw Failure;
            return new Status();
        }
    }
    private sealed class Status : IAppInstallInventoryStatus
    {
        public int InstallState => (int)global::Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallState.Paused;
        public ulong BytesDownloaded => 0;
        public ulong DownloadSizeInBytes => 100;
        public double PercentComplete => 0;
        public bool IsStaged => false;
        public bool ReadyForLaunch => false;
        public Exception? ErrorCode => null;
    }
}
