{
  config,
  inputs,
  local,
  ...
}:
{
  nix-homebrew = {
    enable = true;
    user = local.user;
    enableRosetta = local.system == "aarch64-darwin";
    autoMigrate = true;
    mutableTaps = false;
    taps = {
      "homebrew/homebrew-core" = inputs.homebrew-core;
      "homebrew/homebrew-cask" = inputs.homebrew-cask;
    };
  };

  homebrew = {
    enable = true;
    taps = builtins.attrNames config.nix-homebrew.taps;

    # Portable command-line tools belong to Nix/Home Manager. Add a formula
    # here only when nixpkgs is concretely unavailable or broken, and document
    # that exception beside the declaration.
    brews = [ ];
    casks = [
      "google-chrome"
      "chatgpt"
      "raycast"

      # Local, on-device voice input used on this Mac. Keeping it declared is
      # required because strict Homebrew reconciliation removes undeclared casks.
      "fluidvoice"

      # Native keyboard remapper. Home Manager owns its complete declarative
      # configuration directory; Raycast's native Hyper Key stays disabled.
      "karabiner-elements"

      # Anthropic's terminal CLI. This is not the Claude desktop application;
      # the separate `claude` cask must not be added to this profile.
      "claude-code"

      # Native terminal application. Herdr runs inside it and is installed by
      # Home Manager from its official flake instead of through Homebrew.
      "cmux"

      # Open-source mouse utility. Home Manager owns its immutable JSON
      # configuration and launch agent; only macOS Accessibility remains manual.
      "linearmouse"

      # The desktop app provides authentication and the CLI is a separate
      # vendor bundle; installing it does not enable secret injection.
      "1password"
      "1password-cli"
    ];
    masApps = { };

    onActivation = {
      autoUpdate = false;
      upgrade = false;

      # Reconcile only software managed by Homebrew. Never use "zap", which can
      # additionally remove application-associated files and user data.
      cleanup = "uninstall";
    };
  };
}
