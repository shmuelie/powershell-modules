using System.Management.Automation;

namespace Shmuelie.Windows.AppInstall;

/// <summary>Passively observes exactly one retained caller item using manager-event invalidation.</summary>
[Cmdlet(VerbsLifecycle.Wait, "AppInstallItem")]
[OutputType(typeof(AppInstallMonitorResult))]
public sealed class WaitAppInstallItemCommand : PSCmdlet
{
    private readonly object stopSync = new();
    private CancellationTokenSource? activeWait;
    private bool stopRequested;

    [Parameter(Mandatory = true)]
    [ValidateNotNull]
    public AppInstallContext Context { get; set; } = null!;

    [Parameter(Mandatory = true)]
    public Guid LocalItemId { get; set; }

    [Parameter(Mandatory = true)]
    [ValidateRange(1, 30)]
    public int TimeoutSeconds { get; set; }

    protected override void ProcessRecord()
    {
        using var wait = new CancellationTokenSource();
        lock (stopSync)
        {
            activeWait = wait;
            if (stopRequested) wait.Cancel();
        }
        try
        {
            var result = AppInstallMonitor.Wait(Context, LocalItemId, TimeSpan.FromSeconds(TimeoutSeconds), wait.Token);
            if (Stopping || wait.IsCancellationRequested) throw new PipelineStoppedException();
            WriteObject(result);
        }
        catch (AppInstallOperationException failure)
        {
            var record = failure.Error.ToErrorRecord();
            record.ErrorDetails = new ErrorDetails(
                $"Observation failed during {failure.Error.Phase} (HRESULT 0x{unchecked((uint)failure.Error.HResult):X8}). " +
                "The error target retains original diagnostics and cleanup failures. Installation was not canceled.");
            ThrowTerminatingError(record);
        }
        finally { lock (stopSync) activeWait = null; }
    }

    protected override void StopProcessing()
    {
        lock (stopSync)
        {
            stopRequested = true;
            activeWait?.Cancel();
        }
    }
}
