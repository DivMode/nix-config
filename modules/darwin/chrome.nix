{
  lib,
  local,
  pkgs,
  ...
}:
let
  plist = pkgs.formats.plist { };

  # THIS FILE CARRIES ONLY KEYS THAT MUST BE MANDATORY, and that is the whole
  # point of its size.
  #
  # Everything below — generating a plist, hashing it, the receipt guard, the
  # activation script, the boot reconciler — exists because of
  # `WebAppInstallForceList`. That policy is declared `RECOMMENDED_PROHIBITED`
  # in Chromium's handler list (chrome/browser/policy/
  # configuration_policy_handler_list_factory.cc), so Chrome REFUSES it at
  # recommended level with "Policy level is not supported." Mandatory policy on
  # a Mac without MDM can only come from a forced value, and the only non-MDM
  # source of forced values is /Library/Managed Preferences — the directory
  # macOS rebuilds at boot. The machinery follows from that single constraint.
  #
  # `ExtensionInstallForcelist` rides in the same file for the same reason: its
  # upstream definition (components/policy/resources/templates/
  # policy_definitions/Extensions/ExtensionInstallForcelist.yaml) carries no
  # `can_be_recommended`, so it too is mandatory-only. It costs nothing extra —
  # the machinery already exists — but it inherits the machinery's one gap: the
  # file is absent between a boot and the reconciler's next pass. Upstream is
  # explicit that "if a previously force-installed app or extension is removed
  # from this list, Google Chrome automatically uninstalls it", so a Chrome
  # started inside that window may drop a forced extension and reinstall it
  # once the policy returns. The Gmail PWA has lived with the same window since
  # 2026-08-31; this is not a new failure mode, only a second passenger.
  #
  # The download settings USED to ride along in here, and paid for it. They are
  # now ordinary user preferences in the `system.defaults` block below, because
  # `DownloadDirectory` is `can_be_recommended: true` upstream and its handler
  # (chrome/browser/download/download_dir_policy_handler.cc) sets the pref
  # regardless of level. Nothing wipes a user preference, so downloads no longer
  # depend on this file being present at all.
  #
  # Do not move them back. On 2026-08-31 a boot at 15:29 left this machine with
  # no download policy loaded, Chrome fell back to a stale profile preference,
  # and an 829 MB download went somewhere nobody had chosen. A key that does not
  # need to be mandatory should not be, because being mandatory here means being
  # briefly absent after every restart.

  chromePolicy = plist.generate "com.google.Chrome.plist" {
    # Never send usage statistics or crash reports to Google, and the reason
    # this must be mandatory rather than a recommended user preference: it is
    # also what suppresses the "Welcome to Google Chrome" first-run dialog.
    # chrome/browser/first_run/first_run_internal_posix.cc returns early from
    # ShouldShowFirstRunDialog() when metrics::IsMetricsReportingPolicyManaged(),
    # and that (chrome/browser/metrics/metrics_reporting_state.cc) is
    # `pref->IsManaged()` on kMetricsReportingEnabled — true only for a forced
    # value. The dialog's other checkbox, default browser, is
    # modules/home/browser.nix. The policy's own definition
    # (policy_definitions/Miscellaneous/MetricsReportingEnabled.yaml): "When
    # this policy is Disabled, anonymous reporting is disabled and no usage or
    # crash data is sent to Google. Users won't be able to change this setting."
    MetricsReportingEnabled = false;

    WebAppInstallForceList = [
      {
        # The URL Chromium itself maps the old Gmail Chrome App to for policy
        # installs (components/policy/core/common/
        # default_chrome_apps_migrator.cc). Authentication remains inside each
        # Chrome profile.
        #
        # Until that profile is signed in to Google, every Gmail URL redirects
        # to accounts.google.com, which Chrome treats as a failed load and
        # answers with a PLACEHOLDER app (chrome/browser/web_applications/jobs/
        # install_placeholder_job.cc): the policy URL as its start URL, and no
        # icon at all unless the policy gives one. That was the broken,
        # iconless Gmail.app on 2026-10-05. Chrome swaps in the real app only
        # at profile start, on a policy change, or when a tab lands on exactly
        # this URL — so after signing in, quit and reopen Chrome once. Do not
        # add Gmail by hand as well; that creates a second app.
        url = "https://mail.google.com/mail/installwebapp?usp=admin";
        default_launch_container = "window";
        # `fallback_app_name` is ignored whenever `custom_name` is set
        # (policy_definitions/.../WebAppInstallForceList.yaml), so it is gone.
        custom_name = "Gmail";
        # The owner's pick, option 3 of the 2026-10-06 icon page: Google's 2026
        # Gmail logo on a dark rounded square drawn to Apple's app-icon grid
        # (824 px body on a 1024 canvas). Gmail's manifest offers only a bare
        # "M", which Chrome on macOS 26+ hands to the system unchanged
        # (os_integration/mac/web_app_shortcut_creator.mm) and macOS 27 then
        # shrinks into a grey box. Chrome takes a custom icon only from a public
        # HTTPS URL, fetched without cookies and used only if its SHA-256
        # matches, hence this repository's raw URL on main; it also gives a
        # pre-sign-in placeholder its icon. Replacing the PNG means updating
        # the hash.
        custom_icon = {
          url = "https://raw.githubusercontent.com/DivMode/nix-config/main/modules/darwin/chrome-icons/gmail.png";
          hash = "cbc39f90f738fbbec7c53ea99b1a2cda8489c582703fdc49b9e8198ece8e94b0";
        };
      }
    ];

    # Extensions installed silently into every profile, which the user cannot
    # disable or remove from chrome://extensions. Each entry is
    # `<32-letter id>;<update url>`; the update URL is only used for the
    # FIRST install and is the Web Store's, spelled out rather than left to the
    # default so what Chrome fetches is written down here.
    #
    # Adding an extension here is a force-INSTALL, not an allow: it appears in
    # every profile on this Mac. Sign-in to the extension itself remains
    # profile state, exactly as the Gmail PWA's authentication does.
    ExtensionInstallForcelist = [
      # Loom — Screen Recorder & Screen Capture. The id is the one Chrome
      # itself had already installed under
      # ~/Library/Application Support/Google/Chrome/Default/Extensions on
      # 2026-09-06 (manifest name "Loom – Screen Recorder & Screen Capture"),
      # so the policy adopts that install rather than adding a second one.
      "liecbddmkiiihnedobmlmillhodjkdmb;https://clients2.google.com/service/update2/crx"

      # 1Password – Password Manager, the browser half of the `1password` cask
      # in ./homebrew.nix. The id is the one the Chrome Web Store serves that
      # title under (chromewebstore.google.com/detail/aeblfdkhhhdcdjpifhhbdiojplfjncoa,
      # checked 2026-10-05). Unlocking it, or linking it to the desktop app,
      # stays a one-time step inside 1Password.
      "aeblfdkhhhdcdjpifhhbdiojplfjncoa;https://clients2.google.com/service/update2/crx"
    ];

    # Keeps 1Password's button on the toolbar rather than behind the puzzle
    # menu. `force_pinned` is one of the three `toolbar_pin` values in the
    # policy's schema (policy_definitions/Extensions/ExtensionSettings.yaml:
    # force_pinned, default_unpinned, default_pinned); force means the user
    # cannot unpin it.
    ExtensionSettings.aeblfdkhhhdcdjpifhhbdiojplfjncoa.toolbar_pin = "force_pinned";
  };
  policyHash = builtins.hashFile "sha256" chromePolicy;
  policyPath = "/Library/Managed Preferences/com.google.Chrome.plist";
  receiptPath = "/Library/Managed Preferences/.nix-config-com.google.Chrome.sha256";

  # ONE installer, run from TWO places: activation, and a boot-time daemon.
  #
  # The daemon is not belt-and-braces, it is the only reason the policy is
  # still there tomorrow. macOS owns /Library/Managed Preferences and rebuilds
  # it at boot from the installed configuration profiles; a plist put there by
  # hand is not backed by a profile, so it is discarded. Measured on this Mac
  # on 2026-08-21: the plist was written at 14:00, the Mac booted at 14:09:02,
  # and by 14:10 the directory had been rewritten with the plist gone. The
  # dotfile receipt beside it survived, because the rebuild only replaces the
  # managed plists it knows about.
  #
  # That has two consequences this module previously got wrong:
  #
  # 1. Every reboot silently dropped the Gmail PWA policy until the next
  #    rebuild. Nothing reported it; Chrome simply stopped being managed.
  # 2. Receipt-without-policy is the NORMAL state after any reboot, not
  #    evidence of tampering — and the old code treated it as fatal, so the
  #    first rebuild after any restart aborted with "Refusing to trust an
  #    orphaned Chrome policy receipt". That is a self-inflicted outage: the
  #    guard fired on a condition macOS creates on purpose.
  #
  # The alternative is a real .mobileconfig configuration profile, which would
  # be both mandatory AND boot-durable — but a non-MDM profile has to be
  # approved by hand in System Settings on every machine, which is exactly the
  # manual step docs/setup/new-mac.md exists to eliminate. Writing to
  # /Library/Preferences instead would survive boot but only ever be a
  # RECOMMENDED policy — Chromium's own Mac guide says so plainly — and a
  # recommendation is not what "downloads go here, and that is not yours to
  # change" means.
  installPolicy = pkgs.writeShellApplication {
    name = "install-chrome-managed-policy";
    text = ''
      policyPath=${lib.escapeShellArg policyPath}
      receiptPath=${lib.escapeShellArg receiptPath}
      expectedHash=${lib.escapeShellArg policyHash}

      # `activation` when run by a rebuild; the boot reconciler passes nothing.
      mode="''${1:-reconcile}"

      # cfprefsd caches managed preferences and does not notice a file written
      # beside it: after the 1Password extension was added on 2026-10-05, the
      # file listed it while CFPreferences still returned only Loom, and a
      # Chrome restarted three minutes later installed nothing. Every cfprefsd
      # is restarted, root's and each user's, because a user's instance hands
      # out what it last received from root's. launchd restarts them on demand.
      #
      # ONLY during a rebuild someone started. The owner's rule (2026-10-06):
      # nothing on this Mac is restarted by a background job, so the 5-minute
      # reconciler never does this, even when the cache is stale.
      flushPreferencesCache() {
        if [ "$mode" = activation ]; then
          /usr/bin/killall cfprefsd 2>/dev/null || true
        fi
      }

      if [ -L "$policyPath" ] || [ -L "$receiptPath" ]; then
        echo "Refusing to replace a symlink at $policyPath or $receiptPath" >&2
        exit 1
      fi

      # A policy file that IS present still has to prove it is ours before we
      # overwrite it. This is the tamper check that still means something:
      # another administrator or management tool putting a real profile here
      # must win, not be clobbered on the next rebuild.
      if [ -e "$policyPath" ]; then
        if [ ! -f "$policyPath" ] || [ ! -f "$receiptPath" ]; then
          echo "Refusing to overwrite unmanaged Chrome policy at $policyPath" >&2
          exit 1
        fi

        recordedHash=$(/bin/cat "$receiptPath")
        actualHash=$(/usr/bin/shasum -a 256 "$policyPath" | /usr/bin/awk '{ print $1 }')
        if [ "$recordedHash" != "$actualHash" ]; then
          echo "Refusing to overwrite Chrome policy changed outside nix-config" >&2
          exit 1
        fi

        if [ "$recordedHash" = "$expectedHash" ]; then
          # The file is right, but Chrome reads it through cfprefsd's cache,
          # which can still hold an earlier version (see
          # ./chrome-policy-current.js). A rebuild flushes that too, or a
          # policy written while the cache was warm never reaches Chrome.
          if [ "$mode" = activation ] \
            && [ "$(/usr/bin/osascript -l JavaScript ${./chrome-policy-current.js} "$policyPath")" != current ]; then
            flushPreferencesCache
          fi
          exit 0
        fi
      fi

      # Deliberately NO orphaned-receipt branch. See the note above: after a
      # reboot the receipt outlives the policy every single time.
      /bin/mkdir -p "/Library/Managed Preferences"
      /usr/bin/install -m 0644 ${chromePolicy} "$policyPath.new"
      /bin/mv -f "$policyPath.new" "$policyPath"
      /usr/bin/printf '%s\n' "$expectedHash" > "$receiptPath.new"
      /bin/chmod 0644 "$receiptPath.new"
      /bin/mv -f "$receiptPath.new" "$receiptPath"
      flushPreferencesCache
    '';
  };
in
{
  # Where downloads land, as an ordinary user preference rather than a policy.
  #
  # nix-darwin runs this as `defaults write com.google.Chrome …` for the primary
  # user, so it lands in ~/Library/Preferences/com.google.Chrome.plist. Chrome
  # reads policy from that domain too — PolicyLoaderMac::Load() uses
  # CFPreferencesCopyAppValue, which searches the whole domain chain — and
  # applies it at RECOMMENDED level, because CFPreferencesAppValueIsForced is
  # false there. chrome://policy shows it as source Platform, level Recommended.
  #
  # Recommended is enough for these two keys and is NOT enough for the PWA; that
  # asymmetry is the entire reason this module is split in two. See the note at
  # the top.
  #
  # `DefaultDownloadDirectory` is deliberately not the key used. It carries
  # `can_be_mandatory: false` upstream, and `DownloadDirectory` overrides it
  # anyway. The prompt key is `PromptForDownloadLocation` — there is no
  # `PromptForDownload`, and a plausible wrong name would be discarded in
  # silence, because Chrome drops unrecognised policy keys without complaint.
  #
  # The one thing recommended level costs: a value the user has already set in
  # Chrome's own settings shadows this one, because a user store outranks the
  # recommended store. Changing local.downloadsDirectory therefore does not move
  # a profile that has its own `download.default_directory` — change it once in
  # Chrome's UI as well, or delete that key from the profile's Preferences JSON.
  #
  # Read from local.nix because it names a volume on this machine.
  # modules/home/downloads.nix owns creating it; dock.nix pins the same value.
  system.defaults.CustomUserPreferences."com.google.Chrome" = {
    DownloadDirectory = local.downloadsDirectory;
    PromptForDownloadLocation = false;
  };

  # Chrome's real PWA installer is profile-owned, but its machine policy is
  # system state. The receipt keeps activation from overwriting a policy file
  # created or later changed by another administrator or management tool.
  system.activationScripts.extraActivation.text = lib.mkAfter ''
    ${lib.getExe installPolicy} activation
  '';

  # Re-assert at boot, because macOS has just thrown the policy away.
  #
  # RunAtLoad ALONE DOES NOT DO THIS, and the original claim here — that a
  # daemon running during boot "wins that race comfortably" — was measured false
  # on 2026-08-31. The Mac booted at 15:29:41 and launchd registered this daemon
  # at 15:31:45, yet by 16:52 the policy file was gone while Chrome had fallen
  # back to a profile preference pointing at a directory this repository stopped
  # naming days earlier. The proof of the ordering is the receipt's mtime: it
  # still read 2026-08-27, so the installer had taken its "policy present and
  # hash matches, nothing to do" early exit rather than rewriting anything. That
  # is only possible if the policy was STILL THERE when the daemon ran. macOS
  # rebuilt the directory afterwards.
  #
  # So the daemon does not lose the race by starting late; it loses by running
  # ONCE, before the wipe it exists to repair. A one-shot cannot fix damage that
  # happens after it exits, whichever order the two land in.
  #
  # StartInterval turns it into a reconciler, which is the same shape
  # modules/home/network-shares.nix already uses for exactly the same class of
  # problem — state owned by macOS that disappears without notice. The cost of a
  # poll is nil: the installer hashes one small file and exits when it matches,
  # so the steady state is a stat and a shasum every five minutes. Sixty seconds
  # would narrow the window further, but Chrome reads policy only at launch, and
  # login plus a browser start is minutes of real time after boot.
  launchd.daemons.chrome-managed-policy = {
    serviceConfig = {
      ProgramArguments = [ (lib.getExe installPolicy) ];
      RunAtLoad = true;
      StartInterval = 300;
      StandardErrorPath = "/var/log/nix-config-chrome-policy.log";
    };
  };
}
