namespace Shmuelie.Windows.AppInstall;

internal interface IAppInstallSettingsAdapter
{
    string AcquisitionIdentity { get; }
    int AutoUpdateSetting { get; }
    bool CanInstallForAllUsers { get; }
}

internal sealed partial class AppInstallManagerAdapter : IAppInstallSettingsAdapter
{
    public string AcquisitionIdentity => Manager.AcquisitionIdentity;
    public int AutoUpdateSetting => (int)Manager.AutoUpdateSetting;
    public bool CanInstallForAllUsers => Manager.CanInstallForAllUsers;
}
