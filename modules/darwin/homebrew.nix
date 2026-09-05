{
  config,
  inputs,
  lib,
  local,
  sudoAskpass,
  ...
}:
let
  # The version a vendored cask pins, read at evaluation time from the SAME
  # file brew installs from, so the reconcile check below and the artefact it
  # installs cannot disagree.
  pinnedCaskVersion =
    path:
    let
      versionLine = builtins.head (
        builtins.filter (l: lib.hasInfix "version \"" l) (lib.splitString "\n" (builtins.readFile path))
      );
    in
    builtins.head (builtins.match ".*version \"([^\"]+)\".*" versionLine);

  # Every cask served from the in-repo pinned tap, by token. Used twice: the
  # reconcile step below, and nothing else — the cask DECLARATIONS stay in
  # homebrew.casks like every other cask.
  pinnedCasks = {
    chatgpt = ../../taps/homebrew-pinned/Casks/chatgpt.rb;
    thaw = ../../taps/homebrew-pinned/Casks/thaw.rb;
  };

  # Mirrors how nix-darwin's own homebrew activation invokes brew: PATH
  # extended then preserved through sudo, dropping from root to the brew
  # owner with a clean home.
  brewAsOwner = "PATH=\"${config.homebrew.prefix}/bin:$PATH\" sudo --preserve-env=PATH --user=${lib.escapeShellArg config.homebrew.user} --set-home brew";
in
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

      # In-repo tap for casks deliberately held at a version the upstream tap
      # does not carry — see taps/homebrew-pinned/README.md for its rules. Each
      # pinned cask's WHY lives at its declaration in the list below.
      # `builtins.path` fixes the store name so the tap's path does not change
      # whenever unrelated repository files do.
      "nix-config/homebrew-pinned" = builtins.path {
        name = "homebrew-pinned-tap";
        path = ../../taps/homebrew-pinned;
      };
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

      # ChatGPT (which bundles the codex CLI) — served from the in-repo pinned
      # tap, not from the homebrew-cask input. The version is whatever
      # taps/homebrew-pinned/Casks/chatgpt.rb declares, and that file moves
      # only by `./scripts/update.sh chatgpt` (or a full update.sh run), which
      # re-vendors upstream homebrew-cask's current chatgpt.rb verbatim.
      #
      # Why a separate pin rather than the homebrew-cask input like every other
      # cask: on 2026-09-01 the 26.831.20005 that arrived with a lock bump was
      # broken in use, and the owner asked for the previous version back the
      # same morning. Upstream only ever carries latest, and a lock input moves
      # every cask at once, so holding or moving ChatGPT ALONE needs its own
      # file — a whole vendored cask whose versioned URL and sha256 make the
      # artefact reproducible. Holding a broken version back is now a git
      # revert of that one file; moving to latest is the script.
      #
      # The pin has a second half in modules/home/chatgpt.nix: the app updates
      # ITSELF via Sparkle, so without that module's kill switch the declared
      # version would quietly drift within a day. To unpin entirely, revert
      # both together: restore the plain "chatgpt" token here, delete the
      # vendored cask, remove that module, and drop the chatgpt refresh from
      # scripts/update.sh.
      #
      # `greedy` for the same reason as karabiner-elements below: the cask
      # declares `auto_updates`, so plain upgrade skips it and an installed
      # version would sit untouched forever. Greedy makes activation reconcile
      # the installed version to what THIS tap pins — which, with the fully
      # qualified token, can only ever be the vendored file's version.
      {
        name = "nix-config/pinned/chatgpt";
        greedy = true;
      }

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

      # Archive utility. macOS unpacks zip natively but nothing else, and the
      # formats that actually arrive here — rar, 7z, multi-part archives — need
      # a real extractor. A cask rather than a nixpkgs package because this is a
      # GUI app that registers Finder file-type handlers, which a Nix-store
      # bundle outside /Applications does not do reliably on darwin.
      "keka"

      # PDF editing. Reader cannot edit, which is the whole reason this is the
      # Pro cask and not `adobe-acrobat-reader`.
      #
      # Three things about this cask are unlike every other line in this file,
      # and all three are deliberate.
      #
      # 1. It is a `pkg` cask ("Acrobat/Acrobat DC Installer.pkg"), not an app
      #    bundle. Homebrew hands that to macOS's installer, which needs root.
      #    scripts/rebuild.sh already activates under sudo with SUDO_ASKPASS, so
      #    the first install may surface a dialog rather than completing
      #    silently. That is the installer asking, not a fault in this config.
      # 2. It declares `sha256 :no_check` and downloads from trials.adobe.com,
      #    so the artefact behind the pinned version string can change without
      #    the tap moving. This is the one cask here whose bytes the lock does
      #    not really pin, and Adobe — not this repository — decides that.
      # 3. NOT `greedy`, unlike karabiner-elements above. Because the cask is
      #    unversioned, greedy would re-download roughly a gigabyte from Adobe
      #    on every single activation. Its own updater (`auto_updates true`) is
      #    the right owner for a product that ships its own update service.
      #
      # Installing it does not license it. Acrobat Pro is a paid subscription:
      # the cask puts the application on disk, and editing requires signing in
      # to an Adobe account that carries an Acrobat Pro entitlement.
      #
      # NEVER UPGRADE THIS FROM A REBUILD. Requested explicitly on 2026-08-31:
      # this application is to change version only when its owner says so, not
      # as a side effect of `./scripts/update.sh` or any lock bump.
      #
      # `greedy = false` is stated rather than left to the default so the
      # intent survives someone later setting `homebrew.greedyCasks = true`,
      # which is the one change that would silently start upgrading it — a
      # per-cask value overrides that global. With greedy off, `brew upgrade`
      # skips it outright because the cask declares `auto_updates true`.
      #
      # That covers Homebrew, and Homebrew is only HALF of it. Adobe ships its
      # own updater — the ARMDC launchd services and privileged helpers under
      # /Library/PrivilegedHelperTools — which updates Acrobat on Adobe's
      # schedule with no reference to this repository at all. Turning that off
      # is a separate control; see ./adobe-updates.nix.
      {
        name = "adobe-acrobat-pro";
        greedy = false;
      }

      # tailscale-app is deliberately NOT here, and this note exists so it is
      # not "helpfully" added on the next pass.
      #
      # It kept reappearing and being removed — about five times — which looked
      # like a broken uninstall. It was not. Traced on 2026-08-31: a Codex
      # session on 2026-08-28 at 22:46 ran `brew install --cask tailscale-app`
      # and `brew install tmux` while following UPSTREAM Tandem's setup guide,
      # which lists "Tailscale, connected with `tailscale up`" and tmux as
      # requirements. `cleanup = "uninstall"` then reconciled both away on the
      # next activation, correctly, because neither is declared. Homebrew's own
      # logs still show the openssl@3 and ca-certificates pulled in as tmux
      # dependencies that night.
      #
      # Neither requirement applies to this machine. ../home/ai/tandem/default.nix
      # runs a fork specifically to avoid both: "tmux is NOT a dependency of
      # this path and must not become one", and tunnel-client.nix uses a plain
      # port with "no Tailscale Funnel involved". So the loop was an agent
      # installing software for a code path this repository does not use, and
      # Nix undoing it. The removal was the system working.
      #
      # Add it only if something here genuinely needs it, and say what.

      # Menu bar manager (an actively maintained fork of Ice), at the newest
      # release that runs on this macOS: Thaw's 2.x line is macOS 26-only —
      # its release notes state "Systems on macOS 14 or 15 stay on the 1.x
      # line" — and upstream homebrew-cask carries only 2.x, so the upstream
      # `thaw` token cannot install on macOS 15 at all (`depends_on macos:
      # :tahoe`). Hence the in-repo pinned cask, like chatgpt above:
      # taps/homebrew-pinned/Casks/thaw.rb.
      #
      # modules/home/menu-bar.nix seeds its behavioural defaults. Two things
      # stay manual, documented there: the one-time permission grants Thaw asks
      # for, and which icons live in which section (⌘-drag in the menu bar).
      "nix-config/pinned/thaw"

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

  # Reconcile pinned-tap casks DOWNWARD, which `brew bundle` cannot do: it
  # installs what is missing and upgrades what is outdated, but an installed
  # cask NEWER than its declared definition is left in place. Measured on
  # 2026-09-01, the day the chatgpt pin landed: with 26.831.20005 installed
  # and the vendored cask pinning 26.825.51511, activation logged
  # "Using chatgpt" and moved nothing. For a normal tap that gap cannot arise;
  # for a pinned tap it is the entire point of the tap, so activation closes
  # it explicitly here. Runs after the homebrew activation script (this is
  # postActivation), compares the installed version against the version the
  # vendored cask file pins, and reinstalls from the pin only on a mismatch —
  # activations where the pin already holds run one `brew list` per pinned
  # cask and change nothing.
  system.activationScripts.postActivation.text = lib.mkAfter ''
    if [ -f "${config.homebrew.prefix}/bin/brew" ]; then
      ${lib.concatStrings (
        lib.mapAttrsToList (name: path: ''
          installedVersion="$(${brewAsOwner} list --cask --versions ${name} 2>/dev/null | /usr/bin/awk '{ print $2 }')"
          if [ -n "$installedVersion" ] && [ "$installedVersion" != "${pinnedCaskVersion path}" ]; then
            echo "Reconciling cask ${name} to its pin: $installedVersion -> ${pinnedCaskVersion path}" >&2
            ${brewAsOwner} reinstall --cask nix-config/pinned/${name}
          fi
        '') pinnedCasks
      )}
    fi
  '';
}
