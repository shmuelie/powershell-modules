using System.Management.Automation;

namespace Shmuelie.Windows.AppInstall;

// The caller must obtain ShouldProcess approval before executing this internal
// coordinator. The compiled public entry point enforces that confirmation.
internal static class AppInstallUpdateSearch
{
    internal const string OptionsType = "Windows.ApplicationModel.Store.Preview.InstallControl.AppUpdateOptions";
    internal static readonly AppInstallMember Search = new(AppInstallMember.ManagerType,
        "SearchForAllUpdatesAsync", AppInstallMemberKind.Method, 3);
    internal static readonly AppInstallMember Download = new(OptionsType,
        "AutomaticallyDownloadAndInstallUpdateIfFound", AppInstallMemberKind.PropertySet);
    internal static readonly AppInstallMember Restart = new(OptionsType,
        "AllowForcedAppRestart", AppInstallMemberKind.PropertySet);
    private const string ItemType = "Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallItem";
    internal static string Operation => $"{Search.TypeName}.{Search.Name}";

    internal static AppInstallRequestSnapshot Execute(AppInstallContext context, string correlationVector,
        string clientId, CancellationToken stopWaiting)
    {
        ArgumentNullException.ThrowIfNull(context);
        ArgumentNullException.ThrowIfNull(correlationVector);
        ArgumentNullException.ThrowIfNull(clientId);
        var requestId = Guid.NewGuid();
        var acceptance = AppInstallRequestAcceptance.NotSubmitted;
        var operationState = AppInstallOperationState.Unknown;
        var waitState = AppInstallWaitState.NotWaiting;
        var phase = AppInstallErrorPhase.Availability;
        var source = Operation;
        ObservedOperation? observed = null;
        try
        {
            foreach (var required in new[] { Search, Download, Restart,
                new AppInstallMember(ItemType, "ProductId", AppInstallMemberKind.PropertyGet),
                new AppInstallMember(ItemType, "PackageFamilyName", AppInstallMemberKind.PropertyGet),
                new AppInstallMember(ItemType, "GetCurrentStatus", AppInstallMemberKind.Method) })
            {
                stopWaiting.ThrowIfCancellationRequested();
                source = $"{required.TypeName}.{required.Name}";
                context.RequireUpdateSearchMember(required);
            }
            source = "Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallStatus";
            context.RequireUpdateSearchType(source);
            source = Operation;
            var provider = context.Use(Search, manager => manager as IAppInstallUpdateSearchManager ??
                throw new NotSupportedException("This manager does not support the approved paused update search."), out phase);
            source = $"{OptionsType}.ctor";
            var options = context.Use(Search, _ => provider.CreateUpdateOptions(), out phase);
            source = $"{Download.TypeName}.{Download.Name}";
            context.Use(Download, _ => { options.AutomaticallyDownloadAndInstallUpdateIfFound = false; return true; }, out phase);
            source = $"{Restart.TypeName}.{Restart.Name}";
            context.Use(Restart, _ => { options.AllowForcedAppRestart = false; return true; }, out phase);
            stopWaiting.ThrowIfCancellationRequested();
            source = Operation;
            var submitted = context.Use(Search, _ =>
            {
                // A throwing submission cannot prove that remote work was rejected.
                acceptance = AppInstallRequestAcceptance.Unknown;
                var operation = provider.SearchPausedUpdates(correlationVector, clientId, options) ??
                    throw new InvalidOperationException("Search submission returned no async operation.");
                acceptance = AppInstallRequestAcceptance.Accepted;
                return operation;
            }, out phase);

            waitState = AppInstallWaitState.Waiting;
            observed = new ObservedOperation(submitted, state => operationState = state switch
            {
                AppInstallAsyncState.Started => AppInstallOperationState.Started,
                AppInstallAsyncState.Completed => AppInstallOperationState.Completed,
                AppInstallAsyncState.Error => AppInstallOperationState.Failed,
                AppInstallAsyncState.Canceled => AppInstallOperationState.Canceled,
                _ => AppInstallOperationState.Unknown
            });
            var returned = AppInstallOperationWaiter.WaitAndDispose(Operation, observed, stopWaiting);
            waitState = AppInstallWaitState.Completed;
            phase = AppInstallErrorPhase.Invocation;
            source = $"{Operation}.Results";
            var items = new AppInstallInventoryReader(context, stopWaiting.ThrowIfCancellationRequested)
                .CaptureSearchResults(provider.InventoryTracker, returned, Search);
            return Snapshot(AppInstallValueAvailability.Available, items, null);
        }
        catch (Exception failure)
        {
            var error = failure switch
            {
                AppInstallOperationException translated => translated.Error,
                AppInstallCleanupException aggregate => AppInstallError.Capture(
                    aggregate.SourceOperation, aggregate.PrimaryPhase, aggregate.PrimaryException)
                    .WithCleanup(AppInstallError.Capture(aggregate.SourceOperation,
                        AppInstallErrorPhase.Cleanup, aggregate.CleanupException)),
                OperationCanceledException when stopWaiting.IsCancellationRequested =>
                    AppInstallError.Capture(source, AppInstallErrorPhase.LocalWait, failure),
                _ => AppInstallError.Capture(source, observed?.FailurePhase ?? phase, failure)
            };
            if (error.Kind == AppInstallErrorKind.LocalWaitCancellation)
                waitState = AppInstallWaitState.StoppedLocally;
            else if (waitState == AppInstallWaitState.Waiting)
                waitState = AppInstallWaitState.Completed;
            throw new AppInstallUpdateSearchException(Snapshot(AppInstallValueAvailability.Unknown, [], error));
        }

        AppInstallRequestSnapshot Snapshot(AppInstallValueAvailability available,
            IReadOnlyList<AppInstallItemSnapshot> items, AppInstallError? error) =>
            new(context.ContextId, Operation, AppInstallUserScope.Caller, acceptance, operationState, waitState,
                available, items, error, requestId, correlationVector, clientId);
    }

    private sealed class ObservedOperation(
        IAppInstallAsyncOperation<IReadOnlyList<IAppInstallInventoryItem>> operation,
        Action<AppInstallAsyncState> observed) : IAppInstallAsyncOperation<IReadOnlyList<IAppInstallInventoryItem>>
    {
        internal AppInstallErrorPhase? FailurePhase { get; private set; }
        public AppInstallAsyncState State
        {
            get
            {
                try { var state = operation.State; observed(state); return state; }
                catch (Exception) { FailurePhase ??= AppInstallErrorPhase.AsyncStatus; throw; }
            }
        }
        public IReadOnlyList<IAppInstallInventoryItem> GetResult()
        {
            try { return operation.GetResult(); }
            catch (Exception) { FailurePhase ??= AppInstallErrorPhase.AsyncResult; throw; }
        }
        public void Dispose()
        {
            try { operation.Dispose(); }
            catch (Exception) { FailurePhase ??= AppInstallErrorPhase.Cleanup; throw; }
        }
    }
}

internal sealed class AppInstallUpdateSearchException : Exception
{
    internal AppInstallUpdateSearchException(AppInstallRequestSnapshot request)
        : base(request.Error?.Message, request.Error?.Exception)
    {
        Request = request;
        HResult = request.Error?.HResult ??
            throw new InvalidOperationException("A failed search requires an original error.");
    }
    internal AppInstallRequestSnapshot Request { get; }

    internal ErrorRecord ToErrorRecord()
    {
        var native = Request.Error?.ToErrorRecord() ??
            throw new InvalidOperationException("A failed search requires an original error.");
        return new ErrorRecord(native.Exception, native.FullyQualifiedErrorId, native.CategoryInfo.Category, Request);
    }
}
