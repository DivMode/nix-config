# Tandem + Herdr bootstrap and recovery

This runbook is the fallback path for the local AI-control stack while the fully
declarative Nix module is being completed.

The intended steady state is:

```text
ChatGPT Web
  -> OpenAI Secure MCP Tunnel
  -> tunnel-client on the Mac
  -> Tandem stdio MCP
  -> Herdr native session backend
  -> Claude Code / Codex
```

For these hosts, **Herdr owns agent terminals and session state**. Tandem is the
MCP/session-control facade. Do not install or require tmux just for Tandem, and
do not add Tailscale for the single-Mac ChatGPT path.

## Source policy

The production configuration must use a DivMode-managed fork of
`Maxmedawar/tandem` with the Herdr backend committed and tested. Nix must pin an
exact fork commit; it must not fetch a moving branch at activation time.

Until that fork and Nix module are merged, an uncommitted or manually patched
checkout is proof-only and must not be treated as a fresh-machine install path.

The successful proof began from Tandem upstream `0.1.0` at
`a98bcafd2c40ae5473b85fe41183e4f391933799`. Revalidate the fork before using
that value as a package baseline.

## Ownership boundaries

Nix/Home Manager should eventually own:

- the pinned Tandem package/source;
- the Tandem terminal backend selection (`herdr`);
- non-secret static Tandem configuration;
- the OpenAI `tunnel-client` binary;
- launchd startup for the tunnel runtime when protected prerequisites exist;
- Herdr's declarative agent integration hooks;
- health/status helper commands.

Runtime/application state should own:

- ChatGPT custom-app installation and approval state;
- Herdr workspaces, panes, and native agent sessions;
- Tandem mutable session data;
- tunnel runtime state;
- OAuth/session state.

Never put API keys, tunnel identifiers, workspace identifiers, account details,
private checkout names, or private filesystem paths in this repository or the
Nix store. Keep machine-specific values in the repository's ignored local
configuration and secrets in protected runtime files.

## Fresh-Mac check

After the normal Nix bootstrap/rebuild, verify these in order.

### 1. Herdr

```bash
herdr --version
herdr status
herdr agent list
```

Herdr should already be running and should recognize the installed coding
agents. The final declarative configuration should also preserve the Claude Code
and Codex native-session identity integrations.

If an agent is visible in Herdr, prefer Herdr's own control surface over terminal
screen scraping:

```bash
herdr agent list
herdr agent read <agent>
herdr agent focus <agent>
```

Use `herdr --help` / `herdr agent --help` when the installed release changes a
CLI spelling. Herdr's local socket API is the authority for automation.

### 2. Tandem fork

The final Nix package should expose the pinned DivMode Tandem build without a
manual checkout. Verify the installed package/source identity with the wrapper
or package metadata provided by the module.

Required runtime policy:

```text
terminal backend: herdr
Claude: enabled
Codex: enabled only after its native-harness smoke passes
shell: disabled
permission bypass: disabled
cwd allowlist: explicit local paths only
```

The cwd allowlist must never default to `$HOME`, `/`, or a filesystem scan.

### 3. Protected Tandem configuration

The generated runtime configuration must be user-owned and protected (normally
`0600`) and live outside tracked source. Inspect names/permissions only; do not
print secret-bearing files into logs or issues.

The configuration must select the Herdr backend and contain only non-secret
runtime settings. Tunnel credentials belong to the tunnel runtime, not Tandem.

### 4. OpenAI Secure MCP Tunnel

The ChatGPT path uses an outbound Secure MCP Tunnel rather than a public listener:

```text
ChatGPT -> OpenAI control plane <- outbound tunnel-client -> Tandem stdio
```

No public inbound port is required on the Mac.

Verify the installed client and managed runtime using the official client
commands available in the installed release. The proof environment used checks
such as:

```bash
tunnel-client doctor --explain
```

and the runtime health endpoints:

```text
/healthz
/readyz
```

The production Nix module should provide a stable `tandem-status` or equivalent
wrapper so users do not need to remember internal runtime aliases.

Never put the runtime API key directly on a command line. Use a protected
`file:`/environment reference supported by `tunnel-client`.

### 5. launchd

The declarative module should install a per-user launchd service that starts the
managed tunnel runtime after login when all protected prerequisites exist.

A missing secret/runtime reference must fail visibly instead of falling back to
a public listener or silently running an insecure configuration.

The service should be restartable and observable through a small wrapper such as:

```text
tandem-status
tandem-doctor
tandem-restart
```

Those wrapper names are the desired UX; the implementation issue may adjust them
only to match established repository conventions.

## One-time ChatGPT-side setup

This is the part that may remain intentionally manual because it belongs to the
ChatGPT account rather than machine configuration.

After the tunnel runtime is healthy:

1. Open ChatGPT Settings.
2. Enable Developer Mode if it is not already enabled.
3. Create/add a custom App/Connector.
4. Choose **Tunnel** as the connection type.
5. Select the Tandem tunnel associated with the intended workspace.
6. Scan/refresh the tool surface.
7. Name it clearly (for example `Tandem`).
8. Set the app-specific action permission deliberately. For unattended agent
   steering, the expected mode is **Allow all actions**; use a stricter mode if
   that is the operator's intent.
9. Start a new ChatGPT conversation after tool metadata changes so the current
   tool inventory is refreshed.

Do not store the tunnel id or ChatGPT account/workspace identifiers in this
repository.

## End-to-end smoke

From a new ChatGPT conversation with Tandem enabled:

1. Call `list_devices`.
2. Call `list_sessions`.
3. Open a Claude session in an explicitly allowed disposable working directory.
4. Send `Reply with exactly: TANDEM CLAUDE OK`.
5. If the turn is still running, poll the same session instead of resending the
   instruction.
6. Send a second instruction to the **same** session and verify continuity.
7. Open Herdr and confirm the same agent/session is visible there.
8. Close only the Tandem-owned proof session/workspace when finished.

After the Claude path passes, repeat with `engine=codex` and verify that Codex
still has its native Codex harness, project instructions, configured MCP/apps,
and normal local tool surface. Herdr manages the PTY/session; it does not replace
Codex's internal harness.

## Watching and debugging a live session

GitHub is **not** the live message bus.

Live communication is:

```text
ChatGPT <-> Tandem <-> Herdr <-> coding agent
```

Tandem reads agent output through the Herdr backend and returns it directly to
ChatGPT. Herdr remains the human-visible terminal/session UI, so the operator can
watch or focus the same Claude/Codex pane without copying its output through
GitHub.

GitHub should hold durable engineering state such as issues, commits, pull
requests, exact SHAs, and review results — not every agent message or terminal
line.

When debugging:

```bash
herdr status
herdr agent list
herdr pane list
```

Use Herdr's `agent read`, `pane read`, and wait/status commands for the affected
agent. Use Tandem's `list_sessions` / `send_to_session` from the MCP side to prove
that both views refer to the same owned session.

## Recovery sequence

If ChatGPT says Tandem tools are unavailable:

1. Confirm the Tandem app is installed/enabled in ChatGPT.
2. Start a **new** conversation after connector/tool changes.
3. Verify the app's action permission.
4. Verify the tunnel runtime health/ready state on the Mac.
5. Run `tunnel-client doctor --explain` (or the Nix wrapper once available).
6. Verify Herdr is running.
7. Verify Tandem is configured for `herdr` and the intended cwd is allowlisted.
8. Confirm Claude/Codex are available to Herdr.
9. Re-scan/refresh the ChatGPT App tools only after the local runtime is healthy.

If Tandem can list sessions but cannot drive an agent, inspect Herdr's semantic
state and native session identity before changing Tandem. Do not add tmux as a
fallback.

## Disable / rollback

A rollback must be reversible and must not delete Herdr user sessions or agent
history.

Preferred order:

1. Disable the ChatGPT Tandem app/connector if remote control should stop.
2. Stop/disable the Tandem tunnel launchd service.
3. Leave Herdr running unless Herdr itself is being rolled back.
4. Revert the nix-config Tandem module/package pin.
5. Rebuild with the repository's normal rebuild script.

Do not delete protected runtime state or credentials as part of a normal config
rollback. Credential rotation/removal is a separate explicit operation.

## Implementation tracking

The declarative package/service work is tracked in the repository issue titled
`ai(tandem): package Herdr-backed Tandem and auto-start Secure MCP Tunnel`.

The issue is complete only when a fresh Mac can obtain the pinned Tandem fork and
runtime services through the normal Nix flow, with this README covering only the
unavoidable account-side step and emergency recovery.