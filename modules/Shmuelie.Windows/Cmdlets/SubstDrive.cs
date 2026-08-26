namespace Shmuelie.Windows.Cmdlets;

/// <summary>
/// Represents a Windows <c>subst</c> virtual drive mapping between a drive
/// letter and the local directory it points to.
/// </summary>
public sealed class SubstDrive
{
    /// <summary>
    /// Initializes a new instance of the <see cref="SubstDrive"/> class.
    /// </summary>
    /// <param name="driveLetter">The normalized drive letter, for example <c>S:</c>.</param>
    /// <param name="targetPath">The directory the drive letter points to.</param>
    public SubstDrive(string driveLetter, string targetPath)
    {
        DriveLetter = driveLetter;
        TargetPath = targetPath;
    }

    /// <summary>
    /// Gets the normalized drive letter, for example <c>S:</c>.
    /// </summary>
    public string DriveLetter { get; }

    /// <summary>
    /// Gets the local directory the drive letter points to.
    /// </summary>
    public string TargetPath { get; }
}
