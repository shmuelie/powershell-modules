using System;
using System.Collections;
using System.Collections.Generic;
using System.Management.Automation;
using System.Management.Automation.Host;

// Exercises the compiled lifecycle with an explicit ShouldProcess decision;
// every unused runtime operation fails closed.
public sealed class AppInstallerTestRuntime : ICommandRuntime
{
    public bool Approve = true;
    public int PromptCount;
    public readonly List<object> Output = new List<object>();
    public readonly List<string> Targets = new List<string>();
    public PSHost Host => throw new NotSupportedException();
    public PSTransactionContext CurrentPSTransaction => throw new NotSupportedException();
    public bool TransactionAvailable() => false;
    public void WriteObject(object value) => Output.Add(value);
    public void WriteObject(object value, bool enumerateCollection)
    {
        if (enumerateCollection && value is IEnumerable items)
            foreach (object item in items) Output.Add(item);
        else
            Output.Add(value);
    }
    public bool ShouldProcess(string target)
    {
        PromptCount++;
        Targets.Add(target);
        return Approve;
    }
    public bool ShouldProcess(string target, string action) => ShouldProcess(target);
    public bool ShouldProcess(string description, string warning, string caption) => ShouldProcess(description);
    public bool ShouldProcess(string description, string warning, string caption, out ShouldProcessReason reason)
    {
        reason = ShouldProcessReason.None;
        return ShouldProcess(description);
    }
    public bool ShouldContinue(string query, string caption) => throw new NotSupportedException();
    public bool ShouldContinue(string query, string caption, ref bool yesToAll, ref bool noToAll) => throw new NotSupportedException();
    public void ThrowTerminatingError(ErrorRecord error) => throw error.Exception;
    public void WriteError(ErrorRecord error) => throw error.Exception;
    public void WriteDebug(string text) => throw new NotSupportedException();
    public void WriteVerbose(string text) => throw new NotSupportedException();
    public void WriteWarning(string text) => throw new NotSupportedException();
    public void WriteCommandDetail(string text) => throw new NotSupportedException();
    public void WriteProgress(ProgressRecord progress) => throw new NotSupportedException();
    public void WriteProgress(long sourceId, ProgressRecord progress) => throw new NotSupportedException();
}
