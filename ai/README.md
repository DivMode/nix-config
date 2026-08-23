# AI configuration source

This directory is the canonical public source for shared instructions,
specialist agents, client hook programs, Codex preferences, and MCP server
metadata. `modules/home/ai` renders or merges them into client-native files.

The point of declaring any of this is recoverability. A coding agent deleted a
previous machine's assistant configuration; everything here is restored by
`darwin-rebuild switch`, and that restoration is verified, not assumed.

## What is declared, and where it lands

| Source | Rendered to |
| --- | --- |
| `instructions/global.md` | `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md` |
| `agents/*/prompt.md` | `~/.claude/agents/<name>.md`, `~/.codex/skills/<name>/SKILL.md` |
| `hooks/nix-only-guard.py` | referenced by absolute Nix store path from Claude Code's settings |
| `codex/default.nix` | narrowly merged into mutable `~/.codex/config.toml` |
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
