using System.Management.Automation.Runspaces;

namespace Shmuelie.Windows.AppInstall;

/// <summary>
/// Owns one lazily activated AppInstallManager in its creating runspace.
/// Creation is not an access check or an installation request.
/// </summary>
public sealed class AppInstallContext : IDisposable
{
    private readonly object sync = new();
    private readonly Runspace owner;
    private readonly IAppInstallAvailability availability;
    private readonly Lazy<IAppInstallManagerAdapter> manager;
    private bool disposed;

    internal AppInstallContext(
        Runspace owner, IAppInstallAvailability availability, IAppInstallActivation activation)
    {
        ArgumentNullException.ThrowIfNull(owner);
        ArgumentNullException.ThrowIfNull(availability);
        ArgumentNullException.ThrowIfNull(activation);
        if (!availability.IsSupportedPlatform)
            throw new PlatformNotSupportedException("AppInstall contexts require Windows 10 build 19041 or later.");

        this.owner = owner;
        this.availability = availability;
        manager = new Lazy<IAppInstallManagerAdapter>(() => activation.Activate() ??
            throw new InvalidOperationException("AppInstall activation returned no manager."));
        owner.StateChanged += OnRunspaceStateChanged;
        if (owner.RunspaceStateInfo.State is RunspaceState.Closing or RunspaceState.Closed or RunspaceState.Broken)
        {
            Dispose();
            throw new InvalidOperationException("The owning runspace is closing or closed.");
        }
    }

    public Guid ContextId { get; } = Guid.NewGuid();
    public Guid RunspaceId => owner.InstanceId;
    public AppInstallUserScope UserScope => AppInstallUserScope.Caller;
    public bool IsActivated { get { lock (sync) return manager.IsValueCreated; } }
    public bool IsDisposed { get { lock (sync) return disposed; } }

    // Integration seam for later cmdlets: require this explicit context, check
    // every member before activation/invocation. Keep the callback to a short
    // native invocation; wait for returned operations outside this lifecycle
    // lock. A synchronous native call cannot be forcibly canceled by Dispose.
    internal T Use<T>(AppInstallMember member, Func<IAppInstallManagerAdapter, T> operation)
    {
        ArgumentNullException.ThrowIfNull(member);
        ArgumentNullException.ThrowIfNull(operation);
        lock (sync)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (!ReferenceEquals(Runspace.DefaultRunspace, owner))
                throw new InvalidOperationException("An AppInstall context can only be used in its creating runspace.");
            if (!availability.IsSupportedPlatform)
                throw new PlatformNotSupportedException("AppInstall contexts require Windows 10 build 19041 or later.");
            if (!availability.IsTypePresent(AppInstallMember.ManagerType) ||
                !availability.IsTypePresent(member.TypeName) ||
                !availability.IsMemberPresent(member))
                throw new MissingMemberException(member.TypeName, member.Name);

            return operation(manager.Value);
        }
    }

    private void OnRunspaceStateChanged(object? sender, RunspaceStateEventArgs args)
    {
        if (args.RunspaceStateInfo.State is RunspaceState.Closing or RunspaceState.Closed or RunspaceState.Broken)
            Dispose();
    }

    public void Dispose()
    {
        lock (sync)
        {
            if (disposed) return;
            disposed = true;
            owner.StateChanged -= OnRunspaceStateChanged;
            if (manager.IsValueCreated) manager.Value.Dispose();
        }
    }
}

/// <summary>Caller scope does not assert a SID, account identity, or queue visibility.</summary>
public enum AppInstallUserScope { Unknown, Caller }
