{ ... }:
{
  # This machine stays awake and comes back by itself. It hosts long-running
  # work and is administered remotely, so an unattended sleep is an outage.
  power = {
    sleep = {
      # "Prevent automatic sleeping when the display is off". The display may
      # sleep; the machine may not.
      computer = "never";

      # Turn the display off after 30 minutes idle. There is no screen saver
      # (modules/home/screensaver.nix); macOS asks for the password when the
      # display wakes, after its own lock delay (sysadminctl -screenLock).
      display = 30;

      # "Put hard disks to sleep when possible" — off. Spinning storage back up
      # stalls whatever is running.
      harddisk = "never";
    };

    # "Start up automatically after a power failure". Without this the machine
    # stays dark after an outage and has to be woken physically.
    restartAfterPowerFailure = true;

    # "Restart automatically if the computer freezes". A hung server that waits
    # for someone to hold the power button is the same outage as a dark one.
    restartAfterFreeze = true;
  };

  # "Wake for network access" (pmset womp). nix-darwin applies it with
  # `systemsetup -setWakeOnNetworkAccess`. It already read 1 on 2026-10-06;
  # declared so a new machine gets it too.
  networking.wakeOnLan.enable = true;

  # Low Power Mode (pmset lowpowermode 0) has no nix-darwin option; verify it
  # with `pmset -g custom`.
}
