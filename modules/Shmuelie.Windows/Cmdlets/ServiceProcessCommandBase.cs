using System.Management.Automation;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Security.Principal;

namespace Shmuelie.Windows.Cmdlets;

/// <summary>
/// Shared base for the service-process cmdlets. Provides the Windows-only
/// platform guard and an elevation check. Kept separate from the subst base so
/// the two command families evolve independently.
/// </summary>
public abstract class ServiceProcessCommandBase : PSCmdlet
{
    /// <summary>
    /// Throws a terminating error when the current platform is not Windows.
    /// The assembly still loads on any operating system; only invoking a
    /// service-process cmdlet off Windows fails.
    /// </summary>
    protected void EnsureWindows()
    {
        if (!RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
        {
            ThrowTerminatingError(new ErrorRecord(
                new PlatformNotSupportedException($"{MyInvocation.MyCommand.Name} is only supported on Windows."),
                "WindowsOnly",
                ErrorCategory.NotImplemented,
                targetObject: null));
        }
    }

    /// <summary>
    /// Determines whether the current session is running elevated (as a member
    /// of the built-in Administrators role).
    /// </summary>
    [SupportedOSPlatform("windows")]
    protected static bool IsElevated()
    {
        using WindowsIdentity identity = WindowsIdentity.GetCurrent();
        return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
    }
}
