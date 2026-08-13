# AGENTS.md — nix-config

This is a public, multi-host Nix configuration repository. It configures macOS
today and is intentionally structured to add NixOS servers later.

## Safety rules

- Never commit personal usernames, email addresses, hostnames, tokens, SSH
  material, decrypted secrets, private prompts, chat histories, or session data.
- Keep machine identity in the ignored `local.nix`; update
  `local.example.nix` only with generic placeholders.
- Load ignored identity metadata only through an explicit `NIX_CONFIG_LOCAL`
  absolute path and `--impure`; never infer or scan the home directory for it.
- Never put secret values in Nix expressions: evaluation can copy them into the
  world-readable Nix store. Store only secret names and runtime paths here.
- Homebrew activation cleanup must remain `"uninstall"` for strict desired-state
  reconciliation. Never use `"zap"`, which can remove associated application data.
- Activation must fail on unmanaged-file collisions. Do not silently overwrite,
  move, or delete existing home-directory files.
- Do not run `darwin-rebuild switch`, install Nix/Homebrew, or alter the current
  machine unless the user explicitly asks for activation.
- Prefer small modules with explicit ownership boundaries. Nix owns desired
  configuration; applications own mutable history, auth, caches, and sessions.
- Nix/Home Manager own Zsh, its plugins, Git, portable CLIs, and Herdr.
  Homebrew owns only declared native/vendor casks; formulae require a documented
  nixpkgs incompatibility. Never declare the same executable through both.
- `claude-code` is Anthropic's terminal CLI cask. Do not add the separate
  `claude` desktop cask. cmux is the native terminal; Herdr runs inside it.
- Karabiner-Elements exclusively owns keyboard remapping; Raycast's native Hyper
  Key stays disabled and LinearMouse exclusively owns mouse behavior. Home
  Manager owns LinearMouse's documented JSON; never automate TCC approval.
  Manage the complete Karabiner config directory, never only a
  `karabiner.json` symlink.

## Development

- Work on branches; do not push directly to `main`.
- Format with `nix fmt`.
- Evaluate with `nix flake check` and
  `nix eval .#darwinConfigurations.example-mac.system` before activation.
- Inspect activation diffs before switching a host.
