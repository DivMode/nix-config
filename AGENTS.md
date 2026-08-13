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
- Anthropic's Claude Code terminal CLI is a **Nix package**, from the
  `llm-agents` flake input, declared in `modules/home/development.nix`. It is
  deliberately not the `claude-code` Homebrew cask, which lags the release
  stream by days; do not move it back. Never add the separate `claude` desktop
  cask. cmux is the native terminal; Herdr runs inside it.
- Exactly one thing may provide `bin/claude`. `development.nix` withholds the
  unwrapped package whenever the 1Password launcher in `secrets.nix` is enabled,
  because that launcher installs its own executable of the same name.
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
- Activate with `./scripts/rebuild.sh`, and run it yourself rather than handing
  the command to the user. It sets `SUDO_ASKPASS` and uses `sudo -A`, so the
  password is collected in a native dialog and no controlling terminal is
  needed — that script exists precisely so an agent can activate. Do not
  assemble a `darwin-rebuild switch` command line by hand.
- A change is not finished at activation. Verify the observable behaviour the
  change was for, and prefer the application's own source or stored state over
  assuming the setting means what its name suggests.
- Never hand-derive the stored form of a `targets.darwin.defaults` value that is
  not a plain boolean, string, or integer. Set it once in the application's own
  UI, read it back with `plutil -p ~/Library/Preferences/<domain>.plist`, and
  declare exactly those bytes. Applications using the `Defaults` library store
  enums as JSON, so the correct value contains literal double quotes — see
  `modules/home/mouse.nix`. When an application's settings window disagrees with
  what its plist plainly says, the value is stored in a form it cannot decode.
- A comment that names a root cause must carry the evidence that proves it: the
  source file, the log line, the stored bytes. Write anything unproven as a
  hypothesis. A confident, wrong root-cause comment is worse than none — one in
  `mouse.nix` misdirected a whole day's debugging on 2026-08-13.
- Activation runs on every rebuild, so an entry that restarts an application
  must first check whether its input actually changed. `install` copies
  unconditionally and bumps mtime; `launchctl kickstart -k` kills and restarts.
  Ungated, they disrupt applications during activations that have nothing to do
  with them. Gate on `cmp -s` against the desired file. The exception is state
  written through cfprefsd, whose flush is asynchronous and cannot be compared
  on disk — restart unconditionally there and say why.
