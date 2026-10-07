{
  lib,
  local,
  pkgs,
  ...
}:
let
  # Applied by ./dock.py rather than nix-darwin's `system.defaults.dock`,
  # because nix-darwin restarts the Dock on EVERY activation whenever any Dock
  # option is declared (modules/system/defaults-write.nix: `optionalString
  # (length dock > 0)` → `killall … Dock`), with no check that anything
  # changed. The owner's rule (2026-10-06) is that a rebuild restarts nothing
  # whose settings did not change. dock.py writes the same tile shapes
  # nix-darwin wrote, and only when the Dock's stored state differs.
  dock = {
    settings = {
      autohide = true;
      # Reorder Spaces by recent use instead of keeping fixed Space numbers.
      mru-spaces = true;
      show-recents = false;
    };

    apps = [
      # Apps.app replaced Launchpad.app; on macOS 27 (2026-10-05)
      # /System/Applications/Launchpad.app does not exist and its pin rendered
      # as a question mark.
      "/System/Applications/Apps.app"
      # The shim Chrome creates from ./chrome.nix's WebAppInstallForceList; its
      # dark icon is a Finder custom icon (../home/chrome-app-icons.nix). After
      # signing in to Google and reopening Chrome once, the real app's shim
      # takes this same path.
      "${local.homeDirectory}/Applications/Chrome Apps.localized/Gmail.app"
      "/Applications/Google Chrome.app"
      # Home Manager owns Ghostty (modules/home/terminal.nix) and, from
      # stateVersion 25.11 onward, copies rather than symlinks bundles into
      # this directory so Spotlight and LaunchServices resolve them.
      "${local.homeDirectory}/Applications/Home Manager Apps/Ghostty.app"
      "/Applications/ChatGPT.app"
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
    # The integers are what the Dock stores, the same mapping nix-darwin used:
    # arrangement name 1, date-added 2, date-modified 3, date-created 4,
    # kind 5; displayas stack 0; showas automatic 0. date-modified puts the
    # newest download at the top, the only ordering that makes a stack useful
    # for a directory this large.
    others = [
      {
        path = lib.removeSuffix "/" local.downloadsDirectory;
        arrangement = 3;
        displayas = 0;
        showas = 0;
      }
    ];
  };

  desired = pkgs.writeText "dock.json" (builtins.toJSON dock);
  asUser = ''launchctl asuser "$(id -u -- ${lib.escapeShellArg local.user})" sudo --user=${lib.escapeShellArg local.user} --'';
in
{
  # Which pinned apps exist BEFORE Homebrew runs, so the step after it can tell
  # whether this activation installed one. A newly installed pinned cask shows
  # as a question mark until the Dock re-resolves its tiles, which is the one
  # reason to restart the Dock when its settings did not change.
  system.activationScripts.preActivation.text = lib.mkAfter ''
    dockAppsBefore=""
    for dockApp in ${lib.escapeShellArgs dock.apps}; do
      [ -e "$dockApp" ] && dockAppsBefore="$dockAppsBefore|$dockApp|"
    done
  '';

  system.activationScripts.postActivation.text = lib.mkAfter ''
    dockAppAppeared=""
    for dockApp in ${lib.escapeShellArgs dock.apps}; do
      if [ -e "$dockApp" ] && [[ "$dockAppsBefore" != *"|$dockApp|"* ]]; then
        dockAppAppeared=--app-appeared
      fi
    done
    ${asUser} ${pkgs.python3}/bin/python3 -I ${./dock.py} ${desired} $dockAppAppeared
  '';
}
