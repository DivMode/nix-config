# Terminal and Zsh

cmux is the native terminal application. Herdr is the Nix-installed persistent,
tmux-style workspace manager that runs inside cmux; it is a CLI/TUI, not another
`.app`.

nix-darwin registers the Nix-provided Zsh as an allowed login shell. Home Manager
owns its completion, autosuggestions, syntax highlighting, fzf integration,
Starship prompt, and mise activation. It uses an Emacs keymap, interactive
comments, and no terminal bell.

History is mutable local state at `~/.local/state/zsh/history`; it never belongs
in Git, iCloud, or the Nix store. Project commands belong in project `justfile`s,
not in a global alias collection that can hide deploy or destructive context.

nix-darwin installs JetBrains Mono Nerd Font. cmux selects
`JetBrainsMono Nerd Font Mono` at 14 pt through its Ghostty-compatible config,
and Starship uses the official Nerd Font Symbols preset.

Oh My Zsh is intentionally absent. Home Manager already owns its useful baseline
features, and the Oh My Zsh `sudo` plugin's double-Escape binding conflicts with
the Caps Lock to Escape mapping.
