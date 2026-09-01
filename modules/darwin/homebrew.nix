{
  config,
  inputs,
  local,
  sudoAskpass,
  ...
}:
{
  nix-homebrew = {
    enable = true;
    user = local.user;
    enableRosetta = local.system == "aarch64-darwin";
    autoMigrate = true;
    mutableTaps = false;
    taps = {
      "homebrew/homebrew-core" = inputs.homebrew-core;
      "homebrew/homebrew-cask" = inputs.homebrew-cask;
    };
  };

  homebrew = {
    enable = true;
    taps = builtins.attrNames config.nix-homebrew.taps;

    # Portable command-line tools belong to Nix/Home Manager. Add a formula
    # here only when nixpkgs is concretely unavailable or broken, and document
    # that exception beside the declaration.
    brews = [ ];
    casks = [
      "google-chrome"
      "chatgpt"
      "raycast"

      # Local, on-device voice input used on this Mac. Keeping it declared is
      # required because strict Homebrew reconciliation removes undeclared casks.
      "fluidvoice"

      # Native keyboard remapper. Home Manager owns its complete declarative
      # configuration directory; Raycast's native Hyper Key stays disabled.
      #
      # `greedy` because `upgrade = true` alone did NOT keep this current, and
      # the reason is worth writing down. `brew upgrade` SKIPS any cask marked
      # `auto_updates true` — the assumption being that the app updates itself —
      # and karabiner-elements carries that flag. Measured here on 2026-08-31:
      # `brew outdated --cask` listed nothing, while `brew outdated --cask
      # --greedy` listed karabiner-elements, with 16.1.0 installed against the
      # 16.2.0 the pinned tap defines. Its own Sparkle updater had not closed
      # that gap either, plausibly because installing its pkg needs an admin
      # prompt nobody answered. So the cask sat a version behind, silently.
      #
      # This does not make activation pull arbitrary versions. homebrew-cask is
      # a pinned flake input, so greedy can only ever move this to the version
      # flake.lock already names — the upgrade still arrives as a reviewable
      # lock bump, exactly like the note on `upgrade` below describes.
      {
        name = "karabiner-elements";
        greedy = true;
      }

      # Anthropic's terminal CLI is NOT here. It is a Nix package, declared in
      # modules/home/development.nix from the llm-agents flake input, because
      # the cask lags the release stream by days. Do not add `claude-code` back,
      # and never add the separate `claude` desktop cask either.

      # cmux is NOT here. Ghostty replaced it; see modules/home/terminal.nix.

      # Open-source mouse utility, and the ONLY owner of mouse EVENTS here.
      # Home Manager owns its JSON configuration, written as a real file it can
      # still save over; its login item, not a launch agent, starts it. Only
      # macOS Accessibility approval remains manual.
      "linearmouse"

      # Logitech's own utility, declared as a deliberate exception to the rule
      # one line above and in modules/darwin/README.md: do not run a second
      # mouse tool alongside LinearMouse.
      #
      # It is here for exactly one thing LinearMouse cannot do. The MX Master
      # MagSpeed wheel has two MECHANICAL modes, ratchet and free-spin, and they
      # are a HID++ feature of the mouse firmware — not an event stream anything
      # on this Mac can filter. docs/research/2026-08-13-linearmouse-high-
      # resolution-wheel-mx-master-3.md states it plainly: LinearMouse's
      # highResolutionWheel flag "does not configure SmartShift, SmartShift
      # sensitivity, ratchet mode, free-spin mode, or the top mode-shift
      # button". A wheel stuck in free-spin is therefore unfixable from this
      # repository, and was, for most of 2026-08-21.
      #
      # The precise reason, so nobody has to ask "why not just fix it in
      # LinearMouse" a second time. Two DIFFERENT HID++ features are involved:
      #
      #   0x2121 hiResWheel  - setWheelMode: resolution, invert, event routing.
      #                        Reports ratchet state; does not set it.
      #   0x2110 SmartShift  - setRatchetControlMode: the authoritative control
      #                        for ratchet vs free-spin. autoDisengage 0xFF
      #                        means "ratchet always engaged", which is exactly
      #                        what turning SmartShift off in Options+ does.
      #
      # LinearMouse implements ONLY 0x2121, and within it only the single bit
      # 0x02 - its controller defines getMode, setMode and
      # highResolutionModeBit, and nothing else. There is no 0x2110 code in it
      # and no ratchet field in linearmouse.json's schema. So LinearMouse did
      # not turn ratchet off and cannot turn it back on: it has never been able
      # to address that feature. It is a missing capability upstream, not a
      # protocol limit, and it also means LinearMouse cannot clobber whatever
      # Options+ sets here.
      #
      # Every alternative was checked before adding a second daemon. logiops,
      # logiops-rs and OpenLogi do SmartShift but are Linux; Mouser, mx3-lite,
      # optune and nibble are macOS but do not expose it; SteerMouse remaps
      # input events and cannot reach a firmware feature at all. This cask is
      # the only macOS option that can, and it is the only reason it is here.
      #
      # The wheel mode lives on the MOUSE, so this may be removable once set:
      # configure ratchet and SmartShift, confirm the setting survives, then
      # delete this line and let strict cleanup uninstall it. Verify before
      # relying on that — it is device-firmware behaviour, not a promise.
      #
      # It needs Accessibility and Input Monitoring approval, which Nix cannot
      # grant. Grant them only if you keep it; a permission outliving the app it
      # was for is exactly the mutable state docs/state-boundary.md warns about.
      "logi-options+"

      # Media player and e-book library.
      "iina"
      "calibre"

      # The desktop app provides authentication and the CLI is a separate
      # vendor bundle; installing it does not enable secret injection.
      "1password"
      "1password-cli"
    ];
    masApps = { };

    onActivation = {
      # Never contact Homebrew's remotes during activation. The taps are pinned
      # flake inputs and `mutableTaps` is false, so there is nothing to fetch;
      # this only suppresses an implicit `brew update`.
      autoUpdate = false;

      # Let a pkg cask's privileged installer ask for the password.
      #
      # A `pkg` cask — karabiner-elements, adobe-acrobat-pro, logi-options+ —
      # is installed by handing the payload to /usr/sbin/installer under sudo,
      # unconditionally (Homebrew's cask/artifact/pkg.rb). Activation reaches
      # Homebrew through nix-darwin's `#!/usr/bin/env -i` script and then
      # `sudo --preserve-env=PATH`, so it arrives with no controlling terminal
      # AND no SUDO_ASKPASS. Homebrew adds sudo's -A flag only when it can see
      # that variable, so without this every pkg cask fails identically:
      #
      #   sudo: a terminal is required to read the password
      #
      # Measured here on 2026-08-31, when karabiner-elements and
      # adobe-acrobat-pro both failed that way and `brew bundle` returned
      # non-zero, which under the activation script's `set -e` aborted the
      # switch with the generation half-applied. That also corrects the note in
      # scripts/rebuild.sh recording a silent exit 0 from the 2026-08-21
      # logi-options+ failure: on these versions it is not silent, it stops the
      # rebuild.
      #
      # extraEnv is what makes this reachable. Its values are written literally
      # into the activation command line rather than inherited, so unlike an
      # exported variable they survive `env -i` and the --preserve-env
      # whitelist. ./sudo.nix's sudo.conf entry is NOT sufficient on its own:
      # that path is consulted only when -A is passed.
      #
      # Be clear about what this buys. It does not make activation unattended —
      # it converts a hard failure into a password dialog. Any rebuild that
      # installs or upgrades a pkg cask will WAIT for someone to answer it.
      # Rebuilds that touch no pkg cask are unaffected.
      extraEnv.SUDO_ASKPASS = "${sudoAskpass}";

      # Bring installed casks up to the version the pinned tap defines.
      #
      # This does NOT make activation pull arbitrary new software, which is the
      # usual reason to leave it off. `homebrew-cask` is a flake input, so the
      # only version activation can move a cask to is the one flake.lock already
      # pins. Upgrades therefore still arrive as a reviewable lock bump in git,
      # exactly like every nixpkgs change. Combined with autoUpdate = false,
      # this is nix-darwin's documented "only ever upgrade during activation".
      #
      # False means "install the pinned version, but leave anything already
      # installed stale forever" — it passes `--no-upgrade`. That stranded
      # claude-code on 2.1.222 until 2026-08-13, before it moved to Nix. It went
      # unnoticed because every other declared cask except 1password-cli carries
      # Homebrew's `auto_updates` flag and quietly updates itself, so this
      # setting is the only thing keeping 1password-cli current.
      upgrade = true;

      # Reconcile only software managed by Homebrew. Never use "zap", which can
      # additionally remove application-associated files and user data.
      cleanup = "uninstall";
    };
  };
}
