using System.Collections.ObjectModel;
using System.Globalization;
using System.Management.Automation;
using System.Management.Automation.Host;
using System.Management.Automation.Runspaces;
using System.Security;
using Shmuelie.Windows.AppInstall;

namespace Shmuelie.Windows.AppInstall.Tests;

public static partial class UpdateSearchScenarios
{
    public static AppInstallRequestSnapshot VerifyCommand(string manifestPath) =>
        RunCommand("CommandSuccess", manifestPath) ??
            throw new InvalidOperationException("The fake compiled command returned no request.");

    private static AppInstallRequestSnapshot? RunCommand(string scenario, string? manifestPath = null)
    {
        var state = InitialSessionState.CreateDefault2();
        if (manifestPath is null)
            state.Commands.Add(new SessionStateCmdletEntry("Request-AppInstallUpdateSearch",
                typeof(RequestAppInstallUpdateSearchCommand), null));
        var host = new SearchHost();
        using var owner = RunspaceFactory.CreateRunspace(host, state);
        owner.Open();
        var manager = new Manager();
        if (manifestPath is not null)
        {
            manager.ExpectedCorrelationVector = "SYNTHETIC-PRIVATE-VECTOR-244-7F3A";
            manager.ExpectedClientId = "SYNTHETIC-PRIVATE-CLIENT-244-9C2B";
        }
        var availability = new Availability();
        var activation = new Activation(manager);
        using var context = new AppInstallContext(owner, availability, activation);
        using var pipeline = PowerShell.Create();
        pipeline.Runspace = owner;
        if (manifestPath is not null)
        {
            pipeline.AddCommand("Import-Module").AddParameter("Name", manifestPath);
            pipeline.Invoke();
            Check(!pipeline.HadErrors && availability.Checks == 0 && activation.Count == 0, "search module import");
            pipeline.Commands.Clear();
        }
        pipeline.AddCommand("Request-AppInstallUpdateSearch")
            .AddParameter("CorrelationVector", manager.ExpectedCorrelationVector)
            .AddParameter("ClientId", manager.ExpectedClientId);
        if (scenario != "CommandPipelineContext") pipeline.AddParameter("Context", context);
        if (scenario == "CommandWhatIf") pipeline.AddParameter("WhatIf");
        else pipeline.AddParameter("Confirm", scenario == "CommandDecline");

        if (scenario == "CommandStopProcessing")
        {
            using var started = new ManualResetEventSlim();
            manager.Operation.NativeState = AppInstallAsyncState.Started;
            manager.Operation.OnRead = started.Set;
            using var output = new PSDataCollection<PSObject>();
            var invocation = pipeline.BeginInvoke<PSObject, PSObject>(null, output);
            try
            {
                Check(started.Wait(TimeSpan.FromSeconds(5)), "compiled search began waiting");
                var stopping = pipeline.BeginStop(null, null);
                Check(stopping.AsyncWaitHandle.WaitOne(TimeSpan.FromSeconds(5)), "StopProcessing completed promptly");
                pipeline.EndStop(stopping);
                try { pipeline.EndInvoke(invocation); }
                catch (PipelineStoppedException) { }
                Check(pipeline.InvocationStateInfo.State == PSInvocationState.Stopped &&
                    output.Count == 0 && manager.Operation.DisposeCount == 1 &&
                    manager.Operation.NativeState == AppInstallAsyncState.Started &&
                    !context.IsDisposed && manager.DisposeCount == 0, scenario);
            }
            finally
            {
                if (!invocation.IsCompleted) pipeline.Stop();
            }
            return null;
        }

        if (scenario == "CommandDisposed") context.Dispose();
        if (scenario == "CommandGrouped")
        {
            var parent = new Item(1);
            var child = new Item(2);
            parent.ChildItems.Add(child);
            manager.Operation.Items = [parent, child];
        }
        if (scenario == "CommandFailure")
            manager.Operation.ResultError = new UnauthorizedAccessException("Synthetic sensitive native diagnostics.");
        if (scenario == "CommandWrongRunspace")
        {
            using var other = RunspaceFactory.CreateRunspace(state);
            other.Open();
            pipeline.Runspace = other;
            AssertFailure(Invoke(), AppInstallErrorKind.ContextUnavailable, AppInstallRequestAcceptance.NotSubmitted);
            Check(availability.Checks == 0 && activation.Count == 0, scenario);
            return null;
        }
        if (scenario == "CommandInvalidInput")
        {
            foreach (var parameter in new[] { "CorrelationVector", "ClientId" })
            {
                foreach (var value in new[] { "", "   " })
                {
                    pipeline.Commands.Clear();
                    pipeline.AddCommand("Request-AppInstallUpdateSearch").AddParameter("Context", context)
                        .AddParameter("CorrelationVector", parameter == "CorrelationVector" ? value : "synthetic-vector")
                        .AddParameter("ClientId", parameter == "ClientId" ? value : "synthetic-client")
                        .AddParameter("Confirm", false);
                    try { pipeline.Invoke(); throw new InvalidOperationException("Invalid correlation was accepted."); }
                    catch (ParameterBindingException) { }
                }
            }
            Check(availability.Checks == 0 && activation.Count == 0, scenario);
            return null;
        }

        var result = Invoke();
        switch (scenario)
        {
            case "CommandWhatIf":
            case "CommandDecline":
                Check(result.Output.Count == 0 && result.Error is null && activation.Count == 0 &&
                    availability.Checks == 0 && manager.Calls.Count == 0 && !context.IsDisposed, scenario);
                Check(host.UserInterface.Prompts == (scenario == "CommandDecline" ? 1 : 0), scenario);
                var text = string.Join(" ", host.UserInterface.Messages);
                Check(text.Contains("All apps in caller scope", StringComparison.Ordinal) &&
                    text.Contains("queue paused", StringComparison.Ordinal) &&
                    text.Contains("automatic download/install=false", StringComparison.Ordinal) &&
                    text.Contains("forced restart=false", StringComparison.Ordinal), scenario);
                Check(!text.Contains("synthetic-vector", StringComparison.Ordinal) &&
                    !text.Contains("synthetic-client", StringComparison.Ordinal), "confirmation privacy");
                break;
            case "CommandSuccess":
            case "CommandPipelineContext":
                Check(result.Error is null && result.Output.Count == 1 &&
                    result.Output[0].BaseObject is AppInstallRequestSnapshot snapshot &&
                    snapshot.ContextId == context.ContextId && snapshot.RequestId is not null &&
                    snapshot.Acceptance == AppInstallRequestAcceptance.Accepted &&
                    snapshot.OperationState == AppInstallOperationState.Completed && snapshot.Items.Count == 0 &&
                    snapshot.ItemsAvailability == AppInstallValueAvailability.Available &&
                    activation.Count == 1 && !context.IsDisposed && manager.DisposeCount == 0, scenario);
                break;
            case "CommandGrouped":
                Check(result.Error is null && result.Output.Count == 1 &&
                    result.Output[0].BaseObject is AppInstallRequestSnapshot grouped &&
                    grouped.ContextId == context.ContextId && grouped.Items.Count == 1 &&
                    grouped.Items[0].Children.Count == 1 &&
                    grouped.Items[0].Children[0].Identity.ParentLocalItemId == grouped.Items[0].Identity.LocalItemId &&
                    grouped.Acceptance == AppInstallRequestAcceptance.Accepted &&
                    grouped.OperationState == AppInstallOperationState.Completed &&
                    grouped.Items[0].Status.TerminalState == AppInstallTerminalState.NotTerminal, scenario);
                break;
            case "CommandFailure":
                AssertFailure(result, AppInstallErrorKind.AccessDenied, AppInstallRequestAcceptance.Accepted);
                Check(ReferenceEquals(result.Error!.Exception, manager.Operation.ResultError) &&
                    !result.Error.ErrorDetails.Message.Contains("Synthetic sensitive", StringComparison.Ordinal), scenario);
                break;
            case "CommandDisposed":
                AssertFailure(result, AppInstallErrorKind.ContextUnavailable, AppInstallRequestAcceptance.NotSubmitted);
                Check(activation.Count == 0 && availability.Checks == 0, scenario);
                break;
            default: throw new ArgumentOutOfRangeException(nameof(scenario), scenario, "No live command fallback.");
        }
        return result.Output.Count == 1 && result.Output[0].BaseObject is AppInstallRequestSnapshot request ? request : null;

        (List<PSObject> Output, ErrorRecord? Error) Invoke()
        {
            var output = new List<PSObject>();
            try
            {
                pipeline.Invoke<PSObject>(scenario == "CommandPipelineContext" ? new[] { context } : null, output);
                Check(pipeline.Streams.Error.Count <= 1, "one terminating search error");
                return (output, pipeline.Streams.Error.SingleOrDefault());
            }
            catch (RuntimeException error) when (error.ErrorRecord.TargetObject is AppInstallRequestSnapshot)
            {
                return (output, error.ErrorRecord);
            }
        }
    }

    private static void AssertFailure((List<PSObject> Output, ErrorRecord? Error) result,
        AppInstallErrorKind kind, AppInstallRequestAcceptance acceptance) =>
        Check(result.Output.Count == 0 && result.Error?.TargetObject is AppInstallRequestSnapshot request &&
            request.Acceptance == acceptance && request.ItemsAvailability == AppInstallValueAvailability.Unknown &&
            request.Error?.Kind == kind && request.RequestId is not null &&
            request.CorrelationVector == "synthetic-vector" && request.ClientId == "synthetic-client", "compiled error target");

    private sealed class SearchHost : PSHost
    {
        internal SearchHostUi UserInterface { get; } = new();
        public override PSHostUserInterface UI => UserInterface;
        public override Guid InstanceId { get; } = Guid.NewGuid();
        public override string Name => "FailClosedSearchHost";
        public override Version Version => new(1, 0);
        public override CultureInfo CurrentCulture => CultureInfo.InvariantCulture;
        public override CultureInfo CurrentUICulture => CultureInfo.InvariantCulture;
        public override void EnterNestedPrompt() => throw new NotSupportedException();
        public override void ExitNestedPrompt() => throw new NotSupportedException();
        public override void NotifyBeginApplication() => throw new NotSupportedException();
        public override void NotifyEndApplication() => throw new NotSupportedException();
        public override void SetShouldExit(int exitCode) => throw new NotSupportedException();
    }

    private sealed class SearchHostUi : PSHostUserInterface
    {
        internal List<string> Messages { get; } = [];
        internal int Prompts;
        public override PSHostRawUserInterface? RawUI => null;
        public override int PromptForChoice(string caption, string message, Collection<ChoiceDescription> choices, int defaultChoice)
        {
            Prompts++;
            Messages.Add(message);
            for (int i = 0; i < choices.Count; i++)
                if (choices[i].Label == "&No") return i;
            throw new InvalidOperationException("Confirmation did not offer No.");
        }
        public override string ReadLine() => throw new NotSupportedException();
        public override SecureString ReadLineAsSecureString() => throw new NotSupportedException();
        public override Dictionary<string, PSObject> Prompt(string caption, string message, Collection<FieldDescription> descriptions) =>
            throw new NotSupportedException();
        public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName) =>
            throw new NotSupportedException();
        public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName,
            PSCredentialTypes allowedCredentialTypes, PSCredentialUIOptions options) => throw new NotSupportedException();
        public override void Write(string value) => Messages.Add(value);
        public override void Write(ConsoleColor foregroundColor, ConsoleColor backgroundColor, string value) => Messages.Add(value);
        public override void WriteLine(string value) => Messages.Add(value);
        public override void WriteErrorLine(string value) => Messages.Add(value);
        public override void WriteDebugLine(string message) => Messages.Add(message);
        public override void WriteProgress(long sourceId, ProgressRecord record) => throw new NotSupportedException();
        public override void WriteVerboseLine(string message) => Messages.Add(message);
        public override void WriteWarningLine(string message) => Messages.Add(message);
    }
}
