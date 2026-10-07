{
  config,
  lib,
  local,
  pkgs,
  ...
}:
let
  inherit (lib)
    concatStringsSep
    escapeShellArg
    getExe
    hasInfix
    hasPrefix
    mapAttrsToList
    mkEnableOption
    mkIf
    mkMerge
    mkOption
    types
    ;

  cfg = config.nixConfig.secrets.onePassword;

  referenceIsSafe =
    reference:
    hasPrefix "op://" reference
    && builtins.match "^op://.+/.+/.+$" reference != null
    && !(hasInfix "\n" reference)
    && !(hasInfix "\r" reference);

  setupBootstrap = cfg.setupBootstrap;

  # Every 1Password read on this Mac goes through the self-hosted Connect
  # server, and nothing falls back to anything else (owner ruling, restated
  # 2026-10-07: "Everything should be using connect. Nothing should be using
  # my desktop one password app."). The `op` CLI runtime launcher, the
  # desktop application's SSH agent and the service account (its cached
  # token, `op read` bootstrap and SDK write command) were removed on
  # 2026-10-07; all three had been switched off since the move to Connect.

  # AWS reads credentials by EXECUTING this and parsing its stdout
  # (`credential_process`). Nothing is cached to disk: the keys stay in
  # 1Password and are fetched per invocation through Connect
  # (scripts/aws-credential-connect.py). If Connect cannot answer, the aws call
  # fails loudly.
  awsCredentialProcess = pkgs.writeShellApplication {
    name = "aws-credential-connect";
    text = ''
      exec ${pkgs.python3}/bin/python3 ${../../scripts}/aws-credential-connect.py \
        ${escapeShellArg cfg.connect.envPath} "$@"
    '';
  };

  awsConfigText = concatStringsSep "\n" (
    mapAttrsToList (profileName: profile: ''
      [profile ${profileName}]
      region = ${profile.region}
      credential_process = ${getExe awsCredentialProcess} ${escapeShellArg profile.vault} ${escapeShellArg profile.item}
    '') local.onePassword.awsProfiles
  );
in
{
  options.nixConfig.secrets.onePassword = {
    setupBootstrap = mkOption {
      type = types.bool;
      readOnly = true;
      internal = true;
      default = builtins.getEnv "NIX_CONFIG_SETUP_BOOTSTRAP" == "1";
      description = "Whether this evaluation is the explicit install-only bootstrap generation.";
    };

    connect = {
      enable = mkEnableOption ''
        the cached 1Password Connect environment file every 1Password reader
        on this Mac uses.

        Deliberately NOT exported to shells: the env FILE is the interface,
        and each consumer reads it at its own invocation seam (the git signer
        and transport, the AWS credential process, the network-share mount,
        the local.nix backup, and the work monorepo's deploy seams)
      '';

      envPath = mkOption {
        type = types.str;
        default = "${config.xdg.configHome}/op/connect.env";
        description = ''
          Absolute path to the 0600 env file holding OP_CONNECT_HOST and
          OP_CONNECT_TOKEN. A path, never a value.
        '';
      };
    };

    aws.enable = mkEnableOption ''
      AWS profiles whose credentials are fetched from 1Password on demand
      through `credential_process`.

      No access key is ever written to disk: `~/.aws/config` names the profiles
      and points at a generated helper, and the helper resolves the keys per
      invocation. There is no `~/.aws/credentials` to leak or to go stale
    '';
  };

  config = mkMerge [
    {
      assertions = [
        {
          assertion = !cfg.connect.enable || referenceIsSafe local.onePassword.connectReference;
          message = "local.onePassword.connectReference must be a single-line op://vault/item/field URI. Use the item ID: the Connect credentials item is titled with parentheses.";
        }
        {
          assertion = !cfg.connect.enable || hasPrefix "http" local.onePassword.connectHost;
          message = "local.onePassword.connectHost must be the Connect server URL. It is machine-invariant: the work monorepo's sst.config.ts pins the same value and a per-machine divergence replaces every onepassword.Item.";
        }
      ];
    }

    (mkIf cfg.connect.enable {
      # The local.nix backup in 1Password (a Secure Note, written and read
      # through Connect): scripts/rebuild.sh saves it after every activation.
      # A declared command, so nothing outside it handles the Connect path.
      home.packages = [
        (pkgs.writeShellApplication {
          name = "nix-config-connect-note";
          text = ''
            exec ${pkgs.python3}/bin/python3 ${../../scripts}/onepassword-connect-note.py \
              ${escapeShellArg cfg.connect.envPath} "$@"
          '';
        })

        # Keep the 1Password copy of the token current, so a new Mac is set up
        # with the token this one uses: `nix-config-connect-store-token ids`
        # shows token IDs (never tokens), `... store` writes it and reads back.
        (pkgs.writeShellApplication {
          name = "nix-config-connect-store-token";
          text = ''
            exec ${pkgs.python3}/bin/python3 ${../../scripts}/connect-store-token.py \
              ${escapeShellArg cfg.connect.envPath} ${escapeShellArg local.onePassword.connectReference} "$@"
          '';
        })

        # Replace the Connect token: `nix-config-connect-set-token TOKEN_FILE`.
        # A Connect token's vaults are fixed when it is issued (`op connect
        # token create --vault ...`), so granting a vault means issuing a new
        # token, and the setup wizard keeps any token that still works. Same
        # steps as the wizard's: write a 0600 candidate beside the env file,
        # publish it only after Connect accepts it. The host is local.nix's
        # connectHost; the token is read from a file, never an argument, so it
        # appears in no process list.
        (pkgs.writeShellApplication {
          name = "nix-config-connect-set-token";
          text = ''
            tokenFile="''${1:?usage: nix-config-connect-set-token TOKEN_FILE}"
            envPath=${escapeShellArg cfg.connect.envPath}
            if [[ ! -s "$tokenFile" ]]; then
              printf '%s\n' "ERROR: $tokenFile is empty or missing." >&2
              exit 1
            fi
            token="$(tr -d '[:space:]' < "$tokenFile")"
            mkdir -p "$(dirname "$envPath")"
            chmod 700 "$(dirname "$envPath")"
            candidate="$(umask 077; mktemp "$envPath.tmp.XXXXXX")"
            trap 'rm -f "$candidate"' EXIT
            printf 'OP_CONNECT_HOST=%s\nOP_CONNECT_TOKEN=%s\n' \
              ${escapeShellArg local.onePassword.connectHost} "$token" > "$candidate"
            unset token
            chmod 600 "$candidate"
            if ! ${pkgs.python3}/bin/python3 ${../../scripts}/onepassword-connect-note.py "$candidate" check; then
              printf '%s\n' "ERROR: Connect did not accept the new token; the current one is unchanged." >&2
              exit 1
            fi
            mv "$candidate" "$envPath"
            trap - EXIT
            printf '%s\n' "Connect accepted the new token; it is now in use."
          '';
        })
      ];

      # Activation never reads 1Password and never refreshes the token: the
      # human setup writes this 0600 file once (scripts/setup-mac.sh connect).
      # A missing or incomplete file fails loudly.
      home.activation.onePasswordConnectEnv = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        envPath=${escapeShellArg cfg.connect.envPath}
        if ${if setupBootstrap then "true" else "false"}; then
          printf '%s\n' 'First-generation setup: the Connect environment is written by the setup wizard.' >&2
        elif [ ! -s "$envPath" ] \
          || ! /usr/bin/grep -q '^OP_CONNECT_HOST=.' "$envPath" \
          || ! /usr/bin/grep -q '^OP_CONNECT_TOKEN=.' "$envPath"; then
          printf '%s\n' "ERROR: $envPath is missing or incomplete. Everything that reads 1Password uses Connect only; run scripts/setup-mac.sh connect to write it." >&2
          exit 1
        elif [ "$(/usr/bin/stat -f %Lp "$envPath")" != 600 ]; then
          printf '%s\n' "ERROR: $envPath must be mode 600." >&2
          exit 1
        fi
      '';
    })

    (mkIf cfg.aws.enable {
      # Declared rather than cached: this file holds no credential, only the
      # profile names, regions, and the helper to run. Losing it costs a
      # rebuild, not a rotation.
      home.file.".aws/config".text = awsConfigText;

      # `aws` was absent entirely after this machine was rebuilt, and its
      # absence is not loud: `just ship` reported only "SST lock inspector
      # skipped — aws CLI not found" while the deploy failed for a different
      # reason further down.
      home.packages = [
        pkgs.awscli2
        awsCredentialProcess
      ];
    })
  ];
}
