{
  config,
  lib,
  local,
  pkgs,
  ...
}:
let
  inherit (lib)
    all
    attrValues
    concatStringsSep
    concatMapStringsSep
    escapeShellArg
    getExe
    getExe'
    hasAttr
    hasInfix
    hasPrefix
    mapAttrsToList
    mkEnableOption
    mkIf
    mkMerge
    mkOption
    optionalString
    types
    ;

  cfg = config.nixConfig.secrets.onePassword;

  referenceIsSafe =
    reference:
    hasPrefix "op://" reference
    && builtins.match "^op://.+/.+/.+$" reference != null
    && !(hasInfix "\n" reference)
    && !(hasInfix "\r" reference);

  environmentNameIsSafe = name: builtins.match "^[A-Za-z_][A-Za-z0-9_]*$" name != null;

  mappingsResolve = all (referenceName: hasAttr referenceName cfg.references) (
    attrValues cfg.environment
  );

  environmentLines =
    if mappingsResolve then
      mapAttrsToList (
        environmentName: referenceName: "${environmentName}=${cfg.references.${referenceName}}"
      ) cfg.environment
    else
      [ ];

  environmentTemplate = pkgs.writeText "onepassword-ai.env" (
    concatStringsSep "\n" environmentLines + optionalString (environmentLines != [ ]) "\n"
  );

  environmentFile = "${config.xdg.configHome}/nix-config/secrets/ai.env";
  sshAgentSocket = "${config.home.homeDirectory}/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock";
  homebrewPrefix = if pkgs.stdenv.hostPlatform.isAarch64 then "/opt/homebrew" else "/usr/local";
  opExecutable = "${homebrewPrefix}/bin/op";
  setupBootstrap = cfg.setupBootstrap;

  # First-machine bootstrap is deliberately a separate, interactive command.
  # Routine activation never authenticates through the desktop application: it
  # requires the token this command stores and fails closed when that token is
  # absent. The setup wizard invokes this only after the user has signed in and
  # enabled the CLI integration.
  onePasswordBootstrap = pkgs.writeShellApplication {
    name = "nix-config-bootstrap-onepassword";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      if [ ! -t 0 ] || [ ! -t 1 ]; then
        printf '%s\n' '1Password bootstrap requires an interactive human setup terminal.' >&2
        exit 1
      fi

      reference="''${1:?service-account reference required}"
      tokenPath="''${2:-$HOME/.config/op/service-account-token}"

      if [ -s "$tokenPath" ]; then
        exit 0
      fi

      if [ -n "''${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
        printf '%s\n' 'A service-account token is already set but its cache is empty; start a fresh setup terminal.' >&2
        exit 1
      fi

      if [ ! -x ${escapeShellArg opExecutable} ]; then
        printf '%s\n' '1Password CLI is unavailable; complete the first Nix generation before bootstrapping.' >&2
        exit 1
      fi

      if ! mkdir -p "$(dirname "$tokenPath")"; then
        printf '%s\n' 'Could not create the service-account token directory.' >&2
        exit 1
      fi
      tmp="$(mktemp "''${tokenPath}.tmp.XXXXXX")" || {
        printf '%s\n' 'Could not create a private temporary token file.' >&2
        exit 1
      }
      trap 'rm -f "$tmp"' EXIT
      umask 077
      if ! ${escapeShellArg opExecutable} read "$reference" > "$tmp" 2>/dev/null; then
        printf '%s\n' 'Could not read the service-account token; confirm the 1Password app is signed in and CLI integration is enabled.' >&2
        exit 1
      fi
      if [ ! -s "$tmp" ]; then
        printf '%s\n' '1Password returned an empty service-account token.' >&2
        exit 1
      fi

      if ! chmod 600 "$tmp"; then
        printf '%s\n' 'Could not set private permissions on the service-account token.' >&2
        exit 1
      fi
      if ! mv "$tmp" "$tokenPath"; then
        printf '%s\n' 'Could not publish the service-account token.' >&2
        exit 1
      fi
      trap - EXIT
    '';
  };

  # AWS reads credentials by EXECUTING this and parsing its stdout
  # (`credential_process`). Nothing is cached to disk: the keys stay in
  # 1Password and are fetched per invocation, which is why this is preferable
  # to writing ~/.aws/credentials.
  #
  # The original hand-written version of this script (documented in the work
  # monorepo) ran `eval $(op signin)` when it found no
  # session. `credential_process` is executed by the AWS SDK with no terminal,
  # so that branch could only ever raise a desktop-app prompt or hang. It loads
  # the cached service-account token instead, and forces service-account mode:
  # with OP_CONNECT_* inherited, `op item get --fields` fails outright, because
  # Connect refuses every non-JSON output format.
  awsCredentialProcess = pkgs.writeShellApplication {
    name = "op-aws-credential-process";

    # curl is declared, not inherited. `credential_process` is executed by the
    # AWS SDK, not by a login shell, so PATH is whatever that caller happened to
    # have — and a heartbeat probe that silently fails to find curl would send
    # every read down the service-account path, quietly spending the daily
    # budget this helper exists to protect.
    runtimeInputs = [ pkgs.curl ];

    text = ''
      vault="''${1:?vault name required}"
      item="''${2:?1Password item title required}"

      # Prefer Connect, which serves reads from the LAN server and does NOT
      # spend the service account's 1,000 request/24h account-wide budget.
      # `credential_process` runs on EVERY aws invocation, so charging that
      # budget here would exhaust it through ordinary use.
      #
      # The choice is made on REACHABILITY, not on whether connect.env exists —
      # and that distinction is the whole bug this replaced. The previous
      # version tested `[ -r connect.env ]` and its comment claimed it fell back
      # "only when Connect is absent (off-LAN)". Going off-LAN does not delete
      # the file. It stayed readable, Connect was sourced anyway, `op read` then
      # tried to reach a LAN address that was not there, and the `elif` holding
      # the service-account fallback could never execute. The fallback was
      # unreachable code, so every `aws` call away from the LAN failed with no
      # second chance — a deploy path that worked at a desk and not on a train.
      #
      # A one-second heartbeat is cheap on-LAN (single-digit milliseconds) and
      # bounds the off-LAN penalty rather than waiting out op's own timeout.
      connectEnv=${escapeShellArg cfg.connect.envPath}
      tokenPath=${escapeShellArg cfg.serviceAccount.tokenPath}
      useConnect=0

      if [ -r "$connectEnv" ]; then
        connectHost=$(
          # shellcheck source=/dev/null
          . "$connectEnv" >/dev/null 2>&1
          printf '%s' "''${OP_CONNECT_HOST:-}"
        )
        if [ -n "$connectHost" ] \
          && curl -fsS -m 1 -o /dev/null "$connectHost/heartbeat" 2>/dev/null; then
          useConnect=1
        fi
      fi

      # Reads through whichever path is live, and if the preferred one fails
      # anyway — Connect up but refusing, a rotated token — tries the other
      # rather than surfacing a partial credential.
      readSecret() {
        if [ "$useConnect" = 1 ]; then
          if value=$(
            set -a
            # shellcheck source=/dev/null
            . "$connectEnv"
            set +a
            ${escapeShellArg opExecutable} read "$1" 2>/dev/null
          ); then
            printf '%s' "$value"
            return 0
          fi
        fi

        if [ -r "$tokenPath" ]; then
          if value=$(
            OP_SERVICE_ACCOUNT_TOKEN="$(cat "$tokenPath")" \
              ${escapeShellArg opExecutable} read "$1" 2>/dev/null
          ); then
            printf '%s' "$value"
            return 0
          fi
        fi

        return 1
      }

      # `op read` with an item ID, not `op item get --fields`: under Connect the
      # CLI refuses every non-JSON output format, so `--fields` cannot work
      # there. The ID also sidesteps the reference parser rejecting the '(' in
      # these items' titles — both constraints measured 2026-08-13.
      if ! access_key_id=$(readSecret "op://$vault/$item/access key id") \
        || ! secret_access_key=$(readSecret "op://$vault/$item/secret access key"); then
        printf '%s\n' "could not read AWS credentials for $item from 1Password (Connect unreachable and no usable service-account token)" >&2
        exit 1
      fi

      # Both or neither. A half-resolved pair printed as JSON is accepted by the
      # AWS SDK and then fails much further downstream as an opaque signature
      # error, rather than here where the cause is obvious.
      if [ -z "$access_key_id" ] || [ -z "$secret_access_key" ]; then
        printf '%s\n' "1Password returned an empty AWS credential field for $item" >&2
        exit 1
      fi

      printf '{"Version":1,"AccessKeyId":"%s","SecretAccessKey":"%s"}\n' \
        "$access_key_id" "$secret_access_key"
    '';
  };

  # The connect.env content derives from `connectHost` and `connectReference`
  # alone — the host is NOT restated as a separate mapping, so each machine
  # types it exactly once in local.nix. The host is a literal known at
  # evaluation time; the token is resolved at activation, so no secret reaches
  # the store.
  connectEnvLines = ''
    if ! printf '%s=%s\n' OP_CONNECT_HOST ${escapeShellArg local.onePassword.connectHost} >> "$tmp"; then
      printf '%s\n' 'Could not write OP_CONNECT_HOST to the temporary Connect environment file.' >&2
      exit 1
    fi
    if value=$(${escapeShellArg opExecutable} read ${escapeShellArg local.onePassword.connectReference} 2>/dev/null) && [ -n "$value" ]; then
      if ! printf '%s=%s\n' OP_CONNECT_TOKEN "$value" >> "$tmp"; then
        printf '%s\n' 'Could not write OP_CONNECT_TOKEN to the temporary Connect environment file.' >&2
        exit 1
      fi
    else
      printf '%s\n' 'Could not resolve OP_CONNECT_TOKEN from 1Password; the Connect environment file was not written.' >&2
      resolved=0
    fi
  '';

  awsConfigText = concatStringsSep "\n" (
    mapAttrsToList (profileName: profile: ''
      [profile ${profileName}]
      region = ${profile.region}
      credential_process = ${getExe awsCredentialProcess} ${escapeShellArg profile.vault} ${escapeShellArg profile.item}
    '') local.onePassword.awsProfiles
  );

  # `claude` is a Nix launcher for Anthropic's native install rather than a
  # Homebrew cask, so this reaches it by absolute store path. `development.nix` withholds the unwrapped package
  # whenever this launcher is enabled, because both provide bin/claude.
  claudeExecutable = getExe' config.nixConfig.claudeCode.package "claude";
  sshAgentConfig = concatMapStringsSep "\n" (itemId: ''
    [[ssh-keys]]
    item = "${itemId}"
  '') local.onePassword.sshAgentKeyIds;

  makeOnePasswordLauncher =
    name: executable:
    pkgs.writeShellApplication {
      inherit name;
      text = ''
        if [ ! -x ${escapeShellArg opExecutable} ]; then
          printf '%s\n' '1Password CLI is unavailable; rebuild the nix-darwin Homebrew configuration and sign in to 1Password.' >&2
          exit 127
        fi

        if [ ! -r ${escapeShellArg environmentFile} ]; then
          printf '%s\n' 'The generated 1Password environment-reference file is missing; rebuild the Home Manager configuration.' >&2
          exit 1
        fi

        exec ${escapeShellArg opExecutable} run \
          --env-file=${escapeShellArg environmentFile} \
          -- ${escapeShellArg executable} "$@"
      '';
    };

  # The absolute store path reaches the vendor Claude Code binary instead of
  # resolving this wrapper recursively through PATH — this launcher is itself
  # named `claude`. No Codex launcher is part of this module.
  claudeWithOnePassword = makeOnePasswordLauncher "claude" claudeExecutable;
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

    enable = mkEnableOption "runtime secret injection from 1Password on macOS";

    references = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = {
        exampleApiToken = "op://Automation/Example API/credential";
      };
      description = ''
        Public-safe 1Password secret references. Every value must use the
        op:// URI form. Literal tokens and passwords are rejected because they
        would be copied into the Nix store.
      '';
    };

    environment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = {
        EXAMPLE_API_TOKEN = "exampleApiToken";
      };
      description = ''
        Environment-variable names mapped to keys in `references`. Values are
        reference names, never secret text or op:// URIs themselves.
      '';
    };

    sshAgent.enable = mkEnableOption "the optional 1Password SSH agent integration";

    serviceAccount = {
      enable = mkEnableOption ''
        a cached 1Password service-account token exported to every shell.

        This exists so the desktop application never prompts. A service
        account authenticates without the app, without biometrics, and
        without a controlling terminal, which is the only way a
        non-interactive process — a `just` recipe, a hook, an agent's
        shell — can read a secret silently.

        Deliberately NOT the Connect server, even though Connect is the
        canonical mode for the Pulumi provider: with OP_CONNECT_HOST
        exported, `op` refuses every non-JSON output format, so
        `op item get --fields ... --reveal` fails. Measured 2026-08-13
        against the live server: "Connect can only be used in combination
        with the JSON output format." Connect belongs at the sst
        invocation boundary, never in a login profile
      '';

      tokenPath = mkOption {
        type = types.str;
        default = "${config.xdg.configHome}/op/service-account-token";
        description = ''
          Absolute path to the 0600 file holding the token. This is a path,
          never a token: any value written into a Nix option is copied into
          the world-readable store.
        '';
      };
    };

    connect = {
      enable = mkEnableOption ''
        a cached 1Password Connect environment file for the deploy path.

        Deliberately NOT exported to shells. Connect is the canonical Pulumi
        provider auth and it does not spend the service account's rolling
        24h request cap, but with OP_CONNECT_HOST set the CLI refuses every
        non-JSON output format, which breaks `op item get --fields`. The
        consumer sources this file at its own invocation seam instead
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
          assertion = !cfg.enable || pkgs.stdenv.hostPlatform.isDarwin;
          message = "The direct 1Password integration is currently supported only on macOS.";
        }
        {
          assertion = mappingsResolve;
          message = "Every nixConfig.secrets.onePassword.environment value must name a declared reference.";
        }
        {
          assertion = !cfg.sshAgent.enable || pkgs.stdenv.hostPlatform.isDarwin;
          message = "The 1Password SSH agent integration is currently supported only on macOS.";
        }
        {
          assertion = !cfg.serviceAccount.enable || hasPrefix "/" cfg.serviceAccount.tokenPath;
          message = "nixConfig.secrets.onePassword.serviceAccount.tokenPath must be an absolute path. A token value here would be copied into the world-readable Nix store.";
        }
        {
          assertion = !cfg.serviceAccount.enable || referenceIsSafe local.onePassword.serviceAccountReference;
          message = "local.onePassword.serviceAccountReference must be a single-line op://vault/item/field URI. Use the item ID rather than its title: a title containing '(' is rejected by op as an invalid secret reference.";
        }
        {
          assertion = !cfg.connect.enable || referenceIsSafe local.onePassword.connectReference;
          message = "local.onePassword.connectReference must be a single-line op://vault/item/field URI. Use the item ID: the Connect credentials item is titled with parentheses, which op rejects outright.";
        }
        {
          assertion = !cfg.connect.enable || hasPrefix "http" local.onePassword.connectHost;
          message = "local.onePassword.connectHost must be the Connect server URL. It is machine-invariant: the work monorepo's sst.config.ts pins the same value and a per-machine divergence replaces every onepassword.Item.";
        }
      ]
      ++ mapAttrsToList (name: reference: {
        assertion = referenceIsSafe reference;
        message = "1Password reference '${name}' must be a single-line op://vault/item/field URI; literal secret values are forbidden.";
      }) cfg.references
      ++ mapAttrsToList (name: _referenceName: {
        assertion = environmentNameIsSafe name;
        message = "1Password environment mapping '${name}' is not a valid environment-variable name.";
      }) cfg.environment;
    }

    (mkIf cfg.enable {
      xdg.configFile."nix-config/secrets/ai.env".source = environmentTemplate;

      home.packages = [
        claudeWithOnePassword
      ];
    })

    (mkIf cfg.sshAgent.enable {
      xdg.configFile."1Password/ssh/agent.toml".text = sshAgentConfig;
      home.sessionVariables.SSH_AUTH_SOCK = sshAgentSocket;

      programs.ssh = {
        enable = true;
        enableDefaultConfig = false;

        # 1Password owns and may rewrite this file. Home Manager owns only the
        # Include directive in ~/.ssh/config and never manages the target.
        includes = [ "~/.ssh/1Password/config" ];

        # SSH clients that read ~/.ssh/config can reach the agent even when they
        # were not launched by a shell that inherited SSH_AUTH_SOCK.
        settings."*".IdentityAgent = ''"${sshAgentSocket}"'';
      };
    })

    (mkIf cfg.serviceAccount.enable {
      # The command is present for the explicit first-machine setup step. It
      # refuses non-interactive callers and accepts the reference/path at run
      # time so the first generation's placeholder local.nix is harmless.
      home.packages = [ onePasswordBootstrap ];

      # `.zshenv`, not `.zshrc`: zsh reads `.zshrc` only for INTERACTIVE shells,
      # and the processes that must never prompt — `just` recipes, Lefthook
      # hooks, an agent's Bash tool — are non-interactive. Wiring this into
      # `initContent` would look correct and fail in exactly the cases it is for.
      programs.zsh.envExtra = ''
        if [[ -r ${escapeShellArg cfg.serviceAccount.tokenPath} ]]; then
          export OP_SERVICE_ACCOUNT_TOKEN="$(<${escapeShellArg cfg.serviceAccount.tokenPath})"
        fi
      '';

      # The token is fetched by the explicit interactive bootstrap command
      # rather than this routine activation entry. A new machine needs the
      # 1Password sign-in that stage 3 of setup-mac.sh already requires; after
      # that, every unattended refresh uses only the cached service-account
      # value. Nix owns the procedure; the value lands only in a 0600 file and
      # never in the store.
      home.activation.onePasswordServiceAccountToken = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        tokenPath=${escapeShellArg cfg.serviceAccount.tokenPath}
        if ${if setupBootstrap then "true" else "false"}; then
          # The setup wizard's first generation exists to install 1Password;
          # its explicit interactive bootstrap runs after sign-in. The flag is
          # read during this one impure evaluation, so this generation carries
          # an install-only branch; the final normal evaluation restores the
          # strict routine path.
          printf '%s\n' 'First-generation setup: service-account bootstrap deferred until after interactive sign-in.' >&2
        elif [ -s "$tokenPath" ]; then
          # Already cached. Activation runs on EVERY rebuild, and this account
          # is capped at 1,000 API requests per rolling 24h account-wide, so
          # an ungated fetch here would spend the same budget deploys need.
          :
        elif [ ! -x ${escapeShellArg opExecutable} ]; then
          printf '%s\n' '1Password CLI is unavailable during routine activation; refusing to continue without the configured credential loader.' >&2
          exit 1
        else
          printf '%s\n' 'Cached 1Password service-account token is missing; run the interactive bootstrap before rebuilding.' >&2
          exit 1
        fi
      '';
    })

    (mkIf cfg.connect.enable {
      # NOT sourced by .zshenv, deliberately — the env FILE is the interface.
      # With OP_CONNECT_HOST exported, `op` refuses every non-JSON output
      # format (measured 2026-08-13: `op whoami` and `op item get --fields`
      # both fail with "Connect can only be used in combination with the JSON
      # output format"), so exporting these to every shell would break
      # ordinary CLI use to fix one deploy path. Each consumer that needs
      # Connect sources this file at its own invocation seam instead: the AWS
      # `credential_process` helper above, and the work monorepo's deploy seams
      # (its sst-connect-env.sh and worker-secrets resolver) load it themselves
      # when the variables are absent.

      # Ordered AFTER the service-account entry BY NAME, not merely after
      # writeBoundary: both would otherwise land in one DAG tier with no
      # ordering between them, and this entry needs that token to already
      # exist so its `op read` can authenticate headlessly.
      home.activation.onePasswordConnectEnv =
        lib.hm.dag.entryAfter [ "onePasswordServiceAccountToken" ]
          ''
            envPath=${escapeShellArg cfg.connect.envPath}
            if ${if setupBootstrap then "true" else "false"}; then
              printf '%s\n' 'First-generation setup: Connect refresh deferred until after interactive sign-in.' >&2
            elif [ ! -s ${escapeShellArg cfg.serviceAccount.tokenPath} ]; then
              if [ ! -x ${escapeShellArg opExecutable} ]; then
                printf '%s\n' '1Password CLI is unavailable during routine Connect refresh; refusing to continue.' >&2
                exit 1
              else
                printf '%s\n' 'Cached 1Password service-account token is missing; Connect refresh cannot use the desktop session.' >&2
                exit 1
              fi
            elif [ ! -x ${escapeShellArg opExecutable} ]; then
              printf '%s\n' '1Password CLI is unavailable while a cached service-account token exists.' >&2
              exit 1
            else
              if [ -n "''${OP_CONNECT_HOST:-}" ] || [ -n "''${OP_CONNECT_TOKEN:-}" ]; then
                printf '%s\n' 'Connect variables are already set; refusing to refresh through an inherited credential context.' >&2
                exit 1
              fi
              # Authenticate with the cached service-account token. Activation runs
              # from darwin-rebuild, NOT a login zsh, so OP_SERVICE_ACCOUNT_TOKEN is
              # absent from this environment. Read it explicitly so `op` cannot
              # fall back to the desktop application.
              OP_SERVICE_ACCOUNT_TOKEN="$(cat ${escapeShellArg cfg.serviceAccount.tokenPath})"
              if [ -z "$OP_SERVICE_ACCOUNT_TOKEN" ]; then
                printf '%s\n' 'Cached 1Password service-account token is empty; Connect refresh aborted.' >&2
                exit 1
              fi
              export OP_SERVICE_ACCOUNT_TOKEN
              mkdir -p "$(dirname "$envPath")"
              if ! (
                umask 077
                tmp="$(mktemp "''${envPath}.tmp.XXXXXX")" || {
                  printf '%s\n' 'Could not create a private temporary Connect environment file.' >&2
                  exit 1
                }
                trap 'rm -f "$tmp"' EXIT
                resolved=1
                ${connectEnvLines}
                # All-or-nothing. A half-written file exports some variables and
                # silently omits others, which surfaces much further downstream —
                # as a provider "not initialized" error mid-deploy rather than here.
                # Rewrite only when the resolved content actually differs, per
                # the cmp -s rule for activation entries that run every rebuild.
                # This entry used to skip entirely when the file merely existed,
                # which meant a rotated Connect token could never reach the file:
                # granting the server a new vault requires issuing a NEW token
                # (vault scope is fixed per token), and activation kept serving
                # the old one until the file was deleted by hand. Observed
                # 2026-08-21, two rebuilds with no effect.
                if [ "$resolved" = 1 ]; then
                  publish=1
                  if [ -e "$envPath" ]; then
                    if cmp -s "$tmp" "$envPath"; then
                      rm -f "$tmp"
                      publish=0
                    else
                      cmp_status=$?
                      if [ "$cmp_status" -ne 1 ]; then
                        printf '%s\n' 'Could not compare the refreshed Connect environment with the existing file.' >&2
                        exit 1
                      fi
                    fi
                  fi
                  if [ "$publish" = 1 ]; then
                    if ! chmod 600 "$tmp"; then
                      printf '%s\n' 'Could not set private permissions on the Connect environment file.' >&2
                      exit 1
                    fi
                    if ! mv "$tmp" "$envPath"; then
                      printf '%s\n' 'Could not publish the refreshed Connect environment file.' >&2
                      exit 1
                    fi
                  fi
                else
                  rm -f "$tmp"
                  exit 1
                fi
              ); then
                printf '%s\n' 'Could not refresh the 1Password Connect environment with the cached service-account token.' >&2
                exit 1
              fi
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
