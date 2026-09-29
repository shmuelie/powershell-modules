using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Nodes;
using Shmuelie.Windows.AppInstall;

namespace Shmuelie.Windows.AppInstall.Tests;

public static class InventoryScenarios
{
    private const string Prefix = "Windows.ApplicationModel.Store.Preview.InstallControl.";

    public static void Run(string name)
    {
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
            var reader = new AppInstallInventoryReader(context, () => { });
            var first = new Item(1);
            manager.Items.Add(first);
            switch (name)
            {
                case "Empty":
                    manager.Items.Clear();
                    Check(reader.Read(false, null, null).Count == 0 && activation.Count == 1, name);
                    break;
                case "ObservedFields":
                    var item = reader.Read(false, null, null).Single();
                    Check(item.Identity.ProductId == "product-1" && item.Identity.PackageFamilyName == "family-1", name);
                    Check(item.InstallType.Value == 1234 && item.IsUserInitiated.Value == true &&
                        item.ItemOperationsMightAffectOtherItems.Value == true, name);
                    Check(item.Status.BytesDownloaded.Value == 123UL && item.Status.DownloadSizeInBytes.Value == ulong.MaxValue &&
                        item.Status.PercentComplete.Value == 100 && item.Status.HResult.Value == 0 &&
                        item.Status.ReadyForLaunch.Value == true && item.Status.IsStaged.Value == true, name);
                    Check(item.Status.TerminalState == AppInstallTerminalState.NotTerminal &&
                        item.ChildrenAvailability == AppInstallValueAvailability.Unknown, name);
                    break;
                case "ExactFilters":
                    manager.Items.Add(new Item(2));
                    Check(reader.Read(false, ["PRODUCT-1"], ["FAMILY-1"]).Single().Identity.ProductId == "product-1", name);
                    Check(reader.Read(false, ["product-1"], ["family-2"]).Count == 0, name);
                    Check(reader.Read(false, ["product"], null).Count == 0, name);
                    Check(reader.Read(false, ["*"], null).Count == 0, name);
                    Check(reader.Read(false, ["product-1", "product-2"], null).Count == 2, name);
                    break;
                case "ProjectionIdentity":
                    var native = typeof(global::Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallItem);
                    Check(native.GetMethod("Equals", [typeof(object)])?.DeclaringType == native &&
                        native.GetMethod("GetHashCode")?.DeclaringType == native, name);
                    var originalId = reader.Read(false, null, null).Single().Identity.LocalItemId;
                    manager.Items[0] = new Item(1);
                    Check(reader.Read(false, null, null).Single().Identity.LocalItemId == originalId, name);
                    break;
                case "DuplicateReferences":
                    manager.Items.Add(new Item(1));
                    Check(reader.Read(false, null, null).Count == 1, name);
                    break;
                case "DuplicateNativeNames":
                    manager.Items.Add(new Item(2) { Product = "product-1", Family = "family-1" });
                    var duplicates = reader.Read(false, ["product-1"], null);
                    Check(duplicates.Count == 2 && duplicates[0].Identity.LocalItemId != duplicates[1].Identity.LocalItemId, name);
                    break;
                case "GroupsAndAliases":
                    var child = new Item(2);
                    first.ChildItems.Add(child);
                    first.ChildItems.Add(new Item(2));
                    manager.Items.Add(child);
                    var group = reader.Read(true, null, null).Single();
                    Check(manager.Grouped && group.Children.Count == 1 &&
                        group.Children[0].Identity.ParentLocalItemId == group.Identity.LocalItemId &&
                        group.Children[0].Identity.ContextId == context.ContextId, name);
                    Check(reader.Read(true, ["product-2"], null).Single().Identity.ParentLocalItemId == group.Identity.LocalItemId, name);
                    Check(reader.Read(true, ["product-1", "product-2"], null).Count == 1, name);
                    break;
                case "DeepGroup":
                    var cursor = first;
                    for (int i = 2; i <= 64; i++)
                    {
                        var next = new Item(i);
                        cursor.ChildItems.Add(next);
                        cursor = next;
                    }
                    var current = reader.Read(true, null, null).Single();
                    int depth = 1;
                    while (current.Children.Count != 0) { current = current.Children.Single(); depth++; }
                    Check(depth == 64, name);
                    break;
                case "Cycle":
                    var second = new Item(2);
                    first.ChildItems.Add(second);
                    second.ChildItems.Add(first);
                    Expect<InvalidDataException>(() => reader.Read(true, null, null));
                    Check(manager.InventoryTracker.Count == 0, name);
                    break;
                case "ConflictingParents":
                    var shared = new Item(3);
                    first.ChildItems.Add(shared);
                    var other = new Item(2);
                    other.ChildItems.Add(shared);
                    manager.Items.Add(other);
                    Expect<InvalidDataException>(() => reader.Read(true, null, null));
                    break;
                case "ScopeMismatch":
                    first.Scope = AppInstallUserScope.Unknown;
                    Expect<InvalidDataException>(() => reader.Read(false, null, null));
                    break;
                case "BoundedDepth":
                    var tail = first;
                    for (int i = 2; i <= AppInstallInventoryReader.MaximumDepth + 1; i++)
                    {
                        var next = new Item(i);
                        tail.ChildItems.Add(next);
                        tail = next;
                    }
                    Expect<InvalidDataException>(() => reader.Read(true, null, null));
                    Check(first.StatusReads == 0, name);
                    break;
                case "BoundedItems":
                    manager.Items.AddRange(Enumerable.Range(2, AppInstallInventoryReader.MaximumItems).Select(i => new Item(i)));
                    Expect<InvalidDataException>(() => reader.Read(false, null, null));
                    Check(manager.InventoryTracker.Count == 0, name);
                    break;
                case "CachePruning":
                    var oldId = reader.Read(false, null, null).Single().Identity.LocalItemId;
                    manager.Items.Clear();
                    reader.Read(false, null, null);
                    Check(manager.InventoryTracker.Count == 0, name);
                    manager.Items.Add(first);
                    Check(reader.Read(false, null, null).Single().Identity.LocalItemId != oldId, name);
                    context.Dispose();
                    Check(manager.InventoryTracker.Count == 0, name);
                    break;
                case "FailedCapturePreservesCache":
                    var retainedId = reader.Read(false, null, null).Single().Identity.LocalItemId;
                    var failing = new Item(2) { FailureMember = "GetCurrentStatus" };
                    manager.Items.Add(failing);
                    Expect<AppInstallOperationException>(() => reader.Read(false, null, null));
                    Check(manager.InventoryTracker.Count == 1, name);
                    manager.Items.Remove(failing);
                    Check(reader.Read(false, null, null).Single().Identity.LocalItemId == retainedId, name);
                    break;
                case "UnavailableFields":
                    availability.Missing.Add("AppInstallStatus.IsStaged");
                    availability.Missing.Add("AppInstallItem.InstallType");
                    availability.Missing.Add("AppInstallItem.Children");
                    first.Status.FailureMember = "IsStaged";
                    first.FailureMember = "InstallType";
                    var unavailable = reader.Read(true, null, null).Single();
                    Check(unavailable.Status.IsStaged.Availability == AppInstallValueAvailability.Unavailable &&
                        unavailable.InstallType.Availability == AppInstallValueAvailability.Unavailable &&
                        unavailable.ChildrenAvailability == AppInstallValueAvailability.Unavailable, name);
                    break;
                case "UnavailableCompletionEvidence":
                    first.Status.State = 6;
                    availability.Missing.Add("AppInstallStatus.ErrorCode");
                    var noResultCode = reader.Read(false, null, null).Single().Status;
                    Check(noResultCode.HResult.Availability == AppInstallValueAvailability.Unavailable &&
                        noResultCode.TerminalState == AppInstallTerminalState.Unknown, name);
                    availability.Missing.Clear();
                    availability.Missing.Add("AppInstallStatus.InstallState");
                    var noState = reader.Read(false, null, null).Single().Status;
                    Check(noState.NativeInstallState.Availability == AppInstallValueAvailability.Unavailable &&
                        noState.TerminalState == AppInstallTerminalState.Unknown, name);
                    break;
                case "GetterMissingMemberIsError":
                    first.Status.FailureMember = "IsStaged";
                    first.Status.Failure = new MissingMemberException("Synthetic getter failure, not a metadata absence.");
                    var getterFailure = Expect<AppInstallOperationException>(() => reader.Read(false, null, null)).Error;
                    Check(ReferenceEquals(getterFailure.Exception, first.Status.Failure) &&
                        getterFailure.Phase == AppInstallErrorPhase.Invocation &&
                        getterFailure.SourceOperation.EndsWith(".IsStaged"), name);
                    break;
                case "MissingCollection":
                    availability.Missing.Add("AppInstallManager.AppInstallItems");
                    var missing = Expect<AppInstallOperationException>(() => reader.Read(false, null, null)).Error;
                    Check(activation.Count == 0 && missing.Kind == AppInstallErrorKind.MemberUnavailable &&
                        missing.Phase == AppInstallErrorPhase.Availability, name);
                    break;
                case "ActivationDenied":
                    activation.Failure = new COMException("Synthetic access denial.", unchecked((int)0x80070005));
                    var denied = Expect<AppInstallOperationException>(() => reader.Read(false, null, null)).Error;
                    Check(ReferenceEquals(denied.Exception, activation.Failure) &&
                        denied.HResult == activation.Failure.HResult && denied.Phase == AppInstallErrorPhase.Activation, name);
                    break;
                case "CollectionDenied":
                    manager.Failure = new COMException("Synthetic collection access denial.", unchecked((int)0x80070005));
                    var collectionError = Expect<AppInstallOperationException>(() => reader.Read(false, null, null)).Error;
                    Check(ReferenceEquals(collectionError.Exception, manager.Failure) &&
                        collectionError.SourceOperation.EndsWith(".AppInstallItems") &&
                        collectionError.Phase == AppInstallErrorPhase.Invocation, name);
                    break;
                case "ItemDisappeared":
                case "StatusDenied":
                case "FieldDenied":
                    reader.Read(false, null, null);
                    Exception failure = new COMException("Synthetic item read failure.",
                        name == "ItemDisappeared" ? unchecked((int)0x80070490) : unchecked((int)0x80070005));
                    if (name == "FieldDenied")
                    {
                        first.Status.FailureMember = "ReadyForLaunch";
                        first.Status.Failure = failure;
                    }
                    else
                    {
                        first.FailureMember = "GetCurrentStatus";
                        first.Failure = failure;
                    }
                    var readError = Expect<AppInstallOperationException>(() => reader.Read(false, null, null)).Error;
                    Check(ReferenceEquals(readError.Exception, failure) && readError.HResult == failure.HResult &&
                        readError.SourceOperation.EndsWith(name == "FieldDenied" ? ".ReadyForLaunch" : ".GetCurrentStatus") &&
                        manager.InventoryTracker.Count == 1, name);
                    break;
                case "InstallFailureIsData":
                    first.Status.State = 9;
                    first.Status.NativeError = new COMException("Synthetic installation failure.", unchecked((int)0x80004005));
                    var failed = reader.Read(false, null, null).Single().Status;
                    Check(failed.TerminalState == AppInstallTerminalState.Failed &&
                        failed.HResult.Value == first.Status.NativeError.HResult &&
                        ReferenceEquals(failed.Error?.Exception, first.Status.NativeError), name);
                    break;
                case "TerminalStates":
                    foreach (int state in Enumerable.Range(0, 14).Append(123456))
                    {
                        first.Status.State = state;
                        var observed = reader.Read(false, null, null).Single().Status;
                        var expected = state switch
                        {
                            6 => AppInstallTerminalState.Succeeded,
                            7 => AppInstallTerminalState.Canceled,
                            9 => AppInstallTerminalState.Failed,
                            123456 => AppInstallTerminalState.Unknown,
                            _ => AppInstallTerminalState.NotTerminal
                        };
                        Check(observed.NativeInstallState.Value == state && observed.TerminalState == expected, name);
                    }
                    break;
                case "Serialization":
                    first.ChildItems.Add(new Item(2));
                    var snapshot = reader.Read(true, null, null).Single();
                    var json = JsonSerializer.Serialize(snapshot);
                    var copy = JsonSerializer.Deserialize<AppInstallItemSnapshot>(json)!;
                    Check(copy.Identity == snapshot.Identity && copy.Children.Count == 1 &&
                        copy.InstallType.Value == 1234 && copy.Status.HResult.Value == 0, name);
                    Check(PSSerializer.Deserialize(PSSerializer.Serialize(snapshot)) is PSObject, name);
                    break;
                case "OlderSnapshotSerialization":
                    var older = JsonNode.Parse(JsonSerializer.Serialize(reader.Read(false, null, null).Single()))!.AsObject();
                    older.Remove("InstallType");
                    older.Remove("IsUserInitiated");
                    older.Remove("ItemOperationsMightAffectOtherItems");
                    older["Status"]!.AsObject().Remove("HResult");
                    var compatible = older.Deserialize<AppInstallItemSnapshot>()!;
                    Check(compatible.InstallType.Availability == AppInstallValueAvailability.Unknown &&
                        compatible.IsUserInitiated.Availability == AppInstallValueAvailability.Unknown &&
                        compatible.ItemOperationsMightAffectOtherItems.Availability == AppInstallValueAvailability.Unknown &&
                        compatible.Status.HResult.Availability == AppInstallValueAvailability.Unknown, name);
                    break;
                case "WrongRunspace":
                    Runspace.DefaultRunspace = null;
                    try
                    {
                        var wrongOwner = Expect<AppInstallOperationException>(() => reader.Read(false, null, null)).Error;
                        Check(wrongOwner.Phase == AppInstallErrorPhase.Availability &&
                            wrongOwner.Exception is InvalidOperationException && activation.Count == 0, name);
                    }
                    finally { Runspace.DefaultRunspace = owner; }
                    break;
                case "DisposedContext":
                    context.Dispose();
                    var disposed = Expect<AppInstallOperationException>(() => reader.Read(false, null, null)).Error;
                    Check(disposed.Kind == AppInstallErrorKind.ContextUnavailable && activation.Count == 0, name);
                    break;
                default: throw new ArgumentOutOfRangeException(nameof(name), name, "Unknown inventory scenario; no live fallback.");
            }
        }
        finally { Runspace.DefaultRunspace = previous; }
    }

    public static void VerifyCommand(string manifestPath)
    {
        using var owner = RunspaceFactory.CreateRunspace();
        owner.Open();
        var manager = new Manager();
        manager.Items.Add(new Item(1));
        manager.Items[0].ChildItems.Add(new Item(2));
        var activation = new Activation(manager);
        using var context = new AppInstallContext(owner, new Availability(), activation);
        using var pipeline = PowerShell.Create();
        pipeline.Runspace = owner;
        pipeline.AddCommand("Import-Module").AddParameter("Name", manifestPath).AddParameter("Force");
        pipeline.Invoke();
        Check(!pipeline.HadErrors, "module import");
        pipeline.Commands.Clear();
        pipeline.AddCommand("Get-AppInstallItem").AddParameter("Context", context).AddParameter("IncludeChildren");
        var output = pipeline.Invoke();
        Check(!pipeline.HadErrors && output.Count == 1 && output[0].BaseObject is AppInstallItemSnapshot item &&
            item.Children.Count == 1 && item.Children[0].Identity.ParentLocalItemId == item.Identity.LocalItemId,
            "compiled command output");
        Check(activation.Count == 1 && manager.Grouped, "fake activation and grouped getter");

        pipeline.Commands.Clear();
        pipeline.AddCommand("Get-AppInstallItem").AddParameter("Context", context).AddParameter("ProductId", "   ");
        Expect<RuntimeException>(() => pipeline.Invoke());
        Check(activation.Count == 1, "invalid filter no activation");

        pipeline.Commands.Clear();
        pipeline.Streams.Error.Clear();
        var failedItem = new Item(3)
        {
            FailureMember = "GetCurrentStatus",
            Failure = new COMException("Synthetic item access denial.", unchecked((int)0x80070005))
        };
        manager.Items.Add(failedItem);
        pipeline.AddCommand("Get-AppInstallItem").AddParameter("Context", context);
        using var buffer = new PSDataCollection<PSObject>();
        var invocation = Expect<RuntimeException>(() =>
            pipeline.Invoke<PSObject, PSObject>(null, buffer, new PSInvocationSettings()));
        Check(buffer.Count == 0, "failed capture emits no partial objects");
        var record = invocation.ErrorRecord;
        Check(record.TargetObject is AppInstallError failure && ReferenceEquals(failure.Exception, failedItem.Failure) &&
            failure.HResult == failedItem.Failure.HResult && failure.Phase == AppInstallErrorPhase.Invocation &&
            failure.SourceOperation.EndsWith(".GetCurrentStatus"), "compiled error record retains source/native failure");
        Check(record.FullyQualifiedErrorId.StartsWith("AppInstallAccessDenied", StringComparison.Ordinal),
            "compiled access-denied error ID");
    }

    private static void Check(bool condition, string scenario)
    {
        if (!condition) throw new InvalidOperationException($"Assertion failed in inventory scenario {scenario}.");
    }
    private static T Expect<T>(Action action) where T : Exception
    {
        try { action(); }
        catch (T error) { return error; }
        throw new InvalidOperationException($"Expected {typeof(T).Name}.");
    }

    private sealed class Availability : IAppInstallAvailability
    {
        internal HashSet<string> Missing = [];
        private readonly HashSet<string> known =
        [
            "AppInstallManager.AppInstallItems", "AppInstallManager.AppInstallItemsWithGroupSupport",
            "AppInstallItem.ProductId", "AppInstallItem.PackageFamilyName", "AppInstallItem.InstallType",
            "AppInstallItem.IsUserInitiated", "AppInstallItem.ItemOperationsMightAffectOtherItems",
            "AppInstallItem.Children", "AppInstallItem.GetCurrentStatus",
            "AppInstallStatus.InstallState", "AppInstallStatus.BytesDownloaded", "AppInstallStatus.DownloadSizeInBytes",
            "AppInstallStatus.PercentComplete", "AppInstallStatus.IsStaged", "AppInstallStatus.ReadyForLaunch",
            "AppInstallStatus.ErrorCode"
        ];
        public bool IsSupportedPlatform => true;
        public bool IsTypePresent(string type) => type == Prefix + "AppInstallManager" ||
            type == Prefix + "AppInstallItem" || type == Prefix + "AppInstallStatus";
        public bool IsMemberPresent(AppInstallMember member)
        {
            var name = member.TypeName[Prefix.Length..] + "." + member.Name;
            if (!known.Contains(name)) throw new InvalidOperationException("Unexpected member query: " + name);
            return !Missing.Contains(name);
        }
    }

    private sealed class Activation(Manager manager) : IAppInstallActivation
    {
        internal int Count;
        internal Exception? Failure;
        public IAppInstallManagerAdapter Activate()
        {
            Count++;
            if (Failure is not null) throw Failure;
            return manager;
        }
    }

    private sealed class Manager : IAppInstallManagerAdapter, IAppInstallInventoryManager
    {
        internal List<Item> Items = [];
        internal bool Grouped;
        internal Exception? Failure;
        public AppInstallInventoryTracker InventoryTracker { get; } = new();
        public IReadOnlyList<IAppInstallInventoryItem> GetItems(bool includeChildren)
        {
            Grouped = includeChildren;
            if (Failure is not null) throw Failure;
            return Items;
        }
        public void Dispose() => InventoryTracker.Clear();
    }

    private sealed record Key(int Id);
    private sealed class Item(int id) : IAppInstallInventoryItem
    {
        internal string Product = "product-" + id;
        internal string Family = "family-" + id;
        internal List<IAppInstallInventoryItem> ChildItems = [];
        internal AppInstallUserScope Scope = AppInstallUserScope.Caller;
        internal Status Status = new();
        internal int StatusReads;
        internal string? FailureMember;
        internal Exception Failure = new InvalidOperationException("Unexpected unavailable getter access.");
        public object IdentityKey { get; } = new Key(id);
        public AppInstallUserScope UserScope => Scope;
        public string ProductId => Read("ProductId", Product);
        public string PackageFamilyName => Read("PackageFamilyName", Family);
        public int InstallType => Read("InstallType", 1234);
        public bool IsUserInitiated => Read("IsUserInitiated", true);
        public bool ItemOperationsMightAffectOtherItems => Read("ItemOperationsMightAffectOtherItems", true);
        public IReadOnlyList<IAppInstallInventoryItem> Children => Read("Children", ChildItems);
        public IAppInstallInventoryStatus GetCurrentStatus()
        {
            StatusReads++;
            return Read("GetCurrentStatus", Status);
        }
        private T Read<T>(string name, T value) { if (FailureMember == name) throw Failure; return value; }
    }

    private sealed class Status : IAppInstallInventoryStatus
    {
        internal int State = 3;
        internal Exception? NativeError;
        internal string? FailureMember;
        internal Exception Failure = new InvalidOperationException("Unexpected unavailable getter access.");
        public int InstallState => Read("InstallState", State);
        public ulong BytesDownloaded => Read("BytesDownloaded", 123UL);
        public ulong DownloadSizeInBytes => Read("DownloadSizeInBytes", ulong.MaxValue);
        public double PercentComplete => Read("PercentComplete", 100d);
        public bool IsStaged => Read("IsStaged", true);
        public bool ReadyForLaunch => Read("ReadyForLaunch", true);
        public Exception? ErrorCode => Read("ErrorCode", NativeError);
        private T Read<T>(string name, T value) { if (FailureMember == name) throw Failure; return value; }
    }
}
