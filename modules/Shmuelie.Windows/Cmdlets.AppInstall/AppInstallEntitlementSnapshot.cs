namespace Shmuelie.Windows.AppInstall;

/// <summary>Entitlement observations only; constructing this object never acquires an entitlement.</summary>
public sealed record AppInstallEntitlementSnapshot
{
    public AppInstallEntitlementSnapshot(string sourceOperation, AppInstallEntitlementScope scope,
        string? productId, AppInstallValue<int> nativeStatus, AppInstallValue<bool> isGranted,
        AppInstallError? error)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sourceOperation);
        ArgumentNullException.ThrowIfNull(nativeStatus);
        ArgumentNullException.ThrowIfNull(isGranted);
        AppInstallModelGuard.Defined(scope);
        SourceOperation = sourceOperation;
        Scope = scope;
        ProductId = productId;
        NativeStatus = nativeStatus;
        IsGranted = isGranted;
        Error = error;
    }

    public string SourceOperation { get; }
    public AppInstallEntitlementScope Scope { get; }
    public string? ProductId { get; }
    public AppInstallValue<int> NativeStatus { get; }
    public AppInstallValue<bool> IsGranted { get; }
    public AppInstallError? Error { get; }
}
