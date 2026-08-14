# AI configuration source

`default.nix` is the canonical public source for shared instructions, specialist
agents, client hook programs, and MCP server metadata. `modules/home/ai` renders
it into client-native files.

The point of declaring any of this is recoverability. A coding agent deleted a
previous machine's assistant configuration; everything here is restored by
`darwin-rebuild switch`, and that restoration is verified, not assumed.

## What is declared, and where it lands

| Source | Rendered to |
| --- | --- |
| `instructions/global.md` | `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md` |
| `agents/*/prompt.md` | `~/.claude/agents/<name>.md`, `~/.codex/skills/<name>/SKILL.md` |
| `hooks/nix-only-guard.py` | referenced by absolute Nix store path from Claude Code's settings |
| `mcp/servers.nix` | `~/.config/nix-config/ai/` review artifacts |

Instructions here are global, so they apply to every project. Repository facts
belong in that repository's own instructions file; duplicating them here makes
the two disagree.

## Claude Code

Its Home Manager module, `programs.claude-code`, owns the instruction file and
the agent definitions. Prefer that module over hand-written `home.file` entries:
it is maintained upstream and already covers commands, skills, rules, output
styles, plugins, and marketplaces when those are wanted.

Two deliberate exceptions:

- **The package is not declared there.** `modules/home/development.nix` installs
  it, from the `llm-agents` flake input, and decides whether the unwrapped
  binary or the 1Password launcher provides `claude`. Declaring it in both
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

Codex mutates `~/.codex/config.toml` at runtime, so its declarative TOML is
emitted as a review artifact rather than linked over the live file. Claude's
mutable user state is likewise not overwritten. Both clients need merge-safe
adapters before those generated settings can become live configuration.

### `~/.codex/config.toml` is deliberately not managed

Investigated on 2026-08-13 and rejected, so it is not re-investigated. Unlike
`~/.claude`, there is nothing here worth declaring, and declaring it would be
actively wrong for three separate reasons.

**It is mostly not configuration.** Of roughly forty keys, six are genuine
preferences — `model`, `model_reasoning_effort`, and four `[desktop]` display
toggles. Everything else is state Codex writes about itself: `last_updated`
timestamps on marketplaces, `source` paths into `~/.codex/.tmp/` and
`~/.cache/codex-runtimes/`, `[plugins."<name>@<marketplace>"]` enable flags for
plugins Codex installs on its own, an `[mcp_servers.node_repl]` block full of
paths into `/Applications/ChatGPT.app` with a pinned SHA256 and the app's build
version, and `[projects."<path>"]` trust levels that accumulate as you work.

**This repository is public.** The file is full of absolute home-directory
paths and the names of private project checkouts. Committing it would breach
the first safety rule in `AGENTS.md`.

**There is no merge-safe way to write it.** The Defaults domain used for Claude
Code can be applied key-by-key with `defaults import`; TOML has no equivalent,
so managing six keys inside a forty-key file that the application rewrites at
runtime needs a real merge adapter. That is why the declarative TOML in this
repository is emitted as a review artifact and not linked over the live file.

**And the recovery case is weak.** Losing this file costs a model preference and
four display toggles. The plugins reinstall themselves and the trust levels
regenerate as you use them. Compare `~/.claude`, which held a 151-line guard
hook that existed nowhere else — that one was worth closing.

Revisit only if Codex grows settings that are expensive to lose and cannot be
recreated by using the application.

### Codex plugins

Codex has a plugin system of its own. Plugins carry a
`.codex-plugin/plugin.json` manifest, marketplaces are declared as
`[marketplaces.<name>]`, and installed plugins as
`[plugins."<plugin>@<marketplace>"]` — all in `~/.codex/config.toml`, which
Codex writes itself. That state is currently unmanaged.

This matters when sharing a third-party skill set between clients: the Claude
Code and Codex plugin formats are **different**, and a repository shipping
`.claude-plugin/plugin.json` is not installable as a Codex plugin. Where an
upstream ships only one manifest, deliver its skills to the other client as
plain skill directories, which both clients read identically.

Runtime secrets follow the interface in [`../secrets/README.md`](../secrets/README.md).
The MCP registry contains endpoint metadata and environment-variable names only,
never tokens.
