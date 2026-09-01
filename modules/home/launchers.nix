{ lib, ... }:
let
  # Apple exposes no typed nix-darwin option for individual symbolic hotkeys,
  # and nix-darwin#518 (the request for exactly this) is still unresolved.
  #
  # `system.defaults.CustomUserPreferences` is the idiomatic escape hatch, but
  # it must NOT be used for this key. It emits
  #   defaults write <domain> <key> '<plist of everything you declared>'
  # which REPLACES the whole `AppleSymbolicHotKeys` dictionary, silently
  # deleting every shortcut not re-enumerated in Nix — Mission Control and the
  # Spaces-switching bindings (79, 80, 81, 82, 164) among them. `-dict-add`
  # merges a single entry instead, so only the two Spotlight IDs are touched.
  #
  # The payload is generated with `lib.generators.toPlist`, the same generator
  # CustomUserPreferences uses, rather than hand-written XML. That is what makes
  # the value types correct by construction. It matters: old-style ASCII plist
  # syntax has no scalar number type, so `-dict-add 64 '{ enabled = 0; }'`
  # stores the *string* "0", macOS ignores it, and the shortcut stays live. That
  # exact bug shipped on 2026-08-13 and looked like a total no-op.
  #
  # Each entry is written whole, including `value`: `-dict-add` replaces the
  # value stored under a shortcut ID rather than merging into it, so an entry
  # written without `parameters` loses its key binding and the Keyboard settings
  # pane can repopulate and re-enable it.
  #
  # parameters = [ ASCII character; virtual key code; modifier mask ]
  #   32      = Space character
  #   49      = Space virtual key code
  #   1048576 = Command
  #   1572864 = Command+Option
  spotlightHotkeys = {
    # Show Spotlight search — freed for Raycast, which binds Command-Space.
    "64" = 1048576;
    # Show Finder search window. Spotlight's other shortcut; disabled because
    # Spotlight is unused. This is not Finder's own Command-F search, and
    # Spotlight indexing stays enabled so Raycast file search keeps working.
    "65" = 1572864;
  };

  # `enabled` is an integer rather than a boolean to match the representation
  # macOS itself writes for the neighbouring shortcut entries.
  hotkeyEntry = modifiers: {
    enabled = 0;
    value = {
      parameters = [
        32
        49
        modifiers
      ];
      type = "standard";
    };
  };

  disableSpotlightHotkey = id: modifiers: ''
    run /usr/bin/defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys \
      -dict-add ${lib.escapeShellArg id} ${
        lib.escapeShellArg (lib.generators.toPlist { escape = true; } (hotkeyEntry modifiers))
      }
  '';
in
{
  # Only the two Spotlight shortcut IDs are touched, so input-source shortcuts,
  # Mission Control, and every unrelated symbolic hotkey survive untouched.
  home.activation.disableSpotlightHotkeys = lib.hm.dag.entryAfter [ "writeBoundary" ] (
    lib.concatStrings (lib.mapAttrsToList disableSpotlightHotkey spotlightHotkeys)
    + ''
      run /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u
    ''
  );

  # The Spotlight menu-bar icon is NOT handled here. An earlier entry in this
  # file tried to remove it by disabling the com.apple.Spotlight LaunchAgent;
  # that mechanism was a verified no-op and was removed on 2026-09-01. The
  # disable flag persisted exactly as designed — `launchctl print-disabled`
  # listed the agent as disabled — while the agent showed `state = running`
  # with a live pid after multiple reboots: macOS records but does not honour
  # the gui-domain disable for this SIP-protected system agent, so the icon
  # returned at every login while the activation message promised otherwise.
  # The icon is owned by modules/home/menu-bar.nix now, via the ByHost
  # MenuItemHidden preference that Spotlight itself honours; the stale disable
  # flag is cleaned up there. Full evidence:
  # docs/research/2026-09-01-menu-bar-status-items-sequoia.md.
}
