using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Management.Automation;
using System.Management.Automation.Host;
using System.Security;

public sealed class WprTestHost : PSHost
{
    private readonly Guid _id = Guid.NewGuid();
    public WprTestUI TestUI { get; } = new();
    public override Guid InstanceId => _id;
    public override string Name => "WprFixture";
    public override Version Version => new(1, 0);
    public override CultureInfo CurrentCulture => CultureInfo.InvariantCulture;
    public override CultureInfo CurrentUICulture => CultureInfo.InvariantCulture;
    public override PSHostUserInterface UI => TestUI;
    public override void SetShouldExit(int exitCode) => throw new NotSupportedException();
    public override void EnterNestedPrompt() => throw new NotSupportedException();
    public override void ExitNestedPrompt() => throw new NotSupportedException();
    public override void NotifyBeginApplication() { }
    public override void NotifyEndApplication() { }
}

public sealed class WprTestUI : PSHostUserInterface
{
    public bool Approve;
    public int ConfirmationPrompts;
    public override PSHostRawUserInterface? RawUI => null;
    public override int PromptForChoice(string caption, string message, Collection<ChoiceDescription> choices, int defaultChoice)
    {
        ConfirmationPrompts++;
        string answer = Approve ? "Yes" : "No";
        for (int i = 0; i < choices.Count; i++)
            if (choices[i].Label.Replace("&", "") == answer) return i;
        throw new InvalidOperationException("Expected an explicit Yes/No confirmation.");
    }
    public override void Write(string value) { }
    public override void Write(ConsoleColor foregroundColor, ConsoleColor backgroundColor, string value) { }
    public override void WriteLine(string value) { }
    public override string ReadLine() => throw new NotSupportedException("Interactive input is forbidden.");
    public override SecureString ReadLineAsSecureString() => throw new NotSupportedException();
    public override Dictionary<string, PSObject> Prompt(string caption, string message, Collection<FieldDescription> descriptions) =>
        throw new NotSupportedException("Missing parameters must not prompt in this noninteractive fixture.");
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
