{
  lib,
  local,
  pkgs,
  ...
}:
let
  plist = pkgs.formats.plist { };
  # Where downloads land: a LOCAL path, and the reason is that this policy has
  # no fallback to give.
  #
  # `DownloadDirectory` takes one static string, read at launch, and it is
  # mandatory. There is no second choice for Chrome to try. So for as long as
  # this named an SMB mount — it did until 2026-08-27 — every download started
  # off the home network was aimed at a path that did not exist and that Chrome
  # could not create, /Volumes being root:wheel drwxr-xr-x.
  #
  # That is not an edge case on this machine. The home connection drops often
  # enough to run on a phone hotspot instead, and on 2026-08-27 it did exactly
  # that: 172.20.10.0/28, all three shares unmounted, for the whole morning.
  #
  # Serving the share when it is mounted and a disk when it is not was
  # considered and rejected. It can only be built by flipping what one fixed
  # path points at, which scatters downloads across two locations according to
  # which network happened to be up, and puts a flip between Chrome writing
  # <name>.crdownload and renaming it. One always-present destination cannot
  # half-work.
  #
  # Read from local.nix because it names a volume on this machine.
  # modules/home/downloads.nix owns creating it; dock.nix pins the same value.
  downloadDirectory = local.downloadsDirectory;

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

    # Every download goes to that one directory, and the setting is not the
    # user's to move.
    #
    # Chrome's own policy definition is unambiguous about the guarantee: it
    # "uses the provided directory, whether or not users specify one or turned
    # on the flag to be prompted for download location every time", and it
    # "overrides the DefaultDownloadDirectory policy". Supported on
    # `chrome.*:11-`, which includes macOS.
    #
    # `DefaultDownloadDirectory` is deliberately NOT the key used here. It
    # carries `can_be_mandatory: false` upstream — it exists only as a
    # recommendation a profile may overrule — so it cannot express "downloads
    # go here, and that is not yours to change".
    #
    # The policy is also what survives a new profile, a reset, or a new Mac.
    # Setting it through `download.default_directory` in the profile's own
    # Preferences JSON does not: docs/state-boundary.md correctly lists that as
    # mutable state Nix does not own, and all three of those events send it
    # quietly back to ~/Downloads with no error.
    DownloadDirectory = downloadDirectory;

    # Strictly redundant for the path guarantee — DownloadDirectory already
    # wins over the prompt, per the sentence quoted above — but declared so the
    # Settings UI AGREES with the behaviour. Without it the "Ask where to save
    # each file" toggle can still read as on while having no effect, which is
    # exactly the kind of application-disagrees-with-stored-state confusion
    # this repository has already paid for once in mouse.nix.
    #
    # The key is `PromptForDownloadLocation`. There is no `PromptForDownload`;
    # a plausible-looking wrong name here would have been silently ignored,
    # because Chrome discards unrecognised policy keys without complaint.
    PromptForDownloadLocation = false;
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
  # Chrome's real PWA installer is profile-owned, but its machine policy is
  # system state. The receipt keeps activation from overwriting a policy file
  # created or later changed by another administrator or management tool.
  system.activationScripts.extraActivation.text = lib.mkAfter ''
    ${lib.getExe installPolicy}
  '';

  # Re-assert at boot, because macOS has just thrown the policy away. Chrome
  # only reads policy when it launches, and it launches after login, so a
  # daemon that runs during boot wins that race comfortably.
  launchd.daemons.chrome-managed-policy = {
    serviceConfig = {
      ProgramArguments = [ (lib.getExe installPolicy) ];
      RunAtLoad = true;
      StandardErrorPath = "/var/log/nix-config-chrome-policy.log";
    };
  };
}
