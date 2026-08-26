using System.Management.Automation;

namespace Shmuelie.Windows.Cmdlets;

/// <summary>
/// Gets Windows <c>subst</c> virtual drive mappings.
/// </summary>
[Cmdlet(VerbsCommon.Get, "SubstDrive")]
[OutputType(typeof(SubstDrive))]
public sealed class GetSubstDriveCommand : SubstDriveCommandBase
{
    /// <summary>
    /// Optional drive letter filter. Specify a single letter, with or without a colon.
    /// </summary>
    [Parameter(Position = 0)]
    [ValidateNotNullOrEmpty]
    public string? DriveLetter { get; set; }

    /// <inheritdoc/>
    protected override void BeginProcessing()
    {
        EnsureWindows();
    }

    /// <inheritdoc/>
    protected override void ProcessRecord()
    {
        string? filter = null;
        if (MyInvocation.BoundParameters.ContainsKey(nameof(DriveLetter)))
        {
            filter = NormalizeDriveLetterOrThrow(DriveLetter!);
        }

        foreach (SubstDrive mapping in SubstDriveService.GetMappings())
        {
            if (filter is not null && !string.Equals(mapping.DriveLetter, filter, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            WriteObject(mapping);
        }
    }
}
