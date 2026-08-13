{ lib, pkgs, ... }:
{
  # cmux uses libghostty for terminal rendering and reads this standard Ghostty
  # configuration. Mutable workspaces, sessions, and scrollback remain app-owned.
  xdg.configFile."ghostty/config".text = ''
    font-family = JetBrainsMono Nerd Font Mono
    font-size = 14
  '';

  # macOS has no single "default terminal" setting and nix-darwin exposes no
  # option for one. The closest mechanism is the LaunchServices document-type
  # handler, which decides what opens an executable script. `duti` is the
  # supported CLI for that; nothing else writes the handler database safely.
  home.packages = [ pkgs.duti ];

  # Only the two types cmux declares with CFBundleTypeRole = Shell are claimed.
  # cmux also declares public.folder, which is deliberately NOT set here:
  # claiming it would make double-clicked folders open a terminal instead of
  # Finder. cmux likewise declares http/https at rank Default; leaving the
  # browser handler alone is intentional.
  home.activation.setDefaultTerminalHandler = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${pkgs.duti}/bin/duti -s com.cmuxterm.app com.apple.terminal.shell-script shell
    run ${pkgs.duti}/bin/duti -s com.cmuxterm.app public.unix-executable shell
  '';

  programs.starship = {
    enable = true;
    enableZshIntegration = true;
    presets = [ "nerd-font-symbols" ];
    settings.add_newline = false;
  };
}
