# Shmuelie.DevTunnel

**Version:** 0.1.0

PowerShell 7.4+ wrappers for the Microsoft `devtunnel` CLI on Windows, Linux,
and macOS. Install the CLI separately using Microsoft's
[getting-started guide](https://learn.microsoft.com/azure/developer/dev-tunnels/get-started),
then put the native executable on `PATH`.

```powershell
Install-PSResource Shmuelie.DevTunnel
Import-Module Shmuelie.DevTunnel
Get-DevTunnelVersion
Connect-DevTunnelAccount -GitHub -DeviceCode
```

## Supported CLI contract

The command/flag mapping was verified against **1.0.2115**. This module requires
that version or a compatible **1.x** version; older and new major versions are
rejected. The CLI itself remains in preview, so compatibility with later 1.x
builds is subject to upstream changes. Unlike older examples in the
[CLI reference](https://learn.microsoft.com/azure/developer/dev-tunnels/cli-commands),
this version uses `--labels`, `--add-labels`, and `--remove-labels`, not tags.

Import does not discover or execute the CLI, authenticate, install anything, or
make network calls. Each real operation resolves the executable and checks its
version. On Windows this reads local product-version metadata; where metadata
is unavailable it runs `devtunnel --version`, which may query the service.
Windows `.cmd`/`.bat` shims are deliberately rejected: use the native executable.
Arguments are passed directly without evaluating shell command strings.

## Commands

| Cmdlet | CLI mapping | Output |
|---|---|---|
| `Get-DevTunnelVersion` | Local metadata or `--version` | `Version` and `Path` object |
| `Connect-DevTunnelAccount` | `user login` | Streaming CLI text/instructions |
| `Disconnect-DevTunnelAccount` | `user logout --json` | CLI JSON |
| `Get-DevTunnelAccount` | `user show --json` | CLI JSON |
| `Get-DevTunnel` | `list --json`; `show [ID] --json` with `-TunnelId`/`-LastUsed` | CLI JSON |
| `New-DevTunnel` | `create [ID] --json` | CLI JSON |
| `Set-DevTunnel` | `update [ID] --json` | CLI JSON |
| `Remove-DevTunnel` | `delete [ID] --force --json`; `delete-all` with `-All` | CLI JSON |
| `Start-DevTunnel` | `host [ID]` | Streaming CLI text |
| `Connect-DevTunnel` | `connect [ID]` | Streaming CLI text |
| `Get-DevTunnelPort` | `port list [ID] --json`; `port show` with `-PortNumber` | CLI JSON |
| `New-DevTunnelPort` | `port create [ID] --json` | CLI JSON |
| `Set-DevTunnelPort` | `port update [ID] --json` | CLI JSON |
| `Remove-DevTunnelPort` | `port delete [ID] --json` | CLI JSON |
| `Get-DevTunnelAccess` | `access list [ID] --json` | CLI JSON |
| `Add-DevTunnelAccess` | `access create [ID] --json` | CLI JSON |
| `Remove-DevTunnelAccess` | `access delete [ID] --json` | CLI JSON |
| `Reset-DevTunnelAccess` | `access reset [ID] --json` | CLI JSON |
| `New-DevTunnelToken` | `token [ID] --json` | CLI JSON containing a secret |
| `Set-DevTunnelDefault` | `set ID --json` | CLI JSON |
| `Clear-DevTunnelDefault` | `unset --json` | CLI JSON |
| `Get-DevTunnelCluster` | `clusters --json` | CLI JSON |
| `Get-DevTunnelLimit` | `limits --json` | CLI JSON |
| `Start-DevTunnelEcho` | `echo PROTOCOL --port=N --interface=ADDRESS` | Streaming CLI text |
| `Test-DevTunnel` | `ping URI` | Streaming CLI text, **not a Boolean** |

JSON is converted to PowerShell objects without reshaping the CLI schema.
For example, `(Get-DevTunnelCluster).clusters` contains the cluster records.
Empty CLI output produces no object. Malformed JSON and nonzero exit codes
terminate with an error, not an empty success result. Non-sensitive failures
include stderr; captured authentication/token failures omit output to avoid
echoing secrets. Foreground authentication instructions are streamed immediately,
with recognizable bearer, JWT, GitHub, and named token/secret values redacted
before emission. A later login failure cannot retract instructions already
displayed; its error does not replay them. Successful management stderr is
surfaced as a warning.

The initial surface intentionally does not forward arbitrary arguments,
access-token inputs, service-principal/managed-identity authentication, header
rewrites, certificate/password inputs, or request-timeout options. Use the CLI
directly when those advanced options are needed. No module credential store or
automatic login is introduced.

## Parameters and defaults

Use `Get-Help <cmdlet> -Full` for syntax and examples. Main parameter mappings:

| PowerShell parameter | CLI option |
|---|---|
| `TunnelId` (`Id` alias; property-name pipeline input on management cmdlets) | Positional ID |
| `PortNumber` | `--port-number` (repeated for hosting multiple ports) |
| `Protocol` | `--protocol` for host/create-port; positional for echo |
| `Description`, `Expiration` | `--description`, `--expiration` |
| `Label`, `AllLabel` | `--labels`, `--all-labels` |
| `AddLabel`, `RemoveLabel` | `--add-labels`, `--remove-labels` |
| `Limit`, `Scope`, `Index` | `--limit`, `--scopes`, `--index` |
| `GitHub`, `DeviceCode` | `--github`, `--use-device-code-auth` |
| `AllowAnonymous` | `--allow-anonymous` |
| `Anonymous`, `Tenant`, `Organization`, `Repository` | One explicit access-rule subject |
| `Deny` | `--deny` |
| `Ping` | `--ping` for cluster latency |
| `Size`, `Interval` | Ping message bytes and interval milliseconds |

Ports must be 1-65535. Expiration accepts whole hours from `1h` through `720h`
or whole days from `1d` through `30d`. Scope values are `create`, `manage`,
`manage:ports`, `host`, `inspect`, or `connect`. Access indices are zero-based.
The CLI owns any additional service-side validation.

Except for creating and hosting new tunnels, an omitted ID uses the CLI's
last-used tunnel. `Get-DevTunnel` lists by default; `-LastUsed` explicitly shows
that tunnel. `Set-DevTunnelDefault` changes the CLI's selection, not a
module-private setting. Use explicit IDs in automation to avoid shared CLI
state surprises.

All state-changing and foreground commands use `SupportsShouldProcess`.
`-WhatIf` performs no executable discovery, version check, login, or operation.
Deletion (including `-All`) and access reset use high-impact confirmation;
use `-Confirm:$false` only for intentional unattended changes. `Remove-DevTunnel`
adds the CLI's `--force` only after PowerShell confirmation to avoid a second,
CLI-owned prompt; it does not bypass PowerShell confirmation.

## Persistent tunnel workflow

Run your service locally before hosting its port:

```powershell
Connect-DevTunnelAccount
New-DevTunnel -TunnelId my-web-tunnel -Description 'Local development' -Label web -Expiration 1d
New-DevTunnelPort -TunnelId my-web-tunnel -PortNumber 3000 -Protocol http
Get-DevTunnel -TunnelId my-web-tunnel
Start-DevTunnel -TunnelId my-web-tunnel
# Cancel hosting before removing resources.
Remove-DevTunnel -TunnelId my-web-tunnel
```

From a different client with authorized CLI credentials:

```powershell
Connect-DevTunnelAccount
Connect-DevTunnel -TunnelId my-web-tunnel
# Access the forwarded localhost port; cancel to stop forwarding.
```

## Temporary hosting and access

```powershell
Start-DevTunnel -PortNumber 3000, 5000 -Protocol http -Expiration 1h
```

Omitting the host ID creates a **new temporary** tunnel; it does not host the
last-used persistent tunnel. Authentication remains required by default.
`-AllowAnonymous` or an explicit `Add-DevTunnelAccess -Anonymous` is an opt-in
that emits a warning: anyone on the internet who knows the address can reach
the exposed service. Never use it on a service that is unsafe to expose.
`Add-DevTunnelAccess` requires exactly one subject; `-Deny` creates a deny rule.
Capture `New-DevTunnelToken` output only into a suitably protected destination;
its JSON contains a credential. Do not write it to transcripts or logs.

## Foreground lifetime and diagnostics

Hosting, connecting, login instructions, echo servers, and ping messages stream
CLI stdout as text; stderr instructions/status use the information stream.
There is no background mode. Cancel the PowerShell pipeline (normally Ctrl+C)
to stop the invocation. Cleanup terminates and waits for only its owned process
tree; unrelated CLI instances are not touched. Management/version commands close
stdin and have a 60-second timeout. Authentication is explicit and uses the CLI
browser/device-code flow, not a module-owned stdin prompt.
Device-code instructions intentionally display a short-lived user code. Avoid
transcribing login sessions or publishing their output. Redaction covers known
credential formats, not arbitrary changes to a future CLI's text; only run a
trusted CLI from `PATH`.

The CLI normally deletes a temporary tunnel on graceful host exit. Pipeline
cancellation can forcefully terminate the process, so service-side deletion is
**not guaranteed**. Set a short expiration or remove the recorded tunnel ID
explicitly afterward. Persistent tunnels remain configured until deleted.

```powershell
Get-DevTunnelCluster -Ping
Get-DevTunnelLimit
Start-DevTunnelEcho -PortNumber 8080  # loopback-only unless Interface is explicit
# In another terminal:
Test-DevTunnel -Uri http://localhost:8080 -Size 64 -Interval 1000
```

## Validation

```powershell
.\build\Build-Module.ps1 -Module Shmuelie.DevTunnel
.\build\Invoke-Tests.ps1 -Path tests\Shmuelie.DevTunnel.Tests.ps1
```

Tests use isolated mocks/fake processes, never real accounts, tunnels, or exposed
network services.

Shared bash behavior is tracked separately in
[shmuelie/bash-scripts#83](https://github.com/shmuelie/bash-scripts/issues/83).
