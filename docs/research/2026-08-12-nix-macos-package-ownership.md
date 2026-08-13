# macOS package ownership with Nix

Date: 2026-08-12

## Decision

Use one owner per concern:

- **Nix + Home Manager:** Zsh, Zsh plugins, Git, dotfiles, portable CLI/developer tools, and Herdr.
- **nix-darwin:** macOS defaults, users, shells, Dock/Finder settings, and system activation.
- **Homebrew casks:** native macOS applications and vendor-distributed Mac bundles that are
  unavailable, materially worse, or operationally awkward in nixpkgs.
- **Homebrew formulas:** exceptions only. Each exception must say why nixpkgs/Home Manager
  cannot reasonably own it.

Therefore, Zsh, autosuggestions, and syntax highlighting should **not** be Homebrew formulas in
this configuration. Home Manager has first-class `programs.zsh` options and owns the shell
package, configuration, and plugins. nix-darwin registers that same Nix Zsh package and assigns
it as the user's login shell. This makes the shell setup portable to future Linux machines
instead of coupling it to Apple `/bin/zsh` or `/opt/homebrew`.

## What the sampled repositories actually do

The five locally cloned macOS Nix configurations are not identical, but the strongest and most
reusable pattern is clear:

- **Wimpy:** tells contributors to put user packages in `home.packages`; its Darwin desktop
  module uses Homebrew primarily for casks while native/CLI packages come from nixpkgs.
  Evidence: `wimpy/AGENTS.md`, `wimpy/darwin/default.nix`, and
  `wimpy/darwin/_mixins/desktop/default.nix`.
- **Dustin Lyons:** integrates Home Manager into nix-darwin, describes the shared HM module as
  owning shell/editor/tool configuration, and directs macOS casks to a Darwin cask module.
  Evidence: `dustin/CLAUDE.md`, `dustin/flake.nix`, and
  `dustin/modules/darwin/home-manager.nix`.
- **Kunchen:** uses `home.packages` for `ripgrep`, `fd`, `fzf`, `jq`, Neovim, and fonts; uses
  `programs.zsh` for autosuggestions and syntax highlighting; and leaves only a narrow formula
  exception plus Mac casks in Homebrew. Evidence: `kunchen/home.nix` and
  `kunchen/configuration.nix`.
- **Heywood:** integrates Home Manager as a nix-darwin module and separates user configuration
  from a Darwin Brew role. It contains more legacy Brew formulas than the recommended target,
  showing that public repos are evidence, not a rule to copy blindly. Evidence:
  `heywood/roles/home-manager/settings.nix` and `heywood/roles/brew.nix`.
- **Colonel Panic:** integrates Home Manager into the Darwin build, manages Zsh through Nix/HM,
  keeps a broad `home.packages` set, and limits Homebrew to a small explicit formula list and
  casks. Evidence: `colonel/nix-darwin/flake.nix` and
  `colonel/nix-darwin/home/common.nix`.

Across the sample, mature configurations use Home Manager for portable user-space state and
nix-darwin for macOS state. Homebrew remains an escape hatch, especially for `.app` bundles.

## Home Manager: integrated module versus CLI

These are separate things:

1. Importing `home-manager.darwinModules.home-manager` integrates each declared HM user into
   the nix-darwin system generation. A single `darwin-rebuild switch --flake ...` then builds
   and activates both the Mac configuration and the user's Home Manager configuration.
2. `programs.home-manager.enable = true` adds the standalone `home-manager` convenience CLI to
   the user's profile.

The integrated module is the architecture we need. The standalone CLI is optional; it does not
perform the integration and is not required for the one-command rebuild. Prefer leaving it off
to keep one activation path (`darwin-rebuild`) unless we deliberately want independent HM-only
switches.

## Migration of the current Homebrew declaration

Portable formulae moved to Nix/Home Manager and the Homebrew formula list became
empty. Native/vendor applications remained Homebrew casks. The live manifests,
not this research note, are canonical: `modules/home/development.nix` owns the
portable package list and `modules/darwin/homebrew.nix` owns casks and formula
exceptions.

`1password-cli` and `claude-code` are command-line-facing exceptions, but they are casks/vendor
bundles rather than ordinary portable formulas. Keep the exception explicit so it can be
revisited if the desired integration becomes reliable through nixpkgs.

`claude-code` is Anthropic's terminal CLI and installs the `claude` command. Do not confuse it
with or add the separate `claude` desktop cask.

Herdr comes from the pinned release `github:ogulcancelik/herdr/v0.8.0`, whose official flake exports a default package for
both Darwin architectures. Its nixpkgs input follows this repository's nixpkgs input, which becomes pinned by `flake.lock`. Herdr
is a persistent, tmux-style terminal workspace manager that runs inside cmux, not another
native terminal application.

## Resulting activation model

`darwin-rebuild` evaluates one flake, nix-darwin applies system/macOS settings, its integrated
Home Manager module activates Zsh/dotfiles/user packages, and the declarative Homebrew module
reconciles only the native/vendor casks. Package upgrades are then controlled by the flake lock
for Nix-owned software and by the declared Homebrew policy for casks.

## Primary references

- [Home Manager manual](https://nix-community.github.io/home-manager/index.xhtml)
- [Home Manager option search](https://nix-community.github.io/home-manager/options.xhtml)
- [nix-darwin](https://github.com/nix-darwin/nix-darwin)
- [nix-homebrew](https://github.com/zhaofengli/nix-homebrew)
- Public repositories cited above were inspected at their referenced revisions.
