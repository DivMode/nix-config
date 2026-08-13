# Architecture

## Composition

```text
flake.nix
└── darwinConfigurations.<host>
    └── hosts/<host>
        ├── modules/darwin
        │   ├── Nix settings
        │   └── nix-homebrew + nix-darwin Homebrew declarations
        └── profiles/<user>
            └── modules/home
                ├── Nix-owned shell, Git, portable tools, and user files
                ├── Herdr terminal workspace manager
                ├── public op:// reference interface and runtime launchers
                └── shared AI renderers
```

`hosts/` is the composition boundary. Reusable policy belongs in `modules/`, and
reusable user choices belong in `profiles/`. Future NixOS servers should add
`nixosConfigurations` and `modules/nixos` without coupling server state to Darwin.

## Ownership

- **Nix** declares nixpkgs, Herdr `v0.8.0`, Home Manager, nix-darwin, and
  Homebrew inputs. `flake.lock` must pin them before activation.
- **nix-darwin** owns macOS system configuration, system generations, and the
  system-wide JetBrains Mono Nerd Font installation.
  `modules/darwin/macos-defaults.nix` is the focused owner of the supported
  Finder, keyboard, and global natural-scrolling baseline.
- **Home Manager/Nix** own Zsh and its plugins, Starship, cmux's
  Ghostty-compatible terminal-rendering configuration, Git, portable CLI
  packages, dotfiles, and Herdr. Integrated Home Manager activates with nix-darwin; no
  standalone Home Manager CLI is installed. The canonical package list is in
  `modules/home/development.nix`.
- **nix-homebrew** owns the Homebrew installation and taps.
- **nix-darwin Homebrew** owns native/vendor casks, with strict `uninstall`
  reconciliation and data-removing `zap` cleanup forbidden. Formulae are
  exceptions requiring a documented nixpkgs gap; the current list is empty.
  `modules/darwin/homebrew.nix` is the canonical cask/formula list.
- **cmux** is the native terminal application. **Herdr** is the persistent,
  tmux-style terminal workspace manager that runs inside cmux; it is not a
  separate terminal application. cmux owns mutable sessions and UI state.
- **mise** owns Node runtime installation and selection; the global fallback is
  Node 24, while exact production pins belong to project repositories.
- **uv** owns Python interpreters, environments, dependencies, and tools. Python
  is not selected by the global mise configuration.
- **rustup** owns Rust toolchains, targets, and components. Mise does not select
  Rust; Home Manager installs the rustup executable and proxies from nixpkgs.
- **Applications/providers** own mutable histories, auth sessions, and databases.
- **1Password** owns secret values and its optional SSH-agent runtime; Nix owns
  only references, mappings, and launchers.
- **LinearMouse** owns mouse event handling at runtime. Homebrew owns the native
  app, while Home Manager owns its documented immutable JSON configuration and
  launch agent. Only macOS Accessibility approval remains interactive.
- **Karabiner-Elements** owns keyboard event remapping at runtime. Homebrew owns
  the native app and services; Home Manager owns its complete declarative config
  directory. Raycast's native Hyper remapper stays off, and LinearMouse retains
  exclusive ownership of mouse behavior.
- **Spotlight** index contents remain mutable macOS state. A nix-darwin launch
  daemon classifies mounted volumes using `diskutil` and reconciles indexing and
  searching off for volumes macOS identifies as external. It never changes
  internal volume indexing and does not use a blanket all-volume command.

## AI source model

`ai/default.nix` is canonical. Renderers consume the same instructions and agent
prompts but produce client-native files. Client-specific settings should remain in
renderer modules rather than leaking into the shared source. The basic profile
keeps these renderers disabled until the AI configuration is ready to activate.
Anthropic's Claude Code terminal CLI is installed through the Homebrew
`claude-code` cask independently of this dormant renderer. The Claude desktop
cask is not installed.

Codex's declarative MCP TOML is rendered to a review artifact, not linked over its
mutable `~/.codex/config.toml`. Claude's user-scoped MCP state is likewise not
overwritten because it is mixed with mutable client state. Both need merge-safe
adapters before the generated registry becomes live client configuration.

## Runtime secret flow

```text
public op:// references in Nix
└── Home Manager reference-only env file
    └── claude launcher (when explicitly enabled)
        └── 1Password CLI (`op run`)
            ├── absolute Homebrew Claude Code terminal binary
            └── secret values in the child process environment only
```

Nix never calls `op read`, `op inject`, or `op run` during evaluation, build, or
activation. The generated launchers call `op run` only when a user starts the
client. This keeps resolved values out of the Nix store and activation logs. The
basic profile installs the CLI but keeps this runtime flow disabled.
