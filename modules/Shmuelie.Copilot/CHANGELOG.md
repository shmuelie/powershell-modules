# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/).
Versions change only when a release is cut; unreleased work stays under
`[Unreleased]`.

## [Unreleased]

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
