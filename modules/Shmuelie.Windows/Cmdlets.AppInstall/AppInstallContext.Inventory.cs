namespace Shmuelie.Windows.AppInstall;

public sealed partial class AppInstallContext
{
    internal bool IsInventoryMemberAvailable(AppInstallMember member)
    {
        lock (sync)
        {
            EnsureUsable();
            return availability.IsTypePresent(member.TypeName) && availability.IsMemberPresent(member);
        }
    }
}
