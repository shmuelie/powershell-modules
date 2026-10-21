# Copilot automatic resume benchmark

`Measure-CopilotResume.ps1` measures **module discovery/selection preparation**,
not native CLI conversation loading. It never launches Copilot, reads a user's
home/session corpus, or changes runtime-owned databases/history.

```powershell
# Run from the repository root with PowerShell 7.4+.
./tests/benchmarks/Measure-CopilotResume.ps1 -Count 100,1000,10000

# Shorter exploratory run; not a wall-clock unit test.
./tests/benchmarks/Measure-CopilotResume.ps1 -Count 100 -Scenario CompleteUnrelated

# Optional actual local Git-process probe case (no network); keep it small.
./tests/benchmarks/Measure-CopilotResume.ps1 -Count 100 -Scenario RecordedGit
```

For a same-fixture comparison, extract the baseline module to a new temporary
directory (no checkout, branch switch or upstream synchronization is needed):

```powershell
$baseline = Join-Path ([IO.Path]::GetTempPath()) "copilot-baseline-$([guid]::NewGuid())"
[void][IO.Directory]::CreateDirectory($baseline)
git archive --format=tar "--output=$baseline/source.tar" c098f36 modules/Shmuelie.Copilot
if ($LASTEXITCODE -ne 0) { throw 'Baseline archive failed.' }
[System.Formats.Tar.TarFile]::ExtractToDirectory((Join-Path $baseline 'source.tar'), $baseline, $false)
$manifest = Join-Path $baseline 'modules/Shmuelie.Copilot/Shmuelie.Copilot.psd1'
./tests/benchmarks/Measure-CopilotResume.ps1 -BaselineModulePath $manifest `
    -Count 1000,10000 -Scenario CompleteUnrelated,CompleteMatching
```

`Baseline` runs before `Current` on each identical fixture, in separate fresh
processes; neither process retains module state from the other. The baseline
directory belongs to the caller and is not deleted by the benchmark. Per-case
milestones use the information stream; the final success-stream output is JSON.

The script creates and removes its own marked temporary fictional home per case.
Each worker is a fresh `pwsh -NoProfile -NonInteractive` process. `ColdMs` measures
the first discovery **after module import**, including first-use JIT and identity
reader compilation when required; it does not mean cold operating-system disk
cache. `WarmMs` contains three further invocations in that process. Fixture setup,
module import, process startup, and the separate profiling invocation are outside
these latencies. Do not compare runs on differently loaded machines.
The full matrix performs many complete inventory/journal scans and can take a
long time, especially while creating/removing thousands of filesystem entries;
start with the 100-session command for a short exploratory run.

The matrix includes 100, 1,000, and 10,000 directories:

| Scenario | Matching identities | Metadata / recovery |
| --- | --- | --- |
| CompleteUnrelated | 1% | Canonical repository and branch, mostly other branches |
| CompleteMatching | 80% | Canonical repository and branch |
| IncompleteUnrelated | 1% | Missing repository, recovered from lifecycle context; known branch conflicts otherwise |
| IncompleteMatching | 80% | Missing repository, recovered from lifecycle context |
| LegacyMatching | 80% | Organization-less ADO repository, recovered with independent lifecycle hostname evidence |

Incomplete/legacy journals contain a lifecycle record followed by approximately
1 MiB of fictional conversation lines. Hard links share identical journals in
groups of at most 500 (to respect NTFS limits), bounding allocated journal content
to about 21 MiB even at 10,000 sessions, rather than generating a multi-gigabyte
corpus. Workspace files and filesystem metadata require additional space.
The actual identity reader still scans every eligible journal in full. No
application-level metadata/journal/Git cache or scan cutoff is used.

The fictional scope is fixed to `acme/Project/widget` / `feature/topic`; no current
repository Git calls are needed. A fail-closed Git stub proves these particular
complete/lifecycle-resolvable cases require **zero native Git invocations**.
Current-checkout scope discovery is stubbed rather than timed: these numbers
measure inventory-dependent candidate discovery/preparation, not module import,
all launcher policies, prompting/user input, or the entire `Start-Copilot` command.
The optional `RecordedGit` case instead has 80% matching incomplete identities
whose lifecycle context lacks a repository. It initializes one local fictional
repository before timing, with worker-local Git routing/configuration isolated
from the user's environment. A fail-closed wrapper permits only the exact two
recorded-path Git read commands, counts actual native invocations, and never
contacts its fictional origin URL. This case is separate from the default matrix
because native-process startup cost scales with the number of recovering sessions.
Discovery validates the expected match count.

`Profile` reports inclusive function time and calls on a separate invocation:
workspace reads, field extraction/splits, path validation, identity resolution,
lifecycle reads and recorded-origin probes. Nested times must not be added.
`JournalBytes` counts logical source bytes scanned, not physical disk traffic:
the existing streaming identity reader traverses those bytes twice. Enumeration
and sorting are separately timed probes, not subtracted from end-to-end discovery.
Instrumentation/wrapper overhead is deliberately excluded from `ColdMs/WarmMs`.

## Target and results

The initial 100-session baseline identified repeated metadata parsing as the
dominant avoidable cost for complete inventories: six field lookups/splits for
each workspace. Instrumented field extraction took 511–558 ms versus 160–177 ms
for path validation, 17–26 ms for identity resolution, and under 7 ms each for
directory enumeration and sorting. Complete/excluded identities already read
zero journal bytes and invoked no Git. In recovery-dense cases, full journal
scans dominated instead.

The chosen bounded change is a single-pass metadata reader for resume's six
fields. Ordinary unquoted, comment-free scalar text is returned directly after
trimming; quoted/commented values and blocks reuse the existing decoders. It
preserves invariant-culture first-field matching and leaves path validation,
recovery, candidate policy and sorting unchanged. Ordinary listing/completion
retain their existing reader.

The target chosen from that baseline is **at least 40% lower warm-median and 25%
lower fresh-process discovery latency for the 1,000/10,000 complete cases**, with
unchanged workspace/journal/Git work except metadata passes (six to one).
Recovery-dense cases are measured and reported separately, not used to claim
that native conversation loading became faster.

### Final same-fixture target evidence

Measured on Windows / PowerShell 7.6.7 on 2026-10-21 against `c098f36`.
Each baseline/current pair used the **same fictional inventory**, separate fresh
processes, and three repeated invocations per process. No other owned benchmark
or validator ran concurrently. Warm is the median of the three samples; cold is
the first discovery as defined above. Times below are seconds, lower is better.

| Sessions | Scenario | Cold baseline → final | Cold reduction | Warm median baseline → final | Warm reduction |
| --- | --- | --- | --- | --- | --- |
| 1,000 | CompleteUnrelated | 5.516 → 3.125 | 43.35% | 3.040 → 1.736 | 42.91% |
| 1,000 | CompleteMatching | 5.362 → 3.014 | 43.78% | 3.048 → 1.753 | 42.49% |
| 10,000 | CompleteUnrelated | 32.426 → 20.824 | 35.78% | 33.992 → 20.058 | 40.99% |
| 10,000 | CompleteMatching | 37.101 → 20.019 | 46.04% | 35.615 → 19.913 | 44.09% |

**All four cases met the original 40% warm / 25% cold reduction target.**
This is an observed candidate-discovery result, not a guarantee for every
machine or inventory. The raw samples show nontrivial variation; no confidence
interval or native conversation-loading improvement is claimed.

| Work per discovery | Baseline | Final |
| --- | --- | --- |
| Workspace reads, 1,000 sessions | 1,000 | 1,000 |
| Metadata splits/passes, 1,000 sessions | 6,000 | 1,000 |
| Workspace reads, 10,000 sessions | 10,000 | 10,000 |
| Metadata splits/passes, 10,000 sessions | 60,000 | 10,000 |
| Lifecycle reads / logical journal bytes, all four complete cases | 0 / 0 | 0 / 0 |
| Native Git calls in these fixed-scope scans | 0 | 0 |

The work reduction is metadata parsing, **not fewer workspace reads or omitted
sessions**. Separate profiling of the final 10,000-session pairs attributed
18.534–20.566 seconds to baseline field extraction versus 3.549–3.707 seconds
to the final reader. Path validation remained 8.049–8.291 versus
8.041–8.405 seconds, and workspace reading 5.190–5.307 versus 5.012–5.205
seconds. These are inclusive instrumented observations, not additive components
of the uninstrumented table.

### Recovery/context evidence and provenance

[The measurement data](CopilotResume.measurements.json) preserves the actual
cold/repeated samples, work counts, inclusive profiling times, source hashes
and both paired runs. Its run/reader labels matter:

- **`final-paired` / `final`** is the final reader with the plain-scalar fast
  path (workspace source SHA256 in the data). Only this paired run establishes
  the final latency target above.
- **`profiling`** is the original baseline matrix at 100, 1,000 and 10,000
  sessions, all five metadata/match-density cases. Large profiling runs
  overlapped validation and showed substantial host-load variation. They
  identify work/bottlenecks, not a controlled final speed comparison.
- **`prior-context` / `single-pass`** is the earlier single-pass reader before
  the final ordinary-scalar fast path. It covers 100-session complete and
  recovery cases, and 1,000/10,000-session incomplete/legacy cases. It is
  **prior-version recovery/context evidence, not final-reader latency proof**.
  At 10,000 sessions it has one repeated sample, explicitly retained as such.
  Those bounded context runs used `-Repeat 1`; the target run used `-Repeat 3`.
- **`git-smoke`** is the successful same-fixture 100-session recorded-origin
  smoke with that prior reader. Both variants selected 80 identities and
  performed **160 actual native Git reads** per discovery (two per eligible
  session), 80 journal reads and 83,951,120 logical journal bytes. No Git
  acceleration is claimed; required native process startup dominates this case.
- **`initial-paired`** retains the prior-reader paired measurements rather
  than hiding the cases that missed the original warm threshold. It is not
  used as final acceptance evidence.

The recovery observations demonstrate why metadata parsing is not the only
cost in every inventory. At 10,000 sessions, 1%-matching incomplete metadata
required 100 journal reads / 104,933,700 logical bytes; 80%-matching incomplete
and legacy metadata required 8,000 reads / 8,394,696,000 and 8,395,120,000 bytes.
Those counts were identical before and after the single-pass change. The final
scalar fast path does not change the identity/journal/Git implementation.
Deterministic final-source tests pin that equivalence and the complete/excluded
identity work-avoidance boundaries; the prior context timings are not relabeled
as measurements of the final scalar fast path.

Necessary lifecycle recovery still scans the full journal, and surviving
recorded-origin recovery still invokes Git when independent evidence is needed.
No cache, size/age/count/time cutoff, current-scope identity borrowing or
history/database mutation is introduced to make the numbers smaller.

The canonical [Copilot tests](../Shmuelie.Copilot.Tests.ps1) assert exact decoded
values, ordered candidates, selector/bypass behavior and avoided work. They do
not assert elapsed time. Use this benchmark separately for performance evidence.
