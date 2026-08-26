using System.ComponentModel;
using System.Management.Automation;

namespace Shmuelie.Windows.Cmdlets;

/// <summary>
/// Removes a Windows <c>subst</c> virtual drive mapping by drive letter.
/// Accepts <c>DriveLetter</c> from the pipeline by property name.
/// </summary>
[Cmdlet(VerbsCommon.Remove, "SubstDrive", SupportsShouldProcess = true)]
public sealed class RemoveSubstDriveCommand : SubstDriveCommandBase
{
    /// <summary>
    /// The virtual drive letter to remove. Specify a single letter, with or without a colon.
    /// </summary>
    [Parameter(Mandatory = true, Position = 0, ValueFromPipelineByPropertyName = true)]
    [ValidateNotNullOrEmpty]
    public string DriveLetter { get; set; } = string.Empty;

    /// <inheritdoc/>
    protected override void BeginProcessing()
    {
        EnsureWindows();
    }

    /// <inheritdoc/>
    protected override void ProcessRecord()
    {
        string normalizedDriveLetter = NormalizeDriveLetterOrThrow(DriveLetter);

        SubstDrive? mapping = SubstDriveService.GetMapping(normalizedDriveLetter);
        if (mapping is null)
        {
            ThrowTerminatingError(new ErrorRecord(
                new InvalidOperationException($"No subst mapping exists for drive letter {normalizedDriveLetter}."),
                "SubstMappingNotFound",
                ErrorCategory.ObjectNotFound,
                normalizedDriveLetter));
            return;
        }

        if (!ShouldProcess(normalizedDriveLetter, "Remove subst mapping"))
        {
            return;
        }

        try
        {
            SubstDriveService.RemoveMapping(normalizedDriveLetter, mapping.TargetPath);
        }
        catch (Win32Exception ex)
        {
            ThrowTerminatingError(new ErrorRecord(
                ex,
                "RemoveMappingFailed",
                ErrorCategory.NotSpecified,
                normalizedDriveLetter));
        }
    }
}
