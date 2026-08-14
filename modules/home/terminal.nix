{ lib, pkgs, ... }:
{
  # Ghostty is the terminal; Herdr provides the persistent workspace and pane
  # management, so a plain terminal emulator is enough.
  programs.ghostty = {
    enable = true;

    # `pkgs.ghostty` is Linux-only: nixpkgs cannot build Ghostty from source on
    # Darwin, so the module's default package fails to evaluate here.
    # `ghostty-bin` is the vendor's signed macOS build, pinned by the flake.
    package = pkgs.ghostty-bin;

    enableZshIntegration = true;

    # bat is not declared on this machine, so there is no syntax cache to add a
    # Ghostty grammar to. Re-enable alongside a `programs.bat` declaration.
    installBatSyntax = false;

    settings = {
      # nix-darwin installs this family system-wide in modules/darwin/fonts.nix.
      # The `Mono` variant is the one whose Nerd Font glyphs stay inside a
      # single cell, which is what Starship's nerd-font-symbols preset needs.
      font-family = "JetBrainsMono Nerd Font Mono";
      font-size = 14;

      # Names are the display form printed by `ghostty +list-themes`, spaces and
      # capitals included; `catppuccin-mocha` is rejected as not found. The
      # `light:,dark:` pair follows the macOS appearance setting.
      theme = "light:Catppuccin Latte,dark:Catppuccin Mocha";

      # Nix owns the version through flake.lock; Sparkle cannot write to the
      # store path anyway.
      auto-update = "off";

      # Herdr owns session persistence. Restoring macOS window state on top of
      # that reopens panes that Herdr is also restoring.
      window-save-state = "never";
    };
  };

  # macOS has no single "default terminal" setting and nix-darwin exposes no
  # option for one. The closest mechanism is the LaunchServices document-type
  # handler, which decides what opens an executable script. `duti` is the
  # supported CLI for that; nothing else writes the handler database safely.
  home.packages = [ pkgs.duti ];

  # Roles mirror what Ghostty.app's own Info.plist declares, because
  # LaunchServices ignores a claim an application does not support:
  #
  #   * `public.unix-executable` — declared with CFBundleTypeRole = Shell.
  #   * `com.apple.terminal.shell-script` — declared by extension (.command,
  #     .sh, .zsh, .csh, .tool, .pl) with CFBundleTypeRole = Editor.
  #
  # Ghostty also declares `public.directory` at LSHandlerRank = Alternate. That
  # is deliberately NOT claimed: it would make double-clicked folders open a
  # terminal instead of Finder.
  home.activation.setDefaultTerminalHandler = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${pkgs.duti}/bin/duti -s com.mitchellh.ghostty public.unix-executable shell
    run ${pkgs.duti}/bin/duti -s com.mitchellh.ghostty com.apple.terminal.shell-script editor
  '';

  programs.starship = {
    enable = true;
    enableZshIntegration = true;
    presets = [ "nerd-font-symbols" ];
    settings.add_newline = false;
  };
}
