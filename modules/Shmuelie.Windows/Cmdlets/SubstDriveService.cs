using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;

namespace Shmuelie.Windows.Cmdlets;

/// <summary>
/// Wraps the Win32 MS-DOS device APIs (<c>DefineDosDevice</c> /
/// <c>QueryDosDevice</c>) used to enumerate, create, and remove <c>subst</c>
/// virtual drive mappings. The P/Invoke surface and the mapping logic live here
/// so the cmdlets themselves stay thin.
/// </summary>
internal static class SubstDriveService
{
    private const uint DDD_REMOVE_DEFINITION = 0x00000002;
    private const uint DDD_EXACT_MATCH_ON_REMOVE = 0x00000004;

    private const int ERROR_INSUFFICIENT_BUFFER = 122;

    /// <summary>
    /// Prefix that MS-DOS device targets carry for locally rooted (subst)
    /// mappings. Real volumes resolve to <c>\Device\...</c> instead.
    /// </summary>
    private const string DosDevicePrefix = @"\??\";

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "DefineDosDeviceW")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DefineDosDevice(uint dwFlags, string lpDeviceName, string? lpTargetPath);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "QueryDosDeviceW")]
    private static extern uint QueryDosDevice(string? lpDeviceName, char[] lpTargetPath, uint ucchMax);

    /// <summary>
    /// Validates a caller-supplied drive letter and normalizes it to the
    /// canonical <c>X:</c> form (single uppercase letter with a trailing colon).
    /// </summary>
    /// <param name="driveLetter">A single letter A-Z, optionally with a colon.</param>
    /// <returns>The normalized drive letter, for example <c>S:</c>.</returns>
    /// <exception cref="ArgumentException">The value is not a single letter A-Z.</exception>
    public static string NormalizeDriveLetter(string driveLetter)
    {
        if (string.IsNullOrEmpty(driveLetter) || !Regex.IsMatch(driveLetter, "^[A-Za-z]:?$"))
        {
            throw new ArgumentException(
                "DriveLetter must be a single letter A-Z, optionally followed by a colon.",
                nameof(driveLetter));
        }

        return string.Concat(char.ToUpperInvariant(driveLetter[0]), ":");
    }

    /// <summary>
    /// Enumerates the current <c>subst</c> mappings.
    /// </summary>
    /// <returns>The active mappings, ordered by drive letter.</returns>
    public static IReadOnlyList<SubstDrive> GetMappings()
    {
        var mappings = new List<SubstDrive>();
        for (char letter = 'A'; letter <= 'Z'; letter++)
        {
            string device = string.Concat(letter, ":");
            string? target = QueryTarget(device);
            if (target is null || !target.StartsWith(DosDevicePrefix, StringComparison.Ordinal))
            {
                continue;
            }

            string path = target.Substring(DosDevicePrefix.Length);

            // subst maps to a locally rooted directory (X:\...). Skip anything
            // else that happens to carry the \??\ prefix (for example network
            // redirector mappings such as \??\UNC\server\share).
            if (path.Length < 2 || path[1] != ':')
            {
                continue;
            }

            mappings.Add(new SubstDrive(device, path));
        }

        return mappings;
    }

    /// <summary>
    /// Gets the single active <c>subst</c> mapping for a drive letter, or
    /// <see langword="null"/> when the drive is not a subst mapping.
    /// </summary>
    /// <param name="normalizedDriveLetter">A drive letter in <c>X:</c> form.</param>
    public static SubstDrive? GetMapping(string normalizedDriveLetter)
    {
        string? target = QueryTarget(normalizedDriveLetter);
        if (target is null || !target.StartsWith(DosDevicePrefix, StringComparison.Ordinal))
        {
            return null;
        }

        string path = target.Substring(DosDevicePrefix.Length);
        if (path.Length < 2 || path[1] != ':')
        {
            return null;
        }

        return new SubstDrive(normalizedDriveLetter, path);
    }

    /// <summary>
    /// Determines whether a drive letter is already in use by any local volume
    /// (real, network, or an existing subst mapping).
    /// </summary>
    /// <param name="normalizedDriveLetter">A drive letter in <c>X:</c> form.</param>
    public static bool IsDriveLetterInUse(string normalizedDriveLetter)
    {
        string root = string.Concat(normalizedDriveLetter, "\\");
        foreach (string logicalDrive in Directory.GetLogicalDrives())
        {
            if (string.Equals(logicalDrive, root, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return GetMapping(normalizedDriveLetter) is not null;
    }

    /// <summary>
    /// Creates a <c>subst</c> mapping from a drive letter to a target directory.
    /// </summary>
    /// <param name="normalizedDriveLetter">A drive letter in <c>X:</c> form.</param>
    /// <param name="targetPath">The existing local directory to map.</param>
    /// <exception cref="Win32Exception">The underlying Win32 call failed.</exception>
    public static void CreateMapping(string normalizedDriveLetter, string targetPath)
    {
        if (!DefineDosDevice(0, normalizedDriveLetter, targetPath))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }

    /// <summary>
    /// Removes a <c>subst</c> mapping. Uses an exact match on the recorded
    /// target so an unrelated mapping is never removed by accident.
    /// </summary>
    /// <param name="normalizedDriveLetter">A drive letter in <c>X:</c> form.</param>
    /// <param name="targetPath">The directory the mapping currently points to.</param>
    /// <exception cref="Win32Exception">The underlying Win32 call failed.</exception>
    public static void RemoveMapping(string normalizedDriveLetter, string targetPath)
    {
        if (!DefineDosDevice(DDD_REMOVE_DEFINITION | DDD_EXACT_MATCH_ON_REMOVE, normalizedDriveLetter, targetPath))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }

    private static string? QueryTarget(string device)
    {
        char[] buffer = new char[1024];
        while (true)
        {
            uint length = QueryDosDevice(device, buffer, (uint)buffer.Length);
            if (length != 0)
            {
                int end = Array.IndexOf(buffer, '\0');
                if (end < 0)
                {
                    end = buffer.Length;
                }

                return end == 0 ? null : new string(buffer, 0, end);
            }

            if (Marshal.GetLastWin32Error() == ERROR_INSUFFICIENT_BUFFER)
            {
                buffer = new char[buffer.Length * 2];
                continue;
            }

            return null;
        }
    }
}
