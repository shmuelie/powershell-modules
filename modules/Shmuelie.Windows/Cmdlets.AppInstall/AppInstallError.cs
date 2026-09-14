using System.Management.Automation;
using System.Runtime.InteropServices;
using System.Text.Json.Serialization;

namespace Shmuelie.Windows.AppInstall;

public enum AppInstallErrorPhase { Availability, Activation, Invocation, AsyncStatus, AsyncResult, LocalWait, Cleanup }
public enum AppInstallErrorKind { NativeFailure, AccessDenied, PlatformUnavailable, MemberUnavailable, ContextUnavailable, NativeCancellation, LocalWaitCancellation, UnclassifiedFailure }

/// <summary>Immutable failure metadata; the original exception reference is retained only in-process.</summary>
public sealed record AppInstallError
{
    [JsonConstructor]
    public AppInstallError(string sourceOperation, AppInstallErrorPhase phase, AppInstallErrorKind kind,
        int hResult, string message, string exceptionType, IReadOnlyList<AppInstallError> cleanupErrors)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sourceOperation);
        ArgumentNullException.ThrowIfNull(message);
        ArgumentException.ThrowIfNullOrWhiteSpace(exceptionType);
        AppInstallModelGuard.Defined(phase);
        AppInstallModelGuard.Defined(kind);
        SourceOperation = sourceOperation;
        Phase = phase;
        Kind = kind;
        HResult = hResult;
        Message = message;
        ExceptionType = exceptionType;
        CleanupErrors = AppInstallModelGuard.Copy(cleanupErrors);
    }

    public string SourceOperation { get; }
    public AppInstallErrorPhase Phase { get; }
    public AppInstallErrorKind Kind { get; }
    public int HResult { get; }
    public string Message { get; }
    public string ExceptionType { get; }
    public IReadOnlyList<AppInstallError> CleanupErrors { get; }
    [JsonIgnore]
    public Exception? Exception { get; }

    private AppInstallError(string sourceOperation, AppInstallErrorPhase phase, AppInstallErrorKind kind,
        Exception exception, IReadOnlyList<AppInstallError> cleanupErrors)
        : this(sourceOperation, phase, kind, exception.HResult, exception.Message,
            exception.GetType().FullName ?? exception.GetType().Name, cleanupErrors)
    {
        Exception = exception;
    }

    private AppInstallError(AppInstallError primary, IReadOnlyList<AppInstallError> cleanupErrors)
        : this(primary.SourceOperation, primary.Phase, primary.Kind, primary.HResult, primary.Message,
            primary.ExceptionType, cleanupErrors)
    {
        Exception = primary.Exception ??
            throw new InvalidOperationException("Detached error metadata cannot be used as a live native exception.");
    }

    internal static bool IsOperational(Exception error) => error is
        COMException or UnauthorizedAccessException or OperationCanceledException or
        NotSupportedException or NotImplementedException or MissingMemberException or
        InvalidOperationException or ArgumentException or IOException or TimeoutException;

    internal static AppInstallError Capture(string operation, AppInstallErrorPhase phase, Exception error,
        bool nativeCanceled = false) => new(operation, phase,
        phase == AppInstallErrorPhase.LocalWait && error is OperationCanceledException
            ? AppInstallErrorKind.LocalWaitCancellation
            : nativeCanceled ? AppInstallErrorKind.NativeCancellation
            : error switch
            {
                PlatformNotSupportedException => AppInstallErrorKind.PlatformUnavailable,
                MissingMemberException => AppInstallErrorKind.MemberUnavailable,
                UnauthorizedAccessException => AppInstallErrorKind.AccessDenied,
                COMException { HResult: unchecked((int)0x80070005) } => AppInstallErrorKind.AccessDenied,
                ObjectDisposedException => AppInstallErrorKind.ContextUnavailable,
                _ => IsOperational(error) ? AppInstallErrorKind.NativeFailure : AppInstallErrorKind.UnclassifiedFailure
            }, error, []);

    internal AppInstallError WithCleanup(AppInstallError cleanup) => new(this, [.. CleanupErrors, cleanup]);

    internal ErrorRecord ToErrorRecord() => new(
        Exception ?? throw new InvalidOperationException("Detached error metadata cannot be used as a live native exception."),
        $"AppInstall{Kind}", Kind switch
        {
            AppInstallErrorKind.AccessDenied => ErrorCategory.PermissionDenied,
            AppInstallErrorKind.PlatformUnavailable or AppInstallErrorKind.MemberUnavailable => ErrorCategory.NotImplemented,
            AppInstallErrorKind.LocalWaitCancellation or AppInstallErrorKind.NativeCancellation => ErrorCategory.OperationStopped,
            AppInstallErrorKind.ContextUnavailable => ErrorCategory.InvalidOperation,
            _ => ErrorCategory.NotSpecified
        }, this);
}

internal sealed class AppInstallOperationException : Exception
{
    internal AppInstallOperationException(AppInstallError error) : base(error.Message, error.Exception)
    {
        Error = error;
        HResult = error.HResult;
    }
    internal AppInstallError Error { get; }
}

internal sealed class AppInstallCleanupException : AggregateException
{
    internal AppInstallCleanupException(string sourceOperation, AppInstallErrorPhase primaryPhase,
        Exception primary, Exception cleanup)
        : base("An AppInstall operation and its cleanup both failed.", primary, cleanup)
    {
        SourceOperation = sourceOperation;
        PrimaryPhase = primaryPhase;
        HResult = primary.HResult;
    }

    public string SourceOperation { get; }
    public AppInstallErrorPhase PrimaryPhase { get; }
    public AppInstallErrorPhase CleanupPhase => AppInstallErrorPhase.Cleanup;
    public Exception PrimaryException => InnerExceptions[0];
    public Exception CleanupException => InnerExceptions[1];
}
