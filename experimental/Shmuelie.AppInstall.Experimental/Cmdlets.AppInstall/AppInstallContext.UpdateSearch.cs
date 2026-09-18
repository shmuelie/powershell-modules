namespace Shmuelie.Windows.AppInstall;

public sealed partial class AppInstallContext
{
    internal void ValidateUpdateSearchContext()
    {
        lock (sync) EnsureUsable();
    }

    internal void RequireUpdateSearchMember(AppInstallMember member)
    {
        lock (sync)
        {
            EnsureUsable();
            if (!availability.IsTypePresent(AppInstallMember.ManagerType) ||
                !availability.IsTypePresent(member.TypeName) || !availability.IsMemberPresent(member))
                throw new MissingMemberException(member.TypeName, member.Name);
        }
    }

    internal void RequireUpdateSearchType(string typeName)
    {
        lock (sync)
        {
            EnsureUsable();
            if (!availability.IsTypePresent(typeName)) throw new TypeLoadException($"The required WinRT type '{typeName}' is unavailable.");
        }
    }
}
