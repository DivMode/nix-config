# macOS package ownership: Nix, Home Manager, Homebrew, and MAS

Date: 2026-08-12

## Decision

Use a deliberately asymmetric boundary:

| Owner | What it should own in this repository |
| --- | --- |
| macOS | Xcode Command Line Tools. |
| Nix / Home Manager | Zsh executable, configuration, and plugins; portable CLI tools; shell utilities; dotfiles; Git executable/configuration; Herdr; fonts; custom scripts; and user-level program configuration. |
| nix-darwin | Host settings, users, system defaults, Dock, Nix settings, Home Manager wiring, and declarative Homebrew orchestration. |
| nix-homebrew | Installation and pinning of Homebrew itself, plus declarative tap ownership. It does **not** manage packages installed by Homebrew. |
| Homebrew casks | Native macOS GUI applications, vendor-distributed applications, and packages whose supported/up-to-date macOS delivery is materially better through Homebrew. |
| Homebrew formulae | Exceptions only: macOS-specific tools or important packages unavailable, broken, or impractical in nixpkgs. Record the reason beside each exception. |
| Mac App Store (`masApps`) | Store-only applications when CLI installation works reliably and the account has already acquired them. |
| Project files | Project-specific runtimes and dependencies. Keep exact Node/Python/Rust versions in each repository rather than a mutable global list. |

Therefore we should **not install Zsh, `zsh-autosuggestions`, or syntax highlighting with Homebrew**. This repository uses the same Nixpkgs Zsh package at both layers: nix-darwin registers and selects it as the user's login shell, while Home Manager configures it and supplies its plugins. This keeps the complete shell setup portable, versioned, rollbackable, and avoids an Apple/Brew/Nix ownership split. Home Manager's Zsh module directly provides `package`, `autosuggestion`, and `syntaxHighlighting` options and sources those Nix packages into the generated Zsh configuration ([Home Manager Zsh module](https://github.com/nix-community/home-manager/blob/master/modules/programs/zsh/default.nix)).

`nix-darwin programs.zsh.enable` and Home Manager `programs.zsh.enable` are different layers. The former creates the macOS system shell integration/environment; the latter manages the user's `.zshrc`, plugins, completion, aliases, and history. Here, `environment.shells`, the declared user's `shell`, and `programs.zsh.package` all refer to `pkgs.zsh`.

## What the official modules actually do

- The nix-darwin Homebrew module generates a Brewfile and invokes `brew bundle` during activation. Its defaults avoid auto-update and upgrade so repeated unchanged activations are idempotent; cleanup/upgrade behavior is explicitly configurable ([nix-darwin Homebrew module](https://github.com/nix-darwin/nix-darwin/blob/master/modules/homebrew.nix)).
- `homebrew.brews` declares formulae, `homebrew.casks` declares casks, and `homebrew.masApps` declares App Store IDs. Removed MAS entries are **not** automatically uninstalled, even with cleanup enabled ([nix-darwin `masApps`](https://github.com/nix-darwin/nix-darwin/blob/master/modules/homebrew.nix)).
- `nix-homebrew` states that it installs/pins Homebrew and optionally owns taps, but does not manage formulae or casks; it directs users to nix-darwin's `homebrew.*` options for those ([nix-homebrew README](https://github.com/zhaofengli/nix-homebrew)).
- The Home Manager Zsh module owns configuration plus Nix-provided autosuggestions and syntax-highlighting packages ([Home Manager source](https://github.com/nix-community/home-manager/blob/master/modules/programs/zsh/default.nix)).

## Evidence from five active macOS Nix configurations

Stars and activity were read from GitHub on 2026-08-12; counts are only a popularity signal and will change.

| Repository | Popularity / activity | Observed ownership pattern |
| --- | --- | --- |
| [wimpysworld/nix-config](https://github.com/wimpysworld/nix-config) | 709 stars; pushed 2026-08-13 UTC | Nix owns shells, CLI tools, fonts, scripts, and many GUI packages available in nixpkgs. Homebrew owns selected native GUI casks such as Blender, Inkscape, Zed, Docker Desktop, OBS, and Tailscale. Its Darwin config enables nix-homebrew and nix-darwin's Homebrew activation; see [Darwin config](https://github.com/wimpysworld/nix-config/blob/main/darwin/default.nix) and [desktop mixin](https://github.com/wimpysworld/nix-config/blob/main/darwin/_mixins/desktop/default.nix). |
| [dustinlyons/nixos-config](https://github.com/dustinlyons/nixos-config) | 3,591 stars; pushed 2026-07-28 UTC | Homebrew's declared list is essentially GUI casks; Nix/Home Manager owns broad CLI/dev packages and Zsh with Nix plugins such as Powerlevel10k. See [Darwin Home Manager](https://github.com/dustinlyons/nixos-config/blob/main/modules/darwin/home-manager.nix), [casks](https://github.com/dustinlyons/nixos-config/blob/main/modules/darwin/casks.nix), and [shared Home Manager config](https://github.com/dustinlyons/nixos-config/blob/main/modules/shared/home-manager.nix). |
| [mitchellh/nixos-config](https://github.com/mitchellh/nixos-config) | 3,071 stars; pushed 2026-06-19 UTC | Homebrew owns native GUI casks and one formula (`gnupg`); Home Manager owns the large portable CLI set, shells, dotfiles, editors, and language tools. nix-darwin enables macOS Zsh integration. See [Darwin packages](https://github.com/mitchellh/nixos-config/blob/main/users/mitchellh/darwin.nix), [Home Manager](https://github.com/mitchellh/nixos-config/blob/main/users/mitchellh/home-manager.nix), and [Mac host](https://github.com/mitchellh/nixos-config/blob/main/machines/macbook-pro-m1.nix). |
| [ryan4yin/nix-config](https://github.com/ryan4yin/nix-config) | 2,013 stars; pushed 2026-08-10 UTC | Uses Nix for core/portable packages and Home Manager shell configuration, but a broader Homebrew exception set for casks and macOS/problematic formulae. The file explicitly says Nix packages are reproducible/rollbackable while Homebrew can be more stable on macOS. See [Darwin apps](https://github.com/ryan4yin/nix-config/blob/main/modules/darwin/apps.nix), [Darwin shell](https://github.com/ryan4yin/nix-config/blob/main/home/darwin/shell.nix), and [portable CLI packages](https://github.com/ryan4yin/nix-config/blob/main/modules/base/packages.nix). |
| [khaneliman/khanelinix](https://github.com/khaneliman/khanelinix) | 341 stars; pushed 2026-08-13 UTC | Home Manager/Nix owns a highly configured Zsh plus syntax highlighting and autosuggestions. Homebrew owns selected casks, MAS apps, and a small number of macOS formula exceptions. See [Zsh module](https://github.com/khaneliman/khanelinix/blob/main/modules/home/programs/terminal/shells/zsh/default.nix), [Homebrew module](https://github.com/khaneliman/khanelinix/blob/main/modules/darwin/tools/homebrew/default.nix), and [desktop suite](https://github.com/khaneliman/khanelinix/blob/main/modules/darwin/suites/desktop/default.nix). |

The common pattern is not “everything on macOS goes through Brew.” It is: Nix owns the reproducible Unix/user environment; Homebrew fills the native-macOS and packaging gaps. Wimpy's repository follows that hybrid model too.

## Exact recommendation for this public repository

### Nix / Home Manager

Nixpkgs Zsh is the executable, nix-darwin assigns it as the login shell, and
Home Manager owns its configuration and plugins. Portable user and developer
tools also belong here. `modules/home/development.nix` is the canonical current
package list; this research note records the ownership decision, not a second
manifest.

### Homebrew

Homebrew owns the requested native/vendor casks. `modules/darwin/homebrew.nix` is
the canonical current cask and formula list.

Homebrew formulae should start empty after portable CLIs move to Nix. Add a formula only with a nearby comment documenting why nixpkgs is unsuitable. `claude-code` remains a cask because the user explicitly selected vendor/Homebrew delivery and it changes rapidly.

The `claude-code` cask is Anthropic's terminal CLI and installs the `claude` command. It is distinct from Homebrew's `claude` desktop cask, which is intentionally absent.

### MAS

Do not add MAS applications yet. MAS adds Apple-ID/acquisition state and removal is not symmetric. Add a store-only app only when there is no preferable cask/Nix package and the rebuild procedure documents the required sign-in/acquisition step.

## Practical rules for future additions

1. If it is a portable CLI or shell plugin and works in nixpkgs, use Nix/Home Manager.
2. If it is a native `.app` distributed by a vendor and updated rapidly, prefer a Homebrew cask.
3. If it is macOS-specific or broken/unavailable in nixpkgs, use a Homebrew formula and document the exception.
4. If it is Store-only, use `masApps`, accepting its external account state and non-declarative removal limitation.
5. Never declare the same executable in two owners. The configuration should make package ownership obvious from one file and one comment.
6. Avoid automatic upgrades during every `darwin-rebuild` if reproducibility is the priority. Update pinned flake inputs/Homebrew state intentionally, then activate.
