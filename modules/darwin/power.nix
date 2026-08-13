{ ... }:
{
  # This machine stays awake and comes back by itself. It hosts long-running
  # work and is administered remotely, so an unattended sleep is an outage.
  power = {
    sleep = {
      # "Prevent automatic sleeping when the display is off". The display may
      # sleep; the machine may not.
      computer = "never";

      # Blank the display after 20 minutes of idle, matching the screen saver
      # in modules/home/screensaver.nix, and cut the backlight at 30.
      display = 30;

      # "Put hard disks to sleep when possible" — off. Spinning storage back up
      # stalls whatever is running.
      harddisk = "never";
    };

    # "Start up automatically after a power failure". Without this the machine
    # stays dark after an outage and has to be woken physically.
    restartAfterPowerFailure = true;
  };

  # Not declarable through nix-darwin, and already correct on this host:
  #   womp 1          "Wake for network access"
  #   lowpowermode 0  Low Power Mode off
  # nix-darwin exposes no options for either (only power.sleep.* and
  # power.restartAfter*). They would need a `pmset` activation script, which is
  # deliberately not added here — verify them with `pmset -g custom` instead.
}
