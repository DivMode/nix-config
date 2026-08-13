# AI configuration source

`default.nix` is the canonical public source for shared instructions,
specialist agents, and MCP server metadata. The basic Mac profile keeps all AI
renderers disabled while the foundational configuration is stabilized.

When explicitly enabled, Home Manager can render client-native instruction,
agent, skill, and reference files for Codex and Claude Code. The MCP registry
contains endpoint metadata and environment-variable names only, never tokens.

Codex's public TOML is emitted as a review artifact rather than linked over the
application-owned mutable `~/.codex/config.toml`. Claude's mutable user state is
also not overwritten. Both clients require merge-safe adapters before those
generated settings can become live configuration.

Installing Anthropic's Claude Code terminal cask is independent of enabling this
renderer. Runtime secrets follow the interface in [`../secrets/README.md`](../secrets/README.md).
