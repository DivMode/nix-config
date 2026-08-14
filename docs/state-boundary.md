# Declarative configuration versus mutable state

The recovery promise is precise: Git plus the committed `flake.lock` can
reconstruct declared packages and configuration. It cannot recreate data that
was never stored in a declarative or provider-backed system.

## Managed declaratively

- Native/vendor Homebrew cask declarations orchestrated by Nix
- Nix/Home Manager package declarations, including Zsh, Starship,
  JetBrains Mono Nerd Font, Git, portable CLIs, and Herdr
- The supported Finder, keyboard, and natural-scrolling defaults explicitly
  represented by nix-darwin
- Home Manager's declared Zsh, prompt, terminal-font configuration, Git
  settings, and global mise fallback
- Public AI instructions, agents, skills, and MCP endpoint metadata
- Secret identifiers, `op://` references, and environment mappings, but never
  secret values

## Mutable state outside Nix

- Codex and Claude chat history or transcripts
- Authentication and OAuth sessions
- macOS Keychain contents
- Browser profiles and history
- Gmail and Chrome authentication; Nix declares Gmail's installation policy,
  while Chrome owns each profile's PWA registration and generated app shim
- Application databases, caches, logs, indexes, and temporary files
- Ghostty and Herdr runtime preferences and session state other than
  Ghostty's declarative `~/.config/ghostty/config`
- LinearMouse's macOS Accessibility approval; its app, launch agent, and JSON
  configuration are declarative
- Karabiner's macOS background-service, Accessibility, and Driver Extension
  approvals; its public keyboard rules are declarative Home Manager state
- Spotlight index contents remain mutable; nix-darwin declaratively installs
  the policy daemon that reconciles indexing and searching off for external volumes
- SSH private keys and API tokens

Cloud-backed history must be recovered from its provider. Secret material must be
recovered from an authorized secret manager. Important local-only data needs a
separate, explicit data-preservation policy; declaring an application's settings
does not preserve its database.

Home Manager activation should fail if a managed path collides with an unmanaged
file. Resolve ownership explicitly instead of enabling automatic overwrite,
renaming, or deletion.

`~/.codex/config.toml` is application-owned mutable state. When the dormant AI
renderer is explicitly enabled, declarative Codex TOML is generated under
`~/.config/nix-config/ai/` for inspection until a merge-safe adapter exists.
Immutable instructions, skills, and agents remain Home Manager-owned.

Declaring the Ghostty and Herdr packages makes the software rebuildable.
Ghostty's `~/.config/ghostty/config` is declarative; neither program's runtime
preferences or sessions are managed.

LinearMouse's documented JSON is generated directly by Home Manager. It matches
the mouse device category so wheel reversal remains portable across Bluetooth
and receiver connections without affecting trackpads. The settings UI cannot
persist changes through the immutable Home Manager link; edit the Nix module
instead.
