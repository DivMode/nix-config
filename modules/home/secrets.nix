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
  claudeExecutable = "${homebrewPrefix}/bin/claude";
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

  # The absolute Homebrew path reaches the vendor Claude Code terminal binary
  # instead of resolving this wrapper recursively through PATH. No Codex
  # launcher or Nix-provided AI executable is part of this module.
  claudeWithOnePassword = makeOnePasswordLauncher "claude" claudeExecutable;
in
{
  options.nixConfig.secrets.onePassword = {
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
  ];
}
