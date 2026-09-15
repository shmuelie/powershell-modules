using System.Management.Automation;

namespace Shmuelie.Windows.AppInstall;

/// <summary>Requests a caller-scoped all-app search that can queue updates in a paused state.</summary>
[Cmdlet(VerbsLifecycle.Request, "AppInstallUpdateSearch", SupportsShouldProcess = true, ConfirmImpact = ConfirmImpact.High)]
[OutputType(typeof(AppInstallRequestSnapshot))]
public sealed class RequestAppInstallUpdateSearchCommand : PSCmdlet
{
    private readonly object stopSync = new();
    private CancellationTokenSource? activeWait;
    private bool stopRequested;

    [Parameter(Mandatory = true, ValueFromPipeline = true)]
    [ValidateNotNull]
    public AppInstallContext Context { get; set; } = null!;

    [Parameter(Mandatory = true)]
    [ValidateNotNullOrWhiteSpace]
    public string CorrelationVector { get; set; } = null!;

    [Parameter(Mandatory = true)]
    [ValidateNotNullOrWhiteSpace]
    public string ClientId { get; set; } = null!;

    protected override void ProcessRecord()
    {
        if (!ShouldProcess($"All apps in caller scope (context {Context.ContextId})",
            "Search for updates and add discovered updates to the queue paused; automatic download/install=false, forced restart=false"))
            return;

        using var wait = new CancellationTokenSource();
        lock (stopSync)
        {
            activeWait = wait;
            if (stopRequested) wait.Cancel();
        }
        try
        {
            var request = AppInstallUpdateSearch.Execute(Context, CorrelationVector, ClientId, wait.Token);
            if (Stopping || wait.IsCancellationRequested) throw new PipelineStoppedException();
            WriteObject(request);
        }
        catch (AppInstallUpdateSearchException failure)
        {
            var record = failure.ToErrorRecord();
            var error = failure.Request.Error!;
            record.ErrorDetails = new ErrorDetails(
                $"{error.SourceOperation} failed during {error.Phase} " +
                $"(HRESULT 0x{unchecked((uint)error.HResult):X8}). " +
                "The error target retains the request outcome and original diagnostics; queued work was not canceled or rolled back.");
            ThrowTerminatingError(record);
        }
        finally
        {
            lock (stopSync) activeWait = null;
        }
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
