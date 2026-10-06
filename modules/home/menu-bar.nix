{
  config,
  lib,
  pkgs,
  ...
}:
{
  # What sits in the menu bar, declaratively: Apple's own removable status
  # items are hidden here. This module owns only menu bar VISIBILITY —
  # Spotlight search and Siri themselves are untouched by every key in this
  # file. No menu bar manager: Thaw was removed on 2026-10-06; macOS 27 chooses
  # visible items in System Settings → Menu Bar.

  # ── Spotlight: hide the icon, keep ⌘Space ─────────────────────────────────
  #
  # The magnifying-glass status item and the ⌘Space search window are the same
  # process (/System/Library/CoreServices/Spotlight.app — running here as its
  # own process, distinct from SystemUIServer and ControlCenter) but separate
  # features; MenuItemHidden removes only the status item. Indexing (mds) is a
  # third thing again and is not involved at all, so Raycast and ⌘Space keep
  # their results. This key, ByHost, is what Spotlight.app's OWN hide routine
  # writes — read from the 15.7.7 binary; evidence and the full mechanism in
  # docs/research/2026-09-01-menu-bar-status-items-sequoia.md.
  #
  # MenuItemHidden is a ByHost preference — it lives in
  # ~/Library/Preferences/ByHost/com.apple.Spotlight.<hardware-UUID>.plist and
  # is only read from there. That rules out two tempting homes for it:
  # nix-darwin's system.defaults.CustomUserPreferences writes plain domains
  # (the wrong plist, silently ignored), and nix-darwin has no general
  # -currentHost mechanism (its defaults-write.nix special-cases exactly one
  # ByHost domain, com.apple.controlcenter). Home Manager's
  # targets.darwin.currentHostDefaults is the faithful one: it runs
  # `defaults -currentHost import` as this user during activation
  # (home-manager modules/targets/darwin/user-defaults/default.nix), with no
  # sudo indirection to another user's domain.
  targets.darwin.currentHostDefaults."com.apple.Spotlight".MenuItemHidden = true;

  # ── Siri: hide the icon, change nothing else ──────────────────────────────
  #
  # StatusMenuVisible governs only the status item — on 15.7.7 the icon is
  # drawn by SystemUIServer, which loads Siri.bundle with
  # isStatusMenuVisible/setStatusMenuVisible: accessors bound to this domain
  # (read from the binaries; see docs/research/2026-09-01-menu-bar-status-
  # items-sequoia.md). Siri on this machine is additionally disabled outright
  # ("Assistant Enabled" = 0 in com.apple.assistant.support, user-set), so
  # this is mostly future-proofing: if Siri is ever enabled, its icon still
  # stays out of the menu bar. Unlike Spotlight's key these are plain
  # (non-ByHost) preferences.
  #
  # The stashed companion key is what the OS restores the icon state from
  # when Siri is toggled back on — that reading is a hypothesis from the key's
  # name and its presence beside StatusMenuVisible in Siri.bundle, but setting
  # it costs nothing and is the difference between the icon staying hidden and
  # popping back on a Siri re-enable.
  targets.darwin.defaults."com.apple.Siri" = {
    StatusMenuVisible = false;
    SiriPrefStashedStatusMenuVisible = false;
  };

  # On macOS 27 the item is a Control Center module, and hiding it takes a
  # second value beside StatusMenuVisible: ByHost com.apple.controlcenter
  # `Siri` = 8 (2 shows it). That pair, and that ControlCenter is the process
  # to restart, is what nix-plist-manager's `menuBar.siri` writes, checked
  # against System Settings → Menu Bar on macOS 27
  # (lib/options/applications/systemSettings/menu-bar.nix, commit 4ef635b).
  targets.darwin.currentHostDefaults."com.apple.controlcenter".Siri = 8;

  # Make a changed Siri visibility take effect now rather than at next login:
  # ControlCenter draws that item on macOS 27 and reads its values at launch.
  #
  # Only when a value actually changed — the owner's rule (2026-10-06) is that
  # a rebuild restarts nothing whose settings did not change. The comparison
  # goes through `defaults export` before setDarwinDefaults writes
  # (./defaults-changed.py), which sees what cfprefsd holds, so the
  # asynchronous flush to disk cannot hide a change.
  #
  # Spotlight's item needs nothing here: on macOS 27 there is no `Spotlight`
  # process to restart (2026-10-06: `pgrep -x Spotlight` found none; search is
  # served by corespotlightd and friends).
  home.activation.checkMenuBarDefaults =
    lib.hm.dag.entryBetween
      [ "setDarwinDefaults" ]
      [
        "writeBoundary"
      ]
      ''
        menuBarChanged=$(
          ${pkgs.python3}/bin/python3 -I ${./defaults-changed.py} com.apple.Siri ${
            pkgs.writeText "siri.json" (builtins.toJSON config.targets.darwin.defaults."com.apple.Siri")
          }
          ${pkgs.python3}/bin/python3 -I ${./defaults-changed.py} -currentHost com.apple.controlcenter ${
            pkgs.writeText "controlcenter.json" (
              builtins.toJSON config.targets.darwin.currentHostDefaults."com.apple.controlcenter"
            )
          }
        )
      '';

  home.activation.refreshMenuBar =
    lib.hm.dag.entryAfter
      [
        "writeBoundary"
        "setDarwinDefaults"
        "checkMenuBarDefaults"
      ]
      ''
        if [[ -n $menuBarChanged ]]; then
          run /usr/bin/killall ControlCenter 2>/dev/null || true
        fi
      '';
}
