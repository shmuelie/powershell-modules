# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/).
Versions change only when a release is cut; unreleased work stays under
`[Unreleased]`.

## [Unreleased]

### Fixed
- Workspace field lookup and replacement now skip literal and folded block
  bodies, so field-looking text in a multiline session name or summary cannot
  replace or mask real metadata. Renaming retains the full multiline text,
  existing field indentation, and line-ending style; discovery and filters keep
  the recorded branch, working directory, and timestamps. (#285)
- `Get-CopilotLaunchPlan` and `Start-Copilot` now apply `-ChangeDir` / `-C`
  before session, branch, and MCP path-policy planning. Relative paths resolve
  from the caller's location and normal plans forward an absolute native `-C`
  path. Invalid directories terminate before launch; planning restores the
  caller's location even on errors, without changing selection, confirmation,
  preview, or help/update passthrough contracts. (#283)
- Plugin and marketplace discovery now reports native failures with exit codes
  and CLI diagnostics before parsing, supports `-ErrorAction Stop`, and preserves
  the caller's native exit status and console encoding. Failed discovery emits no
  inventory objects, unlike successful empty responses which remain error-free.
  Missing or invalid native completion evidence also fails closed.
  Install/register existence checks stop on discovery failure instead of mutating
  based on an apparently empty inventory. (#281)

## [0.5.0] - 2026-09-18

### Changed
- Session selection now uses the active PowerShell host's `PromptForChoice`,
  without automatic grid pickers or custom console input loops. The initial host
  message shows numbered names capped at 80 Unicode text elements, with branches
  only for duplicated displayed names. Numeric labels stay unique beyond nine
  choices; help retains full names and context. Names and branches have terminal
  controls sanitized without changing identity; no default is selected. Global
  Cancel and launch New session remain distinct, and host failures or invalid responses
  terminate without launching. Custom selectors, explicit bypasses, and standard
  PowerShell confirmation/preview behavior are unchanged. (#304)

### Fixed
- `Repair-CopilotSessionEvents` now filters malformed events before relocation,
  preventing empty-ID or unknown-model completions from being reinserted and
  suppressing valid replacement completions. Already-valid raw tool events and
  the existing synthesis and backup policies are preserved. (#284)
- `Merge-CopilotSession` now preserves checkpoint bodies alongside the merged
  index, retaining file references while renumbering rows. The generated root
  index is excluded from body collision checks; differing bodies and type
  conflicts still abort. Missing/unsupported references, failed copies, and
  index/body read-back failures terminate before any source is removed.
- `Merge-CopilotSession` now preflights files, research, and rewind backup paths
  and aborts conflicting merges before creating a destination or removing any
  sources. Overlapping files with different contents and file/directory conflicts
  are rejected without renaming; identical regular-file copies remain supported
  after SHA-256 comparison, with read/hash failures terminating the merge.
  Literal-path handling includes hidden artifacts and nested rewind backups;
  artifact links/reparse points are rejected rather than traversed.
- `Compress-CopilotSession` and file-backed `Repair-CopilotSessionEvents` stop
  before rewriting events when a required backup fails, even under `Continue`.
  Backup copies are staged before replacing an existing backup; failed copies
  preserve the prior backup and original events. `-NoBackup` remains explicit. (#280)
- `Merge-CopilotSession` now aborts required source-read and destination
  create/copy/write/repair failures even under `-ErrorAction Continue`, before
  removing any source sessions. Partial-destination cleanup failures are reported
  without replacing the original error or changing the caller's preferences.

## [0.4.0] - 2026-09-10

### Added
- `Start-Copilot`, `Get-CopilotLaunchPlan`, and `Select-CopilotSession` accept
  `-SessionSelector` callbacks over typed session candidates without a UI
  dependency. Selection preserves existing resume heuristics and launch flags;
  null/new-session/cancellation behavior and invalid-result errors are explicit.
- `Get-CopilotSession` supports composable wildcard Repository, Branch, Cwd, and
  Summary filters plus exclusive UpdatedBefore and positive elapsed OlderThan
  filters. Existing local discovery and exact ID lookup remain unchanged;
  explicit Cwd replaces the implicit directory scope, and All searches globally.
  Missing timestamps never qualify for age-based cleanup.

### Changed
- Built-in session pickers report unavailable interactive input or host prompt
  errors instead of retrying indefinitely. The existing numeric launcher picker
  and grid-first `Select-CopilotSession` picker remain the defaults.
- `Select-CopilotSession` reuses shared session matching, adds Cwd, Summary, and
  age filters, and retains global discovery, wildcard IDs, and newest-first
  selection. Discovery help documents timezone, missing metadata, and safe
  cleanup pipeline semantics.

## [0.3.2] - 2026-09-08

### Fixed
- `Register-CopilotMcpServer` and `Unregister-CopilotMcpServer` now refuse native
  mutations of a symbolic-link-managed `~/.copilot/mcp-config.json`, including
  relative, chained, dangling links, and pipeline removals. The actionable error
  directs users to manage the target instead of allowing the CLI to replace the
  link. Regular configurations retain native behavior and validation; `-WhatIf`
  and `-Confirm` remain supported.

## [0.3.1] - 2026-08-27

### Fixed
- `Get-CopilotSession -Id`, `Remove-CopilotSession`, and `Rename-CopilotSession`
  now validate the session ID through one canonical session-state guard that
  rejects path separators, rooted paths, drive qualifiers, and `.`/`..`
  segments, and confirms the resolved directory is a direct child of the
  session-state root. `Remove`/`Rename` re-resolve the target by ID instead of
  trusting a pipeline object's `Path`, so a crafted ID or `InputObject` can no
  longer read, rewrite, or recursively delete directories outside
  `~/.copilot/session-state`.
- `Merge-CopilotSession` now removes the partially written destination session
  when a merge fails part-way through (JSON parse, timestamp, copy, or repair
  errors), instead of leaving a broken session behind. Source sessions are still
  removed only after the destination completes successfully, and a cleanup
  failure is surfaced as a warning without masking the original error.

## [0.3.0] - 2026-08-25

### Added
- `Start-Copilot` / `Get-CopilotLaunchPlan` gained `-AssistedApproval`
  (`--assisted-approval`), `-AllowAllTools` (`--allow-all-tools`, which implies
  not passing `--allow-all`), and `-UsageOutputFile` (`--usage-output-file`).
- `-EnableMcpServer` now also passes the CLI's native `--enable-mcp-server`, so a
  server disabled in the Copilot settings is enabled for the run — in addition
  to overriding the path-based `autoConnect` policy.

## [0.2.0] - 2026-08-21

### Added
- `Select-CopilotSession` resumes a session chosen from all Copilot sessions on
  the machine, with scriptable filters and a picker fallback.

## [0.1.3] - 2026-08-20

### Added
- Pester coverage for destructive Copilot session merge, compact, and repair
  maintenance cmdlets.
- Pester coverage for Copilot session, plugin, marketplace, and MCP lifecycle
  cmdlets that shell out to the Copilot CLI.

### Changed
- Copilot session workspace metadata parsing and rewriting now share one internal
  workspace.yaml helper that handles quoted and block scalar values.

### Fixed
- `Get-CopilotPlugin`, `Get-CopilotMarketplace`, and
  `Get-CopilotMarketplacePlugin` now decode Copilot CLI output as UTF-8 even
  when the host console uses a legacy code page.
- `Merge-CopilotSession` now preserves checkpoint numbers when renumbering
  merged checkpoint indexes.
- `Start-Copilot -WhatIf` now defers session resume while rendering the dry-run
  command line, so it never opens the interactive resume picker.

## [0.1.2] - 2026-08-14

### Fixed
- Copilot session and MCP config lookups now resolve the home directory
  cross-platform instead of using Windows-only `$env:USERPROFILE`.

### Security
- Validate plugin, marketplace, and MCP values before forwarding them to the
  `copilot` CLI shim so cmd.exe metacharacters are rejected instead of invoked.

## [0.1.1] - 2026-08-12

### Fixed
- `Get-CopilotLaunchPlan -SessionId` no longer triggers the automatic
  session-resume picker or emits a conflicting `--resume` alongside
  `--session-id`. Passing an explicit session UUID is now treated as intent for
  that session, so the auto-resume heuristic is skipped. The `-SessionId` help
  now clarifies it maps to `--session-id` (and points to `-ResumeSession` for
  id-based resume), and documents that combining both emits `--resume` (from
  `-ResumeSession`) and `--session-id` (from `-SessionId`).

## [0.1.0] - 2026-08-05

### Added
- Initial `Shmuelie.Copilot`: GitHub Copilot CLI session, plugin, marketplace,
  and MCP helpers, plus the `Start-Copilot` launcher with session resume, safe
  git deny rules, full flag mapping, and terminal recovery.
- `Start-Copilot -PassThru` returns the resolved launch plan (`Exe`, `Args`,
  `Passthrough`) without launching, so other tools can reuse the built arguments
  and the session-resume decision.
- `Get-CopilotLaunchPlan` computes that launch plan directly. It is the shared
  core `Start-Copilot` delegates to, so an overlay can build identical command
  lines by calling it (instead of shadowing and re-invoking `Start-Copilot`).
- `Start-Copilot -DeferResume` skips the automatic session-resume decision (no
  picker, no `--resume`), so a `-PassThru` overlay can own session selection.
- `Start-Copilot -NoDefaultDenyTools` opts out of the built-in destructive-git
  deny rules for workflows that rely on rebase, `git pull`, amend, and similar.

### Fixed
- `Start-Copilot -Remote:$false` no longer emits `--remote`. The launcher tested
  parameter presence instead of the switch value, so explicitly forcing the flag
  off still passed `--remote`.

### Notes
- Depends only on the public `copilot` CLI.
