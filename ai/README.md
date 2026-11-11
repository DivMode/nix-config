# AI configuration source

This directory is the canonical public source for shared instructions,
specialist agents, client hook programs, Codex preferences, and MCP server
metadata. `modules/home/ai` renders or merges user configuration;
`modules/darwin/agent-hooks.nix` installs machine-managed hook policy.

The point of declaring any of this is recoverability. A coding agent deleted a
previous machine's assistant configuration; everything here is restored by
`darwin-rebuild switch`, and that restoration is verified, not assumed.

## What is declared, and where it lands

| Source | Rendered to |
| --- | --- |
| `instructions/` | `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md` |
| `agents/*/prompt.md` | `~/.claude/agents/<name>.md`, `~/.codex/skills/<name>/SKILL.md` |
| `skills/` | `~/.claude/skills/<name>/`, `~/.codex/skills/<name>/` |
| `claude-skills/` | `~/.claude/skills/<name>/` (Claude Code only) |
| `delegation/assignment.md` | `assignment.md` beside both delegation skills |
| `hooks/default.nix` | Claude managed settings and `/etc/codex/requirements.toml`, through the build-time hook contract |
| `codex/default.nix` | narrowly merged into mutable `~/.codex/config.toml` |
| `mcp/servers.nix` | `~/.config/nix-config/ai/` review artifacts |
| `shell-guard/kill-guard.sh` | sourced by every bash and zsh either client starts (`BASH_ENV`, ZDOTDIR's `.zshenv`) |

Instructions here are global, so they apply to every project. Repository facts
belong in that repository's own instructions file; duplicating them here makes
the two disagree.

## The global instruction document

`instructions/` holds two tracked sources and composes them, in order, into the
one document both clients are given:

- `global.md` — how the owner works, and what "done" means. Owner-edited prose.
- `orchestration.md` — how agents on this machine coordinate with each other:
  who coordinates and merges, where durable state lives, how native workers are listed,
  reused, and polled, what an interruption does and does not cancel, which
  model a worker may pick, and that user environment changes belong in this
  repository rather than in a shell. General by design; it names no project. It
  carries a line budget, because it is loaded into every session of every
  project.

`instructions/default.nix` builds that document and `flake.nix` exposes its
checks as `checks.<system>.agent-instructions`. Reword a rule freely; deleting
one, moving it out of its section, or handing a client anything other than the
canonical text fails `nix flake check`. Five things are asserted, and each
closes a way this rots silently:

- **The rendered document is exactly `global.md` followed by `orchestration.md`.**
  Without this, "one canonical source" is a convention rather than a fact, and
  anything could be appended downstream of the sources.
- **`orchestration.md` is within its line budget.** It is loaded into every
  session of every project, so its size is a per-prompt tax on everything.
- **Every binding rule's text is still present** in the rendered document,
  matched as a fixed string. These were asked for explicitly and must not be
  lost to a tidy-up.
- **Rules that are binding because of where they sit are still there.** A rule
  moved out of the numbered list into the surrounding commentary keeps every
  word and loses its force, and the whole-document check cannot see that. The
  reviewer of record and the rule that the user's words pick the worker (Codex
  or Claude sub-agents) are pinned to `## Roles`; reconciliation, the
  implementation/review split, no self-approval, the optional independent
  reviewer, and the ban on monitor-only sessions are pinned to
  `## Binding rules`.
- **Both consumers equal the canonical text — not merely each other.** Added
  after PR #26. Mutual equality is satisfied by an *identical wrong edit to
  both*: give each of them `"preamble" + text` and the two files still match,
  the rendered document is still exactly its two sources, and every earlier
  check passes while both clients are handed a policy that is not canonical.
  The predicate is defined once and shared by the regression test here and the
  assertion in `modules/home/ai`, so the two cannot restate it differently.

Both halves of the reviewer and monitor rules from PR #27, and of the
reconciliation rule for existing workers, are pinned
separately — either half alone survives an edit that inverts the rule.

Both destinations are loaded automatically and machine-wide: Claude Code reads
`~/.claude/CLAUDE.md` as user memory for every project, and Codex reads
`$CODEX_HOME/AGENTS.md` — `~/.codex/AGENTS.md` unless the environment overrides
`CODEX_HOME`, which nothing here does — as global user instructions.

**Those two clients are the whole audience of these files.** This is policy
for LOCAL workers. Remote workers read neither — they are files on this
Mac and a browser session cannot see them.

Coordination uses the active client's native tools. This repository does not
install a remote agent-control service. Give remote participants the relevant
instructions with their task; local files do not reach them automatically.
The ownership boundaries are recorded in
[`../docs/orchestration-architecture.md`](../docs/orchestration-architecture.md).

The document is composed as a STRING at evaluation time rather than built as a
derivation and passed to both consumers. `programs.claude-code.context` is typed
`either lines path` and branches on `lib.isPath`, which is false for a
derivation, so passing one takes the `.text` branch and is rejected there by
`home.file.<name>.text`'s own `nullOr lines` type — a hard evaluation error,
measured against the pinned home-manager rather than assumed.
`~/.config/nix-config/ai/agent-instructions.md` links the same document for
review.

## Agent shells refuse to signal what they did not start

On 2026-11-11 a script written by a delegated worker sent a terminate signal
to every process group on this Mac, and every application the owner had open
was terminated (issue #270). The command hooks read the text of a tool call;
that call ran a script, and the signal sat three scripts deeper.

`shell-guard/kill-guard.sh` is loaded into every shell Claude Code and Codex
start. Each client sets `AGENT_KILL_GUARD=1` and `BASH_ENV` for the commands
it runs (`shellGuard.environment` in `default.nix`), so every non-interactive
bash sources the file, however deep; zsh sources it from ZDOTDIR's `.zshenv`
when the marker is set. The owner's own shells never load it. In a guarded
shell:

- `kill` aimed at a process group passes only when the group is the shell's
  own or its leader was started by that shell. `-1` (every process the user
  owns) and any group the shell merely looked up are refused, and nothing is
  sent.
- `kill` aimed at single process ids, at jobs, or with the probe signal 0
  passes unchanged.
- `pkill` is refused. `killall` is refused except for the interface agents the
  command hook also allows (Dock, Finder and the menu bar agents).

**The limit.** Agents and the owner's applications run as one user, so the
system delivers any signal an agent process does send. The guard covers the
shell builtin, which is what scripts use. It does not cover a program that
makes the system call itself (Python's `os.kill`, a compiled binary),
`/bin/kill`, `builtin kill`, `command kill`, or `sh`. It stops a mistake at the
moment it is made; it is not a boundary against intent.

`checks.<system>.agent-kill-guard` (macOS) runs `kill-guard-test.sh` in Nix's
bash and zsh and the system's `/bin/bash` and `/bin/zsh`. The test sends a real
signal only to processes it started; a target that must never be signalled is
given only to the function that returns a verdict and sends nothing. Keep it
that way.

## Claude Code

Its Home Manager module, `programs.claude-code`, owns the instruction file and
the agent definitions. Prefer that module over hand-written `home.file` entries:
it is maintained upstream and already covers commands, skills, rules, output
styles, plugins, and marketplaces when those are wanted.

Two deliberate exceptions:

- **The package is not declared there.** `modules/home/development.nix` declares
  it — a launcher for Anthropic's self-updating native install, not the binary
  itself — and decides whether that launcher or the 1Password one provides
  `claude`. Declaring it in both
  places would install it twice and collide on `bin/claude`.
- **`settings.json` is not declared there.** That option writes a read-only Nix
  store symlink, and Claude Code writes to the file itself when settings change
  through its own interface. It is installed as a real file and reasserted on
  activation instead, the same arrangement `karabiner.nix` and `mouse.nix` use.
  The trade-off is deliberate: runtime changes are reverted at the next
  activation, so change settings in `modules/home/ai/default.nix`.

The PreToolUse guard is referenced by absolute store path and run with an
explicit interpreter, so nothing under `~/.claude` is involved in enforcing it.
Deleting that directory cannot disarm the rule.

### Codex delegation (codex-orchestrator)

`codex-orchestrator` (flake input, pinned to the v0.5.1 tag) is loaded as a
Claude Code plugin so Claude can hand precisely scoped implementation work to
the real Codex CLI and keep supervising it. Its tools need Python 3.10+, which
the uv-backed `python3` launcher in `modules/home/development.nix` provides.
`codex-orchestrator/` here adds the local policy skill
(`/codex-orchestrator:codex-delegate`), its `codex-scope` post-run check, and the `codex-guard` hook that stops a delegated job committing, pushing, shipping, or deploying. The
policy fixes the worker to `gpt-6.1-sol` with explicit flags, not a Codex
profile: Codex 0.159.2 started a session with a missing `-p` profile instead of
failing. Claude picks the reasoning effort per job, never `ultra`, and Fast runs
only on request. Remove the plugin from `programs.claude-code.plugins` to
disable all of it.

### Claude sub-agent delegation (opus-delegate)

`claude-skills/opus-delegate` is the sibling of `codex-delegate`: the same assignment,
worktree, single-correction, and acceptance discipline, with the Agent tool as
the mechanism instead of a runner, journal, and guard hook. Claude picks the
model, effort, and agent type per piece. The global Roles rule routes between
the two by the user's words: "Codex" means `codex-delegate`; "Opus", "sub-agents", or
nothing said means `opus-delegate`. Both skills write their briefs from
`delegation/assignment.md`, copied beside each `SKILL.md`, so the two cannot
drift.

### Plugins and marketplaces are deliberately not declared

Checked on 2026-08-13, and the answer is that there is nothing at risk:

- The only marketplace is Anthropic's official one, and Claude Code installs it
  itself — `~/.claude.json` records `officialMarketplaceAutoInstalled`. It
  already survives a wipe without help.
- No third-party marketplaces are configured, and no enabled-plugin state is
  recorded anywhere.
- The `<namespace>:<command>` entries that look like plugins are a project's own
  tracked `.claude/commands/**`, restored by cloning that repository.

`programs.claude-code.marketplaces` takes a *directory*, which it records as
`source = { source = "directory"; path = <store path>; }`. Declaring the
official marketplace would therefore replace a self-healing GitHub install with
a pinned copy that must then be updated by hand — maintenance bought with no
recoverability gained. Revisit this only if a marketplace is added that Claude
Code does not install on its own.

## Codex

Codex mutates `~/.codex/config.toml` at runtime. The live file therefore remains
a normal user-writable file; it is never replaced by a Nix-store symlink. Home
Manager now overlays one durable, machine-wide preference layer while leaving
Codex's application state in place.

### `~/.codex/config.toml` has a narrowly managed preference layer

The [official Codex configuration reference](https://developers.openai.com/codex/config-reference/)
defines the approval, sandbox, and app-default keys this machine needs to keep
across every project:

```toml
approval_policy = "never"
approvals_reviewer = "auto_review"
sandbox_mode = "danger-full-access"

[apps._default]
approvals_reviewer = "auto_review"
default_tools_approval_mode = "approve"
destructive_enabled = true
enabled = true
open_world_enabled = true
```

`codex/default.nix` generates exactly that document and packages
`merge-config.py` with nixpkgs' pinned Python and TomlKit. On activation the
merger parses the existing file, updates only those leaves, and round-trips all
unknown keys, tables, comments, plugin and marketplace entries, project trust
entries, MCP paths, and ordering as far as TomlKit's preserving parser allows.
The generated preferences are also linked under
`~/.config/nix-config/ai/codex-managed-preferences.toml` for review.

Invalid TOML fails activation without touching the original. Changed content is
written to a `0600` temporary file in the same directory, flushed, and atomically
renamed over the live path. Identical bytes are not rewritten; an otherwise
current file with broader permissions is tightened to `0600` without changing
its contents or modification time.

Everything outside the document above remains application-owned mutable state:
model and desktop choices, update timestamps, plugins and marketplaces, project
trust, generated MCP launch paths, and client-specific metadata. The public
repository never imports or commits the live file, because it can contain
private checkout paths and application-generated values.

### Codex plugins

Codex has a plugin system of its own. Plugins carry a
`.codex-plugin/plugin.json` manifest, marketplaces are declared as
`[marketplaces.<name>]`, and installed plugins as
`[plugins."<plugin>@<marketplace>"]` — all in `~/.codex/config.toml`, which
Codex writes itself. That state remains application-managed; the preference
merger preserves it but does not declare it.

This matters when sharing a third-party skill set between clients: the Claude
Code and Codex plugin formats are **different**, and a repository shipping
`.claude-plugin/plugin.json` is not installable as a Codex plugin. Where an
upstream ships only one manifest, deliver its skills to the other client as
plain skill directories, which both clients read identically.

Runtime secrets follow the interface in [`../secrets/README.md`](../secrets/README.md).
The MCP registry contains endpoint metadata and environment-variable names only,
never tokens.
