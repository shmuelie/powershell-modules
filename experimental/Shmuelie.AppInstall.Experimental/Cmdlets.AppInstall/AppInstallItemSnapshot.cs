using System.Text.Json.Serialization;

namespace Shmuelie.Windows.AppInstall;

/// <summary>Observed native identifiers plus explicitly local, context-scoped correlation.</summary>
public sealed record AppInstallItemIdentity
{
    public AppInstallItemIdentity(Guid contextId, Guid localItemId, Guid? parentLocalItemId,
        AppInstallUserScope userScope, AppInstallValueAvailability availability,
        string? productId, string? packageFamilyName)
    {
        ContextId = AppInstallModelGuard.Id(contextId);
        LocalItemId = AppInstallModelGuard.Id(localItemId);
        if (parentLocalItemId is Guid parent)
        {
            AppInstallModelGuard.Id(parent);
            if (parent == localItemId) throw new ArgumentException("An item cannot be its own parent.", nameof(parentLocalItemId));
        }
        AppInstallModelGuard.Defined(userScope);
        AppInstallModelGuard.Defined(availability);
        if (availability != AppInstallValueAvailability.Available && (productId is not null || packageFamilyName is not null))
            throw new ArgumentException("Unobserved identifiers cannot contain native values.", nameof(availability));
        if (availability == AppInstallValueAvailability.Available && productId is null && packageFamilyName is null)
            throw new ArgumentException("An available identity must contain an observed native identifier.", nameof(availability));
        ParentLocalItemId = parentLocalItemId;
        UserScope = userScope;
        Availability = availability;
        ProductId = productId;
        PackageFamilyName = packageFamilyName;
    }

    public Guid ContextId { get; }
    public Guid LocalItemId { get; }
    public Guid? ParentLocalItemId { get; }
    public AppInstallUserScope UserScope { get; }
    public AppInstallValueAvailability Availability { get; }
    public string? ProductId { get; }
    public string? PackageFamilyName { get; }
}

public sealed record AppInstallItemSnapshot
{
    public AppInstallItemSnapshot(AppInstallItemIdentity identity, AppInstallStatusSnapshot status,
        AppInstallValueAvailability childrenAvailability, IReadOnlyList<AppInstallItemSnapshot> children)
        : this(identity, status, childrenAvailability, children,
            AppInstallValue<int>.Unknown, AppInstallValue<bool>.Unknown, AppInstallValue<bool>.Unknown) { }

    [JsonConstructor]
    public AppInstallItemSnapshot(AppInstallItemIdentity identity, AppInstallStatusSnapshot status,
        AppInstallValueAvailability childrenAvailability, IReadOnlyList<AppInstallItemSnapshot> children,
        AppInstallValue<int>? installType, AppInstallValue<bool>? isUserInitiated,
        AppInstallValue<bool>? itemOperationsMightAffectOtherItems)
    {
        ArgumentNullException.ThrowIfNull(identity);
        ArgumentNullException.ThrowIfNull(status);
        // Older foundation snapshots did not contain these observations.
        InstallType = installType ?? AppInstallValue<int>.Unknown;
        IsUserInitiated = isUserInitiated ?? AppInstallValue<bool>.Unknown;
        ItemOperationsMightAffectOtherItems = itemOperationsMightAffectOtherItems ?? AppInstallValue<bool>.Unknown;
        AppInstallModelGuard.Defined(childrenAvailability);
        Identity = identity;
        Status = status;
        ChildrenAvailability = childrenAvailability;
        Children = AppInstallModelGuard.Copy(children);
        if (childrenAvailability != AppInstallValueAvailability.Available && Children.Count != 0)
            throw new ArgumentException("Unobserved children cannot contain items.", nameof(children));
        foreach (var child in Children)
        {
            if (child.Identity.ContextId != identity.ContextId ||
                child.Identity.ParentLocalItemId != identity.LocalItemId ||
                child.Identity.UserScope != identity.UserScope)
                throw new ArgumentException("Children must have unique local IDs and the same context, parent and user scope.", nameof(children));
        }
        var ids = new HashSet<Guid> { identity.LocalItemId };
        var pending = new Stack<AppInstallItemSnapshot>(Children);
        while (pending.TryPop(out var item))
        {
            if (!ids.Add(item.Identity.LocalItemId))
                throw new ArgumentException("A group cannot repeat a local item ID, including an ancestor's ID.", nameof(children));
            foreach (var child in item.Children) pending.Push(child);
        }
    }

    public AppInstallItemIdentity Identity { get; }
    public AppInstallStatusSnapshot Status { get; }
    public AppInstallValueAvailability ChildrenAvailability { get; }
    public IReadOnlyList<AppInstallItemSnapshot> Children { get; }
    public AppInstallValue<int> InstallType { get; }
    public AppInstallValue<bool> IsUserInitiated { get; }
    public AppInstallValue<bool> ItemOperationsMightAffectOtherItems { get; }
}
