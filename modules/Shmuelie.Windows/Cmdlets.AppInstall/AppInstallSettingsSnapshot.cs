using System.Text.Json.Serialization;

namespace Shmuelie.Windows.AppInstall;

public enum AppInstallSettingsProperty { AcquisitionIdentity, AutoUpdateSetting, CanInstallForAllUsers }
public enum AppInstallSettingScope { ManagerContext, Device, CallingProcess }

/// <summary>Detached, read-only observations from one explicit caller context, not an authorization grant.</summary>
public sealed record AppInstallSettingsSnapshot
{
    public AppInstallSettingsSnapshot(Guid contextId, IReadOnlyList<AppInstallSettingsProperty> requestedProperties,
        AppInstallValueAvailability acquisitionIdentityAvailability, string? acquisitionIdentity,
        AppInstallValue<int> autoUpdateSetting, AppInstallValue<bool> canInstallForAllUsers)
    {
        ArgumentNullException.ThrowIfNull(requestedProperties);
        ArgumentNullException.ThrowIfNull(autoUpdateSetting);
        ArgumentNullException.ThrowIfNull(canInstallForAllUsers);
        var requested = requestedProperties.ToArray();
        if (requested.Length == 0 || requested.Distinct().Count() != requested.Length)
            throw new ArgumentException("Select at least one property, without duplicates.", nameof(requestedProperties));
        foreach (var property in requested) AppInstallModelGuard.Defined(property);
        AppInstallModelGuard.Defined(acquisitionIdentityAvailability);
        if ((acquisitionIdentityAvailability == AppInstallValueAvailability.Available) != (acquisitionIdentity is not null))
            throw new ArgumentException("Only an available identity observation must contain a value.", nameof(acquisitionIdentity));

        CheckSelection(AppInstallSettingsProperty.AcquisitionIdentity, acquisitionIdentityAvailability);
        CheckSelection(AppInstallSettingsProperty.AutoUpdateSetting, autoUpdateSetting.Availability);
        CheckSelection(AppInstallSettingsProperty.CanInstallForAllUsers, canInstallForAllUsers.Availability);
        ContextId = AppInstallModelGuard.Id(contextId);
        RequestedProperties = Array.AsReadOnly(requested);
        AcquisitionIdentityAvailability = acquisitionIdentityAvailability;
        AcquisitionIdentity = acquisitionIdentity;
        AutoUpdateSetting = autoUpdateSetting;
        CanInstallForAllUsers = canInstallForAllUsers;
        ReadProperties = Array.AsReadOnly(requested.Where(property => property switch
        {
            AppInstallSettingsProperty.AcquisitionIdentity => acquisitionIdentityAvailability == AppInstallValueAvailability.Available,
            AppInstallSettingsProperty.AutoUpdateSetting => autoUpdateSetting.Availability == AppInstallValueAvailability.Available,
            AppInstallSettingsProperty.CanInstallForAllUsers => canInstallForAllUsers.Availability == AppInstallValueAvailability.Available,
            _ => false
        }).ToArray());

        void CheckSelection(AppInstallSettingsProperty property, AppInstallValueAvailability availability)
        {
            if (requested.Contains(property) == (availability == AppInstallValueAvailability.Unknown))
                throw new ArgumentException("Selected properties must be observed or unavailable; unselected properties must remain unknown.",
                    nameof(requestedProperties));
        }
    }

    public Guid ContextId { get; }
    public AppInstallUserScope UserScope => AppInstallUserScope.Caller;
    public IReadOnlyList<AppInstallSettingsProperty> RequestedProperties { get; }
    public IReadOnlyList<AppInstallSettingsProperty> ReadProperties { get; }
    public AppInstallSettingScope AcquisitionIdentityScope => AppInstallSettingScope.ManagerContext;
    public AppInstallValueAvailability AcquisitionIdentityAvailability { get; }
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? AcquisitionIdentity { get; }
    public AppInstallSettingScope AutoUpdateSettingScope => AppInstallSettingScope.Device;
    public AppInstallValue<int> AutoUpdateSetting { get; }
    public AppInstallSettingScope CanInstallForAllUsersScope => AppInstallSettingScope.CallingProcess;
    public AppInstallValue<bool> CanInstallForAllUsers { get; }
}
