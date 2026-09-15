namespace Shmuelie.Windows.AppInstall;

internal sealed class AppInstallInventoryTracker
{
    private readonly object sync = new();
    private Dictionary<object, Guid> active = new();
    private Dictionary<object, AppInstallTrackedItem> retained = new();
    internal int Count { get { lock (sync) return active.Count; } }

    internal Guid GetLocalId(object key)
    {
        lock (sync) return active.TryGetValue(key, out var id) ? id : Guid.NewGuid();
    }

    internal void Commit(IReadOnlyDictionary<object, Guid> observed,
        IReadOnlyDictionary<object, AppInstallTrackedItem>? items = null)
    {
        if (observed.Count > AppInstallInventoryReader.MaximumItems)
            throw new InvalidDataException("The inventory exceeds the bounded identity cache limit.");
        lock (sync)
        {
            active = new Dictionary<object, Guid>(observed);
            retained = items is null ? new() : new(items);
        }
    }

    internal void Clear() { lock (sync) { active.Clear(); retained.Clear(); } }

    internal void Merge(IReadOnlyDictionary<object, Guid> observed,
        IReadOnlyDictionary<object, AppInstallTrackedItem>? items = null)
    {
        lock (sync)
        {
            var combined = new Dictionary<object, Guid>(active);
            foreach (var pair in observed) combined[pair.Key] = pair.Value;
            if (combined.Count > AppInstallInventoryReader.MaximumItems)
                throw new InvalidDataException("Search results exceed the bounded identity cache; no unrelated identities were pruned.");
            var combinedItems = new Dictionary<object, AppInstallTrackedItem>(retained);
            foreach (var key in observed.Keys)
            {
                if (items is not null && items.TryGetValue(key, out var item)) combinedItems[key] = item;
                else combinedItems.Remove(key);
            }
            active = combined;
            retained = combinedItems;
        }
    }

    internal AppInstallTrackedItem Resolve(Guid localItemId)
    {
        lock (sync)
        {
            foreach (var pair in active)
                if (pair.Value == localItemId && retained.TryGetValue(pair.Key, out var item)) return item;
            throw new InvalidOperationException("The exact local item is no longer retained by this context. Capture inventory again; no native-name fallback is used.");
        }
    }
}

internal sealed record AppInstallTrackedItem(IAppInstallInventoryItem Item, AppInstallItemIdentity Identity);
