{ ... }:
{
  # Screen saver idle time. nix-darwin exposes `system.defaults.screensaver`
  # options for the password prompt but none for the idle timer, and the timer
  # is a per-host (`defaults -currentHost`) preference, so it is declared here
  # through Home Manager's currentHostDefaults rather than in the system module.
  #
  # 20 minutes, deliberately shorter than the 30-minute display sleep in
  # modules/darwin/power.nix, so the lock engages before the screen goes dark.
  targets.darwin.currentHostDefaults."com.apple.screensaver".idleTime = 1200;
}
