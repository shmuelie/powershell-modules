# Changelog

Unpublished development only; no Gallery release is authorized.

## [Unreleased]

### Added
- Experimental compiled `Wait-AppInstallItem` for one exact retained caller item,
  using only payload-free manager-event invalidation, an explicit context and a
  mandatory 1-30 second local budget. Captures are execution-thread-only, bounded
  to 64 observations and returned after cleanup; local cancellation never cancels
  installation. Observation leases preserve exact identities without altering
  inventory pruning/search merging and defer disposed-context manager release
  until unsubscribe completes. Primary and cleanup failures remain explicit;
  group completion, individual-item events, broader scope and release remain
  gated. The private-capability restriction and #233 support hold remain in force.
- Experimental compiled `Request-AppInstallUpdateSearch` for only caller-scoped
  all-app searches through an explicit context and caller-provided correlation
  inputs. Both automatic download/install and forced restart are fixed false;
  discovered updates can still be queued paused, so high-impact `ShouldProcess`
  protects every submission and `-WhatIf` performs no native calls. Immutable
  request/item identities distinguish acceptance, search completion and install
  status; failures preserve original errors and stopping only ends local waiting.
  Default request display omits native correlation strings and raw payloads;
  explicit property inspection and JSON retain the original values.
  Search identities merge without pruning unrelated inventory. Per-app, ForUser,
  custom catalog and automatic-action variants remain gated; empirical access
  is not an official third-party support guarantee.
- Experimental compiled `Get-AppInstallItem` for caller-scoped queue/current
  status snapshots through an explicit AppInstall context, with exact filters,
  optional grouped children, bounded local identity tracking, explicit member
  availability and preserved native errors. No search, install, settings,
  entitlement, queue-control or ForUser operation is performed.
- Experimental compiled `Get-AppInstallSettings` for the three approved
  caller-context getters, using an explicit lazy context. The default reads
  only device auto-update and calling-process all-user privilege observations;
  acquisition identity requires an exact opt-in property selector. Immutable
  snapshots retain scope, requested/read properties, raw enum codes and
  unknown/unavailable/false distinctions. Failures preserve original errors
  without rendering raw native diagnostics or returning a partial snapshot.
  No settings mutation, identity change or installation action is provided.
- Experimental compiled `New-AppInstallContext` factory with explicit lazy
  manager ownership, caller scope, runspace-bound lifetime and deterministic
  disposal. Creating a context performs no native activation or search. The
  documented private-capability restriction remains applicable; observed
  runtime access is not an official third-party support guarantee.
- Immutable AppInstall identity/group, status, request, entitlement and error
  contracts with explicit unknown/unavailable observations. Native HRESULTs,
  original exceptions, local/native cancellation and secondary cleanup errors
  remain distinct; no install completion is inferred from request completion.
- A complete AppInstallManager API/options matrix documenting the deferred,
  gated and retired families without exporting their commands.
