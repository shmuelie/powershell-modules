using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Management.Automation;

namespace Shmuelie.Windows.Cmdlets;

/// <summary>
/// Creates a Windows <c>subst</c> virtual drive mapping to an existing local
/// FileSystem directory.
/// </summary>
[Cmdlet(VerbsCommon.New, "SubstDrive", SupportsShouldProcess = true)]
[OutputType(typeof(SubstDrive))]
public sealed class NewSubstDriveCommand : SubstDriveCommandBase
{
    /// <summary>
    /// The virtual drive letter to create. Specify a single letter, with or without a colon.
    /// </summary>
    [Parameter(Mandatory = true, Position = 0)]
    [ValidateNotNullOrEmpty]
    public string DriveLetter { get; set; } = string.Empty;

    /// <summary>
    /// The existing local directory that the virtual drive should point to.
    /// </summary>
    [Parameter(Mandatory = true, Position = 1)]
    [ValidateNotNullOrEmpty]
    public string TargetPath { get; set; } = string.Empty;

    /// <inheritdoc/>
    protected override void BeginProcessing()
    {
        EnsureWindows();
    }

    /// <inheritdoc/>
    protected override void ProcessRecord()
    {
        string normalizedDriveLetter = NormalizeDriveLetterOrThrow(DriveLetter);
        string resolvedTargetPath = ResolveTargetDirectoryOrThrow(TargetPath);

        if (SubstDriveService.IsDriveLetterInUse(normalizedDriveLetter))
        {
            ThrowTerminatingError(new ErrorRecord(
                new InvalidOperationException($"Drive letter {normalizedDriveLetter} is already in use."),
                "DriveLetterInUse",
                ErrorCategory.ResourceExists,
                normalizedDriveLetter));
        }

        if (!ShouldProcess(normalizedDriveLetter, $"Map to {resolvedTargetPath}"))
        {
            return;
        }

        try
        {
            SubstDriveService.CreateMapping(normalizedDriveLetter, resolvedTargetPath);
        }
        catch (Win32Exception ex)
        {
            ThrowTerminatingError(new ErrorRecord(
                ex,
                "CreateMappingFailed",
                ErrorCategory.NotSpecified,
                normalizedDriveLetter));
        }

        WriteObject(new SubstDrive(normalizedDriveLetter, resolvedTargetPath));
    }

    private string ResolveTargetDirectoryOrThrow(string targetPath)
    {
        Collection<string> resolved;
        ProviderInfo provider;
        try
        {
            resolved = GetResolvedProviderPathFromPSPath(targetPath, out provider);
        }
        catch (ItemNotFoundException)
        {
            ThrowTerminatingError(TargetNotDirectoryError(targetPath));
            throw; // unreachable
        }
        catch (System.Management.Automation.DriveNotFoundException)
        {
            ThrowTerminatingError(TargetNotDirectoryError(targetPath));
            throw; // unreachable
        }

        if (!string.Equals(provider.Name, "FileSystem", StringComparison.OrdinalIgnoreCase))
        {
            ThrowTerminatingError(new ErrorRecord(
                new ArgumentException($"TargetPath must resolve to a FileSystem directory: {targetPath}", nameof(TargetPath)),
                "TargetNotFileSystem",
                ErrorCategory.InvalidArgument,
                targetPath));
        }

        if (resolved.Count == 0 || !Directory.Exists(resolved[0]))
        {
            ThrowTerminatingError(TargetNotDirectoryError(targetPath));
        }

        return resolved[0];
    }

    private static ErrorRecord TargetNotDirectoryError(string targetPath)
    {
        return new ErrorRecord(
            new DirectoryNotFoundException($"TargetPath must be an existing directory: {targetPath}"),
            "TargetNotDirectory",
            ErrorCategory.ObjectNotFound,
            targetPath);
    }
}
