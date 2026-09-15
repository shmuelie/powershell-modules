using Windows.ApplicationModel.Store.Preview.InstallControl;

namespace Shmuelie.Windows.AppInstall;

internal sealed class AppInstallInventoryReader(AppInstallContext context, Action ensureRunning)
{
    internal const int MaximumItems = 4096;
    internal const int MaximumDepth = 128;
    private const string ItemType = "Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallItem";
    private const string StatusType = "Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallStatus";

    internal IReadOnlyList<AppInstallItemSnapshot> Read(bool includeChildren,
        IReadOnlyList<string>? productIds, IReadOnlyList<string>? packageFamilies)
    {
        var collection = Property(AppInstallMember.ManagerType,
            includeChildren ? "AppInstallItemsWithGroupSupport" : "AppInstallItems");
        var provider = Invoke(collection, manager => manager as IAppInstallInventoryManager ??
            throw new NotSupportedException("This manager adapter does not provide caller-scoped inventory."));
        var roots = Invoke(collection, _ => provider.GetItems(includeChildren));
        CheckCollection(roots);
        var nodes = new Dictionary<object, Node>();
        var initialRoots = new List<Node>();
        var pending = new Queue<Node>();
        foreach (var item in roots)
        {
            var node = Add(item);
            if (!initialRoots.Contains(node)) initialRoots.Add(node);
        }

        while (pending.TryDequeue(out var node))
        {
            ensureRunning();
            if (!includeChildren) continue;
            var member = Property(ItemType, "Children");
            if (!Available(member))
            {
                node.ChildrenAvailability = AppInstallValueAvailability.Unavailable;
                continue;
            }
            var children = Required(member, () => node.Item.Children);
            CheckCollection(children);
            node.ChildrenAvailability = AppInstallValueAvailability.Available;
            foreach (var item in children)
            {
                var child = Add(item);
                if (child.Parent is not null && child.Parent != node)
                    throw new InvalidDataException("An inventory item was reported under different parents.");
                child.Parent = node;
                if (!node.Children.Contains(child)) node.Children.Add(child);
            }
        }

        foreach (var node in nodes.Values)
        {
            var ancestors = new HashSet<Node>();
            for (Node? ancestor = node; ancestor is not null; ancestor = ancestor.Parent)
            {
                if (!ancestors.Add(ancestor))
                    throw new InvalidDataException("The inventory contains a parent/child cycle.");
                if (ancestors.Count > MaximumDepth)
                    throw new InvalidDataException("The inventory exceeds the bounded group depth.");
            }
            node.Depth = ancestors.Count;
        }

        foreach (var node in nodes.Values.OrderByDescending(node => node.Depth))
        {
            ensureRunning();
            var product = Required(Property(ItemType, "ProductId"), () => node.Item.ProductId ??
                throw new InvalidDataException("The ProductId getter returned null."));
            var family = Required(Property(ItemType, "PackageFamilyName"), () => node.Item.PackageFamilyName ??
                throw new InvalidDataException("The PackageFamilyName getter returned null."));
            var identity = new AppInstallItemIdentity(context.ContextId, node.LocalId, node.Parent?.LocalId,
                context.UserScope, AppInstallValueAvailability.Available, product, family);
            var status = Required(new(ItemType, "GetCurrentStatus", AppInstallMemberKind.Method),
                () => node.Item.GetCurrentStatus() ??
                    throw new InvalidDataException("GetCurrentStatus returned no status."));
            var state = Optional(Property(StatusType, "InstallState"), () => status.InstallState);
            var errorMember = Property(StatusType, "ErrorCode");
            AppInstallError? error = null;
            var hResult = AppInstallValue<int>.Unavailable;
            if (Available(errorMember))
            {
                var nativeError = Required(errorMember, () => status.ErrorCode);
                // The supported projection represents a successful HRESULT as null.
                hResult = AppInstallValue<int>.From(nativeError?.HResult ?? 0);
                if (nativeError is not null)
                    error = AppInstallError.Capture($"{StatusType}.ErrorCode", AppInstallErrorPhase.Invocation, nativeError);
            }
            var snapshot = new AppInstallStatusSnapshot(state,
                Optional(Property(StatusType, "BytesDownloaded"), () => status.BytesDownloaded),
                Optional(Property(StatusType, "DownloadSizeInBytes"), () => status.DownloadSizeInBytes),
                Optional(Property(StatusType, "PercentComplete"), () => status.PercentComplete),
                Optional(Property(StatusType, "IsStaged"), () => status.IsStaged),
                Optional(Property(StatusType, "ReadyForLaunch"), () => status.ReadyForLaunch),
                TerminalState(state, hResult), error, hResult);
            node.Snapshot = new AppInstallItemSnapshot(identity, snapshot, node.ChildrenAvailability,
                node.Children.Select(child => child.Snapshot ??
                    throw new InvalidDataException("A child snapshot was not captured.")).ToArray(),
                Optional(Property(ItemType, "InstallType"), () => node.Item.InstallType),
                Optional(Property(ItemType, "IsUserInitiated"), () => node.Item.IsUserInitiated),
                Optional(Property(ItemType, "ItemOperationsMightAffectOtherItems"),
                    () => node.Item.ItemOperationsMightAffectOtherItems));
        }

        var output = new List<AppInstallItemSnapshot>();
        var select = new Stack<Node>(initialRoots.Where(node => node.Parent is null).Reverse());
        while (select.TryPop(out var node))
        {
            var snapshot = node.Snapshot ?? throw new InvalidDataException("An item snapshot was not captured.");
            if (Matches(productIds, snapshot.Identity.ProductId) && Matches(packageFamilies, snapshot.Identity.PackageFamilyName))
                output.Add(snapshot);
            else
                foreach (var child in node.Children.AsEnumerable().Reverse()) select.Push(child);
        }
        Invoke(collection, _ =>
        {
            provider.InventoryTracker.Commit(nodes.ToDictionary(pair => pair.Key, pair => pair.Value.LocalId));
            return true;
        });
        return output.AsReadOnly();

        Node Add(IAppInstallInventoryItem item)
        {
            ArgumentNullException.ThrowIfNull(item);
            if (item.UserScope != context.UserScope)
                throw new InvalidDataException("The inventory adapter returned an item outside the caller scope.");
            var key = item.IdentityKey ?? throw new InvalidDataException("An inventory item has no projection identity.");
            if (nodes.TryGetValue(key, out var existing)) return existing;
            if (nodes.Count == MaximumItems)
                throw new InvalidDataException("The inventory exceeds the bounded item limit.");
            var added = new Node(item, provider.InventoryTracker.GetLocalId(key));
            nodes.Add(key, added);
            pending.Enqueue(added);
            return added;
        }
    }

    private static void CheckCollection(IReadOnlyList<IAppInstallInventoryItem> items)
    {
        ArgumentNullException.ThrowIfNull(items);
        if (items.Count > MaximumItems)
            throw new InvalidDataException("The inventory collection exceeds the bounded item limit.");
    }

    private static bool Matches(IReadOnlyList<string>? filters, string? value) =>
        filters is null || filters.Any(filter => string.Equals(filter, value, StringComparison.OrdinalIgnoreCase));

    private static AppInstallMember Property(string type, string name) => new(type, name, AppInstallMemberKind.PropertyGet);

    private T Invoke<T>(AppInstallMember member, Func<IAppInstallManagerAdapter, T> read)
    {
        ensureRunning();
        var phase = AppInstallErrorPhase.Availability;
        try { return context.Use(member, read, value => phase = value); }
        catch (Exception error)
        {
            throw new AppInstallOperationException(AppInstallError.Capture(
                $"{member.TypeName}.{member.Name}", phase, error));
        }
    }

    private T Required<T>(AppInstallMember member, Func<T> read) => Invoke(member, _ => read());

    private bool Available(AppInstallMember member)
    {
        ensureRunning();
        try { return context.IsInventoryMemberAvailable(member); }
        catch (Exception error)
        {
            throw new AppInstallOperationException(AppInstallError.Capture(
                $"{member.TypeName}.{member.Name}", AppInstallErrorPhase.Availability, error));
        }
    }

    private AppInstallValue<T> Optional<T>(AppInstallMember member, Func<T> read) where T : struct =>
        Available(member) ? AppInstallValue<T>.From(Required(member, read)) : AppInstallValue<T>.Unavailable;

    private static AppInstallTerminalState TerminalState(AppInstallValue<int> state, AppInstallValue<int> hResult)
    {
        if (state.Value is not int code) return AppInstallTerminalState.Unknown;
        return (AppInstallState)code switch
        {
            AppInstallState.Completed => hResult.Value is >= 0 ? AppInstallTerminalState.Succeeded : AppInstallTerminalState.Unknown,
            AppInstallState.Canceled => AppInstallTerminalState.Canceled,
            AppInstallState.Error => AppInstallTerminalState.Failed,
            AppInstallState.Pending or AppInstallState.Starting or AppInstallState.AcquiringLicense or
            AppInstallState.Downloading or AppInstallState.RestoringData or AppInstallState.Installing or
            AppInstallState.Paused or AppInstallState.PausedLowBattery or AppInstallState.PausedWiFiRecommended or
            AppInstallState.PausedWiFiRequired or AppInstallState.ReadyToDownload => AppInstallTerminalState.NotTerminal,
            _ => AppInstallTerminalState.Unknown
        };
    }

    private sealed class Node(IAppInstallInventoryItem item, Guid localId)
    {
        internal IAppInstallInventoryItem Item { get; } = item;
        internal Guid LocalId { get; } = localId;
        internal Node? Parent;
        internal List<Node> Children { get; } = [];
        internal AppInstallValueAvailability ChildrenAvailability = AppInstallValueAvailability.Unknown;
        internal int Depth;
        internal AppInstallItemSnapshot? Snapshot;
    }
}
