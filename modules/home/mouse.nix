{ lib, pkgs, ... }:
let
  # LinearMouse's documented configuration interface. Match the device category
  # instead of a particular receiver so this works with Bluetooth and future MX
  # mice while leaving trackpad natural scrolling untouched.
  linearMouseConfiguration = pkgs.writeText "linearmouse.json" (
    builtins.toJSON {
      "$schema" = "https://schema.linearmouse.app/0.11.4";
      schemes = [
        # TWO schemes, exactly as LinearMouse itself wrote them. Do not merge
        # them into one. Collapsing the pair into a single category-level
        # scheme on 2026-08-13 changed the scroll feel immediately and
        # noticeably, even though the merged file carried the same key/value
        # pairs — so the split is load-bearing, not incidental formatting.
        #
        # The base scheme covers any mouse. The second matches this receiver
        # specifically and carries the smoothed-scrolling tuning; where both
        # match, the more specific one wins.
        {
          "if".device.category = "mouse";
          logitech.highResolutionWheel = false;
          scrolling.reverse.vertical = true;
        }
        {
          "if".device = {
            category = "mouse";
            vendorID = "0x46d";
            productID = "0xc548";
            productName = "USB Receiver";
          };

          # On for this device only. Enabled on its own it was rejected the
          # same day as worse — finer steps alone just make the wheel feel
          # loose, because the substeps are recombined into ordinary detents
          # unless the scrolling mode is smoothed. Paired with the smoothed
          # engine below it is what was actually wanted.
          logitech.highResolutionWheel = true;

          # Tuned by hand in LinearMouse's settings window and read back out of
          # the file it wrote, rather than transcribed from the visible
          # sliders — inertia, speed, acceleration and bouncing all sit below
          # the fold in that window.
          #
          # Captured here because of the arrangement described at the top of
          # this file: the application owns this file at runtime and activation
          # reasserts it, so tuning done in the settings window is lost at the
          # next rebuild unless it is written down first.
          scrolling = {
            acceleration.vertical = 1;
            distance.vertical = "auto";
            speed.vertical = 0;
            smoothed.vertical = {
              # 0 is the range's lower bound, which the engine treats as a
              # switch rather than a value: at the bound it bypasses the
              # rate-dependent input curve and the acceleration gain entirely,
              # so every wheel tick travels a constant distance however fast
              # the wheel is spun.
              #
              # Tried at 0 on 2026-08-13 and reverted, along with speed. Neither
              # made terminal text readable while scrolling, and both were worse
              # elsewhere. Taken together those two results say the same thing:
              # if removing rate-dependence AND cutting travel by a third change
              # nothing, then how far and how fast the pointer scrolls is not
              # what makes terminal text unreadable. Look at the terminal, which
              # scrolls whole lines through a scrollback buffer rather than
              # pixels, not at this file.
              acceleration = 1.1;

              # False keeps the smoothed momentum tail but stops LinearMouse
              # marking the synthetic events with scroll-phase and
              # momentum-phase flags. With those flags an application treats
              # the stream as a trackpad gesture, and many hold or discard
              # input while a momentum phase is still running — which is felt
              # as a delay when reversing direction straight after a scroll.
              # Was true.
              bouncing = false;

              enabled = true;

              # Left at the tuned value on purpose. The engine cancels an
              # opposing momentum tail on a direction change, and inertia sets
              # how long that tail lasts — default is 0.65, and decay compounds
              # per frame. If reversing still lags with bouncing off, this is
              # the next thing to lower.
              inertia = 0.74;

              preset = "easeInOut";
              response = 0.68;

              # Distance per wheel tick. With acceleration at its bypass the
              # engine computes
              #   velocity = magnitude * profile.velocityScale * (0.85 + speed * 0.4)
              # so this is a plain multiplier: 1.02 gives 1.258, and 0 gives
              # 0.85, the floor.
              #
              # Tried at 0 on 2026-08-13 and reverted: a third less travel per
              # tick did NOT make text readable while scrolling in the terminal,
              # and the slower scroll was worse everywhere else. That result is
              # the useful part — if cutting distance by a third changes nothing
              # about readability, distance is not what makes terminal text
              # unreadable, and no amount of further tuning here will fix it.
              speed = 1.02;
            };
          };
        }
      ];
    }
  );
in
{
  # Installed as a real file rather than through `xdg.configFile`, for two
  # reasons that both bit this configuration on 2026-08-13:
  #
  # 1. A store symlink is read-only, so LinearMouse cannot save anything you
  #    change in its own settings window.
  # 2. LinearMouse watches linearmouse.json for changes, but Home Manager
  #    replaces the *symlink* with a new store path on every generation. A
  #    watcher holding the previous inode never sees that, so a rebuild appeared
  #    to change nothing: the file on disk read `highResolutionWheel: false`
  #    while the running process still had `true` from eight hours earlier.
  #
  # The running agent is therefore restarted explicitly whenever this file
  # changes, rather than trusting the application to notice. That restart is a
  # SEPARATE activation entry below, and the split is load-bearing — see there.
  home.activation.installLinearMouseConfiguration = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    configDirectory="$HOME/.config/linearmouse"

    # Replace a symlink left by an older generation; never touch a real file's
    # neighbours in that directory.
    if [[ -L "$configDirectory/linearmouse.json" ]]; then
      run rm -f "$configDirectory/linearmouse.json"
    fi

    run mkdir -p "$configDirectory"

    # Written IN PLACE, with a redirect rather than `install`, and the
    # difference is the whole reason the restart below can be conditional.
    #
    # `install` replaces the file: the path keeps its name but gets a new
    # inode. LinearMouse watches the file it opened, so it is left holding the
    # old inode and never sees the change — the same stale-inode failure
    # described at the top of this file, just one layer down. Measured on
    # 2026-08-13: `install` moved the inode, `>` did not.
    #
    # Writing in place keeps the inode, so the application's own watcher picks
    # the change up by itself and no restart is needed for this file at all.
    linearMouseConfigurationChanged=false
    if /usr/bin/cmp -s ${linearMouseConfiguration} "$configDirectory/linearmouse.json"; then
      verboseEcho "LinearMouse configuration is already current"
    else
      run cat ${linearMouseConfiguration} > "$configDirectory/linearmouse.json"
      run /bin/chmod 0644 "$configDirectory/linearmouse.json"
      linearMouseConfigurationChanged=true
    fi
  '';

  # LinearMouse reads BOTH of its configuration sources once, at launch:
  # linearmouse.json above and the Defaults domain below. So the restart must be
  # the LAST thing activation does to this application, after every write.
  #
  # Home Manager's own `setDarwinDefaults` — which applies
  # `targets.darwin.defaults` — is declared `entryAfter [ "writeBoundary" ]`,
  # exactly like the entry above. Two entries in the same DAG tier have no
  # ordering between them, and on 2026-08-13 the restart won: activation
  # relaunched LinearMouse and only THEN imported the Defaults domain. The
  # freshly launched process had already read the previous values, so the plist
  # on disk was correct while the running application still showed the old menu
  # bar behaviour — the icon stayed visible even though `menuBarVisibilityMode`
  # read `whenAttentionNeeded`. Depending on `setDarwinDefaults` by name is what
  # makes the restart observe both sources.
  #
  # Unlike the Karabiner restart, this one is deliberately NOT gated on a
  # detected change. The JSON above can be compared on disk, but the other
  # source — the Defaults domain — is written through cfprefsd, which flushes to
  # ~/Library/Preferences asynchronously. Comparing that file before and after
  # activation would therefore miss real changes, and a missed restart leaves
  # the application running stale settings, which is exactly the failure this
  # entry exists to prevent. A redundant restart of a mouse driver is cheap; a
  # missed one is a day of debugging. Karabiner's is gated because its trigger
  # is purely a file this module owns.
  home.activation.restartLinearMouse =
    lib.hm.dag.entryAfter
      [
        "writeBoundary"
        "installLinearMouseConfiguration"
        "setDarwinDefaults"
      ]
      ''
        # Terminate EVERY running instance, then start exactly one.
        #
        # Relaunched with `open` against the .app rather than by exec'ing
        # Contents/MacOS/LinearMouse. Both start the same binary, but only the
        # bundle launch matches how LinearMouse's own login item starts it, so
        # the process keeps one consistent LaunchServices and TCC identity
        # across a reboot and an activation. `-g` avoids stealing focus, `-j`
        # starts it hidden.
        run /usr/bin/pkill -x LinearMouse || true
        run /usr/bin/open -gj /Applications/LinearMouse.app
      '';

  # These keys are LinearMouse's own documented Defaults values rather than part
  # of linearmouse.json. Only the values we own are declared, so Sparkle update
  # state and other application-managed preferences remain intact.
  #
  # Declared as typed Nix values rather than hand-built `defaults write`
  # commands: Home Manager renders these with `lib.generators.toPlist` and
  # applies them with `defaults import`, so no value passes through shell
  # quoting and every plist TYPE is correct by construction.
  #
  # THE ENUM VALUES BELOW ARE DELIBERATELY WRAPPED IN LITERAL DOUBLE QUOTES.
  # This looks like a quoting bug. It is not. Do not "fix" it — doing so on
  # 2026-08-13 is what broke the menu bar icon, and it cost most of a day.
  #
  # LinearMouse stores preferences through sindresorhus/Defaults. That library
  # picks a bridge by protocol conformance (Defaults+Extensions.swift):
  #
  #   Self: Codable & RawRepresentable                  -> RawRepresentableCodableBridge
  #   Self: Codable & RawRepresentable & PreferRaw…     -> RawRepresentableBridge
  #
  # MenuBarVisibilityMode and MenuBarBatteryDisplayMode are `String, Codable,
  # Defaults.Serializable` and do NOT adopt PreferRawRepresentable, so they get
  # RawRepresentableCodableBridge — a CodableBridge, which serializes through
  # JSONEncoder rather than through `rawValue`. The JSON encoding of a string
  # enum is a quoted JSON string, so the value on disk is the 21-character
  # `"whenAttentionNeeded"`, NOT the 19-character `whenAttentionNeeded`.
  #
  # Write it bare and JSONDecoder fails, Defaults silently returns the key's
  # declared default (`.always` / `.off`), and LinearMouse's own settings window
  # shows "Always" and "Off" while the plist plainly reads something else. That
  # exact disagreement is the fingerprint of this mistake.
  #
  # Plain Bool keys have no bridge and take ordinary unquoted values, which is
  # why showInDock and showPointerLocation kept working throughout.
  targets.darwin.defaults."com.lujjjh.LinearMouse" = {
    # A plain Bool, so no quoting. Also DERIVED — LinearMouse assigns it from
    # the mode in StatusItem.syncLegacyShowInMenuBar:
    #   Defaults[.showInMenuBar] = Defaults[.menuBarVisibilityMode] != .never
    # It is declared only to keep this file and the stored domain in agreement.
    showInMenuBar = true;

    # Suppresses LinearMouse's one-shot migration, which would otherwise
    # overwrite menuBarVisibilityMode with `showInMenuBar ? .always : .never`
    # the first time it runs and undo the mode declared below.
    menuBarVisibilityModeMigrationCompleted = true;

    # Quoted: see the bridge note above. `whenAttentionNeeded` is NOT a
    # permission or error state — StatusItem.menuBarIsVisible defines it as
    # exactly one condition, that the battery indicator has a title:
    #   case .whenAttentionNeeded:
    #     return menuBarBatteryTitle(currentBatteryLevel:, mode:) != nil
    # so it pairs with menuBarBatteryDisplayMode as a single setting: show the
    # icon only at or below that battery threshold, and treat an unknown
    # battery level as hidden. Use `"never"` for an icon that never appears.
    menuBarVisibilityMode = ''"whenAttentionNeeded"'';
    menuBarBatteryDisplayMode = ''"below5"'';
    showInDock = false;
    showPointerLocation = false;
  };

  # Start at login is owned by LinearMouse's own SMAppService registration, NOT
  # by a Home Manager launch agent. There was one here until 2026-08-13; it is
  # deliberately gone.
  #
  # One application, one thing that starts it. LinearMouse registers itself as a
  # login item the moment "Start at login" is ticked in its settings, and that
  # registration cannot be revoked declaratively — so a launch agent does not
  # replace the login item, it races it. Both starting the app means two
  # processes filtering the same mouse events, which is never correct, and it
  # only manifests after a reboot, long after the change that caused it.
  #
  # The agent also bought nothing. Its whole job was to start the app at login,
  # which the login item already does — and does better, because a login item is
  # a real bundle launch, whereas the agent ran the app under /bin/sh and gave
  # it a different LaunchServices and TCC identity for no benefit.
  #
  # The cost of this choice is honest: start-at-login is now mutable GUI state
  # rather than something this repository declares. It is the same arrangement
  # every other application on the machine already uses.
}
