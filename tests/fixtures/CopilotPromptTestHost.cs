using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Management.Automation;
using System.Management.Automation.Host;
using System.Security;

public sealed class CopilotPromptTestHost : PSHost
{
    public readonly CopilotPromptTestUI TestUI = new();
    public bool MissingUI;
    public override Guid InstanceId { get; } = Guid.NewGuid();
    public override string Name => "CopilotPromptFixture";
    public override Version Version => new(1, 0);
    public override CultureInfo CurrentCulture => CultureInfo.InvariantCulture;
    public override CultureInfo CurrentUICulture => CultureInfo.InvariantCulture;
    public override PSHostUserInterface UI => MissingUI ? null : TestUI;
    public override void SetShouldExit(int exitCode) => throw new NotSupportedException();
    public override void EnterNestedPrompt() => throw new NotSupportedException();
    public override void ExitNestedPrompt() => throw new NotSupportedException();
    public override void NotifyBeginApplication() { }
    public override void NotifyEndApplication() { }
}

public sealed class CopilotPromptCall
{
    public string Caption;
    public string Message;
    public Collection<ChoiceDescription> Choices;
    public int DefaultChoice;
}

public sealed class CopilotPromptTestUI : PSHostUserInterface
{
    public readonly Queue<int> Answers = new();
    public readonly List<CopilotPromptCall> Calls = new();
    public Exception Failure;
    public int FailureAfterCalls;
    public int OtherInputCalls;
    public override PSHostRawUserInterface RawUI => null;
    public override int PromptForChoice(string caption, string message, Collection<ChoiceDescription> choices, int defaultChoice)
    {
        Calls.Add(new CopilotPromptCall { Caption = caption, Message = message, Choices = choices, DefaultChoice = defaultChoice });
        if (Failure != null && Calls.Count > FailureAfterCalls) throw Failure;
        if (Answers.Count == 0) throw new NotSupportedException("No prompt input is available.");
        return Answers.Dequeue();
    }
    private Exception UnexpectedInput()
    {
        OtherInputCalls++;
        return new NotSupportedException("Only choice input is allowed in this fixture.");
    }
    public override string ReadLine() => throw UnexpectedInput();
    public override SecureString ReadLineAsSecureString() => throw UnexpectedInput();
    public override Dictionary<string, PSObject> Prompt(string caption, string message, Collection<FieldDescription> descriptions) => throw UnexpectedInput();
    public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName) => throw UnexpectedInput();
    public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName,
        PSCredentialTypes types, PSCredentialUIOptions options) => throw UnexpectedInput();
    public override void Write(string value) { }
    public override void Write(ConsoleColor foreground, ConsoleColor background, string value) { }
    public override void WriteLine(string value) { }
    public override void WriteErrorLine(string value) { }
    public override void WriteDebugLine(string value) { }
    public override void WriteVerboseLine(string value) { }
    public override void WriteWarningLine(string value) { }
    public override void WriteProgress(long sourceId, ProgressRecord record) { }
}
