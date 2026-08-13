{
  config,
  lib,
  local,
  pkgs,
  ...
}:
{
  imports = [
    ./ai
    ./development.nix
    ./karabiner.nix
    ./launchers.nix
    ./mouse.nix
    ./privacy.nix
    ./screensaver.nix
    ./secrets.nix
    ./terminal.nix
  ];

  programs.git = {
    enable = true;
    settings = {
      user = {
        inherit (local.git) name email;
        signingKey = local.git.signingKey;
      };
      init.defaultBranch = "main";
      pull.rebase = true;
      gpg = {
        format = "ssh";
        ssh.program = "/Applications/1Password.app/Contents/MacOS/op-ssh-sign";
      };
      commit.gpgSign = true;
      tag.gpgSign = true;
    };
  };

  programs.zsh = {
    enable = true;
    package = pkgs.zsh;
    enableCompletion = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;
    defaultKeymap = "emacs";
    setOptions = [
      "INTERACTIVE_COMMENTS"
      "NO_BEEP"
    ];
    history = {
      path = "${config.xdg.stateHome}/zsh/history";
      size = 50000;
      save = 10000;
      expireDuplicatesFirst = true;
      extended = true;
      findNoDups = true;
      ignoreDups = true;
      ignoreSpace = true;
      share = true;
    };
  };

  programs.fzf = {
    enable = true;
    enableZshIntegration = true;
  };

  # Home Manager is integrated into the nix-darwin generation. Do not install
  # the separate `home-manager` CLI or create a second activation path.
  programs.home-manager.enable = false;
  # The shared AI renderers and API-secret runtime injection remain dormant.
  # SSH authentication and Git signing are a separate 1Password capability.
  nixConfig.ai.enable = false;
  nixConfig.secrets.onePassword.enable = false;
  nixConfig.secrets.onePassword.sshAgent.enable = lib.mkDefault true;

  # Validate collisions before Home Manager begins writing any managed state.
  home.activation.validateScreenshotsDirectory = lib.hm.dag.entryBefore [ "writeBoundary" ] ''
    screenshotsDirectory="${config.home.homeDirectory}/Documents/Screenshots"
    if [[ -L "$screenshotsDirectory" || ( -e "$screenshotsDirectory" && ! -d "$screenshotsDirectory" ) ]]; then
      echo "Cannot create $screenshotsDirectory because a symlink or non-directory already exists" >&2
      exit 1
    fi
  '';

  # Screenshot.app requires its destination to exist as a normal writable
  # directory. `run` preserves Home Manager's dry-run behavior.
  home.activation.ensureScreenshotsDirectory = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run mkdir -p "${config.home.homeDirectory}/Documents/Screenshots"
  '';

  # Bump only after reviewing Home Manager release notes.
  home.stateVersion = "26.05";
}
