namespace Shmuelie.Windows.AppInstall;

internal sealed class AppInstallInventoryTracker
{
    private readonly object sync = new();
    private Dictionary<object, Guid> active = new();
    internal int Count { get { lock (sync) return active.Count; } }

    internal Guid GetLocalId(object key)
    {
        lock (sync) return active.TryGetValue(key, out var id) ? id : Guid.NewGuid();
    }

    internal void Commit(IReadOnlyDictionary<object, Guid> observed)
    {
        if (observed.Count > AppInstallInventoryReader.MaximumItems)
            throw new InvalidDataException("The inventory exceeds the bounded identity cache limit.");
        lock (sync) active = new Dictionary<object, Guid>(observed);
    }

    internal void Clear() { lock (sync) active.Clear(); }

    internal void Merge(IReadOnlyDictionary<object, Guid> observed)
    {
        lock (sync)
        {
            var combined = new Dictionary<object, Guid>(active);
            foreach (var pair in observed) combined[pair.Key] = pair.Value;
            if (combined.Count > AppInstallInventoryReader.MaximumItems)
                throw new InvalidDataException("Search results exceed the bounded identity cache; no unrelated identities were pruned.");
            active = combined;
        }
    }
}
