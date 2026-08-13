# Developer tools

`development.nix` is the canonical portable-tool declaration. Home Manager
installs stable CLI tools from locked Nix inputs; native/vendor macOS software
belongs to Homebrew.

Runtime ownership is deliberately single-purpose:

- `mise` installs and selects Node. The machine fallback is Node 24; projects
  should commit exact versions and locks.
- `uv` installs Python interpreters and owns Python environments, dependencies,
  tools, and lockfiles. Python is not also selected by mise.
- `rustup` owns Rust toolchains, targets, and components. Rust projects should
  commit `rust-toolchain.toml` when a specific toolchain is required.

Language runtimes are mutable developer state downloaded on first use, not
during a Nix activation. Run `mise trust` only after reviewing a project's
configuration.

Git is installed and configured through Home Manager. Its complete identity and
signing setup is documented in [`../../secrets/README.md`](../../secrets/README.md).
The standalone Home Manager CLI is disabled so `darwin-rebuild` remains the
single routine activation path.
