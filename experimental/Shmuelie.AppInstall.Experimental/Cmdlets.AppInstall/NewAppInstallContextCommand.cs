using System.Management.Automation;
using System.Management.Automation.Runspaces;

namespace Shmuelie.Windows.AppInstall;

/// <summary>Creates a caller-owned, lazy AppInstallManager context without native activation.</summary>
[Cmdlet(VerbsCommon.New, "AppInstallContext", SupportsShouldProcess = true)]
[OutputType(typeof(AppInstallContext))]
public sealed class NewAppInstallContextCommand : PSCmdlet
{
    private readonly IAppInstallAvailability availability;
    private readonly IAppInstallActivation activation;

    public NewAppInstallContextCommand() : this(new AppInstallAvailability(), new AppInstallActivation()) { }

    internal NewAppInstallContextCommand(IAppInstallAvailability availability, IAppInstallActivation activation)
    {
        this.availability = availability;
        this.activation = activation;
    }

    protected override void ProcessRecord()
    {
        if (!availability.IsSupportedPlatform)
        {
            ThrowTerminatingError(AppInstallError.Capture("New-AppInstallContext", AppInstallErrorPhase.Availability,
                new PlatformNotSupportedException("New-AppInstallContext requires Windows 10 build 19041 or later."),
                nativeCanceled: false).ToErrorRecord());
        }

        if (!ShouldProcess("Current runspace", "Create a lazy AppInstall context (no native activation)"))
            return;

        var owner = Runspace.DefaultRunspace ??
            throw new InvalidOperationException("New-AppInstallContext requires an owning PowerShell runspace.");
        var context = new AppInstallContext(owner, availability, activation);
        bool delivered = false;
        try
        {
            WriteObject(context);
            delivered = true;
        }
        finally
        {
            if (!delivered) context.Dispose();
        }
    }
}
