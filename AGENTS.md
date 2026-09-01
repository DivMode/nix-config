# AGENTS.md — nix-config

This is a public, multi-host Nix configuration repository. It configures macOS
today and is intentionally structured to add NixOS servers later.

## Safety rules

- Never commit personal usernames, email addresses, hostnames, tokens, SSH
  material, decrypted secrets, private prompts, chat histories, or session data.
- Never commit the name of a private repository, project, or 1Password vault —
  not in code, not in a comment, not in a docs example. Comments describe them
  generically ("the work monorepo"); values live in `local.nix` and are read at
  run time, the way `scripts/rebuild.sh` reads the backup vault. This rule is
  enforced, not trusted: `scripts/check-private-names.sh` derives a denylist
  from `local.nix` and a `pre-commit` hook blocks any commit that matches.
  Install it with `scripts/install-hooks.sh` (`rebuild.sh` and `setup-mac.sh`
  both do), and audit the whole tree with `--tree`. It exists because a
  2026-08-14 audit found seventeen occurrences already committed: a private
  monorepo named in nine comments across three modules and a research note, and
  a vault name hard-coded in six lines of two scripts.
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
- Do not install Nix/Homebrew or alter the current machine outside this
  repository. Activating a change you were asked to make is not "altering the
  machine" — it is how the change gets verified, and it is expected. Do not wait
  to be told to activate.
- Prefer small modules with explicit ownership boundaries. Nix owns desired
  configuration; applications own mutable history, auth, caches, and sessions.
- Nix/Home Manager own Zsh, its plugins, Git, portable CLIs, and Herdr.
  Homebrew owns only declared native/vendor casks; formulae require a documented
  nixpkgs incompatibility. Never declare the same executable through both.
- Anthropic's Claude Code terminal CLI is a **Nix package**: the `llm-agents`
  flake input provides the build recipe, and the VERSION is pinned by this
  repository in `modules/home/claude-code-pin.json`, which `scripts/update.sh`
  refreshes from Anthropic's own release bucket — so an update always delivers
  Anthropic's latest, not a packager's. It is deliberately not the
  `claude-code` Homebrew cask, which lags the release stream by days; do not
  move it back, and do not hand the version back to llm-agents' automation,
  which trails by hours-to-a-day. Never add the separate `claude` desktop
  cask. Ghostty is the terminal, installed by Home Manager from
  `pkgs.ghostty-bin` because `pkgs.ghostty` is Linux-only; Herdr runs inside it.
  cmux was the superseded terminal and was removed entirely on 2026-08-14.
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
- Activate and verify BEFORE committing, not after. `nix build` proves a
  configuration evaluates, not that it works.
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
