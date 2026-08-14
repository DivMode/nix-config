{ lib, pkgs, ... }:
let
  # LinearMouse's documented configuration interface. Match the device category
  # instead of a particular receiver so this works with Bluetooth and future MX
  # mice while leaving trackpad natural scrolling untouched.
  linearMouseConfiguration = pkgs.writeText "linearmouse.json" (
    builtins.toJSON {
      "$schema" = "https://schema.linearmouse.app/0.11.4";
      schemes = [
        {
          "if".device.category = "mouse";

          # High-resolution wheel is ON, and the history matters because the
          # comment here previously said the opposite. It was tried alone on
          # 2026-08-13 and rejected: finer steps on their own just make the
          # wheel feel loose, because LinearMouse recombines the substeps into
          # ordinary detents when the scrolling mode is not smoothed. It is
          # good in combination with the smoothed engine below, which is what
          # was actually wanted, and was adopted the same day.
          logitech.highResolutionWheel = true;

          scrolling = {
            reverse.vertical = true;

            # Values tuned by hand in LinearMouse's own settings window and
            # then read back out of the file it wrote, rather than guessed
            # from the visible sliders — several of these sit below the fold
            # in that window and would have been missed.
            #
            # This is the arrangement described at the top of this file: the
            # application owns the file at runtime, and activation reasserts
            # it. That means any tuning done in the settings window is lost at
            # the next rebuild unless it is captured here first.
            smoothed.vertical = {
              enabled = true;
              preset = "easeInOut";
              response = 0.68;
              speed = 1.02;
              acceleration = 1.1;
              inertia = 0.74;
              bouncing = true;
            };

            # Written alongside the smoothed block by the application. `speed`
            # and `acceleration` here are the non-smoothed engine's controls;
            # the smoothed engine ignores `scrolling.acceleration` and uses its
            # own, so these are kept only so the file matches what LinearMouse
            # itself produces and no rebuild shows a spurious difference.
            acceleration.vertical = 1;
            speed.vertical = 0;
            distance.vertical = "auto";
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

    # Copy only on a real difference, so an unrelated activation does not bump
    # this file's mtime and make LinearMouse's watcher see a phantom change.
    if /usr/bin/cmp -s ${linearMouseConfiguration} "$configDirectory/linearmouse.json"; then
      verboseEcho "LinearMouse configuration is already current"
    else
      run /usr/bin/install -m 0644 ${linearMouseConfiguration} \
        "$configDirectory/linearmouse.json"
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
