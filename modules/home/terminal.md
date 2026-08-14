# Terminal and Zsh

Ghostty is the terminal application. Herdr is the Nix-installed persistent,
tmux-style workspace manager that runs inside it; it is a CLI/TUI, not another
`.app`. Ghostty owns the Dock slot, the Hyper+Space Karabiner binding, and the
LaunchServices shell handlers.

Home Manager installs Ghostty from `pkgs.ghostty-bin`, the vendor's signed macOS
build, because nixpkgs cannot build Ghostty from source on Darwin — it has no
Swift 6 or xcodebuild-friendly environment, so `pkgs.ghostty` is Linux-only and
the Home Manager module's default package fails to evaluate here. The flake pins
the version, so Ghostty's own Sparkle updater is turned off.

Home Manager copies Ghostty into `~/Applications/Home Manager Apps`, which macOS
gates behind App Management permission for whichever terminal runs the rebuild.

Theme names are the display form printed by `ghostty +list-themes`, spaces and
capitals included. `catppuccin-mocha` is rejected as not found; `Catppuccin
Mocha` validates. The `light:,dark:` pair follows the macOS appearance setting.

Ghostty's early reputation for thin, washed-out text on macOS was linear alpha
blending, which the documentation describes as making dark text "look much
thinner than normal and light text much thicker". The macOS default has been
`native` since Ghostty 1.1.0, so no workaround is needed; `alpha-blending` is
declared at that same value to record that the old workaround is obsolete.
`font-thicken` is the remaining dial and is off, because it is documented to
make blur worse on non-HiDPI displays and this machine drives a single
5120x2880 Retina panel. The blurry-text reports that remain open upstream are
specific to low-DPI external monitors; attaching one is the condition under
which `font-thicken` becomes worth setting.

nix-darwin registers the Nix-provided Zsh as an allowed login shell. Home Manager
owns its completion, autosuggestions, syntax highlighting, fzf integration,
Starship prompt, mise activation, and Ghostty's shell integration. It uses an
Emacs keymap, interactive comments, and no terminal bell.

History is mutable local state at `~/.local/state/zsh/history`; it never belongs
in Git, iCloud, or the Nix store. Project commands belong in project `justfile`s,
not in a global alias collection that can hide deploy or destructive context.
The per-project launchers in `projects.md` are not an exception to that rule:
they change directory and start an agent, wrapping no build or deploy step.

nix-darwin installs JetBrains Mono Nerd Font. Ghostty selects
`JetBrainsMono Nerd Font Mono` at 14 pt, and Starship uses the official Nerd Font
Symbols preset.

Oh My Zsh is intentionally absent. Home Manager already owns its useful baseline
features, and the Oh My Zsh `sudo` plugin's double-Escape binding conflicts with
the Caps Lock to Escape mapping.
