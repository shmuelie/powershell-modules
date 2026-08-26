using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Linq;
using System.Management.Automation;
using System.Runtime.Versioning;
using System.ServiceProcess;

namespace Shmuelie.Windows.Cmdlets;

/// <summary>
/// Gets the hosting process for one or more Windows services.
/// </summary>
/// <remarks>
/// Each service name (wildcards supported) is resolved to its hosting process
/// via the Win32 Service Control Manager APIs. When a single running service is
/// matched, the underlying <see cref="Process"/> is returned so the cmdlet
/// composes naturally with <c>Stop-Process</c>, <c>Wait-Process</c>, and so on.
/// Otherwise one <see cref="ServiceProcessInfo"/> object is emitted per service.
/// </remarks>
[Cmdlet(VerbsCommon.Get, "ServiceProcess", SupportsShouldProcess = true)]
[OutputType(typeof(Process), typeof(ServiceProcessInfo))]
[SupportedOSPlatform("windows")]
public sealed class GetServiceProcessCommand : ServiceProcessCommandBase
{
    /// <summary>
    /// One or more service names. Supports wildcards. Accepts pipeline input by
    /// value (string) or by property name (for example
    /// <c>Get-Service | Get-ServiceProcess</c>).
    /// </summary>
    [Parameter(Position = 0, Mandatory = true, ValueFromPipeline = true, ValueFromPipelineByPropertyName = true)]
    [ValidateNotNullOrEmpty]
    public string[] Name { get; set; } = Array.Empty<string>();

    /// <summary>
    /// Reconfigures each matched service to run in its own process via the
    /// Win32 <c>ChangeServiceConfig</c> API (<c>SERVICE_WIN32_OWN_PROCESS</c>).
    /// Requires elevation. The change takes effect on the next service restart.
    /// </summary>
    [Parameter]
    public SwitchParameter PerService { get; set; }

    private readonly List<ServiceProcessInfo> _results = new();

    /// <inheritdoc/>
    protected override void BeginProcessing()
    {
        EnsureWindows();

        if (PerService.IsPresent && !IsWhatIf() && !IsElevated())
        {
            ThrowTerminatingError(new ErrorRecord(
                new InvalidOperationException("-PerService requires an elevated session."),
                "ElevationRequired",
                ErrorCategory.PermissionDenied,
                targetObject: null));
        }
    }

    /// <inheritdoc/>
    protected override void ProcessRecord()
    {
        ServiceController[] services;
        try
        {
            services = ServiceController.GetServices();
        }
        catch (Exception ex)
        {
            WriteError(new ErrorRecord(ex, "ServiceEnumerationFailed", ErrorCategory.NotSpecified, targetObject: null));
            return;
        }

        try
        {
            foreach (string pattern in Name)
            {
                var wildcard = new WildcardPattern(pattern, WildcardOptions.IgnoreCase);
                List<ServiceController> matched = services
                    .Where(s => wildcard.IsMatch(s.ServiceName))
                    .ToList();

                if (matched.Count == 0)
                {
                    WriteError(new ErrorRecord(
                        new ItemNotFoundException($"No service matched '{pattern}'."),
                        "ServiceNotFound",
                        ErrorCategory.ObjectNotFound,
                        pattern));
                    continue;
                }

                foreach (ServiceController service in matched)
                {
                    ProcessService(service);
                }
            }
        }
        finally
        {
            foreach (ServiceController service in services)
            {
                service.Dispose();
            }
        }
    }

    /// <inheritdoc/>
    protected override void EndProcessing()
    {
        if (_results.Count == 1 && _results[0].Process is not null)
        {
            WriteObject(_results[0].Process);
        }
        else
        {
            foreach (ServiceProcessInfo info in _results)
            {
                WriteObject(info);
            }
        }
    }

    private void ProcessService(ServiceController service)
    {
        string name = service.ServiceName;

        if (PerService.IsPresent && ShouldProcess(name, "ChangeServiceConfig type= own (SERVICE_WIN32_OWN_PROCESS)"))
        {
            try
            {
                ServiceProcessService.SetOwnProcess(name);
            }
            catch (Win32Exception ex)
            {
                WriteError(new ErrorRecord(ex, "ChangeServiceConfigFailed", ErrorCategory.NotSpecified, name));
                return;
            }

            WriteWarning($"{name}: reconfigured to type=own. Restart the service for the change to take effect.");
        }

        int processId = ServiceProcessService.GetProcessId(name);
        Process? process = ResolveProcess(processId);

        _results.Add(new ServiceProcessInfo
        {
            Name = name,
            DisplayName = service.DisplayName,
            Status = service.Status,
            ProcessId = processId,
            ProcessName = process?.ProcessName ?? string.Empty,
            Process = process,
            CommandLine = ServiceProcessService.GetCommandLine(name),
        });
    }

    private static Process? ResolveProcess(int processId)
    {
        if (processId <= 0)
        {
            return null;
        }

        try
        {
            return Process.GetProcessById(processId);
        }
        catch (ArgumentException)
        {
            return null;
        }
    }

    private bool IsWhatIf()
    {
        if (MyInvocation.BoundParameters.TryGetValue("WhatIf", out object? value))
        {
            return value switch
            {
                SwitchParameter sp => sp.ToBool(),
                bool b => b,
                _ => false,
            };
        }

        return GetVariableValue("WhatIfPreference") is bool preference && preference;
    }
}
