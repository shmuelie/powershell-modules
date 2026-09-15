using Windows.ApplicationModel.Store.Preview.InstallControl;

namespace Shmuelie.Windows.AppInstall;

internal interface IAppInstallManagerAdapter : IDisposable
{
}

internal interface IAppInstallActivation
{
    IAppInstallManagerAdapter Activate();
}

internal sealed class AppInstallActivation : IAppInstallActivation
{
    public IAppInstallManagerAdapter Activate() => new AppInstallManagerAdapter(new AppInstallManager());
}

internal sealed partial class AppInstallManagerAdapter(AppInstallManager manager) : IAppInstallManagerAdapter
{
    private AppInstallManager? manager = manager;

    // Future caller-scoped adapters extend this class; the native object never
    // escapes through a public context property or PowerShell pipeline result.
    internal AppInstallManager Manager => manager ?? throw new ObjectDisposedException(nameof(AppInstallManagerAdapter));

    public void Dispose()
    {
        // AppInstallManager is not IClosable. Drop our projection reference;
        // do not force-release COM objects shared by the WinRT projection.
        manager = null;
    }
}
