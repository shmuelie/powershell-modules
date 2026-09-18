global using System;
global using System.Collections.Generic;
global using System.IO;

using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Globalization;
using System.Management.Automation;
using System.Management.Automation.Host;
using System.Security;

namespace Shmuelie.Windows.Cmdlets;

// The isolated compilation excludes the production service and all native mapping APIs.
internal static class SubstDriveService
{
    public static string NormalizeDriveLetter(string driveLetter) =>
        driveLetter == "S" ? "S:" : throw new InvalidOperationException("Unexpected fixture drive letter.");

    public static bool IsDriveLetterInUse(string driveLetter)
    {
        if (driveLetter != "S:") throw new InvalidOperationException("Unexpected fixture drive check.");
        SubstTargetFixture.DriveChecks++;
        return SubstTargetFixture.DriveInUse;
    }

    public static void CreateMapping(string driveLetter, string targetPath)
    {
        if (driveLetter != "S:" || !SubstTargetFixture.AllowedTargets.Contains(targetPath))
            throw new InvalidOperationException("Mapping target is not an owned fixture directory.");
        SubstTargetFixture.MappingAttempts++;
        if (SubstTargetFixture.FailMapping) throw new Win32Exception(5, "Synthetic mapping failure.");
        SubstTargetFixture.Mappings.Add(new SubstDrive(driveLetter, targetPath));
    }
}

public static class SubstTargetFixture
{
    public static readonly HashSet<string> AllowedTargets = new(StringComparer.OrdinalIgnoreCase);
    public static readonly List<SubstDrive> Mappings = new();
    public static int DriveChecks, MappingAttempts;
    public static bool DriveInUse, FailMapping;

    public static void Reset()
    {
        DriveChecks = MappingAttempts = 0;
        DriveInUse = FailMapping = false;
        Mappings.Clear();
    }
}

public sealed class SubstTargetHost : PSHost
{
    private readonly Guid _id = Guid.NewGuid();
    public SubstTargetUI TestUI { get; } = new();
    public override Guid InstanceId => _id;
    public override string Name => "SubstTargetFixture";
    public override Version Version => new(1, 0);
    public override CultureInfo CurrentCulture => CultureInfo.InvariantCulture;
    public override CultureInfo CurrentUICulture => CultureInfo.InvariantCulture;
    public override PSHostUserInterface UI => TestUI;
    public override void SetShouldExit(int exitCode) => throw new NotSupportedException();
    public override void EnterNestedPrompt() => throw new NotSupportedException();
    public override void ExitNestedPrompt() => throw new NotSupportedException();
    public override void NotifyBeginApplication() => throw new NotSupportedException();
    public override void NotifyEndApplication() => throw new NotSupportedException();
}

public sealed class SubstTargetUI : PSHostUserInterface
{
    public bool Approve;
    public int PromptCount;
    public readonly List<string> Messages = new();
    public override PSHostRawUserInterface? RawUI => null;
    public override int PromptForChoice(string caption, string message, Collection<ChoiceDescription> choices, int defaultChoice)
    {
        PromptCount++;
        string answer = Approve ? "Yes" : "No";
        for (int i = 0; i < choices.Count; i++)
            if (choices[i].Label.Replace("&", "") == answer) return i;
        throw new InvalidOperationException("Expected an explicit Yes/No confirmation choice.");
    }
    public override void Write(string value) => Messages.Add(value);
    public override void Write(ConsoleColor foregroundColor, ConsoleColor backgroundColor, string value) => Write(value);
    public override void WriteLine(string value) => Write(value);
    public override string ReadLine() => throw new NotSupportedException();
    public override SecureString ReadLineAsSecureString() => throw new NotSupportedException();
    public override Dictionary<string, PSObject> Prompt(string caption, string message, Collection<FieldDescription> descriptions) =>
        throw new NotSupportedException();
    public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName) =>
        throw new NotSupportedException();
    public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName,
        PSCredentialTypes allowedCredentialTypes, PSCredentialUIOptions options) => throw new NotSupportedException();
    public override void WriteErrorLine(string value) => throw new NotSupportedException();
    public override void WriteDebugLine(string message) => throw new NotSupportedException();
    public override void WriteVerboseLine(string message) => throw new NotSupportedException();
    public override void WriteWarningLine(string message) => throw new NotSupportedException();
    public override void WriteProgress(long sourceId, ProgressRecord record) => throw new NotSupportedException();
}
