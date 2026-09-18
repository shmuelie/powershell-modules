namespace Shmuelie.Windows.AppInstall;

public enum AppInstallValueAvailability { Unknown, Available, Unavailable }
public enum AppInstallTerminalState { Unknown, NotTerminal, Succeeded, Failed, Canceled }
public enum AppInstallRequestAcceptance { Unknown, NotSubmitted, Accepted, Rejected }
public enum AppInstallOperationState { Unknown, Started, Completed, Failed, Canceled }
public enum AppInstallWaitState { NotWaiting, Waiting, Completed, StoppedLocally }
public enum AppInstallEntitlementScope { Unknown, Caller, Device }

/// <summary>A measured scalar, distinct from an unobserved or unavailable member.</summary>
public sealed record AppInstallValue<T> where T : struct
{
    public AppInstallValue(AppInstallValueAvailability availability, T? value)
    {
        AppInstallModelGuard.Defined(availability);
        if ((availability == AppInstallValueAvailability.Available) != value.HasValue)
            throw new ArgumentException("Only an available observation must contain a value.", nameof(value));
        Availability = availability;
        Value = value;
    }

    public AppInstallValueAvailability Availability { get; }
    public T? Value { get; }
    public static AppInstallValue<T> Unknown { get; } = new(AppInstallValueAvailability.Unknown, null);
    public static AppInstallValue<T> Unavailable { get; } = new(AppInstallValueAvailability.Unavailable, null);
    public static AppInstallValue<T> From(T value) => new(AppInstallValueAvailability.Available, value);
}

internal static class AppInstallModelGuard
{
    internal static void Defined<T>(T value) where T : struct, Enum
    {
        if (!Enum.IsDefined(value)) throw new ArgumentOutOfRangeException(nameof(value), value, "Unknown contract enum value.");
    }

    internal static Guid Id(Guid value)
    {
        if (value == Guid.Empty) throw new ArgumentException("A local correlation ID must not be empty.", nameof(value));
        return value;
    }

    internal static IReadOnlyList<T> Copy<T>(IReadOnlyList<T> values) where T : class
    {
        ArgumentNullException.ThrowIfNull(values);
        var copy = values.ToArray();
        if (copy.Any(value => value is null))
            throw new ArgumentException("Snapshot collections cannot contain null entries.", nameof(values));
        return Array.AsReadOnly(copy);
    }
}
