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
- **Home Manager/Nix** own Zsh and its plugins, Starship, Ghostty and its
  terminal-rendering configuration, Git, portable CLI
  packages, dotfiles, and Herdr. Integrated Home Manager activates with nix-darwin; no
  standalone Home Manager CLI is installed. The canonical package list is in
  `modules/home/development.nix`.
- **nix-homebrew** owns the Homebrew installation and taps.
- **nix-darwin Homebrew** owns native/vendor casks, with strict `uninstall`
  reconciliation and data-removing `zap` cleanup forbidden. Formulae are
  exceptions requiring a documented nixpkgs gap; the current list is empty.
  `modules/darwin/homebrew.nix` is the canonical cask/formula list.
- **Ghostty** is the terminal application, installed by Home Manager from
  `pkgs.ghostty-bin` — the vendor's signed macOS build, because nixpkgs cannot
  build Ghostty from source on Darwin. **Herdr** is the persistent, tmux-style
  terminal workspace manager that runs inside it; it is not a separate terminal
  application. Ghostty owns mutable window and UI state.
- **IINA** is the media player and **Calibre** manages the e-book library. Both
  are Homebrew casks, like every other native GUI application here.
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

The `ai/` directory is canonical. `ai/default.nix` supplies shared instructions
and agent prompts, while client-specific declarations stay in their own source
and renderer modules rather than leaking into the shared layer.

The renderers are enabled, and the reason is recoverability: a coding agent
deleted a previous machine's assistant configuration, so the instruction file,
agent definitions, and Claude Code's user settings — including the PreToolUse
guard that enforces Nix-only machine changes — are all declared here and
restored by `darwin-rebuild switch`. Project-scoped instructions stay in each
project's own repository; this layer is deliberately global-only.

Claude Code's own Home Manager module, `programs.claude-code`, owns the
instruction file and agent definitions. Its `package` and `settings` options are
deliberately unused: the package is installed by `modules/home/development.nix`
from the `llm-agents` flake input, and `settings.json` is installed as a real
reasserted file because that option would make an application-writable file a
read-only store symlink. The Claude desktop cask is not installed.

Codex's declarative MCP TOML is rendered to a review artifact, not linked over
its mutable `~/.codex/config.toml`. A separate TomlKit adapter atomically merges
only the generic approval, sandbox, and app defaults into that live file while
preserving its unknown application-owned state. Claude's user-scoped MCP state
is likewise not overwritten because it is mixed with mutable client state; the
generated MCP registry remains review-only for both clients.

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
