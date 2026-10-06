{ ... }:
{
  # No screen saver. The display still turns off after 30 minutes
  # (modules/darwin/power.nix), and the Mac never sleeps.
  #
  # The idle timer is a per-host (`defaults -currentHost`) preference, which
  # nix-darwin has no option for, so it is declared through Home Manager's
  # currentHostDefaults. 0 is what System Settings shows as "Start Screen
  # Saver… Never": nix-plist-manager's `wallpaper.startScreenSaver` maps
  # "Never" to ByHost com.apple.screensaver idleTime = 0, and its harness
  # checks that against the real System Settings pane on macOS 27
  # (github.com/sushydev/nix-plist-manager, coverage.json, commit 4ef635b).
  targets.darwin.currentHostDefaults."com.apple.screensaver".idleTime = 0;
}
