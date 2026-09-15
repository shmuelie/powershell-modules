namespace Shmuelie.Windows.AppInstall;

[Flags]
public enum AppInstallObservationReason { None = 0, Initial = 1, ManagerStatusInvalidated = 2, ManagerCompletionInvalidated = 4 }
public enum AppInstallObservationOutcome { TimedOut, TargetTerminal }
public enum AppInstallGroupObservation { NotEvaluated }

/// <summary>A locally ordered read, not an identity-bearing native event.</summary>
public sealed record AppInstallObservation
{
    public AppInstallObservation(int sequence, TimeSpan elapsed, AppInstallObservationReason reason,
        AppInstallItemSnapshot snapshot)
    {
        if (sequence is < 1 or > 64) throw new ArgumentOutOfRangeException(nameof(sequence));
        if (elapsed < TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(elapsed));
        if ((reason & ~(AppInstallObservationReason.Initial | AppInstallObservationReason.ManagerStatusInvalidated |
            AppInstallObservationReason.ManagerCompletionInvalidated)) != 0) throw new ArgumentOutOfRangeException(nameof(reason));
        ArgumentNullException.ThrowIfNull(snapshot);
        Sequence = sequence;
        Elapsed = elapsed;
        Reason = reason;
        Snapshot = snapshot;
    }
    public int Sequence { get; }
    public TimeSpan Elapsed { get; }
    public AppInstallObservationReason Reason { get; }
    public AppInstallItemSnapshot Snapshot { get; }
}

/// <summary>Returned only after all observation-owned resources have been released successfully.</summary>
public sealed record AppInstallMonitorResult
{
    public AppInstallMonitorResult(Guid contextId, Guid localItemId, AppInstallObservationOutcome outcome,
        IReadOnlyList<AppInstallObservation> observations)
    {
        ContextId = AppInstallModelGuard.Id(contextId);
        LocalItemId = AppInstallModelGuard.Id(localItemId);
        AppInstallModelGuard.Defined(outcome);
        Observations = AppInstallModelGuard.Copy(observations);
        if (Observations.Count > 64 || Observations.Where((value, index) =>
            value.Sequence != index + 1 || value.Snapshot.Identity.ContextId != contextId ||
            value.Snapshot.Identity.LocalItemId != localItemId ||
            value.Snapshot.Identity.UserScope != AppInstallUserScope.Caller).Any())
            throw new ArgumentException("Observations must be bounded, ordered and belong to the exact caller item.", nameof(observations));
        if (outcome == AppInstallObservationOutcome.TargetTerminal &&
            (Observations.Count == 0 || Observations[^1].Snapshot.Status.TerminalState is not
                (AppInstallTerminalState.Succeeded or AppInstallTerminalState.Failed or AppInstallTerminalState.Canceled)))
            throw new ArgumentException("TargetTerminal requires an observed terminal status.", nameof(outcome));
        Outcome = outcome;
    }
    public Guid ContextId { get; }
    public Guid LocalItemId { get; }
    public AppInstallUserScope UserScope => AppInstallUserScope.Caller;
    public AppInstallObservationOutcome Outcome { get; }
    public AppInstallGroupObservation GroupOutcome => AppInstallGroupObservation.NotEvaluated;
    public IReadOnlyList<AppInstallObservation> Observations { get; }
}
