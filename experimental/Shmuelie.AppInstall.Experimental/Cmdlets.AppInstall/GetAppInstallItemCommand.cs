using System.Management.Automation;

namespace Shmuelie.Windows.AppInstall;

/// <summary>Reads caller-scoped queue snapshots through an explicitly owned AppInstall context.</summary>
[Cmdlet(VerbsCommon.Get, "AppInstallItem")]
[OutputType(typeof(AppInstallItemSnapshot))]
public sealed class GetAppInstallItemCommand : PSCmdlet
{
    [Parameter(Mandatory = true, Position = 0, ValueFromPipeline = true)]
    [ValidateNotNull]
    public AppInstallContext Context { get; set; } = null!;

    [Parameter]
    [ValidateNotNullOrEmpty]
    public string[]? ProductId { get; set; }

    [Parameter]
    [ValidateNotNullOrEmpty]
    public string[]? PackageFamilyName { get; set; }

    [Parameter]
    public SwitchParameter IncludeChildren { get; set; }

    protected override void ProcessRecord()
    {
        ValidateFilter(ProductId, nameof(ProductId));
        ValidateFilter(PackageFamilyName, nameof(PackageFamilyName));
        IReadOnlyList<AppInstallItemSnapshot> items;
        try
        {
            items = new AppInstallInventoryReader(Context, EnsureRunning)
                .Read(IncludeChildren.IsPresent, ProductId, PackageFamilyName);
        }
        catch (AppInstallOperationException error)
        {
            ThrowTerminatingError(error.Error.ToErrorRecord());
            return;
        }
        catch (InvalidDataException error)
        {
            ThrowTerminatingError(new ErrorRecord(error, "AppInstallInventoryInvalidData",
                ErrorCategory.InvalidData, null));
            return;
        }
        foreach (var item in items)
        {
            EnsureRunning();
            WriteObject(item);
        }
    }

    private static void ValidateFilter(string[]? values, string parameter)
    {
        if (values is not null && (values.Length == 0 || values.Any(string.IsNullOrWhiteSpace)))
            throw new ArgumentException("Identity filters require nonempty, non-whitespace literal values.", parameter);
    }

    private void EnsureRunning()
    {
        if (Stopping) throw new PipelineStoppedException();
    }
}
