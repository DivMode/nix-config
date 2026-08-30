# Tandem + Herdr

ChatGPT drives this Mac's coding agents through Tandem. Herdr owns the
terminals; Tandem is only the MCP facade in front of it.

```text
ChatGPT Web
  → OpenAI Secure MCP Tunnel (outbound only, no inbound listener)
  → tunnel-client, started by launchd
  → Tandem stdio MCP, from the pinned DivMode fork
  → Herdr native session backend
  → Claude Code / Codex
```

Two things this path deliberately does **not** use:

- **tmux.** Upstream Tandem hard-codes its session lifecycle to tmux. The fork
  adds a `herdr` terminal backend instead, so no second multiplexer is
  installed and Herdr stays the authoritative PTY and session runtime.
- **Tailscale.** Upstream's `hub` mode couples browser MCP exposure to a
  Tailscale Funnel. The Secure MCP Tunnel is outbound-only, so nothing on this
  Mac listens on a public port and no tailnet is needed for the single-Mac
  ChatGPT path.

`modules/home/ai/tandem/` implements all of it. This file is the operator
runbook: what to check, in what order, and what to do when it is broken. The
design record behind it — roles and authority, the two bootstrap channels,
session and interruption discipline, the reviewer hierarchy, and why no MCP
server can wake a dormant chat client — is
[`../../docs/orchestration-architecture.md`](../../docs/orchestration-architecture.md).

## Who tells ChatGPT how to orchestrate

Two audiences, two channels, and they are not the same document.

**Local workers** — Claude Code and Codex on this Mac — read the Nix-managed
global instruction files, `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`, both
rendered from `ai/instructions/` (see [`../README.md`](../README.md)).

**ChatGPT on the web** reads neither: they are local files, and a browser
session cannot see them. It is briefed by **Tandem over MCP** instead. The
server returns an orchestration brief as the `initialize` result's
`instructions` and serves the full versioned policy from its
`get_orchestration_policy` tool, while enforcing the session, polling, and
model-routing rules server-side regardless of what any client read. The pinned
revision serves policy **v1.2.0**, which carries the reviewer-of-record,
no-monitor-only-sessions, and foreman-event reconciliation rules alongside the
session and model-routing ones.

So Tandem is not merely the session bus for a remote foreman; at this revision
it is also the only thing that tells one how to behave. Keeping the two
documents saying the same thing is manual: the checks in this repository can
only hold up the local side. The procedure for that, and the reasoning behind
the split, is in
[`../../docs/orchestration-architecture.md`](../../docs/orchestration-architecture.md).

## Source policy

The package is built from a **DivMode-managed fork** of `Maxmedawar/tandem`,
pinned in `flake.nix` to an **exact commit**, never to a branch:

```sh
nix flake metadata --json | jq -r '.locks.nodes.tandem.locked.rev'
```

Upstream is preserved as the fork's `upstream` remote. Moving Tandem means
editing that revision deliberately and re-running the fork's typecheck and
tests against the new commit — `nix flake update` cannot move it, which is the
point for the component that lets a remote model open sessions here.

## Ownership boundaries

Nix and Home Manager own:

- the pinned Tandem source and its Node runtime;
- the `tunnel-client` binary, with the `cloudflared` it was released with
  kept beside it in `libexec` and off `PATH`, so it cannot shadow the
  `cloudflared` the deploy path already declares;
- Tandem's protected runtime configuration — non-secret settings only;
- the `herdr` terminal-backend selection;
- the launchd agent for the tunnel runtime;
- the `tandem-status`, `tandem-doctor`, and `tandem-restart` wrappers.

Applications and runtime state own:

- the ChatGPT-side custom app and its approval — account state, not machine
  configuration;
- Herdr workspaces, panes, and native Claude/Codex session identity;
- Tandem's mutable session inventory;
- tunnel runtime state under `~/Library/Application Support/tunnel-client`;
- OAuth and login sessions.

The runtime API key is in neither list, because this repository never handles
it. Nix stores the **path** it is read from; the file itself is yours to
create.

Three things this module explicitly does **not** do, each considered and
rejected rather than merely left out:

- **It installs, builds, and vendors no coding agent.** Claude Code comes from
  `modules/home/development.nix`; Codex is whatever the host already has. No
  agent is compiled from source here, and no release stream of someone else's
  becomes this repository's problem.
- **It changes no global `PATH`.** `home.packages` adds Tandem, `tunnel-client`,
  and the wrappers. `workspacePath` is handed to Herdr as
  `workspace.create.env.PATH` for Tandem's own disposable workspaces only, so
  an agent Tandem can see does not thereby appear in your shell.
- **It touches no Herdr configuration, plugin, or session.**
  `modules/home/herdr/` owns those. Tandem attaches to a session that is
  already running and never resets or reloads it.

## Host configuration

Everything host-specific lives in the ignored `local.nix`, under `tandem`. See
`local.example.nix` for the annotated shape. The whole module is off until
`cwdAllowlist` names at least one directory.

`cwdAllowlist` is the admission boundary for every session ChatGPT can open, so
it is written out explicitly and never derived. `/`, `/Users`, and the home
directory itself are rejected at evaluation time. Start with one disposable
directory.

Claude is the only engine enabled by default. `shell` is refused outright — it
is arbitrary command execution, and the Herdr backend will not start it. Claude
permission bypass is never set. Codex is opt-in through `extraEngines` and
should stay off until a real Tandem → Herdr → Codex session has been proven on
the host.

### What Tandem does and does not decide about permissions

Tandem sets no bypass flag for any engine. What it cannot do is override the
posture an agent takes from its **own** configuration, and that is worth
knowing before enabling Codex.

Measured on this host 2026-08-29: a Codex session opened through Tandem
reported `permissions: YOLO mode` in its own banner. That comes from Codex's
user configuration, not from anything here — but the practical effect is that
enabling `codex` in `extraEngines` can hand a remote model full-permission
execution inside whatever `cwdAllowlist` admits.

So the allowlist is the boundary that matters for Codex, not the engine's
prompts. Keep it to directories where that posture is acceptable, check
`codex` in its own configuration if it should be stricter, and treat widening
the allowlist and enabling Codex as one decision rather than two.

### Making an agent visible to Tandem's workspaces

A Herdr workspace inherits the environment of the **Herdr server**, not of the
shell that configured anything. An agent the server cannot see does not exist
as far as Tandem is concerned — and that failure does not announce itself:
`agent.start` is accepted, the pane prints `codex: command not found`, the
command exits, the managed agent name disappears with it, and Tandem reports

```text
failed to open session: agent target <name> not found
```

which reads like a Herdr lifecycle bug and is not one.

`tandem.workspacePath` in `local.nix` is the fix. It is passed as
`workspace.create.env.PATH` and applies to Tandem's own disposable workspaces
and nothing else — no global `PATH`, no shim, no change to your Herdr session.

The usual case is Codex, which the ChatGPT desktop app ships inside its bundle
and puts on no `PATH` at all:

```nix
tandem.workspacePath = [ "/Applications/ChatGPT.app/Contents/Resources" ];
```

Confirm what that directory actually holds before pointing at it:

```sh
/Applications/ChatGPT.app/Contents/Resources/codex --version
```

One entry is enough, and that is measured rather than assumed. What Herdr
receives is the **initial** environment of the launched process, and the login
shell then rebuilds `PATH` around it. Probed on 2026-08-29 with a disposable
workspace created as `--env PATH=/Applications/ChatGPT.app/Contents/Resources`:
`command -v claude` still resolved to the Home Manager profile, and
`command -v codex` resolved inside the app bundle. So naming the one directory
Herdr was missing does not cost you the ones it already had.

The same probe with `--env PATH=/usr/bin` showed the mechanism plainly: zsh's
own startup reported `command not found: mv` and `mkdir` — both of which live
in `/bin` — before it finished assembling the full `PATH`. The injected value
really is the starting point, not the final answer.

This is **not required of every host**. A machine whose Herdr already sees its
agents needs nothing here, and leaving the list empty is the right answer
there. `tandem-doctor` tells you which case you are in: with `workspacePath`
set it resolves `codex` against exactly the directories Tandem will pass and
fails if it is not there; with the list empty it says the inheritance is
unverifiable rather than pretending to know, and does not fail on it.

## Fresh-Mac check

After the normal bootstrap and `./scripts/rebuild.sh`, verify in this order.
Each step tells you which layer is wrong, so stop at the first failure.

### 1. Herdr

```sh
herdr --version
herdr session list --json
herdr agent list
```

Herdr must already be running: Tandem attaches to the persistent session named
by `tandem.herdrSession` and never starts, resets, or reloads it.

### 2. Tandem

```sh
tandem-status
```

That prints the package version, the pinned fork commit, the backend, the
enabled engines, the allowlist, the runtime configuration path, the
`tunnel-client` version, the launchd agent's state and last exit code, and the
tunnel's health.

### 3. Everything else, in one command

```sh
tandem-doctor
```

It checks the protected runtime configuration and its permissions, that a
tunnel id is configured, that the runtime key file exists, is non-empty and is
not readable by anyone else, and that Herdr answers. When Codex is enabled it
also resolves `codex` against the workspace `PATH` described above. Then it
hands off to `tunnel-client doctor --explain`. It exits non-zero if anything is
wrong, so it works as a gate and not only as something to read.

The Codex check is deliberately not part of what gates the tunnel service: a
Codex `PATH` problem must never stop the tunnel from serving Claude, which is
the engine that is always on.

It never prints the key. Existence, size, and mode answer "is this usable"
without the value reaching a terminal, a log, or an issue comment.

### 4. The runtime key

`tunnel-client` reads the key from the file named by `tandem.tunnel.apiKeyFile`
in `local.nix`. Create it once, from
<https://platform.openai.com/settings/organization/api-keys>:

```sh
install -m 0600 /dev/null "$(...path from local.nix...)"
# then write the key into it with an editor, or:
#   pbpaste > "$keyFile"    # after copying it from the dashboard
tandem-restart
```

Never pass the key on a command line: it would land in shell history and in the
process table. Never put it in a Nix expression: evaluation copies values into
the world-readable Nix store, and no later `chmod` undoes that.

### 5. The launchd agent

The agent is loaded at login and restarts the tunnel if it dies. When a
prerequisite is missing it exits cleanly instead of crash-looping, and says why
in its log:

```sh
tandem-status
tail -f ~/Library/Logs/tandem-tunnel.log
tandem-restart        # after fixing whatever the log named
```

`tandem-restart` is the command to run after provisioning the key or changing
the tunnel id — a clean exit leaves the agent loaded but idle, and this is what
starts it.

## One-time ChatGPT-side setup

This part is genuinely manual. It belongs to the ChatGPT account, not to the
machine, and nothing in this repository can provision it.

Once `tandem-doctor` passes:

1. Open ChatGPT settings and enable **Developer Mode**.
2. Create a custom App/Connector.
3. Choose **Tunnel** as the connection type.
4. Select the tunnel this host is configured for (or paste its id).
5. Refresh the tool surface and give the app a clear name.
6. Set the app's action permission deliberately. Unattended agent steering
   needs write-capable actions; choose a stricter mode if that is the intent.
7. Start a **new** conversation. Tool metadata is captured per conversation, so
   an existing one keeps the old inventory.

Reference: <https://developers.openai.com/api/docs/guides/secure-mcp-tunnels>

## End-to-end smoke

From a new ChatGPT conversation with the app enabled:

1. `list_devices` — the local device reports its enabled engines.
2. `list_sessions` — only sessions Tandem owns are listed, and no others.
3. `open_session` in a directory that is on the allowlist. A directory that is
   not on it must fail; that failure is the boundary working.
4. `send_to_session`: `Reply with exactly: TANDEM CLAUDE OK`.
5. Read the reply back. If the turn is still running, poll the same session
   rather than resending.
6. Send a second instruction to the **same** session and confirm continuity.
7. `close_session` when finished. Under Herdr this closes only the
   Tandem-owned workspace, after re-checking its ownership tags.

Then confirm both views are the same session, which is the whole point of using
Herdr rather than a hidden multiplexer:

```sh
herdr agent list
herdr agent read <agent>
herdr agent focus <agent>
```

`open_session` also returns a real `herdr agent attach` command as its attach
hint.

Repeat with `engine=codex` before enabling Codex in `local.nix`. Run
`tandem-doctor` first: if it cannot resolve `codex`, set `tandem.workspacePath`
as described above, because the session will otherwise fail as a missing agent
target rather than as a missing command. Check that Codex still has its own
harness, project instructions, and tool surface — Herdr manages the PTY, it
does not replace what runs inside it.

## Watching a live session

GitHub is not the message bus. Live traffic is
`ChatGPT ↔ Tandem ↔ Herdr ↔ agent`, and Herdr is the human-visible end of it:
watch or focus the same pane directly rather than copying output anywhere.

GitHub holds durable engineering state — issues, commits, exact SHAs, review
results — not every agent message.

## When ChatGPT says the tools are unavailable

Work outwards from the machine:

1. `tandem-doctor` — if it fails, nothing further out can work.
2. `tail ~/Library/Logs/tandem-tunnel.log` for the reason the runtime stopped.
3. `tandem-restart`, then `tandem-status` until the tunnel reports healthy and
   ready.
4. `herdr session list --json` — Tandem cannot open anything if Herdr is down.
5. Confirm the app is still enabled in ChatGPT and its action permission has
   not been narrowed.
6. Start a new conversation. After any connector change, an existing
   conversation keeps the tool inventory it started with.

If Tandem can list sessions but cannot drive one, read Herdr's semantic state
(`agent list`, `agent get`) before changing Tandem: `working`, `blocked`, and
`idle` are reported by Herdr, not guessed from screen text, so a stuck session
usually says what it is waiting for. Do not add tmux as a fallback.

## Disable and roll back

Reversible, in this order, and none of it deletes Herdr sessions or agent
history:

1. Disable the Tandem app in ChatGPT if remote control should stop immediately.
   This is the only step that does not need the Mac.
2. Stop the runtime for this login session:
   `launchctl bootout gui/$(id -u)/org.nix-community.home.tandem-tunnel`
3. Remove it declaratively by emptying `tandem.cwdAllowlist` in `local.nix` and
   running `./scripts/rebuild.sh`. That withdraws the package, the launchd
   agent, and the wrappers.
4. To roll back only the Tandem version, move the pinned revision in
   `flake.nix` back and rebuild.

Leave the protected runtime key alone: rotating or destroying a credential is a
separate, deliberate operation, not part of a configuration rollback.

## Manual fallback

If the wrappers are unavailable — a half-applied generation, or a machine mid
recovery — the same runtime can be driven directly. The profile is generated by
Nix, so read the path from the agent that launchd loaded:

```sh
plutil -p ~/Library/LaunchAgents/org.nix-community.home.tandem-tunnel.plist
tunnel-client doctor --config <profile> --explain
tunnel-client health --config <profile>
tunnel-client run    --config <profile>
```

And Tandem's MCP server can be spoken to over stdio on its own, which is how to
tell a Tandem problem from a tunnel problem:

```sh
tandem-mcp
```

It reads the same protected configuration the tunnel gives it, so a failure
here is Tandem or Herdr, never the tunnel.

## Keep out of this repository

No secrets, personal paths, private repository names, tunnel ids, workspace
ids, or account identifiers. Host-specific values go in the ignored
`local.nix`; the runtime key goes in a protected file that only `tunnel-client`
reads. `scripts/check-private-names.sh` enforces the first half of that rule on
every commit.
