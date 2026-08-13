{
  imports = [
    ./dock.nix
    ./fonts.nix
    ./homebrew.nix
    ./macos-defaults.nix
    ./nix.nix
    ./spotlight.nix
  ];

  programs.zsh.enable = true;

  # Bump only after reviewing nix-darwin release notes. This is not macOS's version.
  system.stateVersion = 6;
}
