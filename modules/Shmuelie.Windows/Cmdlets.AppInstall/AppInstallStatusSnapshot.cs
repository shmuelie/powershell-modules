namespace Shmuelie.Windows.AppInstall;

/// <summary>A point-in-time observation, not a live native item or an inferred installation result.</summary>
public sealed record AppInstallStatusSnapshot
{
    public AppInstallStatusSnapshot(AppInstallValue<int> nativeInstallState,
        AppInstallValue<ulong> bytesDownloaded, AppInstallValue<ulong> downloadSizeInBytes,
        AppInstallValue<double> percentComplete, AppInstallValue<bool> isStaged,
        AppInstallValue<bool> readyForLaunch, AppInstallTerminalState terminalState,
        AppInstallError? error)
    {
        ArgumentNullException.ThrowIfNull(nativeInstallState);
        ArgumentNullException.ThrowIfNull(bytesDownloaded);
        ArgumentNullException.ThrowIfNull(downloadSizeInBytes);
        ArgumentNullException.ThrowIfNull(percentComplete);
        ArgumentNullException.ThrowIfNull(isStaged);
        ArgumentNullException.ThrowIfNull(readyForLaunch);
        AppInstallModelGuard.Defined(terminalState);
        if (percentComplete.Value is double percent && (!double.IsFinite(percent) || percent is < 0 or > 100))
            throw new ArgumentOutOfRangeException(nameof(percentComplete), "An observed percentage must be finite and between 0 and 100.");
        NativeInstallState = nativeInstallState;
        BytesDownloaded = bytesDownloaded;
        DownloadSizeInBytes = downloadSizeInBytes;
        PercentComplete = percentComplete;
        IsStaged = isStaged;
        ReadyForLaunch = readyForLaunch;
        TerminalState = terminalState;
        Error = error;
    }

    // Retain unknown future native enum codes rather than mapping them to success.
    public AppInstallValue<int> NativeInstallState { get; }
    public AppInstallValue<ulong> BytesDownloaded { get; }
    public AppInstallValue<ulong> DownloadSizeInBytes { get; }
    public AppInstallValue<double> PercentComplete { get; }
    public AppInstallValue<bool> IsStaged { get; }
    public AppInstallValue<bool> ReadyForLaunch { get; }
    public AppInstallTerminalState TerminalState { get; }
    public AppInstallError? Error { get; }
}
