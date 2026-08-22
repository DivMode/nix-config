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
    runtimeInputs = [ ];
    text = ''
      server=${escapeShellArg (shares.server or "")}
      account=${escapeShellArg (shares.account or "")}

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

        # At login the agent can start before the network is reachable. Retry a
        # few times close together so a cold boot settles in under a minute,
        # rather than waiting out the whole StartInterval.
        attempt=0
        while [ "$attempt" -lt 5 ]; do
          # The ACCOUNT is in the URL deliberately. A bare smb://server/share
          # leaves NetFS to pick a username, and the Keychain item is keyed on
          # (server, account) — miss the account and the stored password is not
          # found, so a mount that should be silent raises an authentication
          # dialog instead. It also matches the form the existing mounts
          # already have: //<account>@<server>/<share>.
          if /usr/bin/osascript ${mountVolume} "smb://''${account}@''${server}/''${share}" >/dev/null 2>&1; then
            mountedSomething=1
            return 0
          fi
          attempt=$((attempt + 1))
          sleep 10
        done

        printf 'could not mount smb://%s/%s after 5 attempts\n' "$server" "$share" >&2
        return 1
      }

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
