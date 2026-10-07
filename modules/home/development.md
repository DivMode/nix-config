# Developer tools

`development.nix` is the canonical portable-tool declaration. Home Manager
installs stable CLI tools from locked Nix inputs; native/vendor macOS software
belongs to Homebrew.

## Claude Code

Anthropic's terminal CLI updates itself. The binary is Anthropic's native
install — versions under `~/.local/share/claude/versions`, reached through
`~/.local/bin/claude` — and its background updater follows the `latest`
channel, declared as `autoUpdatesChannel` in the managed settings. That is
application-owned state, like ChatGPT.app's Sparkle updates; `claude update`
forces a check.

What this module declares is the **launcher** that `claude` on PATH resolves
to. It runs the native install, and on a machine that has none it first
installs Anthropic's latest using a hash-pinned seed binary
(`claude-code-bootstrap.json`) — the same `claude install` step Anthropic's
install script performs, without piping an unpinned script into a shell. The
seed's version is irrelevant and nothing refreshes it. `programs.claude-code`
wraps the launcher with `--plugin-dir`, so plugins still come from the store;
`~/.local/bin` stays off PATH so nothing reaches the binary around that
wrapping.

It was a Nix package until 2026-09-18, and every form of that lagged: the
Homebrew cask by days (2026-08-13: 2.1.223 against 2.1.231), llm-agents'
packaging by hours-to-a-day, and this repository's own version pin by however
long since the last `nixup` (2026-09-17: 2.1.269 against 2.1.276). A store path
cannot update itself, so that package also had to disable Claude Code's
updater and its "update available" notice.

Exactly one thing provides `bin/claude`: this launcher, wrapped by
`programs.claude-code` with the plugin directories. `nixConfig.claudeCode.package`
is the single source that module reads.

Runtime ownership is deliberately single-purpose:

- `mise` installs and selects Node. The machine fallback is Node 24; projects
  should commit exact versions and locks.
- `uv` installs Python interpreters and owns Python environments, dependencies,
  tools, and lockfiles. Python is not also selected by mise. The machine
  fallback is CPython 3.14 (`pythonDefault`, written to
  `~/.config/uv/.python-version`); `python3` and `python` on PATH are a launcher
  that runs the interpreter uv picks for the current directory, installing it
  on first use. uv is set to `only-managed`, so macOS's `/usr/bin/python3`
  (3.9) is never chosen. uv's downloaded CPython builds run on macOS as-is; a
  future NixOS host would need `programs.nix-ld` for them.
- `rustup` owns Rust toolchains, targets, and components. Rust projects should
  commit `rust-toolchain.toml` when a specific toolchain is required.

Language runtimes are mutable developer state downloaded on first use, not
during a Nix activation. mise trusts every project's configuration
(`trusted_config_paths = ["/"]`), so no checkout needs a `mise trust`.

Git is installed and configured through Home Manager. Its complete identity and
signing setup is documented in [`../../secrets/README.md`](../../secrets/README.md).
The standalone Home Manager CLI is disabled so `darwin-rebuild` remains the
single routine activation path.

## Codex

The Codex CLI is the copy ChatGPT.app bundles and updates with itself. This
module declares only the `codex` launcher on PATH, which execs
`/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex` and exits 127
with a message when the app is absent. Nothing pins a codex version, and the
launcher is the single provider of `bin/codex`.
