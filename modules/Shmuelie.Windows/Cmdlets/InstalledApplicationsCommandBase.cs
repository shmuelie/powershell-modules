using System.Management.Automation;
using System.Runtime.InteropServices;

namespace Shmuelie.Windows.Cmdlets;

/// <summary>
/// Shared base for the installed-application inventory cmdlet. Provides the
/// Windows-only platform guard and a reliable <c>-WhatIf</c> detection helper.
/// The base is intentionally independent of the <c>subst</c> cmdlet base so the
/// two features do not share mutable surface.
/// </summary>
public abstract class InstalledApplicationsCommandBase : PSCmdlet
{
    /// <summary>
    /// Throws a terminating error when the current platform is not Windows.
    /// The assembly still loads on any operating system; only invoking the
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
    /// Determines whether the invocation is running under <c>-WhatIf</c> (either
    /// the bound common parameter or an inherited <c>$WhatIfPreference</c>).
    /// </summary>
    protected bool IsWhatIf()
    {
        if (MyInvocation.BoundParameters.TryGetValue("WhatIf", out object? bound))
        {
            return bound switch
            {
                SwitchParameter sp => sp.ToBool(),
                bool b => b,
                _ => false,
            };
        }

        object? preference = GetVariableValue("WhatIfPreference");
        return preference switch
        {
            bool b => b,
            SwitchParameter sp => sp.ToBool(),
            _ => false,
        };
    }
}
