namespace Shmuelie.Windows.AppInstall;

internal static class AppInstallSettingsReader
{
    internal static AppInstallSettingsSnapshot Read(AppInstallContext context,
        IReadOnlyList<AppInstallSettingsProperty> properties)
    {
        ArgumentNullException.ThrowIfNull(context);
        ArgumentNullException.ThrowIfNull(properties);
        if (properties.Count == 0) throw new ArgumentException("Select at least one property.", nameof(properties));
        var requested = properties.Distinct().ToArray();
        foreach (var property in requested) AppInstallModelGuard.Defined(property);
        var identityAvailability = AppInstallValueAvailability.Unknown;
        string? identity = null;
        var autoUpdate = AppInstallValue<int>.Unknown;
        var allUsers = AppInstallValue<bool>.Unknown;

        foreach (var property in requested)
        {
            var member = new AppInstallMember(AppInstallMember.ManagerType, property.ToString(), AppInstallMemberKind.PropertyGet);
            var phase = AppInstallErrorPhase.Availability;
            try
            {
                switch (property)
                {
                    case AppInstallSettingsProperty.AcquisitionIdentity:
                        identity = context.Use(member, manager => Settings(manager).AcquisitionIdentity ??
                            throw new InvalidOperationException("The acquisition identity getter returned null."), out phase);
                        identityAvailability = AppInstallValueAvailability.Available;
                        break;
                    case AppInstallSettingsProperty.AutoUpdateSetting:
                        autoUpdate = context.Use(member, manager => AppInstallValue<int>.From(Settings(manager).AutoUpdateSetting), out phase);
                        break;
                    case AppInstallSettingsProperty.CanInstallForAllUsers:
                        allUsers = context.Use(member, manager => AppInstallValue<bool>.From(Settings(manager).CanInstallForAllUsers), out phase);
                        break;
                }
            }
            catch (MissingMemberException) when (phase == AppInstallErrorPhase.Availability)
            {
                switch (property)
                {
                    case AppInstallSettingsProperty.AcquisitionIdentity:
                        identityAvailability = AppInstallValueAvailability.Unavailable;
                        break;
                    case AppInstallSettingsProperty.AutoUpdateSetting:
                        autoUpdate = AppInstallValue<int>.Unavailable;
                        break;
                    case AppInstallSettingsProperty.CanInstallForAllUsers:
                        allUsers = AppInstallValue<bool>.Unavailable;
                        break;
                }
            }
            // E_NOINTERFACE/E_POINTER can use these mapped exception types.
            // Preserve them without claiming that an arbitrary managed bug is native.
            catch (Exception error) when (AppInstallError.IsOperational(error) ||
                error is InvalidCastException or NullReferenceException)
            {
                throw new AppInstallOperationException(AppInstallError.Capture(
                    $"AppInstallManager.{property}", phase, error));
            }
        }

        return new AppInstallSettingsSnapshot(context.ContextId, requested, identityAvailability, identity, autoUpdate, allUsers);
    }

    private static IAppInstallSettingsAdapter Settings(IAppInstallManagerAdapter manager) =>
        manager as IAppInstallSettingsAdapter ??
        throw new InvalidOperationException("The context manager does not implement the settings-read adapter.");
}
