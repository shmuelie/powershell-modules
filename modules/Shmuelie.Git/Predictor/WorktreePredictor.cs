using System.Diagnostics;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Management.Automation.Subsystem;
using System.Management.Automation.Subsystem.Prediction;

namespace WorktreePredictor;

public sealed class WorktreeCommandPredictor : ICommandPredictor
{
    internal static readonly Guid PredictorId = new("a1b2c3d4-e5f6-7890-abcd-ef1234567890");

    private static readonly string[] WorktreeBranchCommands =
    [
        "Set-Worktree",
        "Remove-Worktree",
        "cw",
        "rw"
    ];

    private static readonly string[] AddWorktreeCommands =
    [
        "Add-Worktree"
    ];

    private volatile string[]? _cachedWorktreeBranches;
    private volatile string[]? _cachedCheckoutableBranches;
    private volatile string? _cachedCwd;
    private int _refreshing;
    private long _cacheTimeTicks = DateTime.MinValue.Ticks;
    private static readonly TimeSpan CacheDuration = TimeSpan.FromSeconds(30);

    // Static reference so the PowerShell hook can reach the registered instance
    internal static WorktreeCommandPredictor? Instance { get; set; }

    public Guid Id => PredictorId;
    public string Name => "Worktree";
    public string Description => "Suggests git worktree branch names for worktree commands";

    /// <summary>
    /// Called from PowerShell (prompt function) to update the current working directory.
    /// This is the only reliable way to get the CWD since the predictor runs on a
    /// thread with no runspace.
    /// </summary>
    public static void UpdateWorkingDirectory(string path)
    {
        Instance?.RefreshCache(path);
    }

    public SuggestionPackage GetSuggestion(PredictionClient client, PredictionContext context, CancellationToken cancellationToken)
    {
        var input = context.InputAst.Extent.Text;
        if (string.IsNullOrWhiteSpace(input))
        {
            return default;
        }

        string[]? branches = null;
        var matchedCommand = Array.Find(WorktreeBranchCommands, cmd => StartsWithCommand(input, cmd));
        if (matchedCommand is not null)
        {
            branches = _cachedWorktreeBranches;
        }
        else
        {
            matchedCommand = Array.Find(AddWorktreeCommands, cmd => StartsWithCommand(input, cmd));
            if (matchedCommand is not null)
            {
                branches = _cachedCheckoutableBranches;
            }
        }

        if (matchedCommand is null)
        {
            return default;
        }

        if (branches is null || branches.Length == 0)
        {
            return default;
        }

        // Split the line into the already-typed prefix and the trailing partial token
        // (the branch fragment being typed). Everything before that token — including any
        // parameters/switches like -BranchName, -RemoveBranch, -Force — is preserved
        // verbatim so accepting the suggestion keeps the user's flags and casing. Only the
        // trailing token is completed against the branch list.
        string prefix;
        string partial;
        if (input.Length == matchedCommand.Length)
        {
            // Command typed with no trailing space yet (e.g. "Remove-Worktree").
            prefix = input + " ";
            partial = string.Empty;
        }
        else
        {
            var lastWs = -1;
            for (var i = input.Length - 1; i >= matchedCommand.Length; i--)
            {
                if (char.IsWhiteSpace(input[i])) { lastWs = i; break; }
            }
            if (lastWs < 0)
            {
                return default;
            }
            prefix = input[..(lastWs + 1)];
            partial = input[(lastWs + 1)..];
        }

        // The trailing token is a switch/parameter name being typed (e.g. "-Rem"), not a
        // branch — don't offer branch predictions there.
        if (partial.StartsWith('-'))
        {
            return default;
        }

        var suggestions = new List<PredictiveSuggestion>();
        foreach (var branch in branches)
        {
            if (cancellationToken.IsCancellationRequested)
            {
                break;
            }

            // Substring match: the profile uses ListView prediction, which displays
            // suggestions even when the typed fragment appears in the MIDDLE of the branch
            // name (e.g. typing "wim" matches "user/alex/wim-work"). The already-typed
            // prefix (command + any switches) is preserved in the emitted suggestion.
            if (partial.Length == 0 || branch.Contains(partial, StringComparison.OrdinalIgnoreCase))
            {
                suggestions.Add(new PredictiveSuggestion($"{prefix}{branch}"));
            }
        }

        return suggestions.Count > 0
            ? new SuggestionPackage(suggestions)
            : default;
    }

    // Match a command name at the start of the line only on a word boundary — the next
    // char must be whitespace or end-of-line — so "cwd" doesn't trigger the "cw" predictor.
    private static bool StartsWithCommand(string input, string cmd) =>
        input.StartsWith(cmd, StringComparison.OrdinalIgnoreCase) &&
        (input.Length == cmd.Length || char.IsWhiteSpace(input[cmd.Length]));

    internal void RefreshCache(string cwd)
    {
        var isSameCwd = string.Equals(_cachedCwd, cwd, StringComparison.OrdinalIgnoreCase);
        var cacheTime = new DateTime(Interlocked.Read(ref _cacheTimeTicks), DateTimeKind.Utc);
        var isExpired = DateTime.UtcNow - cacheTime > CacheDuration;

        if (isSameCwd && !isExpired)
        {
            return;
        }

        if (Interlocked.CompareExchange(ref _refreshing, 1, 0) != 0)
        {
            return;
        }

        try
        {
            _ = Task.Run(() =>
            {
                try
                {
                    var worktreeBranches = FetchWorktreeBranches(cwd);
                    _cachedWorktreeBranches = worktreeBranches;
                    _cachedCheckoutableBranches = FetchCheckoutableBranches(cwd, worktreeBranches);
                    _cachedCwd = cwd;
                    Interlocked.Exchange(ref _cacheTimeTicks, DateTime.UtcNow.Ticks);
                }
                catch (Exception ex)
                {
                    Debug.WriteLine($"WorktreePredictor refresh failed: {ex}");
                }
                finally
                {
                    Interlocked.Exchange(ref _refreshing, 0);
                }
            });
        }
        catch
        {
            Interlocked.Exchange(ref _refreshing, 0);
            throw;
        }
    }

    private static string[] RunGit(string cwd, string arguments)
    {
        try
        {
            var psi = new ProcessStartInfo("git", arguments)
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = cwd
            };

            using var process = Process.Start(psi);
            if (process is null)
            {
                return [];
            }

            var output = process.StandardOutput.ReadToEnd();
            if (!process.WaitForExit(5000))
            {
                return [];
            }

            return output.Split('\n', StringSplitOptions.RemoveEmptyEntries);
        }
        catch
        {
            return [];
        }
    }

    private static string[] FetchWorktreeBranches(string cwd)
    {
        var branches = new List<string>();
        foreach (var line in RunGit(cwd, "worktree list --porcelain"))
        {
            var trimmed = line.Trim();
            if (trimmed.StartsWith("branch refs/heads/"))
            {
                branches.Add(trimmed["branch refs/heads/".Length..]);
            }
        }

        return branches.ToArray();
    }

    private static string[] FetchCheckoutableBranches(string cwd, string[] worktreeBranches)
    {
        var branches = new List<string>();
        foreach (var line in RunGit(cwd, "branch --format=%(refname:short)"))
        {
            var trimmed = line.Trim();
            if (trimmed.Length > 0 &&
                !worktreeBranches.Contains(trimmed, StringComparer.OrdinalIgnoreCase))
            {
                branches.Add(trimmed);
            }
        }

        return branches.ToArray();
    }

    public bool CanAcceptFeedback(PredictionClient client, PredictorFeedbackKind feedback) => false;
    public void OnSuggestionDisplayed(PredictionClient client, uint session, int countOrIndex) { }
    public void OnSuggestionAccepted(PredictionClient client, uint session, string acceptedSuggestion) { }
    public void OnCommandLineAccepted(PredictionClient client, IReadOnlyList<string> history) { }
    public void OnCommandLineExecuted(PredictionClient client, string commandLine, bool success) { }
}

public class Init : IModuleAssemblyInitializer, IModuleAssemblyCleanup
{
    public void OnImport()
    {
        var predictor = new WorktreeCommandPredictor();
        WorktreeCommandPredictor.Instance = predictor;
        SubsystemManager.RegisterSubsystem(SubsystemKind.CommandPredictor, predictor);
    }

    public void OnRemove(PSModuleInfo psModuleInfo)
    {
        WorktreeCommandPredictor.Instance = null;
        SubsystemManager.UnregisterSubsystem(SubsystemKind.CommandPredictor, WorktreeCommandPredictor.PredictorId);
    }
}
