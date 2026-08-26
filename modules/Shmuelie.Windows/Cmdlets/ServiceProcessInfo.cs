using System.Diagnostics;
using System.ServiceProcess;

namespace Shmuelie.Windows.Cmdlets;

/// <summary>
/// Describes a Windows service and the process that hosts it, as emitted by
/// <c>Get-ServiceProcess</c>. The property shape mirrors the previous
/// script-based cmdlet so the existing <c>ServiceProcess</c> format view still
/// applies.
/// </summary>
public sealed class ServiceProcessInfo
{
    /// <summary>
    /// Gets the service name (not the display name).
    /// </summary>
    public string Name { get; init; } = string.Empty;

    /// <summary>
    /// Gets the service display name.
    /// </summary>
    public string DisplayName { get; init; } = string.Empty;

    /// <summary>
    /// Gets the current service status.
    /// </summary>
    public ServiceControllerStatus Status { get; init; }

    /// <summary>
    /// Gets the id of the hosting process, or <c>0</c> when the service is not
    /// running.
    /// </summary>
    public int ProcessId { get; init; }

    /// <summary>
    /// Gets the name of the hosting process, or an empty string when the
    /// service is not running.
    /// </summary>
    public string ProcessName { get; init; } = string.Empty;

    /// <summary>
    /// Gets the underlying hosting process, or <see langword="null"/> when the
    /// service is not running.
    /// </summary>
    public Process? Process { get; init; }

    /// <summary>
    /// Gets the service binary command line. For a shared-host service this is
    /// the full <c>svchost.exe -k &lt;group&gt;</c> command line.
    /// </summary>
    public string CommandLine { get; init; } = string.Empty;
}
