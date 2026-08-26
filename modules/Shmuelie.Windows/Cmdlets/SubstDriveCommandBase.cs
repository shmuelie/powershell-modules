using System.Management.Automation;
using System.Runtime.InteropServices;

namespace Shmuelie.Windows.Cmdlets;

/// <summary>
/// Shared base for the <c>subst</c> drive cmdlets. Provides the Windows-only
/// platform guard and drive-letter normalization used by every subst command.
/// </summary>
public abstract class SubstDriveCommandBase : PSCmdlet
{
    /// <summary>
    /// Throws a terminating error when the current platform is not Windows.
    /// The assembly still loads on any operating system; only invoking a subst
    /// cmdlet off Windows fails.
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
    /// Normalizes a caller-supplied drive letter, converting an invalid value
    /// into a terminating validation error.
    /// </summary>
    /// <param name="driveLetter">A single letter A-Z, optionally with a colon.</param>
    /// <returns>The normalized drive letter, for example <c>S:</c>.</returns>
    protected string NormalizeDriveLetterOrThrow(string driveLetter)
    {
        try
        {
            return SubstDriveService.NormalizeDriveLetter(driveLetter);
        }
        catch (ArgumentException ex)
        {
            ThrowTerminatingError(new ErrorRecord(
                ex,
                "InvalidDriveLetter",
                ErrorCategory.InvalidArgument,
                driveLetter));
            throw; // unreachable: ThrowTerminatingError does not return.
        }
    }
}
