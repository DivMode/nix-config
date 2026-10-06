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

  # Agent-facing vault/item WRITES through the service account. The `op` CLI is
  # denied to agents (ai/hooks/nix-only-guard.py) because it falls back to the
  # owner's desktop session; the SDK authenticates only with the token, so it
  # cannot. The SDK comes from nixpkgs rather than a per-project install.
  onePasswordServiceAccount = pkgs.writeShellApplication {
    name = "onepassword-sa";
    text = ''
      exec ${pkgs.python3.withPackages (ps: [ ps.onepassword-sdk ])}/bin/python3 \
        ${../../scripts/onepassword-sa.py} "$@"
    '';
  };

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
  # Connect only (scripts/aws-credential-connect.py): no `op`, no service
  # account, no fallback. If Connect cannot answer, the aws call fails loudly.
  awsCredentialProcess = pkgs.writeShellApplication {
    name = "aws-credential-connect";
    text = ''
      exec ${pkgs.python3}/bin/python3 ${../../scripts/aws-credential-connect.py} \
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
      home.packages = [
        onePasswordBootstrap
        onePasswordServiceAccount
      ];

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
      # Connect is the only 1Password path. Activation never calls `op` and
      # never refreshes the token: the human setup writes this 0600 file once
      # (scripts/setup-mac.sh). A missing or incomplete file fails loudly.
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
