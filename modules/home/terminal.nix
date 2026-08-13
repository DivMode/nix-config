{ ... }:
{
  # cmux uses libghostty for terminal rendering and reads this standard Ghostty
  # configuration. Mutable workspaces, sessions, and scrollback remain app-owned.
  xdg.configFile."ghostty/config".text = ''
    font-family = JetBrainsMono Nerd Font Mono
    font-size = 14
  '';

  programs.starship = {
    enable = true;
    enableZshIntegration = true;
    presets = [ "nerd-font-symbols" ];
    settings.add_newline = false;
  };
}
