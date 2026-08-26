using System.Management.Automation;
using System.Runtime.InteropServices;

namespace Shmuelie.Windows.Cmdlets;

/// <summary>
/// Shared base for the App Installer cmdlets. Provides the Windows-only platform
/// guard and a reliable <c>-WhatIf</c> detection helper. Although the assembly
/// only loads on Windows (its WinRT target framework cannot load elsewhere), the
/// guard is retained as defense in depth in case the DLL is force-loaded on an
/// unsupported host.
/// </summary>
public abstract class AppInstallerCommandBase : PSCmdlet
{
    /// <summary>
    /// Throws a terminating error when the current platform is not Windows.
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
    /// Wraps an <see cref="AppInstallerApplication"/> in a <see cref="PSObject"/>
    /// carrying the <c>Shmuelie.Windows.AppInstallerApplication</c> type name so
    /// the emitted object matches the previous script-based cmdlet.
    /// </summary>
    protected static PSObject AsTypedObject(AppInstallerApplication app)
    {
        PSObject pso = PSObject.AsPSObject(app);
        pso.TypeNames.Insert(0, AppInstallerHelpers.TypeName);
        return pso;
    }
}
