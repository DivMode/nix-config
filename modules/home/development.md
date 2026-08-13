# Developer tools

`development.nix` is the canonical portable-tool declaration. Home Manager
installs stable CLI tools from locked Nix inputs; native/vendor macOS software
belongs to Homebrew.

## Claude Code

Anthropic's terminal CLI is declared here, from the `llm-agents` flake input,
rather than as a Homebrew cask. Both deliver the same signed vendor binary, but
Claude Code publishes several releases a day and the cask trails badly: on
2026-08-13 the newest `homebrew-cask` commit still described 2.1.223 while
upstream was on 2.1.231. Because the tap is itself a pinned flake input, no lock
update could have closed that gap while it stayed a cask.

Update it like any other pin:

```sh
./scripts/update.sh llm-agents
```

Exactly one thing may provide `bin/claude`. When the 1Password launcher in
`secrets.nix` is enabled it installs its own executable of that name, wrapping
this same package by absolute store path, so this module withholds the
unwrapped package to avoid a collision. `nixConfig.claudeCode.package` is the
single source both modules read.

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
