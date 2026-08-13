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

## Codex

Codex mutates `~/.codex/config.toml` at runtime, so its declarative TOML is
emitted as a review artifact rather than linked over the live file. Claude's
mutable user state is likewise not overwritten. Both clients need merge-safe
adapters before those generated settings can become live configuration.

Runtime secrets follow the interface in [`../secrets/README.md`](../secrets/README.md).
The MCP registry contains endpoint metadata and environment-variable names only,
never tokens.
