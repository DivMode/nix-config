{
  config,
  lib,
  pkgs,
  ...
}:
let
  # ByHost com.apple.controlcenter holds one integer per Menu Bar module on
  # macOS 27: 8 hides it, 2 shows it. Read back from this Mac on 2026-10-06:
  # switching Spotlight off in System Settings → Menu Bar wrote exactly
  # `Spotlight = 8` here and nothing else; Siri's 8/2 pair is nix-plist-
  # manager's `menuBar.siri`, checked against the same pane on macOS 27
  # (lib/options/applications/systemSettings/menu-bar.nix, commit 4ef635b).
  controlCenter = {
    Spotlight = 8;
    Siri = 8;
  };

  # Text Input (the keyboard / "U.S." item that appears because this Mac has
  # several input sources): com.apple.TextInputMenu `visible`, drawn by
  # TextInputMenuAgent, which reads it at launch. Switching it off in the pane
  # on 2026-10-06 stored visible = 0 while the running agent kept the icon —
  # the same mapping and restart nix-plist-manager's `menuBar.textInput` uses.
  textInputMenu.visible = false;

  # ./defaults-changed.py prints "changed" when a domain does not already hold
  # these values. Run before setDarwinDefaults writes them, so a restart below
  # happens only when a value really changes (the owner's rule, 2026-10-06).
  changed =
    flags: domain: values:
    "${pkgs.python3}/bin/python3 -I ${./defaults-changed.py} ${flags} ${domain} ${pkgs.writeText "${domain}.json" (builtins.toJSON values)}";
in
{
  # What sits in the menu bar: Apple's own items hidden here, the rest left to
  # System Settings → Menu Bar. Spotlight search (⌘Space) and Siri themselves
  # are untouched; only their menu bar items are hidden.
  targets.darwin.currentHostDefaults."com.apple.controlcenter" = controlCenter;
  targets.darwin.defaults."com.apple.TextInputMenu" = textInputMenu;

  # Siri's own visibility keys, kept beside the Control Center module value.
  # On macOS 15 SystemUIServer drew the item from these; on 27 the module value
  # above decides, and these keep a re-enabled Siri from bringing it back.
  targets.darwin.defaults."com.apple.Siri" = {
    StatusMenuVisible = false;
    SiriPrefStashedStatusMenuVisible = false;
  };

  home.activation.checkMenuBarDefaults =
    lib.hm.dag.entryBetween
      [ "setDarwinDefaults" ]
      [
        "writeBoundary"
      ]
      ''
        controlCenterChanged=$(
          ${changed "-currentHost" "com.apple.controlcenter" controlCenter}
          ${changed "" "com.apple.Siri" config.targets.darwin.defaults."com.apple.Siri"}
        )
        textInputMenuChanged=$(${changed "" "com.apple.TextInputMenu" textInputMenu})
      '';

  # Make changed items take effect now rather than at next login. Both agents
  # are relaunched by launchd within a second and hold no user state.
  home.activation.refreshMenuBar =
    lib.hm.dag.entryAfter
      [
        "writeBoundary"
        "setDarwinDefaults"
        "checkMenuBarDefaults"
      ]
      ''
        if [[ -n $controlCenterChanged ]]; then
          run /usr/bin/killall ControlCenter 2>/dev/null || true
        fi
        if [[ -n $textInputMenuChanged ]]; then
          run /usr/bin/killall TextInputMenuAgent 2>/dev/null || true
        fi
      '';
}
