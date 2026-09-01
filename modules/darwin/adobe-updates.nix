{
  lib,
  local,
  pkgs,
  ...
}:
let
  # The two privileged daemons. Both are ON-DEMAND mach services — no
  # RunAtLoad, no StartInterval, no watch paths — so neither initiates
  # anything. They are the root-level install path the updater calls into.
  daemonLabels = [
    "com.adobe.ARMDC.Communicator"
    "com.adobe.ARMDC.SMJobBlessHelper"
  ];

  disableArm = pkgs.writeShellApplication {
    name = "disable-adobe-arm-updater";
    text = ''
      uid=$(/usr/bin/id -u -- ${lib.escapeShellArg local.user})

      # The AGENT is the trigger: RunAtLoad plus StartInterval 12600, i.e.
      # every login and then every 3.5 hours, fetching AcrobatManifest.xml from
      # armmf.adobe.com and applying what it finds.
      #
      # Its label is com.adobe.ARMDCHelper.<sha256 of the helper app's absolute
      # path>. Verified 2026-08-31:
      #
      #   echo "/Library/Application Support/Adobe/ARMDC/Application/Acrobat Update Helper.app" \
      #     | shasum -a 256
      #   -> cc24aef4a1b90ed56a725c38014c95072f92651fb65e1bf9c8e43c37a23d420d
      #
      # which is exactly the suffix on the installed plist. The path is a fixed
      # system location, so the label is STABLE across reinstalls — and that is
      # precisely what makes disabling it durable. Globbed rather than
      # hard-coded so an Adobe path change shows up as "nothing matched"
      # instead of silently disabling a label that no longer exists.
      shopt -s nullglob
      matched=0
      for plist in /Library/LaunchAgents/com.adobe.ARMDCHelper.*.plist; do
        matched=1
        label=$(/usr/bin/basename "$plist" .plist)

        # bootout stops what is running NOW and survives nothing. disable is
        # the durable half — launchctl(1): "Once a service is disabled, it
        # cannot be loaded in the specified domain until it is once again
        # enabled. This state persists across boots of the device." It is
        # recorded in /var/db/com.apple.xpc.launchd/disabled.<uid>.plist keyed
        # by LABEL, not by file, so reinstalling the cask does not clear it and
        # a re-bootstrap of a disabled label fails rather than quietly winning.
        /bin/launchctl bootout "gui/$uid/$label" 2>/dev/null || true
        /bin/launchctl disable "user/$uid/$label"
      done

      if [ "$matched" -eq 0 ]; then
        echo "No com.adobe.ARMDCHelper.* LaunchAgent found; Adobe may have moved it" >&2
      fi

      for label in ${lib.escapeShellArgs daemonLabels}; do
        /bin/launchctl bootout "system/$label" 2>/dev/null || true
        /bin/launchctl disable "system/$label"
      done
    '';
  };
in
{
  # Acrobat updates ONLY when its owner says so. Requested 2026-08-31.
  #
  # Three independent things can change Acrobat's version, and stopping one
  # does nothing about the other two:
  #
  #   1. Homebrew, on a lock bump          -> ./homebrew.nix, `greedy = false`
  #   2. Adobe's ARM updater, on a schedule -> the launchd half, below
  #   3. Help > Check for Updates, in-app   -> the bUpdater half, below
  #
  # Adobe's documented enterprise lockdown, `bUpdater = false`, "disables and
  # locks the Updater", overrides UpdateMode, and per Adobe "future product
  # updates won't affect this file":
  #   https://www.adobe.com/devnet-docs/acrobatetk/tools/PrefRef/Macintosh/Updater-Mac.html
  #   https://www.adobe.com/devnet-docs/acrobatetk/tools/AdminGuide_Mac/predeployment_configuration_advanced.html
  #
  # CustomSystemPreferences, NOT CustomUserPreferences — the distinction
  # matters and is easy to get backwards. nix-darwin wraps the user option in
  # `launchctl asuser … sudo --user=… defaults write`
  # (modules/system/defaults-write.nix), landing it in ~/Library/Preferences.
  # Adobe's lock path is the MACHINE root, /Library/Preferences. The user
  # option would write a file Acrobat never consults for lockdown, and would
  # look like it worked.
  #
  # BOTH spellings of FeatureLockdown are written, which is not paranoia.
  # Measured 2026-08-31 against Acrobat 26.001.21771 with `strings`:
  #
  #   Updater.acroplugin/Contents/MacOS/Updater   FeatureLockdown x8, FeatureLockDown x0
  #   Acrobat Update Helper                       FeatureLockDown x2, FeatureLockdown x0
  #
  # and the shipped registration file "…/Registered Products/
  # com.adobe.acrobat.dc.plist" resolves its indirection to the key path
  # "DC/FeatureLockdown/bUpdater" (lowercase d) while Adobe's PUBLISHED example
  # uses capital D. Adobe's own guide says "preference names are case
  # sensitive", so the documentation disagrees with the binaries. Writing both
  # costs one dictionary and removes the question entirely.
  #
  # cServices/bUpdater is a SEPARATE registered product
  # (com.adobe.acrobat.servicesupdater.dc.plist); one bUpdater does not cover
  # it. That key path is read from the shipped file rather than from Adobe's
  # documentation, which does not describe cServices under Updater — harmless
  # if it turns out to be wrong.
  #
  # Deliberately NOT ./chrome.nix's pattern of generating a plist and guarding
  # it with a hash receipt and a reconciler daemon. That machinery exists for
  # one reason: macOS wipes /Library/Managed Preferences at every boot. Nothing
  # wipes /Library/Preferences. Going through `defaults`/cfprefsd rather than
  # writing the file directly is also deliberate — Adobe's guide warns that
  # plists are cached per session and hand-edited files get overwritten.
  system.defaults.CustomSystemPreferences."/Library/Preferences/com.adobe.Acrobat.Pro" = {
    DC = {
      FeatureLockdown = {
        bUpdater = false;
        cServices.bUpdater = false;
      };
      FeatureLockDown = {
        bUpdater = false;
        cServices.bUpdater = false;
      };
    };
  };

  # The preference alone is NOT enough, and this is the part that is easy to
  # miss. com.adobe.ARMDCHelper.plist — the updater's registration for ITSELF —
  # carries no FeatureLockDown entry at all, so bUpdater cannot gate it.
  # Without this half the agent still runs at every login and every 3.5 hours
  # and still contacts armmf.adobe.com; it merely stops updating Acrobat.
  #
  # The converse is equally true, which is why both halves are here: disabling
  # launchd does nothing about Help > Check for Updates, which runs in-process
  # via Updater.acroplugin and never touches launchd. Each control closes the
  # other's gap.
  #
  # NOT deleting these plists. They appear in no pkg receipt — every one on
  # this Mac was checked on 2026-08-31 — so Adobe's code writes them at
  # runtime, and an SMJobBless helper can re-bless itself. Deletion is the
  # option that looks strongest and is actually the weakest.
  #
  # NOT removing Contents/Plugins/Updater.acroplugin, which Adobe does document.
  # That bundle is signed by Adobe Inc. (JQ525L2MZD) with hardened runtime and
  # sealed resources over 5465 files; deleting a plugin breaks the seal for no
  # gain the two layers here do not already provide.
  #
  # No reconciler daemon, unlike chrome.nix: launchd's disabled database
  # persists across boots by design, so asserting it once per activation is
  # enough.
  system.activationScripts.extraActivation.text = lib.mkAfter ''
    ${lib.getExe disableArm}
  '';
}
