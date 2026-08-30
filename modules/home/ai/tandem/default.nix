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
# AND THREE THINGS IT SPECIFICALLY DOES NOT DO, because each was considered and
# rejected rather than merely omitted:
#
#   - It does not install, build, or vendor a coding agent. Claude Code comes
#     from ../../development.nix, and Codex is whatever the host already has —
#     on a Mac running the ChatGPT desktop app that is the `codex` inside the
#     application bundle. Building an agent CLI from source to satisfy Tandem
#     would put this repository in the business of shipping someone else's
#     release stream.
#   - It does not change any global PATH. `home.packages` adds Tandem, the
#     tunnel client, and the wrappers, and nothing else reaches an environment.
#     `workspacePath` is passed to Herdr as `workspace.create.env.PATH` for
#     Tandem's own disposable workspaces only, so an agent that Tandem can see
#     does not thereby appear in the user's shell.
#   - It does not touch the user's Herdr configuration, plugins, or personal
#     session. ../../herdr owns those. Tandem's own silent config lives in
#     Tandem's state directory, and the only session it manages is its
#     dedicated one: it starts a headless Herdr server for that session when it
#     is not already running, and never reloads or resets a server that is.
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

  # The shell environment Tandem-owned Herdr panes need, and its tests. Kept in
  # its own file because the reasoning is long, the rule is subtle, and it is
  # the kind of thing that gets "tidied" into a global export by someone who
  # did not read why it is scoped. See ./workspace-env.nix.
  workspaceEnv = import ./workspace-env.nix { inherit pkgs lib; };

  # Which Herdr session Tandem owns, and why it may not be the personal one.
  # The value is defined once in ./session.nix so the option default below, the
  # local.example.nix template, and the binding rule in the canonical policy
  # cannot drift apart. See that file for what silently breaks when they do.
  inherit (import ./session.nix { inherit pkgs lib; }) dedicatedSession personalSession;

  # The PATH a Tandem-owned Herdr workspace actually starts with.
  #
  # Herdr applies TANDEM_HERDR_WORKSPACE_PATH as the workspace's EXACT PATH, not
  # as an addition to one, so whatever this string holds is the whole of PATH
  # while the login shell is still starting. Emitting `workspacePath` verbatim
  # therefore handed a fresh workspace a single directory, and zsh's own startup
  # broke on it before any prompt appeared — measured 2026-08-29:
  # `compdump: command not found: mv` from compinit, then `.zshrc:22: command
  # not found: dirname` and the same for `mkdir` from the HISTFILE line. Those
  # are /bin and /usr/bin tools; nothing was wrong with the shell.
  #
  # So the standard directories are the module's floor and `workspacePath` is
  # only ever ADDED to it. They come first deliberately: the entries a host adds
  # exist to expose something the standard set lacks (on this Mac, the `codex`
  # that ships inside the ChatGPT app bundle), and that same bundle also ships
  # an `rg` — leading entries would silently shadow the user's ripgrep with an
  # app's private copy. Anything genuinely absent from the standard set still
  # resolves; anything present keeps resolving to the system copy.
  #
  # `home.profileDirectory` rather than a literal: it is /etc/profiles/per-user/
  # $USER for a Home Manager run as a nix-darwin module and ~/.nix-profile for a
  # standalone one, and it is where `claude` and `herdr` live either way. No
  # store hash and no home path is written down here.
  standardWorkspacePath = [
    "${config.home.profileDirectory}/bin"
    "/run/current-system/sw/bin"
    "/nix/var/nix/profiles/default/bin"
    "/usr/local/bin"
    "/usr/bin"
    "/bin"
    "/usr/sbin"
    "/sbin"
  ];

  # Empty stays empty: that is the documented "pass no PATH and inherit the
  # Herdr server's environment" case on hosts that need nothing, and a server
  # environment is not the thing this defect was about.
  effectiveWorkspacePath =
    if cfg.workspacePath == [ ] then [ ] else lib.unique (standardWorkspacePath ++ cfg.workspacePath);

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
    TANDEM_HERDR_WORKSPACE_PATH = concatStringsSep ":" effectiveWorkspacePath;
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

  codexEnabled = lib.elem "codex" cfg.extraEngines;

  # Codex resolvability, checked ONLY when Codex is enabled.
  #
  # Deliberately not part of `preflight`: a Codex PATH problem must never stop
  # the tunnel from serving Claude, which is the engine that is always on. This
  # belongs to the doctor, where it is a question being asked, not a gate being
  # applied to an unrelated engine.
  #
  # What it can and cannot know is the whole design here:
  #
  #   - With `workspacePath` set, the workspace PATH is the composed
  #     `effectiveWorkspacePath`, so "will Codex resolve" is fully decidable
  #     from outside — look in those directories. A miss is a real failure and
  #     is counted.
  #   - With `workspacePath` empty, Tandem passes no PATH and the workspace
  #     inherits the Herdr SERVER's environment, which nothing outside Herdr can
  #     read. That is not provably broken, so it is an advisory that does not
  #     count against the exit status. Reporting a guess as a failure would make
  #     the doctor unusable as a gate.
  #
  # This is why `workspacePath` is not required of every host: a machine whose
  # Herdr already sees Codex needs nothing, and one whose Herdr does not gets
  # told exactly which knob to turn.
  codexCheck = optionalString codexEnabled (
    if cfg.workspacePath == [ ] then
      ''
        printf '%s\n' "codex: enabled with no tandem.workspacePath, so its Herdr workspaces inherit the Herdr server's environment. Nothing outside Herdr can read that, so this is unverified rather than wrong. If open_session reports \"agent target ... not found\", read the pane: \"codex: command not found\" means Herdr cannot see the CLI, and tandem.workspacePath in local.nix is the fix."
      ''
    else
      ''
        tandem_codex_resolved=""
        ${
          # One test per configured directory, unrolled at build time. A shell
          # loop over an interpolated list is a loop over literals when the
          # list has one entry, which is the usual case and which shellcheck
          # rejects (SC2043) — correctly, since Nix already knows the entries.
          lib.concatMapStrings (directory: ''
            if [ -z "$tandem_codex_resolved" ] && [ -x ${lib.escapeShellArg "${directory}/codex"} ]; then
              tandem_codex_resolved=${lib.escapeShellArg "${directory}/codex"}
            fi
          '') effectiveWorkspacePath
        }

        if [ -n "$tandem_codex_resolved" ]; then
          printf '%s\n' "codex: resolves to $tandem_codex_resolved"
        else
          tandem_report "codex: enabled, but no executable 'codex' exists on the exact PATH its Herdr workspaces are given: ${concatStringsSep " " effectiveWorkspacePath}"
        fi
      ''
  );

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
      printf '%s\n' "wsp PATH   ${
        if cfg.workspacePath == [ ] then
          "(none; Tandem's Herdr workspaces inherit the Herdr server's environment)"
        else
          concatStringsSep " " effectiveWorkspacePath
      }"
      printf '%s\n' "config     ${runtimeConfigFile}"
      printf '%s\n' "tunnel     ${getExe tunnelClient} ${tunnelClient.version}"
      printf '\n'

      printf '%s\n' "launchd:"
      launchctl print "gui/$(id -u)/${launchdLabel}" 2>/dev/null \
        | grep -E '^[[:space:]]+(state|pid|last exit code) ' \
        || printf '%s\n' "  the ${launchdLabel} agent is not loaded"
      printf '\n'

      printf '%s\n' "tunnel health:"
      # An idle agent is the normal state on a host with no tunnel id, so a
      # failed probe is reported as that rather than as a bare connection error.
      if ! ${getExe tunnelClient} health --port ${healthPort} 2>&1; then
        printf '%s\n' "  no live runtime on ${cfg.tunnel.healthListenAddress} (the launchd agent is idle or stopped; see 'tandem-doctor')"
      fi
    '';
  };

  tandemDoctor = pkgs.writeShellApplication {
    name = "tandem-doctor";
    text = ''
      ${preflight}
      ${codexCheck}

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

  # Reconcile launchd's LOADED job with the plist Home Manager just wrote.
  #
  # Home Manager installs the agent, but its own reload can fail — measured on
  # this host while taking the Tandem 963c583 bump: `setupLaunchAgents` printed
  # "Failed to stop agent 'gui/501/${launchdLabel}': Unrecognized target
  # specifier", then "Failed to start agent ... I/O error (code 5)", and gave
  # up. The plist on disk pointed at the new tunnel service while launchd's
  # in-memory record still executed the PREVIOUS generation's, whose preflight
  # checks an older key path, so the service reported missing prerequisites and
  # exited 0 on every start. `tandem-restart` then faithfully restarted the
  # stale record, which is why a rebuild plus a restart still left the agent
  # loaded but not running. The next rebuild made it worse: the plist no longer
  # differed, so Home Manager skipped the reload entirely and the stale record
  # survived indefinitely.
  #
  # bootout/bootstrap is the only way to replace a loaded job, and it belongs
  # HERE — inside declared activation, where the machine is already being
  # changed deliberately — rather than in a shell command a human is told to
  # run, which is precisely the bypass this repository exists to prevent.
  tunnelAgentReload = pkgs.writeShellApplication {
    name = "tandem-tunnel-agent-reload";
    text = ''
      label=${lib.escapeShellArg launchdLabel}
      plist=${lib.escapeShellArg "${local.homeDirectory}/Library/LaunchAgents/${launchdLabel}.plist"}
      wanted=${lib.escapeShellArg (toString tunnelService)}
      target="gui/$(id -u)/$label"

      # The store path launchd is CURRENTLY running for this label, empty when
      # the job is not loaded at all (a first install, or a booted-out agent).
      loaded_service() {
        /bin/launchctl print "$target" 2>/dev/null \
          | /usr/bin/grep -o '/nix/store/[a-z0-9]\{32\}-tandem-tunnel-service' \
          | /usr/bin/head -n 1 \
          || true
      }

      if [ ! -f "$plist" ]; then
        printf '%s\n' "tandem: $plist is missing; Home Manager did not install the agent" >&2
        exit 1
      fi

      if [ "$(loaded_service)" = "$wanted" ]; then
        # Idempotent: the common rebuild changes nothing here and must not
        # restart a healthy tunnel.
        exit 0
      fi

      # Tolerated: the job may not be loaded, and bootout is asynchronous.
      /bin/launchctl bootout "$target" >/dev/null 2>&1 || true
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        /bin/launchctl print "$target" >/dev/null 2>&1 || break
        /bin/sleep 0.2
      done

      if ! /bin/launchctl bootstrap "gui/$(id -u)" "$plist"; then
        printf '%s\n' "tandem: could not bootstrap $label from $plist" >&2
        exit 1
      fi
      /bin/launchctl kickstart -k "$target" >/dev/null 2>&1 || true

      after="$(loaded_service)"
      if [ "$after" != "$wanted" ]; then
        printf '%s\n' "tandem: $label still runs \"''${after:-no}\" tunnel service after reload; expected this generation" >&2
        exit 1
      fi
      printf '%s\n' "tandem: reloaded $label onto this generation's tunnel service"
    '';
  };

  # `tunnel-client health` probes a LIVE daemon and takes --url/--url-file/--port,
  # not --config: the profile describes how to start a runtime, while health asks
  # a running one how it is. Passing --config there fails with "unknown flag",
  # which is how this was found — `tandem-status` ended in that error on the
  # freshly activated host instead of a health reading. The assertion below
  # keeps the address on loopback, so the port is the only part health needs.
  healthPort = lib.last (lib.splitString ":" cfg.tunnel.healthListenAddress);

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
      default = tandemLocal.herdrSession or dedicatedSession;
      defaultText = lib.literalExpression ''local.tandem.herdrSession or "${dedicatedSession}"'';
      description = ''
        The named persistent Herdr session Tandem talks to, and the only one it
        manages. When that session is not already running, Tandem writes its own
        silent Herdr config and starts a headless Herdr server for it against
        that config; when it is running, Tandem uses it as it stands and never
        reloads or resets it.

        It defaults to the dedicated `${dedicatedSession}` session and may not
        be the personal `${personalSession}` one. That is a binding rule of the
        canonical orchestration policy, and two mechanisms depend on it: a
        remote foreman's constant agent-state notifications stay out of the
        user's own workspace, and the transcript-persistence guard in
        ./workspace-env.nix has a session to scope itself to. Pointed at the
        personal session that guard emits nothing by design, and Tandem's
        workers lose their transcripts with no warning.
      '';
    };

    workspacePath = mkOption {
      type = types.listOf types.str;
      default = tandemLocal.workspacePath or [ ];
      defaultText = lib.literalExpression "local.tandem.workspacePath or [ ]";
      description = ''
        EXTRA PATH entries for the Herdr workspaces Tandem creates for itself,
        as absolute directories. They are appended to the standard macOS and
        Nix user directories this module always provides, never used in place
        of them: Herdr treats the value as the workspace's entire PATH, and a
        PATH without /usr/bin and /bin breaks zsh's own startup before the
        first prompt. Because they are appended, an entry can expose a command
        the standard set lacks but cannot shadow one it already provides.

        This exists because a Herdr workspace inherits the environment of the
        Herdr SERVER, not of the shell that configured it. On 2026-08-29 that
        surfaced as `agent target ... not found` from Tandem and
        `codex: command not found` in the pane behind it — the agent name
        disappeared because the command it named exited immediately. Scoping a
        PATH to Tandem's own workspaces fixes that without a global shim and
        without touching the user's Herdr session.

        One entry is normally enough. Leaving the list empty passes no PATH at
        all, and the workspace then inherits the Herdr server's environment.
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
        assertion = cfg.herdrSession != personalSession;
        message = ''
          nixConfig.ai.tandem.herdrSession is the personal `${personalSession}` Herdr
          session. Tandem workers belong in a dedicated session — `${dedicatedSession}`
          unless the host names another — so a remote foreman's agent-state
          notifications stay out of your own workspace, and so the
          transcript-persistence guard has a session to scope itself to. On the
          personal session that guard emits nothing and Tandem's workers
          silently stop writing transcripts.
          See modules/home/ai/tandem/session.nix.
        '';
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

    # Claude workers opened by Tandem inherit CLAUDE_CODE_CHILD_SESSION from the
    # Herdr server, which makes Claude Code stop writing their transcripts and
    # say so. This restores persistence for Tandem's panes and only those; the
    # personal session is untouched, and nothing global changes. The whole
    # derivation of that is in ./workspace-env.nix.
    programs.zsh.envExtra = workspaceEnv.forceSessionPersistence cfg.herdrSession;

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
    # AFTER setupLaunchAgents, which is what writes the plist this reconciles
    # against. Failing loudly is deliberate: an agent left on a previous
    # generation's service is the exact silent state this exists to end.
    home.activation.reloadTandemTunnelAgent =
      lib.hm.dag.entryAfter [ "writeBoundary" "setupLaunchAgents" ]
        ''
          run ${getExe tunnelAgentReload}
        '';

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
