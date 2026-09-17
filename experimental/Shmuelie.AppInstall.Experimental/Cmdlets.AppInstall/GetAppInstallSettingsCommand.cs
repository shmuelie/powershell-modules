using System.Management.Automation;

namespace Shmuelie.Windows.AppInstall;

/// <summary>Reads explicitly selected settings from a caller-owned context; acquisition identity is opt-in.</summary>
[Cmdlet(VerbsCommon.Get, "AppInstallSettings")]
[OutputType(typeof(AppInstallSettingsSnapshot))]
public sealed class GetAppInstallSettingsCommand : PSCmdlet
{
    [Parameter(Mandatory = true, ValueFromPipeline = true)]
    [ValidateNotNull]
    public AppInstallContext Context { get; set; } = null!;

    [Parameter]
    [ValidateNotNullOrEmpty]
    [ValidateSet("AcquisitionIdentity", "AutoUpdateSetting", "CanInstallForAllUsers")]
    public string[] Property { get; set; } =
        [nameof(AppInstallSettingsProperty.AutoUpdateSetting), nameof(AppInstallSettingsProperty.CanInstallForAllUsers)];

    protected override void ProcessRecord()
    {
        AppInstallSettingsSnapshot snapshot;
        try
        {
            var selected = Property.Select(name => Enum.Parse<AppInstallSettingsProperty>(name, ignoreCase: true)).ToArray();
            snapshot = AppInstallSettingsReader.Read(Context, selected);
        }
        catch (AppInstallOperationException failure)
        {
            var record = failure.Error.ToErrorRecord();
            // Native messages may contain identity data. Preserve diagnostics in
            // the ErrorRecord, but do not render their raw text by default.
            record.ErrorDetails = new ErrorDetails(
                $"{failure.Error.SourceOperation} failed during {failure.Error.Phase} " +
                $"(HRESULT 0x{unchecked((uint)failure.Error.HResult):X8}). Original diagnostics are retained in the error record.");
            ThrowTerminatingError(record);
            return;
        }
        WriteObject(snapshot);
    }
}
