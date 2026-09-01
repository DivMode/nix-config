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
    # that modules/home/downloads.nix creates. It is an SMB share again as of
    # 2026-08-31 (see the note in local.nix), so expect the question-mark tile
    # whenever that share is not mounted — the stack renders the path it was
    # given, mounted or not.
    #
    # `arrangement` is the stack's own sort order, the same control as the
    # "Sort by" section of its right-click menu. date-modified puts the newest
    # download at the top, which is the only ordering that makes a stack useful
    # for a directory this large. nix-darwin maps the name to the integer the
    # Dock actually stores (name 1, date-added 2, date-modified 3, date-created
    # 4, kind 5), so the readable name belongs here rather than the number.
    #
    # This is the attrset form of a persistent-others entry. A bare string still
    # works and means `{ folder = { path = …; arrangement = "name"; }; }`, which
    # is why the stack sorted alphabetically before.
    persistent-others = [
      {
        folder = {
          path = local.downloadsDirectory;
          arrangement = "date-modified";
        };
      }
    ];
    show-recents = false;
  };

  # nix-darwin applies Dock defaults before its Homebrew activation phase.
  # Refresh once more after Homebrew so newly installed casks resolve instead
  # of appearing as question marks during a machine's first activation.
  system.activationScripts.postActivation.text = ''
    /usr/bin/killall -qu ${local.user} Dock || true
  '';
}
