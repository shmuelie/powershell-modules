using System.Text.Json.Serialization;

namespace Shmuelie.Windows.AppInstall;

/// <summary>Request/async/wait observations; completion does not assert installation success.</summary>
public sealed record AppInstallRequestSnapshot
{
    public AppInstallRequestSnapshot(Guid contextId, string sourceOperation, AppInstallUserScope userScope,
        AppInstallRequestAcceptance acceptance, AppInstallOperationState operationState,
        AppInstallWaitState waitState, AppInstallValueAvailability itemsAvailability,
        IReadOnlyList<AppInstallItemSnapshot> items, AppInstallError? error)
        : this(contextId, sourceOperation, userScope, acceptance, operationState, waitState,
            itemsAvailability, items, error, null, null, null) { }

    [JsonConstructor]
    public AppInstallRequestSnapshot(Guid contextId, string sourceOperation, AppInstallUserScope userScope,
        AppInstallRequestAcceptance acceptance, AppInstallOperationState operationState,
        AppInstallWaitState waitState, AppInstallValueAvailability itemsAvailability,
        IReadOnlyList<AppInstallItemSnapshot> items, AppInstallError? error,
        Guid? requestId, string? correlationVector, string? clientId)
    {
        if (requestId is Guid id) AppInstallModelGuard.Id(id);
        RequestId = requestId;
        CorrelationVector = correlationVector;
        ClientId = clientId;
        ContextId = AppInstallModelGuard.Id(contextId);
        ArgumentException.ThrowIfNullOrWhiteSpace(sourceOperation);
        AppInstallModelGuard.Defined(userScope);
        AppInstallModelGuard.Defined(acceptance);
        AppInstallModelGuard.Defined(operationState);
        AppInstallModelGuard.Defined(waitState);
        AppInstallModelGuard.Defined(itemsAvailability);
        SourceOperation = sourceOperation;
        UserScope = userScope;
        Acceptance = acceptance;
        OperationState = operationState;
        WaitState = waitState;
        ItemsAvailability = itemsAvailability;
        Items = AppInstallModelGuard.Copy(items);
        if (itemsAvailability != AppInstallValueAvailability.Available && Items.Count != 0)
            throw new ArgumentException("Unobserved request items cannot contain values.", nameof(items));
        if (Items.Any(item => item.Identity.ContextId != contextId || item.Identity.UserScope != userScope))
            throw new ArgumentException("Request items must belong to the request context and user scope.", nameof(items));
        Error = error;
    }

    public Guid ContextId { get; }
    public string SourceOperation { get; }
    public AppInstallUserScope UserScope { get; }
    public AppInstallRequestAcceptance Acceptance { get; }
    public AppInstallOperationState OperationState { get; }
    public AppInstallWaitState WaitState { get; }
    public AppInstallValueAvailability ItemsAvailability { get; }
    public IReadOnlyList<AppInstallItemSnapshot> Items { get; }
    public AppInstallError? Error { get; }
    public Guid? RequestId { get; }
    public string? CorrelationVector { get; }
    public string? ClientId { get; }
}
