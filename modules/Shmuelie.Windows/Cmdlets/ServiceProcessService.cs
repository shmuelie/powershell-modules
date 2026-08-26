using System.ComponentModel;
using System.Runtime.InteropServices;
using static Shmuelie.Windows.Cmdlets.ServiceProcessNativeMethods;

namespace Shmuelie.Windows.Cmdlets;

/// <summary>
/// Wraps the Win32 Service Control Manager calls used to resolve a service's
/// hosting process id and binary command line, and to reconfigure a service to
/// run in its own process. The P/Invoke handling lives here so the cmdlet stays
/// thin.
/// </summary>
internal static class ServiceProcessService
{
    /// <summary>
    /// Resolves the process id hosting a service via
    /// <c>QueryServiceStatusEx</c>. Returns <c>0</c> when the service is stopped
    /// or the id cannot be determined.
    /// </summary>
    /// <param name="serviceName">The service name (not the display name).</param>
    public static int GetProcessId(string serviceName)
    {
        IntPtr scm = OpenSCManager(null, null, SC_MANAGER_CONNECT);
        if (scm == IntPtr.Zero)
        {
            return 0;
        }

        try
        {
            IntPtr service = OpenService(scm, serviceName, SERVICE_QUERY_STATUS);
            if (service == IntPtr.Zero)
            {
                return 0;
            }

            try
            {
                int size = Marshal.SizeOf<SERVICE_STATUS_PROCESS>();
                IntPtr buffer = Marshal.AllocHGlobal(size);
                try
                {
                    if (!QueryServiceStatusEx(service, SC_STATUS_PROCESS_INFO, buffer, (uint)size, out _))
                    {
                        return 0;
                    }

                    SERVICE_STATUS_PROCESS status = Marshal.PtrToStructure<SERVICE_STATUS_PROCESS>(buffer);
                    return (int)status.dwProcessId;
                }
                finally
                {
                    Marshal.FreeHGlobal(buffer);
                }
            }
            finally
            {
                CloseServiceHandle(service);
            }
        }
        finally
        {
            CloseServiceHandle(scm);
        }
    }

    /// <summary>
    /// Resolves a service's binary command line via <c>QueryServiceConfig</c>.
    /// For a shared-host service this is the full <c>svchost.exe -k &lt;group&gt;</c>
    /// command line. Returns an empty string when it cannot be determined.
    /// </summary>
    /// <param name="serviceName">The service name (not the display name).</param>
    public static string GetCommandLine(string serviceName)
    {
        IntPtr scm = OpenSCManager(null, null, SC_MANAGER_CONNECT);
        if (scm == IntPtr.Zero)
        {
            return string.Empty;
        }

        try
        {
            IntPtr service = OpenService(scm, serviceName, SERVICE_QUERY_CONFIG);
            if (service == IntPtr.Zero)
            {
                return string.Empty;
            }

            try
            {
                QueryServiceConfig(service, IntPtr.Zero, 0, out uint needed);
                if (needed == 0)
                {
                    return string.Empty;
                }

                IntPtr buffer = Marshal.AllocHGlobal((int)needed);
                try
                {
                    if (!QueryServiceConfig(service, buffer, needed, out _))
                    {
                        return string.Empty;
                    }

                    QUERY_SERVICE_CONFIG config = Marshal.PtrToStructure<QUERY_SERVICE_CONFIG>(buffer);
                    return config.lpBinaryPathName == IntPtr.Zero
                        ? string.Empty
                        : Marshal.PtrToStringUni(config.lpBinaryPathName) ?? string.Empty;
                }
                finally
                {
                    Marshal.FreeHGlobal(buffer);
                }
            }
            finally
            {
                CloseServiceHandle(service);
            }
        }
        finally
        {
            CloseServiceHandle(scm);
        }
    }

    /// <summary>
    /// Reconfigures a service to run in its own process
    /// (<c>SERVICE_WIN32_OWN_PROCESS</c>) via <c>ChangeServiceConfig</c>. The
    /// change takes effect the next time the service is restarted. Requires an
    /// elevated session.
    /// </summary>
    /// <param name="serviceName">The service name (not the display name).</param>
    /// <exception cref="Win32Exception">The underlying Win32 call failed.</exception>
    public static void SetOwnProcess(string serviceName)
    {
        IntPtr scm = OpenSCManager(null, null, SC_MANAGER_CONNECT);
        if (scm == IntPtr.Zero)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }

        try
        {
            IntPtr service = OpenService(scm, serviceName, SERVICE_CHANGE_CONFIG);
            if (service == IntPtr.Zero)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }

            try
            {
                if (!ChangeServiceConfig(
                    service,
                    SERVICE_WIN32_OWN_PROCESS,
                    SERVICE_NO_CHANGE,
                    SERVICE_NO_CHANGE,
                    lpBinaryPathName: null,
                    lpLoadOrderGroup: null,
                    lpdwTagId: IntPtr.Zero,
                    lpDependencies: null,
                    lpServiceStartName: null,
                    lpPassword: null,
                    lpDisplayName: null))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
            }
            finally
            {
                CloseServiceHandle(service);
            }
        }
        finally
        {
            CloseServiceHandle(scm);
        }
    }
}
