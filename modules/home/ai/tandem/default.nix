# Tandem: the MCP facade that lets ChatGPT drive this Mac's Herdr agents.
#
#   ChatGPT Web
#     → OpenAI Secure MCP Tunnel (outbound only)
#     → tunnel-client, started by launchd
#     → Tandem stdio MCP, from the pinned DivMode fork
#     → Herdr native session backend
#     → Claude Code / Codex
#
# Herdr stays the authoritative PTY and session runtime: ../../herdr owns its
# configuration and plugins, and Tandem only asks it to create workspaces it
# tags as its own. tmux is NOT a dependency of this path and must not become
# one — upstream Tandem hard-codes tmux, which is why the fork exists. Neither
# is Tailscale: upstream's `hub` mode couples browser MCP exposure to a Funnel,
# and the Secure MCP Tunnel replaces all of it with an outbound connection.
#
# WHAT THIS MODULE OWNS
#   - the pinned Tandem source and its Node runtime;
#   - the `tunnel-client` binary;
#   - Tandem's protected runtime configuration (non-secret settings only);
#   - the launchd agent that keeps the tunnel running;
#   - the tandem-status / tandem-doctor / tandem-restart operator wrappers.
#
# WHAT IT DELIBERATELY DOES NOT OWN
#   - the ChatGPT-side app/connector approval, which is account state;
#   - the runtime API key, which stays in a protected file this module only
#     ever references by path;
#   - Herdr workspaces, panes, and native agent sessions;
#   - tunnel runtime state under ~/Library/Application Support/tunnel-client.
#
# The whole module is off unless local.nix names at least one allowlisted
# working directory, the same "empty list disables it" shape ../../network-shares.nix
# uses for its mounts. That is not a convenience: Tandem's cwd allowlist is the
# admission boundary for every session ChatGPT can open, and a default would be
# a default answer to "which directories may a remote model write to".
{
  config,
  inputs,
  lib,
  local,
  pkgs,
  ...
}:
let
  inherit (lib)
    concatStringsSep
    getExe
    hasPrefix
    mkIf
    mkOption
    optionalString
    types
    ;

  cfg = config.nixConfig.ai.tandem;
  tandemLocal = local.tandem or { };
  tunnelLocal = tandemLocal.tunnel or { };

  inherit (pkgs.stdenv.hostPlatform) system;

  # ../../herdr owns Herdr's configuration and ../../development.nix installs
  # it; this is the same derivation, referenced for its path only. Tandem is
  # given the absolute store path rather than a bare `herdr`, so the backend
  # cannot resolve to some other binary that happens to be on PATH first.
  herdr = inputs.herdr.packages.${system}.default;

  tandem = pkgs.callPackage ./package.nix {
    src = inputs.tandem;
    rev = inputs.tandem.rev;
  };

  tunnelClient = pkgs.callPackage ./tunnel-client.nix { };

  # Tandem's protected runtime configuration, as Nix declares it.
  #
  # Every value here is non-secret: directory names, engine ids, the backend
  # selection, and store paths. The runtime API key is NOT here and must never
  # be — it belongs to the tunnel, not to Tandem, and this module only ever
  # names the file it lives in.
  #
  # Keys must match /^TANDEM_[A-Z0-9_]+$/ and map to strings; Tandem's
  # src/runtime-config.ts rejects anything else before it starts.
  declaredRuntimeConfig = {
    TANDEM_CWD_ALLOWLIST = concatStringsSep ":" cfg.cwdAllowlist;

    # Empty means Claude only. Codex is opt-in and stays off until its
    # Herdr-backed session has actually been proven on this host.
    TANDEM_ENABLED_ENGINES = concatStringsSep "," cfg.extraEngines;

    TANDEM_TERMINAL_BACKEND = "herdr";
    TANDEM_HERDR_BIN = getExe herdr;
    TANDEM_HERDR_SESSION = cfg.herdrSession;
    TANDEM_HERDR_WORKSPACE_PATH = concatStringsSep ":" cfg.workspacePath;
  };

  runtimeConfigJson = pkgs.writeText "tandem-config.json" (
    builtins.toJSON declaredRuntimeConfig + "\n"
  );

  runtimeDirectory = "${config.xdg.configHome}/tandem";
  runtimeConfigFile = "${runtimeDirectory}/config.json";

  # The stdio MCP server with its configuration attached.
  #
  # A wrapper rather than an environment variable in the launchd plist, so the
  # tunnel service, `tandem-doctor`, and anyone running the MCP server by hand
  # all reach the same configuration through one definition instead of three
  # copies that can disagree.
  tandemMcp = pkgs.writeShellApplication {
    name = "tandem-mcp";
    text = ''
      export TANDEM_CONFIG_FILE=${lib.escapeShellArg runtimeConfigFile}
      exec ${tandem}/bin/tandem-stdio "$@"
    '';
  };

  # tunnel-client's native profile. Flags > environment > YAML > defaults, and
  # a file is the surface upstream documents for a long-lived runtime.
  #
  # `api_key` is a REFERENCE, never a value: `file:<path>` makes tunnel-client
  # read the key at startup from a file this repository does not own and never
  # reads. Putting the key itself here would copy it into the world-readable
  # Nix store, which AGENTS.md forbids and which no later chmod could undo.
  #
  # The tunnel id is an identifier, not a credential, and it comes from the
  # ignored local.nix rather than tracked source — the same treatment the
  # 1Password item IDs in ../../secrets.nix get. It is worth nothing without
  # the runtime key.
  tunnelProfile = (pkgs.formats.yaml { }).generate "tandem-tunnel-profile.yaml" {
    config_version = 1;
    control_plane = {
      base_url = cfg.tunnel.controlPlaneBaseUrl;
      tunnel_id = cfg.tunnel.id;
      api_key = "file:${toString cfg.tunnel.apiKeyFile}";
    };
    health.listen_addr = cfg.tunnel.healthListenAddress;
    admin_ui.open_browser = false;
    log = {
      level = "info";
      format = "struct-text";
    };
    # Stdio transports are always bound to channel `main`; upstream's
    # sample_mcp_stdio_local says so explicitly.
    mcp.commands = [
      {
        channel = "main";
        command = getExe tandemMcp;
      }
    ];
  };

  # Shared preflight. Every prerequisite that can be checked without printing a
  # secret, in the order a failure should be read: configuration first, then
  # the key file, then Herdr.
  #
  # It never cats the key file. `test -s` and a permission check answer "is
  # this usable" without the value ever entering a log, a terminal, or an issue
  # comment.
  #
  # The tunnel id is checked at BUILD time rather than with a shell test: it is
  # interpolated from local.nix, so a runtime `[ -z ... ]` would be comparing a
  # literal against itself — which is exactly what shellcheck rejects, and it
  # is right to.
  preflight = ''
    tandem_preflight_problems=0

    tandem_report() {
      printf '%s\n' "$1" >&2
      tandem_preflight_problems=$((tandem_preflight_problems + 1))
    }

    if [ ! -f ${lib.escapeShellArg runtimeConfigFile} ]; then
      tandem_report "Tandem runtime configuration is missing: ${runtimeConfigFile} (run the repository's rebuild script)"
    elif [ -n "$(find ${lib.escapeShellArg runtimeConfigFile} -perm +077 2>/dev/null)" ]; then
      tandem_report "Tandem runtime configuration permissions are too broad: ${runtimeConfigFile}"
    fi

    ${optionalString (cfg.tunnel.id == "") ''
      tandem_report "No Secure MCP Tunnel id is configured; set tandem.tunnel.id in local.nix"
    ''}

    if [ ! -f ${lib.escapeShellArg (toString cfg.tunnel.apiKeyFile)} ]; then
      tandem_report "The tunnel runtime key file is missing: ${toString cfg.tunnel.apiKeyFile}"
    elif [ ! -s ${lib.escapeShellArg (toString cfg.tunnel.apiKeyFile)} ]; then
      tandem_report "The tunnel runtime key file is empty: ${toString cfg.tunnel.apiKeyFile}"
    elif [ -n "$(find ${lib.escapeShellArg (toString cfg.tunnel.apiKeyFile)} -perm +077 2>/dev/null)" ]; then
      tandem_report "The tunnel runtime key file must not be group- or world-readable: ${toString cfg.tunnel.apiKeyFile}"
    fi

    if ! ${getExe herdr} session list --json >/dev/null 2>&1; then
      tandem_report "Herdr is not answering; start it before expecting Tandem sessions to open"
    fi
  '';

  # What launchd actually runs.
  #
  # A missing prerequisite exits 0 rather than failing: with KeepAlive on a
  # non-zero exit, an unconfigured machine would otherwise crash-loop the
  # daemon every few seconds and bury the one line that says why. Exiting
  # cleanly leaves the reason in the log, leaves `tandem-doctor` to report it,
  # and leaves `tandem-restart` as the one command to run after provisioning
  # the key. A configured host that then FAILS still exits non-zero and is
  # restarted, which is the case KeepAlive is for.
  tunnelService = pkgs.writeShellApplication {
    name = "tandem-tunnel-service";
    text = ''
      ${preflight}

      if [ "$tandem_preflight_problems" -ne 0 ]; then
        printf '%s\n' "tandem: not starting the Secure MCP Tunnel until the problems above are resolved; run 'tandem-restart' afterwards" >&2
        exit 0
      fi

      exec ${getExe tunnelClient} run --config ${tunnelProfile}
    '';
  };

  tandemStatus = pkgs.writeShellApplication {
    name = "tandem-status";
    text = ''
      printf '%s\n' "tandem     ${tandem.version}"
      printf '%s\n' "source     ${inputs.tandem.rev}"
      printf '%s\n' "backend    herdr (${getExe herdr})"
      printf '%s\n' "engines    claude${
        optionalString (cfg.extraEngines != [ ]) ", ${concatStringsSep ", " cfg.extraEngines}"
      }"
      printf '%s\n' "allowlist  ${concatStringsSep " " cfg.cwdAllowlist}"
      printf '%s\n' "config     ${runtimeConfigFile}"
      printf '%s\n' "tunnel     ${getExe tunnelClient} ${tunnelClient.version}"
      printf '\n'

      printf '%s\n' "launchd:"
      launchctl print "gui/$(id -u)/${launchdLabel}" 2>/dev/null \
        | grep -E '^[[:space:]]+(state|pid|last exit code) ' \
        || printf '%s\n' "  the ${launchdLabel} agent is not loaded"
      printf '\n'

      printf '%s\n' "tunnel health:"
      ${getExe tunnelClient} health --config ${tunnelProfile} 2>&1 || true
    '';
  };

  tandemDoctor = pkgs.writeShellApplication {
    name = "tandem-doctor";
    text = ''
      ${preflight}

      if [ "$tandem_preflight_problems" -eq 0 ]; then
        printf '%s\n' "prerequisites: ok"
      fi

      printf '\n%s\n' "tunnel-client doctor:"
      ${getExe tunnelClient} doctor --config ${tunnelProfile} --explain 2>&1 || tandem_preflight_problems=$((tandem_preflight_problems + 1))

      printf '\n%s\n' "herdr:"
      ${getExe herdr} --version 2>&1 || true

      # Non-zero on any problem, so this is usable as a gate and not only as
      # something to read.
      [ "$tandem_preflight_problems" -eq 0 ]
    '';
  };

  tandemRestart = pkgs.writeShellApplication {
    name = "tandem-restart";
    text = ''
      # kickstart -k stops the running instance and starts a fresh one. It is
      # the right verb even when nothing is running: the agent is loaded at
      # login, and a clean exit from an unconfigured preflight leaves it loaded
      # but idle, which is exactly the state this command exists to leave.
      launchctl kickstart -k "gui/$(id -u)/${launchdLabel}"
      printf '%s\n' "restarted ${launchdLabel}; follow ${tunnelLogFile}"
    '';
  };

  launchdLabel = "org.nix-community.home.tandem-tunnel";
  tunnelLogFile = "${local.homeDirectory}/Library/Logs/tandem-tunnel.log";

  # An allowlist root must not be able to admit the whole machine. `/` and the
  # home directory itself are the obvious cases; `/Users` is the one that looks
  # specific and is not.
  swallowsHome =
    entry: entry == "/" || entry == local.homeDirectory || hasPrefix "${entry}/" local.homeDirectory;
in
{
  options.nixConfig.ai.tandem = {
    enable = mkOption {
      type = types.bool;
      default = cfg.cwdAllowlist != [ ];
      defaultText = lib.literalExpression "local.tandem.cwdAllowlist != [ ]";
      description = ''
        Install the pinned Tandem fork, its Herdr backend configuration, and the
        Secure MCP Tunnel runtime. Enabled by naming at least one allowlisted
        working directory in local.nix.
      '';
    };

    cwdAllowlist = mkOption {
      type = types.listOf types.str;
      default = tandemLocal.cwdAllowlist or [ ];
      defaultText = lib.literalExpression "local.tandem.cwdAllowlist or [ ]";
      description = ''
        The only directories in which Tandem may start an agent session, as
        absolute paths. This is the admission boundary for everything ChatGPT
        can reach, so it is explicit host configuration and is never derived
        from $HOME, from `/`, or from a scan of the filesystem.
      '';
    };

    extraEngines = mkOption {
      type = types.listOf (types.enum [ "codex" ]);
      default = tandemLocal.extraEngines or [ ];
      defaultText = lib.literalExpression "local.tandem.extraEngines or [ ]";
      description = ''
        Engines enabled in addition to Claude, which is always on. Only `codex`
        is accepted: `shell` is arbitrary command execution and the Herdr
        backend refuses it outright, and `hermes` attaches to a loopback
        gateway this configuration does not run.
      '';
    };

    herdrSession = mkOption {
      type = types.strMatching "[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}";
      default = tandemLocal.herdrSession or "default";
      defaultText = lib.literalExpression ''local.tandem.herdrSession or "default"'';
      description = ''
        The named persistent Herdr session Tandem talks to. Tandem never starts,
        resets, or reloads it; it must already be running.
      '';
    };

    workspacePath = mkOption {
      type = types.listOf types.str;
      default = tandemLocal.workspacePath or [ ];
      defaultText = lib.literalExpression "local.tandem.workspacePath or [ ]";
      description = ''
        PATH entries applied to the Herdr workspaces Tandem creates for itself,
        as absolute directories.

        This exists because a Herdr workspace inherits the environment of the
        Herdr SERVER, not of the shell that configured it. On 2026-08-29 that
        surfaced as `agent target ... not found` from Tandem and
        `codex: command not found` in the pane behind it — the agent name
        disappeared because the command it named exited immediately. Scoping a
        PATH to Tandem's own workspaces fixes that without a global shim and
        without touching the user's Herdr session.
      '';
    };

    tunnel = {
      id = mkOption {
        type = types.str;
        default = tunnelLocal.id or "";
        defaultText = lib.literalExpression ''local.tandem.tunnel.id or ""'';
        description = ''
          The Secure MCP Tunnel id this host connects to. Account-specific, so
          it lives in the ignored local.nix. Empty leaves the launchd agent
          loaded and idle rather than crash-looping, and `tandem-doctor` says so.
        '';
      };

      apiKeyFile = mkOption {
        type = types.str;
        default = tunnelLocal.apiKeyFile or "${runtimeDirectory}/tunnel-api-key";
        defaultText = lib.literalExpression ''local.tandem.tunnel.apiKeyFile or "''${config.xdg.configHome}/tandem/tunnel-api-key"'';
        description = ''
          Path to the file holding the tunnel runtime API key. A PATH, never a
          value: the key is read by tunnel-client at startup and must never
          reach a Nix expression, the store, or a command line. Create it
          yourself with mode 0600; nothing in this repository writes it.
        '';
      };

      controlPlaneBaseUrl = mkOption {
        type = types.str;
        default = "https://api.openai.com";
        description = "OpenAI tunnel control-plane base URL.";
      };

      healthListenAddress = mkOption {
        type = types.str;
        default = "127.0.0.1:8790";
        description = ''
          Where the tunnel runtime serves /healthz, /readyz, and /ui. Loopback
          only: this is an operator surface, not part of the tunnel, and
          binding it to an interface would undo the point of an outbound-only
          architecture.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.cwdAllowlist != [ ];
        message = "nixConfig.ai.tandem.cwdAllowlist must name at least one directory; an empty allowlist refuses every session.";
      }
      {
        assertion = lib.all (entry: hasPrefix "/" entry) cfg.cwdAllowlist;
        message = "Every nixConfig.ai.tandem.cwdAllowlist entry must be an absolute path.";
      }
      {
        assertion = !lib.any swallowsHome cfg.cwdAllowlist;
        message = ''
          A nixConfig.ai.tandem.cwdAllowlist entry admits the whole home directory.
          Name the individual project directories Tandem may work in instead of
          `/`, `/Users`, or ${local.homeDirectory}.
        '';
      }
      {
        assertion = lib.all (entry: hasPrefix "/" entry) cfg.workspacePath;
        message = "Every nixConfig.ai.tandem.workspacePath entry must be an absolute directory.";
      }
      {
        assertion = hasPrefix "127.0.0.1:" cfg.tunnel.healthListenAddress;
        message = "nixConfig.ai.tandem.tunnel.healthListenAddress must stay on loopback.";
      }
    ];

    home.packages = [
      tandem
      tunnelClient
      tandemMcp
      tandemStatus
      tandemDoctor
      tandemRestart
    ];

    # The declared configuration, kept where it can be read and diffed without
    # opening the protected copy — the same review artifact ../default.nix
    # generates for Codex's managed preferences.
    home.file.".config/nix-config/ai/tandem-config.json".source = runtimeConfigJson;

    # Tandem refuses a runtime configuration that is a symlink, is not owned by
    # the caller, or is readable by anyone else (src/runtime-config.ts), so a
    # Home Manager store link cannot be used: it is a symlink into a
    # world-readable store, which is two of those three at once. Install a real
    # 0600 file instead, the arrangement ../default.nix uses for Claude Code's
    # settings.json and ../../karabiner.nix for its config directory.
    #
    # Gated on a real difference. Activation runs on every rebuild, and
    # rewriting this file would otherwise churn a file the running MCP server
    # reads at startup during rebuilds that have nothing to do with Tandem.
    home.activation.installTandemRuntimeConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      tandemDirectory=${lib.escapeShellArg runtimeDirectory}
      tandemConfig=${lib.escapeShellArg runtimeConfigFile}

      # An older generation may have linked this into the store, and Tandem
      # rejects a symlink outright rather than following it.
      if [[ -L "$tandemConfig" ]]; then
        run rm -f "$tandemConfig"
      fi

      run mkdir -p "$tandemDirectory"
      run chmod 0700 "$tandemDirectory"

      if /usr/bin/cmp -s ${runtimeConfigJson} "$tandemConfig"; then
        verboseEcho "Tandem runtime configuration is already current"
      else
        run install -m 0600 ${runtimeConfigJson} "$tandemConfig"
      fi
    '';

    # RunAtLoad covers login and reboot; KeepAlive restarts a runtime that
    # dies. SuccessfulExit = false is the important half: the service script
    # exits 0 when a prerequisite is missing, and that must NOT be restarted in
    # a tight loop — see the comment on tunnelService above.
    #
    # There is no StartInterval. The tunnel is a long-lived outbound poller
    # rather than a reconciler like ../../network-shares.nix: while it is
    # healthy there is nothing to reconcile, and once it is not, KeepAlive has
    # already restarted it.
    launchd.agents.tandem-tunnel = {
      enable = true;
      config = {
        ProgramArguments = [ (getExe tunnelService) ];
        RunAtLoad = true;
        KeepAlive.SuccessfulExit = false;
        ProcessType = "Background";
        StandardOutPath = tunnelLogFile;
        StandardErrorPath = tunnelLogFile;
      };
    };
  };
}
