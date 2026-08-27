{
  lib,
  local,
  pkgs,
  ...
}:
let
  inherit (lib)
    concatMapStringsSep
    escapeShellArg
    hasPrefix
    mkIf
    ;

  # A machine whose local.nix predates this module still evaluates.
  shares =
    local.networkShares or {
      server = "";
      account = "";
      mounts = [ ];
      passwordReference = null;
    };

  enabled = shares.mounts or [ ] != [ ];

  # `mount volume` rather than `mount_smbfs`, and the reason is a permission
  # boundary, not a preference. /Volumes is root:wheel drwxr-xr-x, so a user
  # agent cannot create a mountpoint there, and mount_smbfs will not create one
  # for you. `mount volume` goes through NetFS/automountd, which creates the
  # mountpoint as root on the user's behalf AND performs the Keychain lookup.
  #
  # Passed as argv rather than interpolated into `osascript -e`, so a share
  # name can never be parsed as AppleScript.
  mountVolume = pkgs.writeText "mount-volume.applescript" ''
    on run argv
      mount volume (item 1 of argv)
    end run
  '';

  mountScript = pkgs.writeShellApplication {
    name = "mount-network-shares";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      server=${escapeShellArg (shares.server or "")}
      account=${escapeShellArg (shares.account or "")}

      # Is this server on the network the Mac is attached to RIGHT NOW?
      #
      # Asked before anything touches NetFS, because NetFS reports an
      # unreachable server by DRAWING A MODAL DIALOG — "There was a problem
      # connecting to the server". That dialog comes from NetAuthAgent, a
      # separate process, so the >/dev/null on the osascript call below cannot
      # suppress it and never could. Observed 2026-08-27: on an iPhone hotspot
      # (172.20.10.0/28, the file server nowhere on it) this agent's 300s timer
      # put that dialog on screen three times every five minutes, and
      # ~/Library/Logs/mount-network-shares.log recorded the matching "could
      # not mount ... after 5 attempts" for all three shares.
      #
      # Being off the home network is a NORMAL state for this Mac, not a
      # fault. So the answer here decides between doing nothing quietly and
      # mounting — it is not an error path.
      serverPresent() {
        probe=''${server%.}

        case "$probe" in
          *._smb._tcp.local)
            # A Bonjour service instance name is not a hostname — getaddrinfo
            # cannot resolve it, so only DNS-SD can answer, which is also why
            # `nc` is no use in this branch.
            #
            # `dns-sd` never exits on its own: `timeout` is what ends it, so
            # its exit status is always 124 and says nothing. The OUTPUT is
            # the signal. Captured into a variable rather than piped into
            # `grep -q`, because grep closes the pipe on its first match and
            # `set -o pipefail` would then report the SUCCESSFUL case as a
            # failure.
            #
            # Verified 2026-08-27 by advertising an instance locally with
            # `dns-sd -R`: present prints "can be reached at <host>.local.:<port>"
            # within milliseconds, absent prints nothing at all.
            resolved=$(timeout 3 /usr/bin/dns-sd -L "''${probe%._smb._tcp.local}" _smb._tcp local 2>/dev/null || true)
            case "$resolved" in
              *"can be reached at"*) return 0 ;;
              *) return 1 ;;
            esac
            ;;
          *)
            # A plain hostname or address: ask the SMB port itself. -z sends
            # nothing, -G bounds the connect so an unroutable address cannot
            # hold this agent open for the whole TCP timeout.
            /usr/bin/nc -z -G 2 -w 2 "$server" 445 >/dev/null 2>&1
            ;;
        esac
      }

      # Reconcile one share. Idempotent: this runs at login AND on a timer, so
      # doing nothing when the share is already there is the common path.
      reconcile() {
        share="$1"

        # Test the SOURCE, not the mountpoint.
        #
        # If /Volumes/<share> is occupied by anything — a leftover directory, or
        # the share already mounted — macOS quietly mounts the next attempt at
        # /Volumes/<share>-1 instead of failing. A mountpoint-only check would
        # therefore read "not mounted" forever and stack up -1, -2, -3 copies on
        # every timer tick. The remote source is unique; the local path is not.
        if /sbin/mount | /usr/bin/grep -qF "@''${server}/''${share} on "; then
          return 0
        fi

        # ONE attempt, deliberately. The retry loop that used to be here existed
        # for "the network is not up yet", and that job now belongs to
        # serverPresent — by the time execution reaches this line the server
        # has answered, so a failure means something a retry cannot fix: a
        # share that no longer exists, or a password the Keychain no longer
        # matches. Each such failure costs one NetFS dialog, so five attempts
        # would put five on screen. This is a reconciler; the 300s timer is
        # the retry.
        #
        # The ACCOUNT is in the URL deliberately. A bare smb://server/share
        # leaves NetFS to pick a username, and the Keychain item is keyed on
        # (server, account) — miss the account and the stored password is not
        # found, so a mount that should be silent raises an authentication
        # dialog instead. It also matches the form the existing mounts already
        # have: //<account>@<server>/<share>.
        if /usr/bin/osascript ${mountVolume} "smb://''${account}@''${server}/''${share}" >/dev/null 2>&1; then
          mountedSomething=1
          return 0
        fi

        printf 'could not mount smb://%s/%s\n' "$server" "$share" >&2
        return 1
      }

      # At login this agent can start before Wi-Fi has associated, so give the
      # server a short window to appear before concluding it is absent — the
      # same 5 x 10s the per-share retry used to spend, now spent once, and
      # spent on a probe that draws no UI.
      attempt=0
      until serverPresent; do
        attempt=$((attempt + 1))
        if [ "$attempt" -ge 5 ]; then
          # Silent on purpose, and exit 0 rather than 1. This agent runs every
          # 300s forever, so logging every off-site pass would grow an
          # unbounded log describing a machine that is working correctly.
          exit 0
        fi
        sleep 10
      done

      status=0
      mountedSomething=0
      ${concatMapStringsSep "\n      " (share: "reconcile ${escapeShellArg share} || status=1") (
        shares.mounts or [ ]
      )}

      # Refresh the Dock, but ONLY when a share actually went from absent to
      # mounted.
      #
      # dock.nix pins one of these shares as a stack, and the Dock resolves its
      # tiles when it starts — which at boot is before this agent has mounted
      # anything. A folder tile whose path does not exist yet renders as a
      # question mark, and the Dock never re-checks on its own, so it stays
      # wrong until something restarts it. Observed on 2026-08-21: the tile was
      # written at 14:19, the shares mounted at 14:22, and the Dock showed "?"
      # in between.
      #
      # Gated on the transition rather than run every pass, because this agent
      # fires on a 300s timer and an unconditional refresh would flicker the
      # Dock every five minutes forever.
      if [ "$mountedSomething" -eq 1 ]; then
        /usr/bin/killall -qu "$(/usr/bin/id -un)" Dock || true
      fi

      exit "$status"
    '';
  };

  passwordReference = shares.passwordReference or null;
  seedsKeychain = passwordReference != null;
  homebrewPrefix = if pkgs.stdenv.hostPlatform.isAarch64 then "/opt/homebrew" else "/usr/local";
  opExecutable = "${homebrewPrefix}/bin/op";
in
{
  config = mkIf enabled {
    assertions = [
      {
        assertion = (shares.server or "") != "" && (shares.account or "") != "";
        message = "local.networkShares needs both `server` and `account` when `mounts` is non-empty. The account is half the Keychain lookup key; without it macOS cannot find the stored password and every mount prompts.";
      }
      {
        assertion = !seedsKeychain || hasPrefix "op://" passwordReference;
        message = "local.networkShares.passwordReference must be an op:// URI, never the password itself. A literal value here would be copied into the world-readable Nix store.";
      }
    ];

    # Seed the login Keychain from 1Password, once, on a machine that has no
    # entry yet.
    #
    # This is the answer to "how does a brand-new Mac get the password". Without
    # it the first mount raises a Finder authentication dialog and a human has
    # to type it and tick "Remember this password in my keychain" — which works,
    # but is a manual step that a wiped machine has to remember, and this
    # repository's whole setup path is built to avoid exactly that.
    #
    # The secret goes Keychain-ward only. It is read from 1Password at
    # activation and handed to `security` on a command line that Nix never
    # sees: `passwordReference` is a NAME, so the store holds the reference and
    # never the value.
    home.activation.seedNetworkSharePassword = mkIf seedsKeychain (
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        server=${escapeShellArg shares.server}
        account=${escapeShellArg shares.account}

        # Gated on absence, not run unconditionally. `security` would either
        # refuse (without -U) or rewrite the item on every rebuild, and
        # rewriting resets the item's access-control list — which is what
        # decides whether NetAuthSysAgent may read it without prompting.
        if /usr/bin/security find-internet-password -a "$account" -s "$server" -r 'smb ' >/dev/null 2>&1; then
          verboseEcho "Network share password already in the login Keychain"
        elif [ ! -x ${escapeShellArg opExecutable} ]; then
          printf '%s\n' '1Password CLI unavailable; the network share password was not seeded. The first mount will prompt.' >&2
        else
          # TWO authentication paths, tried in order, because the vault holding
          # this password is deliberately not one the shell-exported service
          # account can reach.
          #
          # 1Password service account vault access is IMMUTABLE. That is
          # documented behaviour, not a quirk of this setup: "After you create
          # a service account, you can't add additional vaults or edit any
          # vault permissions it has." The account this machine exports was
          # minted against one vault, so a reference into any other vault is
          # unreachable to it and always will be. There is no "add vault"
          # control to go looking for.
          #
          # So: try the service-account token, then fall back to the desktop
          # app integration. The fallback is not a regression to the biometric
          # prompt secrets.nix warns about, because this entry is gated on the
          # Keychain entry being ABSENT — it is one authorization, once per
          # machine, at a moment (setup-mac.sh) when a human is already signing
          # into the 1Password app anyway.
          tokenPath="$HOME/.config/op/service-account-token"
          sharePassword=""

          if [ -r "$tokenPath" ]; then
            sharePassword="$(
              OP_SERVICE_ACCOUNT_TOKEN="$(cat "$tokenPath")" \
                ${escapeShellArg opExecutable} read ${escapeShellArg (toString passwordReference)} 2>/dev/null || true
            )"
          fi

          if [ -z "$sharePassword" ]; then
            # `env -u`, not OP_SERVICE_ACCOUNT_TOKEN="". op prefers the
            # variable whenever it is SET, so blanking it authenticates as a
            # service account with an empty token and fails rather than
            # reaching the desktop app.
            sharePassword="$(
              env -u OP_SERVICE_ACCOUNT_TOKEN \
                ${escapeShellArg opExecutable} read ${escapeShellArg (toString passwordReference)} 2>/dev/null || true
            )"
          fi

          if [ -n "$sharePassword" ]; then
            # -r 'smb ' — four characters, trailing space included. That is a
            # SecProtocolType FourCharCode, not a typo, and an entry written
            # without it is not the entry NetAuthSysAgent looks up.
            #
            # -T grants NetAuthSysAgent access without a per-mount "allow"
            # dialog. It is the process that actually performs an SMB mount,
            # so omitting it produces a Keychain entry that exists and still
            # prompts.
            run /usr/bin/security add-internet-password \
              -a "$account" \
              -s "$server" \
              -r 'smb ' \
              -D 'Network Password' \
              -l "$server" \
              -T /System/Library/CoreServices/NetAuthAgent.app/Contents/MacOS/NetAuthSysAgent \
              -w "$sharePassword"
            unset sharePassword
          else
            printf '%s\n' 'Could not read the network share password from 1Password; the first mount will prompt.' >&2
          fi
        fi
      ''
    );

    # RunAtLoad covers login. StartInterval makes it a reconciler rather than a
    # one-shot, which matters because an SMB mount does not survive the server
    # rebooting, the Mac sleeping, or Wi-Fi dropping — and a stale unmount is
    # silent. Chrome would just start writing downloads into a local directory
    # nobody looks in.
    launchd.agents.mount-network-shares = {
      enable = true;
      config = {
        ProgramArguments = [ "${mountScript}/bin/mount-network-shares" ];
        RunAtLoad = true;
        StartInterval = 300;
        ProcessType = "Background";
        StandardErrorPath = "${local.homeDirectory}/Library/Logs/mount-network-shares.log";
      };
    };
  };
}
