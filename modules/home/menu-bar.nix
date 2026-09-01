{ lib, ... }:
{
  # What sits in the menu bar, declaratively: Apple's own removable status
  # items are hidden here, and Thaw (declared in modules/darwin/homebrew.nix)
  # manages the rest. This module owns only menu bar VISIBILITY — Spotlight
  # search and Siri themselves are untouched by every key in this file.

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

  # ── Thaw: seed behaviour, leave layout to the GUI ─────────────────────────
  #
  # Key names verified against Thaw's own source at tag 1.2.0
  # (Thaw/Utilities/Defaults.swift) — they are inherited unchanged from Ice
  # and identical on the 2.x line, but they are an internal schema, not a
  # documented contract: re-verify against that file before adding keys or
  # bumping the pinned version. Only flat behavioural switches are seeded.
  # Per-item section membership is persisted in undocumented blobs
  # (MenuBarItemManager.savedSectionOrder), so which icon lives in which
  # section stays a GUI act: ⌘-drag icons across the divider Thaw adds.
  # Also manual, once: Thaw's permission prompts and its launch-at-login
  # toggle, both TCC/SMAppService state that Nix deliberately does not own.
  targets.darwin.defaults."com.stonerl.Thaw" = {
    # Hidden icons come back out only briefly: re-hide 15s (RehideInterval
    # default) after the pointer leaves the menu bar.
    AutoRehide = true;
    # A third section for icons that never show, even while the hidden
    # section is revealed.
    EnableAlwaysHiddenSection = true;
  };

  # Poke the processes that draw the two Apple status items so the change is
  # visible now rather than at next login. Spotlight.app reads MenuItemHidden
  # at launch; killall is safe — launchd owns it and relaunches on demand, and
  # mds indexing is a different daemon entirely. SystemUIServer is restarted
  # for the Siri item for the same reason. Both exit 0 via `|| true` when not
  # running.
  #
  # Deliberately NOT gated on a detected change, same doctrine as the
  # LinearMouse restart in mouse.nix: these domains are written through
  # cfprefsd, whose flush to disk is asynchronous, so a before/after file
  # comparison can miss a real change — and a missed restart leaves a stale
  # icon, which is the one failure this module exists to remove. Both
  # processes redraw in well under a second and hold no user state.
  home.activation.refreshMenuBar =
    lib.hm.dag.entryAfter
      [
        "writeBoundary"
        "setDarwinDefaults"
      ]
      ''
        run /usr/bin/killall Spotlight 2>/dev/null || true
        run /usr/bin/killall SystemUIServer 2>/dev/null || true
      '';

  # Clean up after the retired launchctl approach (launchers.nix, removed
  # 2026-09-01): activations from 2026-08-13 onward wrote a persistent
  # gui-domain disable for the com.apple.Spotlight agent. Measured before
  # removal: the flag was recorded (`launchctl print-disabled` listed the
  # agent as disabled) AND the agent was running with a live pid across
  # multiple reboots — macOS does not honour the disable for this
  # SIP-protected system agent, so the flag did nothing except misstate
  # intent. It is cleared rather than kept because an ignored flag is a
  # landmine: a future macOS that starts honouring it would silently disable
  # the Spotlight UI, while this module's whole design keeps that UI enabled
  # and merely hides its status item. `enable` on an already-enabled agent is
  # a no-op, so this is idempotent and cheap on every later activation.
  home.activation.clearLegacySpotlightAgentDisable = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run /bin/launchctl enable "gui/$(/usr/bin/id -u)/com.apple.Spotlight" 2>/dev/null || true
  '';
}
