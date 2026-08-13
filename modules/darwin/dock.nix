{ local, ... }:
{
  system.defaults.dock = {
    autohide = true;
    # Reorder Spaces by recent use instead of keeping fixed Space numbers.
    mru-spaces = true;
    persistent-apps = [
      "/System/Applications/Launchpad.app"
      "/Applications/Google Chrome.app"
      # Chrome creates this real app shim after a profile first processes the
      # declared policy. It may show a question mark until Chrome is opened.
      "${local.homeDirectory}/Applications/Chrome Apps.localized/Gmail.app"
      "/Applications/ChatGPT.app"
      "/Applications/cmux.app"
    ];
    persistent-others = [ ];
    show-recents = false;
  };

  # nix-darwin applies Dock defaults before its Homebrew activation phase.
  # Refresh once more after Homebrew so newly installed casks resolve instead
  # of appearing as question marks during a machine's first activation.
  system.activationScripts.postActivation.text = ''
    /usr/bin/killall -qu ${local.user} Dock || true
  '';
}
