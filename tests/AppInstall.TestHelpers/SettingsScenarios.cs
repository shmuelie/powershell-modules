using System.Collections;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json;
using Shmuelie.Windows.AppInstall;
using Windows.ApplicationModel.Store.Preview.InstallControl;

namespace Shmuelie.Windows.AppInstall.Tests;

public static class SettingsScenarios
{
    private static readonly AppInstallSettingsProperty[] Defaults =
        [AppInstallSettingsProperty.AutoUpdateSetting, AppInstallSettingsProperty.CanInstallForAllUsers];
    private const string Identity = "synthetic-sensitive-identity";

    public static void Run(string name)
    {
        var state = InitialSessionState.CreateDefault2();
        state.Commands.Add(new SessionStateCmdletEntry("Get-AppInstallSettings", typeof(GetAppInstallSettingsCommand), null));
        using var owner = RunspaceFactory.CreateRunspace(state);
        owner.Open();
        var previous = Runspace.DefaultRunspace;
        Runspace.DefaultRunspace = owner;
        try { RunCore(name, owner); }
        finally { Runspace.DefaultRunspace = previous; }
    }

    private static void RunCore(string name, Runspace owner)
    {
        var availability = new SettingsAvailability();
        var activation = new SettingsActivation();
        using var context = new AppInstallContext(owner, availability, activation);
        Check(activation.Count == 0 && availability.Checked.Count == 0 && !context.IsActivated, name);
        switch (name)
        {
            case "DefaultPrivacy":
                var defaults = Success(Invoke(owner, context));
                Check(defaults.ContextId == context.ContextId && defaults.UserScope == AppInstallUserScope.Caller, name);
                Check(defaults.RequestedProperties.SequenceEqual(Defaults) && defaults.ReadProperties.SequenceEqual(Defaults), name);
                Check(defaults.AcquisitionIdentity is null &&
                    defaults.AcquisitionIdentityAvailability == AppInstallValueAvailability.Unknown, name);
                Check(activation.Manager.Reads.SequenceEqual(Defaults) &&
                    availability.Checked.SequenceEqual(Defaults.Select(p => p.ToString())), name);
                Check(!JsonSerializer.Serialize(defaults).Contains(Identity, StringComparison.Ordinal) &&
                    !JsonSerializer.Serialize(defaults).Contains("\"AcquisitionIdentity\":", StringComparison.Ordinal), name);
                break;
            case "ExplicitIdentityOnly":
            case "ExplicitAll":
            case "DuplicateSelection":
                activation.Manager.AllowIdentity = true;
                AppInstallSettingsProperty[] selection = name == "ExplicitAll"
                    ? [AppInstallSettingsProperty.AcquisitionIdentity, .. Defaults]
                    : name == "DuplicateSelection"
                        ? [AppInstallSettingsProperty.AcquisitionIdentity, AppInstallSettingsProperty.AcquisitionIdentity]
                        : [AppInstallSettingsProperty.AcquisitionIdentity];
                var selected = Success(Invoke(owner, context, selection));
                Check(selected.AcquisitionIdentity == Identity &&
                    selected.AcquisitionIdentityAvailability == AppInstallValueAvailability.Available, name);
                Check(selected.RequestedProperties.SequenceEqual(selection.Distinct()) &&
                    selected.ReadProperties.SequenceEqual(selection.Distinct()) &&
                    activation.Manager.Reads.SequenceEqual(selection.Distinct()), name);
                Check(selected.AutoUpdateSetting.Availability == (name == "ExplicitAll"
                    ? AppInstallValueAvailability.Available : AppInstallValueAvailability.Unknown), name);
                Check(RoundTrip(selected).AcquisitionIdentity == Identity, name);
                break;
            case "FalseAndZero":
                var zero = Success(Invoke(owner, context));
                Check(zero.AutoUpdateSetting.Value == 0 && zero.AutoUpdateSetting.Availability == AppInstallValueAvailability.Available &&
                    zero.CanInstallForAllUsers.Value == false &&
                    zero.CanInstallForAllUsers.Availability == AppInstallValueAvailability.Available, name);
                break;
            case "FutureEnum":
                activation.Manager.AutoUpdateCode = 123456;
                var future = RoundTrip(Success(Invoke(owner, context, [AppInstallSettingsProperty.AutoUpdateSetting])));
                Check(future.AutoUpdateSetting.Value == 123456 &&
                    future.CanInstallForAllUsers.Availability == AppInstallValueAvailability.Unknown, name);
                break;
            case "ReuseAndRefresh":
                var before = Success(Invoke(owner, context));
                activation.Manager.AutoUpdateCode = 3;
                activation.Manager.AllUsers = true;
                var after = Success(Invoke(owner, context));
                Check(activation.Count == 1 && before.ContextId == after.ContextId &&
                    before.AutoUpdateSetting.Value == 0 && after.AutoUpdateSetting.Value == 3 &&
                    after.CanInstallForAllUsers.Value == true && activation.Manager.Reads.Count == 4, name);
                break;
            case "IndependentScopes":
                var first = Success(Invoke(owner, context));
                var otherActivation = new SettingsActivation();
                using (var other = new AppInstallContext(owner, new SettingsAvailability(), otherActivation))
                {
                    var second = Success(Invoke(owner, other));
                    Check(!ReferenceEquals(activation.Manager, otherActivation.Manager) && first.ContextId != second.ContextId, name);
                    Check(first.AcquisitionIdentityScope == AppInstallSettingScope.ManagerContext &&
                        second.AutoUpdateSettingScope == AppInstallSettingScope.Device &&
                        second.CanInstallForAllUsersScope == AppInstallSettingScope.CallingProcess, name);
                    Check(first.AutoUpdateSetting == second.AutoUpdateSetting, name);
                }
                break;
            case "MemberUnavailable":
                availability.Missing.Add(nameof(AppInstallSettingsProperty.CanInstallForAllUsers));
                var missing = Success(Invoke(owner, context));
                Check(missing.CanInstallForAllUsers.Availability == AppInstallValueAvailability.Unavailable &&
                    missing.CanInstallForAllUsers.Value is null &&
                    missing.ReadProperties.SequenceEqual([AppInstallSettingsProperty.AutoUpdateSetting]) &&
                    activation.Manager.Reads.SequenceEqual([AppInstallSettingsProperty.AutoUpdateSetting]), name);
                break;
            case "IdentityUnavailable":
                availability.Missing.Add(nameof(AppInstallSettingsProperty.AcquisitionIdentity));
                var missingIdentity = Success(Invoke(owner, context, [AppInstallSettingsProperty.AcquisitionIdentity]));
                Check(missingIdentity.AcquisitionIdentity is null &&
                    missingIdentity.AcquisitionIdentityAvailability == AppInstallValueAvailability.Unavailable &&
                    missingIdentity.ReadProperties.Count == 0 && activation.Count == 0, name);
                break;
            case "TypeUnavailable":
                availability.TypePresent = false;
                var missingType = Success(Invoke(owner, context));
                Check(missingType.ReadProperties.Count == 0 &&
                    missingType.AutoUpdateSetting.Availability == AppInstallValueAvailability.Unavailable &&
                    missingType.CanInstallForAllUsers.Availability == AppInstallValueAvailability.Unavailable &&
                    activation.Count == 0, name);
                break;
            case "RecheckAvailability":
                Success(Invoke(owner, context));
                availability.Missing.Add(nameof(AppInstallSettingsProperty.AutoUpdateSetting));
                var refreshed = Success(Invoke(owner, context));
                Check(refreshed.AutoUpdateSetting.Availability == AppInstallValueAvailability.Unavailable &&
                    activation.Count == 1 && activation.Manager.Reads.Count == 3, name);
                break;
            case "DisposedBeforeRead":
            case "DisposedAfterRead":
                if (name == "DisposedAfterRead") Success(Invoke(owner, context));
                context.Dispose();
                context.Dispose();
                var disposed = Failure(Invoke(owner, context));
                Check(disposed.Exception is ObjectDisposedException &&
                    ((AppInstallError)disposed.TargetObject).Kind == AppInstallErrorKind.ContextUnavailable &&
                    activation.Count == (name == "DisposedAfterRead" ? 1 : 0) &&
                    activation.Manager.DisposeCount == (name == "DisposedAfterRead" ? 1 : 0), name);
                break;
            case "WrongRunspace":
                using (var otherOwner = RunspaceFactory.CreateRunspace(owner.InitialSessionState))
                {
                    otherOwner.Open();
                    var wrong = Failure(Invoke(otherOwner, context));
                    Check(wrong.Exception is InvalidOperationException &&
                        ((AppInstallError)wrong.TargetObject).Phase == AppInstallErrorPhase.Availability &&
                        ((AppInstallError)wrong.TargetObject).Kind == AppInstallErrorKind.ContextUnavailable &&
                        activation.Count == 0 && availability.Checked.Count == 0, name);
                }
                break;
            case "PlatformFailure":
                availability.IsSupportedPlatform = false;
                var platform = Failure(Invoke(owner, context));
                Check(platform.Exception is PlatformNotSupportedException &&
                    ((AppInstallError)platform.TargetObject).Kind == AppInstallErrorKind.PlatformUnavailable &&
                    activation.Count == 0 && availability.Checked.Count == 0, name);
                break;
            case "ActivationDenied":
            case "ActivationMissingMember":
                activation.Error = name == "ActivationDenied"
                    ? new COMException(Identity, unchecked((int)0x80070005))
                    : new MissingMemberException("Synthetic activation member failure.");
                var failedActivation = Failure(Invoke(owner, context));
                AssertError(failedActivation, activation.Error, AppInstallErrorPhase.Activation);
                AssertError(Failure(Invoke(owner, context)), activation.Error, AppInstallErrorPhase.Activation);
                Check(activation.Count == 1 && !context.IsActivated && activation.Manager.Reads.Count == 0, name);
                break;
            case "GetterDenied":
            case "GetterComFailure":
            case "GetterMissingMember":
            case "MappedNullReferenceFailure":
            case "MappedInvalidCastFailure":
            case "PartialReadFailure":
            case "IdentityFailurePrivacy":
                var failingProperty = name == "PartialReadFailure" ? AppInstallSettingsProperty.CanInstallForAllUsers
                    : name == "IdentityFailurePrivacy" ? AppInstallSettingsProperty.AcquisitionIdentity
                    : AppInstallSettingsProperty.AutoUpdateSetting;
                activation.Manager.AllowIdentity = name == "IdentityFailurePrivacy";
                Exception error = name == "GetterMissingMember" ? new MissingMemberException(Identity)
                    : name == "GetterDenied" ? new UnauthorizedAccessException(Identity)
                    : name == "MappedNullReferenceFailure" ? new NullReferenceException(Identity)
                    : name == "MappedInvalidCastFailure" ? new InvalidCastException(Identity)
                    : new COMException(Identity, unchecked((int)0x80004005));
                activation.Manager.Errors.Add(failingProperty, error);
                var failure = Failure(Invoke(owner, context, name == "IdentityFailurePrivacy" ? [failingProperty] : null));
                AssertError(failure, error, AppInstallErrorPhase.Invocation);
                Check(((AppInstallError)failure.TargetObject).SourceOperation == $"AppInstallManager.{failingProperty}", name);
                Check(activation.Manager.Reads.Count == (name == "PartialReadFailure" ? 2 : 1), name);
                if (name is "MappedNullReferenceFailure" or "MappedInvalidCastFailure")
                    Check(((AppInstallError)failure.TargetObject).Kind == AppInstallErrorKind.UnclassifiedFailure, name);
                if (name == "GetterDenied")
                    Check(((AppInstallError)failure.TargetObject).Kind == AppInstallErrorKind.AccessDenied &&
                        failure.CategoryInfo.Category == ErrorCategory.PermissionDenied, name);
                break;
            case "NullIdentityFailure":
            case "EmptyIdentityAvailable":
                activation.Manager.AllowIdentity = true;
                activation.Manager.IdentityValue = name == "NullIdentityFailure" ? null : "";
                var identityResult = Invoke(owner, context, [AppInstallSettingsProperty.AcquisitionIdentity]);
                if (name == "NullIdentityFailure")
                    Check(Failure(identityResult).Exception is InvalidOperationException, name);
                else
                {
                    var empty = Success(identityResult);
                    Check(empty.AcquisitionIdentity == "" &&
                        empty.AcquisitionIdentityAvailability == AppInstallValueAvailability.Available, name);
                }
                break;
            case "UnclassifiedFailure":
                var bug = new SettingsTestException("Synthetic managed failure.");
                activation.Manager.Errors.Add(AppInstallSettingsProperty.AutoUpdateSetting, bug);
                var propagated = Expect<SettingsTestException>(() => AppInstallSettingsReader.Read(context, Defaults));
                Check(ReferenceEquals(bug, propagated), name);
                break;
            case "ImmutableJson":
                var values = new List<AppInstallSettingsProperty>(Defaults);
                var immutable = new AppInstallSettingsSnapshot(context.ContextId, values, AppInstallValueAvailability.Unknown,
                    null, AppInstallValue<int>.From(0), AppInstallValue<bool>.From(false));
                values.Clear();
                Check(immutable.RequestedProperties.Count == 2 && immutable.ReadProperties.Count == 2, name);
                Check(typeof(AppInstallSettingsSnapshot).IsSealed &&
                    typeof(AppInstallSettingsSnapshot).GetProperties(BindingFlags.Public | BindingFlags.Instance)
                        .All(property => property.SetMethod is null), name);
                Expect<NotSupportedException>(() => ((IList)immutable.RequestedProperties).Clear());
                Expect<NotSupportedException>(() => ((IList)immutable.ReadProperties).Clear());
                var detached = RoundTrip(immutable);
                Check(detached.ContextId == context.ContextId && detached.AutoUpdateSetting.Value == 0 &&
                    detached.CanInstallForAllUsers.Value == false &&
                    detached.AcquisitionIdentityAvailability == AppInstallValueAvailability.Unknown, name);
                Expect<NotSupportedException>(() => ((IList)detached.RequestedProperties).Clear());
                Check(activation.Count == 0, name);
                break;
            case "SchemaValidation":
                Expect<ArgumentException>(() => new AppInstallSettingsSnapshot(context.ContextId, Defaults,
                    AppInstallValueAvailability.Unknown, Identity, AppInstallValue<int>.From(0), AppInstallValue<bool>.From(false)));
                Expect<ArgumentException>(() => new AppInstallSettingsSnapshot(context.ContextId, Defaults,
                    AppInstallValueAvailability.Available, Identity, AppInstallValue<int>.From(0), AppInstallValue<bool>.From(false)));
                Expect<ArgumentException>(() => new AppInstallSettingsSnapshot(context.ContextId, Defaults,
                    AppInstallValueAvailability.Unknown, null, AppInstallValue<int>.Unknown, AppInstallValue<bool>.From(false)));
                Expect<ArgumentException>(() => new AppInstallSettingsSnapshot(context.ContextId, [],
                    AppInstallValueAvailability.Unknown, null, AppInstallValue<int>.Unknown, AppInstallValue<bool>.Unknown));
                Expect<ArgumentOutOfRangeException>(() => AppInstallSettingsReader.Read(context, [(AppInstallSettingsProperty)99]));
                Check(activation.Count == 0, name);
                break;
            case "SdkSignatures":
                var native = typeof(AppInstallManager);
                Check(native.GetProperty("AcquisitionIdentity")!.PropertyType == typeof(string), name);
                Check(native.GetProperty("AutoUpdateSetting")!.PropertyType == typeof(AutoUpdateSetting), name);
                var allUsersProperty = native.GetProperty("CanInstallForAllUsers")!;
                Check(allUsersProperty.PropertyType == typeof(bool) && allUsersProperty.GetMethod is not null &&
                    allUsersProperty.SetMethod is null, name);
                Check((int)AutoUpdateSetting.Disabled == 0 && (int)AutoUpdateSetting.Enabled == 1 &&
                    (int)AutoUpdateSetting.DisabledByPolicy == 2 && (int)AutoUpdateSetting.EnabledByPolicy == 3, name);
                Check(typeof(IAppInstallSettingsAdapter).GetProperties().All(p => p.SetMethod is null), name);
                Check(activation.Count == 0 && availability.Checked.Count == 0, name);
                break;
            case "InvalidSelector":
                foreach (var invalid in new object[]
                {
                    "*", "All", 0, "0", 1, "1", 2, "2", "99", "ForUser",
                    "AcquisitionIdentity,AutoUpdateSetting", Array.Empty<string>()
                })
                {
                    using var invalidPipeline = PowerShell.Create();
                    invalidPipeline.Runspace = owner;
                    invalidPipeline.AddCommand("Get-AppInstallSettings").AddParameter("Context", context).AddParameter("Property", invalid);
                    Expect<ParameterBindingException>(() => invalidPipeline.Invoke());
                }
                Check(activation.Count == 0 && availability.Checked.Count == 0, name);
                break;
            case "PipelineContext":
                using (var pipeline = PowerShell.Create())
                {
                    pipeline.Runspace = owner;
                    pipeline.AddCommand("Get-AppInstallSettings");
                    var output = pipeline.Invoke(new[] { context });
                    Check(!pipeline.HadErrors && output.Count == 1 &&
                        ((AppInstallSettingsSnapshot)output[0].BaseObject).ContextId == context.ContextId &&
                        activation.Count == 1, name);
                }
                break;
            default: throw new ArgumentOutOfRangeException(nameof(name), name, "Unknown scenario; no live fallback.");
        }
    }

    private static Invocation Invoke(Runspace owner, AppInstallContext context, AppInstallSettingsProperty[]? properties = null)
    {
        using var pipeline = PowerShell.Create();
        pipeline.Runspace = owner;
        pipeline.AddCommand("Get-AppInstallSettings").AddParameter("Context", context).AddParameter("Verbose").AddParameter("Debug");
        if (properties is not null) pipeline.AddParameter("Property", properties);
        var output = new List<PSObject>();
        ErrorRecord[] errors;
        try
        {
            pipeline.Invoke<PSObject>(null, output);
            errors = pipeline.Streams.Error.ToArray();
        }
        catch (RuntimeException error) when (error.ErrorRecord.TargetObject is AppInstallError)
        {
            errors = [error.ErrorRecord];
        }
        Check(pipeline.Streams.Verbose.Count == 0 && pipeline.Streams.Debug.Count == 0 &&
            pipeline.Streams.Warning.Count == 0 && pipeline.Streams.Information.Count == 0, "No unsolicited diagnostic logging");
        return new Invocation(output.Select(value => value.BaseObject).ToArray(), errors);
    }

    private sealed record Invocation(object[] Output, ErrorRecord[] Errors);

    private static AppInstallSettingsSnapshot Success(Invocation invocation)
    {
        Check(invocation.Errors.Length == 0 && invocation.Output.Length == 1, "Expected exactly one successful snapshot");
        return (AppInstallSettingsSnapshot)invocation.Output[0];
    }

    private static ErrorRecord Failure(Invocation invocation)
    {
        Check(invocation.Output.Length == 0 && invocation.Errors.Length == 1, "No partial/error-shaped success");
        var error = invocation.Errors[0];
        Check(error.ErrorDetails is not null && !error.ErrorDetails.Message.Contains(Identity, StringComparison.Ordinal) &&
            !error.ToString().Contains(Identity, StringComparison.Ordinal), "Redacted default error rendering");
        using var formatting = PowerShell.Create();
        formatting.Runspace = Runspace.DefaultRunspace;
        formatting.AddCommand("Out-String");
        var rendered = formatting.Invoke(new[] { error });
        Check(!formatting.HadErrors && rendered.Count > 0 &&
            !string.Join("", rendered.Select(value => value.ToString())).Contains(Identity, StringComparison.Ordinal),
            "Default PowerShell error formatting must not reveal identity");
        return error;
    }

    private static void AssertError(ErrorRecord record, Exception original, AppInstallErrorPhase phase)
    {
        var error = (AppInstallError)record.TargetObject;
        Check(ReferenceEquals(record.Exception, original) && ReferenceEquals(error.Exception, original) &&
            error.HResult == original.HResult && error.Phase == phase, "Preserved original error and phase");
    }

    private sealed class SettingsTestException(string message) : Exception(message)
    {
    }

    private static AppInstallSettingsSnapshot RoundTrip(AppInstallSettingsSnapshot snapshot) =>
        JsonSerializer.Deserialize<AppInstallSettingsSnapshot>(JsonSerializer.Serialize(snapshot)) ??
        throw new InvalidOperationException("Snapshot JSON returned null.");

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

    private sealed class SettingsAvailability : IAppInstallAvailability
    {
        public bool IsSupportedPlatform { get; set; } = true;
        internal bool TypePresent = true;
        internal readonly HashSet<string> Missing = [];
        internal readonly List<string> Checked = [];
        public bool IsTypePresent(string name)
        {
            Check(name == AppInstallMember.ManagerType, "Only manager metadata is permitted");
            return TypePresent;
        }
        public bool IsMemberPresent(AppInstallMember member)
        {
            Check(member.TypeName == AppInstallMember.ManagerType && member.Kind == AppInstallMemberKind.PropertyGet &&
                member.ParameterCount == 0 && Enum.TryParse<AppInstallSettingsProperty>(member.Name, out _),
                "Only exact approved getter metadata is permitted");
            Checked.Add(member.Name);
            return !Missing.Contains(member.Name);
        }
    }

    private sealed class SettingsActivation : IAppInstallActivation
    {
        internal readonly SettingsManager Manager = new();
        internal int Count;
        internal Exception? Error;
        public IAppInstallManagerAdapter Activate()
        {
            Count++;
            if (Error is not null) throw Error;
            Check(Count == 1, "Activation must not be repeated");
            return Manager;
        }
    }

    private sealed class SettingsManager : IAppInstallManagerAdapter, IAppInstallSettingsAdapter
    {
        internal bool AllowIdentity;
        internal string? IdentityValue = Identity;
        internal int AutoUpdateCode;
        internal bool AllUsers;
        internal int DisposeCount;
        internal readonly List<AppInstallSettingsProperty> Reads = [];
        internal readonly Dictionary<AppInstallSettingsProperty, Exception> Errors = [];
        public string AcquisitionIdentity
        {
            get
            {
                Check(AllowIdentity, "Unrequested sensitive getter must not be invoked");
                return Read(AppInstallSettingsProperty.AcquisitionIdentity, IdentityValue!);
            }
        }
        public int AutoUpdateSetting => Read(AppInstallSettingsProperty.AutoUpdateSetting, AutoUpdateCode);
        public bool CanInstallForAllUsers => Read(AppInstallSettingsProperty.CanInstallForAllUsers, AllUsers);
        private T Read<T>(AppInstallSettingsProperty property, T value)
        {
            Check(DisposeCount == 0, "Disposed adapter must not be invoked");
            Reads.Add(property);
            if (Errors.TryGetValue(property, out var error)) throw error;
            return value;
        }
        public void Dispose() => DisposeCount++;
    }
}
