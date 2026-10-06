{
  imports = [
    ./adobe-updates.nix
    ./askpass.nix
    ./chrome.nix
    ./dock.nix
    ./firewall.nix
    ./fonts.nix
    ./github-ssh.nix
    ./homebrew.nix
    ./log-rotation.nix
    ./macos-defaults.nix
    ./nix.nix
    ./power.nix
    ./spotlight.nix
    ./sudo.nix
  ];

  programs.zsh.enable = true;

  # The official Nix installer prepends shell_source_lines() since NixOS/nix
  # commit a408bc3e30e3e5b7ff61596d1072973679761363 (PR #14021).
  # Our pinned nix-darwin recognizes the older appended form, not these bytes.
  # Only recognize stock Apple files plus that exact hook: nix-darwin still
  # checks all other content and creates its normal .before-nix-darwin backups.
  # scripts/check-shell-bootstrap.py reproduces these hashes from public source
  # and cross-checks the stock/appended hashes against the pinned upstream lists.
  environment.etc."bashrc".knownSha256Hashes = [
    "8b5e3466922d1ae34bc145e21c7e53e7329a7a7b58b148b436bd954d5e651ac3"
  ];
  environment.etc."zshrc".knownSha256Hashes = [
    "cf0f7b7775b4c058d6085d9e7e57d58c307ca43730f8e4d921a9ef4e530e7e16" # macOS 26+
  ];

  # Bump only after reviewing nix-darwin release notes. This is not macOS's version.
  system.stateVersion = 6;
}
