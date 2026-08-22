{
  config,
  inputs,
  local,
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
      "karabiner-elements"

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
