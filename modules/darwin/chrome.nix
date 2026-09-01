{
  lib,
  local,
  pkgs,
  ...
}:
let
  plist = pkgs.formats.plist { };

  # THIS FILE CARRIES ONE KEY, and that is the whole point of its size.
  #
  # Everything below — generating a plist, hashing it, the receipt guard, the
  # activation script, the boot reconciler — exists for `WebAppInstallForceList`
  # and nothing else. That policy is declared `RECOMMENDED_PROHIBITED` in
  # Chromium's handler list (chrome/browser/policy/
  # configuration_policy_handler_list_factory.cc), so Chrome REFUSES it at
  # recommended level with "Policy level is not supported." Mandatory policy on
  # a Mac without MDM can only come from a forced value, and the only non-MDM
  # source of forced values is /Library/Managed Preferences — the directory
  # macOS rebuilds at boot. The machinery follows from that single constraint.
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
    WebAppInstallForceList = [
      {
        # Google publishes this endpoint specifically for managed Gmail PWA
        # installation. Authentication remains inside each Chrome profile.
        url = "https://mail.google.com/mail/installwebapp?usp=admin";
        default_launch_container = "window";
        fallback_app_name = "Gmail";
        custom_name = "Gmail";
      }
    ];

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
    ${lib.getExe installPolicy}
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
