using Windows.Foundation.Metadata;

namespace Shmuelie.Windows.AppInstall;

internal enum AppInstallMemberKind { PropertyGet, Method, Event, PropertySet }

internal sealed record AppInstallMember(
    string TypeName, string Name, AppInstallMemberKind Kind, uint ParameterCount = 0)
{
    internal const string ManagerType = "Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallManager";
}

internal interface IAppInstallAvailability
{
    bool IsSupportedPlatform { get; }
    bool IsTypePresent(string typeName);
    bool IsMemberPresent(AppInstallMember member);
}

internal sealed class AppInstallAvailability : IAppInstallAvailability
{
    public bool IsSupportedPlatform => OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041);

    public bool IsTypePresent(string typeName) => ApiInformation.IsTypePresent(typeName);

    public bool IsMemberPresent(AppInstallMember member) => member.Kind switch
    {
        AppInstallMemberKind.PropertyGet => ApiInformation.IsPropertyPresent(member.TypeName, member.Name),
        AppInstallMemberKind.PropertySet => ApiInformation.IsWriteablePropertyPresent(member.TypeName, member.Name),
        AppInstallMemberKind.Method => ApiInformation.IsMethodPresent(member.TypeName, member.Name, member.ParameterCount),
        AppInstallMemberKind.Event => ApiInformation.IsEventPresent(member.TypeName, member.Name),
        _ => throw new ArgumentOutOfRangeException(nameof(member))
    };
}
