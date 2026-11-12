# Shottr: screenshot capture, annotation and OCR. The cask is declared in
# ../darwin/homebrew.nix; this is its configuration, so a new Mac comes back
# with the same hotkeys and settings and nobody opens the settings window.
#
# Shottr is sandboxed (its entitlements carry com.apple.security.app-sandbox),
# so its preferences live in
# ~/Library/Containers/cc.ffitch.shottr/Data/Library/Preferences. `defaults`
# reaches that file through cfprefsd by bundle id, which is what Home
# Manager's `defaults import` uses.
#
# Every key and value type below was READ BACK from the domain after Shottr
# 1.9.3 wrote it (`defaults export cc.ffitch.shottr -`, 2026-11-11), not
# guessed. All are plain bools, integers and strings.
{
  lib,
  pkgs,
  ...
}:
let
  domain = "cc.ffitch.shottr";

  # ── Hotkeys ─────────────────────────────────────────────────────────────
  # Shottr registers its global hotkeys with sindresorhus/KeyboardShortcuts,
  # which stores each one under `KeyboardShortcuts_<name>` as a JSON string
  # of Carbon values. The stored form was read back: Shottr's own defaults
  # were {"carbonModifiers":768,"carbonKeyCode":19} for `area` (Command-
  # Shift-2). KeyboardShortcuts stores a shortcut the user removed as the
  # boolean `false`, which is also what keeps a name's built-in default from
  # coming back.
  #
  # The names are the ones Shottr passes to KeyboardShortcuts.Name in its
  # binary, in its own order: fullscreen, area, repeatArea, window,
  # anyWindow, scrolling, reopen, ocr, loadClipboard, library. Every one is
  # declared, so the set is complete rather than a partial overlay.
  #
  # Carbon modifiers: cmdKey 256, shiftKey 512, optionKey 2048,
  # controlKey 4096. Key codes are kVK_ANSI_*: 1=18 2=19 3=20 4=21 O=31.
  shortcut =
    carbonKeyCode: carbonModifiers: builtins.toJSON { inherit carbonKeyCode carbonModifiers; };
  commandShift = 256 + 512;
  controlOptionCommand = 4096 + 2048 + 256;

  hotkeys = {
    # Shottr takes over the two macOS screenshot keys, which is the setup
    # Shottr's own "reassign default" button offers. The system shortcuts are
    # disabled below; Command-Shift-5 stays with macOS for screen recording,
    # which Shottr does not do.
    fullscreen = shortcut 20 commandShift; # Command-Shift-3
    area = shortcut 21 commandShift; # Command-Shift-4
    scrolling = shortcut 19 commandShift; # Command-Shift-2
    # Shottr's own default, kept.
    ocr = shortcut 31 controlOptionCommand; # Control-Option-Command-O
    repeatArea = false;
    window = false;
    anyWindow = false;
    reopen = false;
    loadClipboard = false;
    library = false;
  };

  settings = {
    # ── Choices ───────────────────────────────────────────────────────────
    # Shottr sends usage telemetry by default (its GATelemetry queue held
    # launch events within a minute of the first start). Off.
    allowTelemetry = false;
    # Every capture goes to the clipboard and opens the editor; Escape in the
    # editor copies the edited version.
    afterGrabCopy = true;
    afterGrabShow = true;
    copyOnEsc = true;
    # NOT auto-saved to a folder. The sandbox only lets Shottr write a folder
    # through a security-scoped bookmark that its own folder picker creates
    # (defaultFolder plus defaultFolderBookmark); a bookmark cannot be
    # declared. Save from the editor instead.
    afterGrabSave = false;
    saveOnEsc = false;
    # Uploads off. Turning S3 on would need a bucket name, which is private
    # and would belong in local.nix, never here.
    uploadMode = "none";

    # ── Shottr's own values, as it stored them ────────────────────────────
    alwaysOnTop = false;
    altZoomDirection = false;
    areaCaptureMode = "editor";
    areaCustomGrabber = false;
    captureCursor = "auto";
    colorFormat = "HEX";
    customBackdropColor = "#6080A0";
    customGradFrom = "#221448";
    customGradTo = "#919BD2";
    downscaleOnSave = false;
    expandableCanvas = true;
    notificationType = "custom";
    ocrRemoveBreaks = false;
    preferLargeWindow = true;
    primaryOCRLang = "en-US";
    realPixels = false;
    saveFormat = "Auto";
    scrollingManualEnabled = false;
    scrollingMax = 20000;
    scrollingReverseAutoscroll = false;
    scrollingSpeed = 2;
    snappingMode = 2;
    thumbnailClosing = "manual";
    windowShadow = "transparent";
    windowSolidColor = "#404448";
  }
  // lib.mapAttrs' (name: lib.nameValuePair "KeyboardShortcuts_${name}") hotkeys;

  # ── macOS's own screenshot shortcuts ────────────────────────────────────
  # System symbolic hotkeys win over an application's Carbon hotkey, so
  # Shottr only receives Command-Shift-3 and -4 once these two are off.
  # 28 = "Save picture of screen as a file" (Command-Shift-3)
  # 30 = "Save picture of selected area as a file" (Command-Shift-4)
  # parameters = [ ASCII character; virtual key code; modifier mask ], with
  # 1179648 = Shift (131072) + Command (1048576). The Control-added clipboard
  # variants (29, 31) and the Command-Shift-5 toolbar (184) are untouched.
  # Same mechanism as the Spotlight entries in ./launchers.nix.
  screenshotHotkeys = {
    "28" = [
      51
      20
      1179648
    ];
    "30" = [
      52
      21
      1179648
    ];
  };
  disabledHotkey = parameters: {
    enabled = 0;
    value = {
      inherit parameters;
      type = "standard";
    };
  };

  defaultsChanged = "${pkgs.python3}/bin/python3 -I ${./defaults-changed.py}";
  shottrApp = "/Applications/Shottr.app";
in
{
  targets.darwin.defaults.${domain} = settings;

  # Shottr registers its hotkeys at launch and keeps its settings in memory,
  # so a changed value needs a restart to take effect. Ordered quit, write,
  # relaunch — rather than write then restart — so nothing the app saves on
  # its way out can land on top of the declared values. Gated on an actual
  # difference: a rebuild that changes nothing here leaves Shottr alone.
  #
  # Quit with the standard quit Apple event, not a signal, and waited on
  # through LaunchServices (`lsappinfo`), the registry `open` consults; see
  # restartLinearMouse in ./mouse.nix for why that wait matters.
  home.activation.quitShottrForSettings =
    lib.hm.dag.entryBetween [ "setDarwinDefaults" ] [ "writeBoundary" ]
      ''
        shottrSettingsChanged=$(${defaultsChanged} ${domain} ${pkgs.writeText "shottr-settings.json" (builtins.toJSON settings)})
        shottrWasRunning=0
        if [[ $shottrSettingsChanged == changed && -n "$(/usr/bin/lsappinfo find bundleid=${domain})" ]]; then
          shottrWasRunning=1
          run /usr/bin/osascript -e 'tell application id "${domain}" to quit' || true
          for _ in {1..50}; do
            [[ -n "$(/usr/bin/lsappinfo find bundleid=${domain})" ]] || break
            /bin/sleep 0.2
          done
          if [[ -n "$(/usr/bin/lsappinfo find bundleid=${domain})" ]]; then
            echo "warning: Shottr did not quit; its new settings apply at its next start" >&2
            shottrWasRunning=0
          fi
        fi
      '';

  home.activation.relaunchShottr =
    lib.hm.dag.entryAfter [ "setDarwinDefaults" "quitShottrForSettings" ]
      ''
        if [[ $shottrWasRunning == 1 && -d ${shottrApp} ]]; then
          run /usr/bin/open -gj ${shottrApp} \
            || echo "warning: Shottr was quit to apply its settings but could not be relaunched" >&2
        fi
      '';

  # Written, and `activateSettings -u` run, only when the stored entries
  # differ, as in ./launchers.nix.
  home.activation.disableScreenshotHotkeys = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    screenshotHotkeysChanged=$(${defaultsChanged} com.apple.symbolichotkeys ${
      pkgs.writeText "screenshot-hotkeys.json" (
        builtins.toJSON { AppleSymbolicHotKeys = lib.mapAttrs (_: disabledHotkey) screenshotHotkeys; }
      )
    })
    if [[ $screenshotHotkeysChanged == changed ]]; then
      ${lib.concatStrings (
        lib.mapAttrsToList (id: parameters: ''
          run /usr/bin/defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys \
            -dict-add ${lib.escapeShellArg id} ${
              lib.escapeShellArg (lib.generators.toPlist { escape = true; } (disabledHotkey parameters))
            }
        '') screenshotHotkeys
      )}
      run /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u
    fi
  '';
}
