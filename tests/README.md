# Tests

[Pester](https://pester.dev/) v5 unit tests for the modules in this repository.

## Layout

One `*.Tests.ps1` file per module. Each file imports the module directly from
`modules/<Module>/<Module>.psd1` (source, not a built artifact) so tests run
without a full build.

- `Shmuelie.Git.Tests.ps1` — table-driven `Get-GitStatusSummary` coverage against
  real temporary git repositories (non-repo, clean, staged/working/untracked
  changes, and ahead-of-upstream tracking), plus `Format-GitStatusSegment`
  rendering (relation indicators, index/working/conflict counts, untracked
  folding, and `-ShowChangeCounts:$false`) driven by synthetic summaries.
- `Shmuelie.Utilities.Tests.ps1` — pure helpers (`Test-IsElevated`,
  `Get-SessionTitle`, `New-GlobalConstant`, `New-PathVariable`,
  `Import-ModuleSafe`, `Invoke-InLocation`) and `Format-Duration` boundary/
  rounding cases.
- `Shmuelie.PackageManagement.Tests.ps1` - deterministic fake-provider coverage
  for selection, options, lazy dependencies, result preservation, failures,
  fail-fast control, previews, and confirmation, plus mocked canonical DotNet
  provider discovery, options, per-tool updates, and observed-version outcomes.
- `Shmuelie.DotNet.Tests.ps1` - canonical .NET tool parsing, parameter and
  pipeline contracts, scope selection, typed results, failure reporting,
  `ShouldProcess`, isolated import, and publishable module layout.
- `Invoke-Tests.Tests.ps1` - supported Pester version selection, bounded
  installation fallback, runner configuration, and failure propagation.
  Module discovery, installation, imports, and test execution are mocked.

## Running

```powershell
./build/Invoke-Tests.ps1                       # whole suite
./build/Invoke-Tests.ps1 -Path tests/Shmuelie.Git.Tests.ps1   # one file
```

The runner selects the newest installed Pester `>=5.2.0` and `<6.0.0`,
installing within that same range if needed. Pester 6 and later do not take
precedence. The runner fails on any failing test. CI runs it in
`.github/workflows/ci.yml`, and it gates publishing in
`.github/workflows/publish-module.yml`.
