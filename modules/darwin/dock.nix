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
      # Home Manager owns Ghostty (modules/home/terminal.nix) and, from
      # stateVersion 25.11 onward, copies rather than symlinks bundles into
      # this directory so Spotlight and LaunchServices resolve them.
      "${local.homeDirectory}/Applications/Home Manager Apps/Ghostty.app"
    ];
    # The downloads directory, as a Dock stack. Absolute path deliberately: a
    # relative path or a `~` produces a Dock item that renders but opens
    # nothing, and it fails silently (nix-darwin#968, nix-darwin#1398).
    #
    # Same single local.nix definition Chrome's DownloadDirectory uses, and
    # that modules/home/downloads.nix creates. It named an SMB share until
    # 2026-08-27; a stack pinned to an unmounted share is the question-mark
    # tile this comment used to describe as a first-activation quirk.
    persistent-others = [ local.downloadsDirectory ];
    show-recents = false;
  };

  # nix-darwin applies Dock defaults before its Homebrew activation phase.
  # Refresh once more after Homebrew so newly installed casks resolve instead
  # of appearing as question marks during a machine's first activation.
  system.activationScripts.postActivation.text = ''
    /usr/bin/killall -qu ${local.user} Dock || true
  '';
}
