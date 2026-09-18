global using System;
global using System.Collections.Generic;

using System.Diagnostics;
using System.Management.Automation;
using System.Runtime.InteropServices;
using System.ServiceProcess;

namespace Shmuelie.Windows.Cmdlets;

// This replaces the P/Invoke class only in the isolated test compilation.
internal static class ServiceProcessNativeMethods
{
    internal const int SC_MANAGER_CONNECT = 1, SERVICE_QUERY_CONFIG = 1, SERVICE_CHANGE_CONFIG = 2, SERVICE_QUERY_STATUS = 4;
    internal const int SC_STATUS_PROCESS_INFO = 0;
    internal const uint SERVICE_NO_CHANGE = 0xffffffff, SERVICE_WIN32_OWN_PROCESS = 0x10;

    [StructLayout(LayoutKind.Sequential)]
    internal struct SERVICE_STATUS_PROCESS
    {
        public uint dwServiceType, dwCurrentState, dwControlsAccepted, dwWin32ExitCode, dwServiceSpecificExitCode,
            dwCheckPoint, dwWaitHint, dwProcessId, dwServiceFlags;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal struct QUERY_SERVICE_CONFIG
    {
        public uint dwServiceType, dwStartType, dwErrorControl;
        public IntPtr lpBinaryPathName, lpLoadOrderGroup;
        public uint dwTagId;
        public IntPtr lpDependencies, lpServiceStartName, lpDisplayName;
    }

    internal static IntPtr OpenSCManager(string? machine, string? database, int access)
    {
        if (machine is not null || database is not null || access != SC_MANAGER_CONNECT)
            throw new InvalidOperationException("Unexpected fixture SCM request.");
        if (ServiceProcessStatusFixture.Failure == "Manager") return IntPtr.Zero;
        ServiceProcessStatusFixture.Handles.Add(new IntPtr(1));
        return new IntPtr(1);
    }

    internal static IntPtr OpenService(IntPtr scm, string name, int access)
    {
        int expectedAccess = ServiceProcessStatusFixture.AllowConfiguration ? SERVICE_CHANGE_CONFIG : SERVICE_QUERY_STATUS;
        if (!ServiceProcessStatusFixture.Handles.Contains(scm) || name != "FixtureService" || access != expectedAccess)
            throw new InvalidOperationException("Unexpected fixture service request.");
        if (ServiceProcessStatusFixture.Failure == "Service") return IntPtr.Zero;
        ServiceProcessStatusFixture.Handles.Add(new IntPtr(2));
        return new IntPtr(2);
    }

    internal static bool CloseServiceHandle(IntPtr handle)
    {
        if (!ServiceProcessStatusFixture.Handles.Remove(handle))
            throw new InvalidOperationException("Unexpected or repeated handle close.");
        ServiceProcessStatusFixture.CloseCalls++;
        return true;
    }

    internal static bool QueryServiceStatusEx(IntPtr service, int level, IntPtr buffer, uint size, out uint needed)
    {
        needed = (uint)Marshal.SizeOf<SERVICE_STATUS_PROCESS>();
        if (!ServiceProcessStatusFixture.Handles.Contains(service) || service != new IntPtr(2) ||
            level != SC_STATUS_PROCESS_INFO || buffer == IntPtr.Zero || size != needed)
            throw new InvalidOperationException("Unexpected status buffer or handle.");
        ServiceProcessStatusFixture.QueryCalls++;
        if (ServiceProcessStatusFixture.Failure == "Throw")
            throw new InvalidOperationException("Synthetic status query failure.");
        if (ServiceProcessStatusFixture.Failure == "Query") return false;
        Marshal.StructureToPtr(new SERVICE_STATUS_PROCESS
        {
            dwCurrentState = ServiceProcessStatusFixture.State,
            dwProcessId = ServiceProcessStatusFixture.NativeProcessId,
            dwServiceType = ServiceProcessStatusFixture.ServiceType,
        }, buffer, false);
        if (ServiceProcessStatusFixture.ChangeStateAfterCapture)
            ServiceProcessStatusFixture.State = 4;
        return true;
    }

    internal static bool QueryServiceConfig(IntPtr service, IntPtr buffer, uint size, out uint needed)
    {
        needed = 0;
        throw new InvalidOperationException("Configuration reads are forbidden in this fixture.");
    }

    internal static bool ChangeServiceConfig(IntPtr service, uint serviceType, uint startType, uint errorControl,
        string? lpBinaryPathName, string? lpLoadOrderGroup, IntPtr lpdwTagId, string? lpDependencies,
        string? lpServiceStartName, string? lpPassword, string? lpDisplayName)
    {
        if (!ServiceProcessStatusFixture.AllowConfiguration || !ServiceProcessStatusFixture.Handles.Contains(service) ||
            serviceType != SERVICE_WIN32_OWN_PROCESS || startType != SERVICE_NO_CHANGE || errorControl != SERVICE_NO_CHANGE ||
            lpBinaryPathName is not null || lpLoadOrderGroup is not null || lpdwTagId != IntPtr.Zero ||
            lpDependencies is not null || lpServiceStartName is not null || lpPassword is not null || lpDisplayName is not null)
            throw new InvalidOperationException("Unexpected fixture configuration change.");
        ServiceProcessStatusFixture.ConfigurationCalls++;
        return true;
    }
}

public static class ServiceProcessStatusFixture
{
    internal static readonly HashSet<IntPtr> Handles = new();
    public static uint State, NativeProcessId, ServiceType;
    public static string Failure = "";
    public static bool ChangeStateAfterCapture, AllowConfiguration, LookupAllowed, ProcessMissing;
    public static int CloseCalls, QueryCalls, ConfigurationCalls, LookupCalls;
    private static Process? _detachedProcess;

    public static int OutstandingHandles => Handles.Count;
    public static Process? DetachedProcess => _detachedProcess;

    public static void Reset(uint state, uint processId, uint serviceType = 0x10)
    {
        if (Handles.Count != 0) throw new InvalidOperationException("A previous case leaked fake handles.");
        _detachedProcess?.Dispose();
        _detachedProcess = null;
        State = state;
        NativeProcessId = processId;
        ServiceType = serviceType;
        Failure = "";
        ChangeStateAfterCapture = AllowConfiguration = LookupAllowed = ProcessMissing = false;
        CloseCalls = QueryCalls = ConfigurationCalls = LookupCalls = 0;
    }

    public static int ReadProcessId() => ServiceProcessService.GetProcessId("FixtureService");
    public static void SetOwnProcess() => ServiceProcessService.SetOwnProcess("FixtureService");

    public static GetServiceProcessCommand CreateCommand(ICommandRuntime runtime) =>
        new(Lookup) { CommandRuntime = runtime };

    private static Process Lookup(int processId)
    {
        LookupCalls++;
        if (!LookupAllowed || processId != NativeProcessId || processId <= 0)
            throw new InvalidOperationException("Invalid service snapshot reached process lookup.");
        if (ProcessMissing) throw new ArgumentException("Synthetic missing process.");
        // This object is never associated with an OS process or inspected for process properties.
        return _detachedProcess ??= new Process();
    }

    public static ServiceProcessInfo Result(uint state, int processId, Process? process, string name) =>
        new()
        {
            Name = name,
            DisplayName = name,
            Status = unchecked((ServiceControllerStatus)state),
            ProcessId = processId,
            Process = process,
            ProcessName = process is null ? "" : "FixtureProcess",
        };

    public static void Cleanup()
    {
        _detachedProcess?.Dispose();
        _detachedProcess = null;
        if (Handles.Count != 0) throw new InvalidOperationException("The fixture leaked native-handle substitutes.");
    }
}
