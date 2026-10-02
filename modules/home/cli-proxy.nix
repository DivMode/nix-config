{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.nixConfig.cliProxy;
  packages = import ./cli-proxy-packages.nix { inherit lib pkgs; };
  inherit (packages) gateway manager;
  state = cfg.stateDirectory;
  dashboardURL = "http://127.0.0.1:${toString cfg.dashboardPort}";
  gatewayURL = "http://127.0.0.1:${toString cfg.gatewayPort}";
  python = pkgs.python3.withPackages (p: [
    p.pyyaml
  ]);
  desired = pkgs.writeText "cli-proxy-boundary.json" (
    builtins.toJSON {
      config-version = 8;
      server = {
        host = "127.0.0.1";
        port = cfg.gatewayPort;
        trusted-proxies = [ ];
        tls.enable = false;
        discovery.enabled = false;
      };
      management = {
        allow-remote = false;
        secret-key = "";
        disable-control-panel = true;
        disable-auto-update-panel = true;
      };
      access.api-keys = [ ];
      oauth = {
        auth-dir = "${state}/auth";
        providers.aistudio.ws-auth = false;
      };
      observability = {
        logs = {
          debug = false;
          logging-to-file = true;
          logs-max-total-size-mb = 100;
          error-logs-max-files = 10;
          request-log = false;
        };
        usage = {
          usage-statistics-enabled = true;
          redis-usage-queue-retention-seconds = 3600;
        };
        pprof.enable = false;
      };
      plugins = {
        enabled = false;
        dir = "${state}/plugins";
      };
    }
  );
  managerConfig = pkgs.writeText "cpa-manager-plus-config.json" (
    builtins.toJSON {
      httpAddr = "127.0.0.1:${toString cfg.dashboardPort}";
      dataDir = "${state}/manager";
      cpaUpstreamUrl = gatewayURL;

      collectorMode = "http";
      corsOrigins = [
        dashboardURL
        "http://localhost:${toString cfg.dashboardPort}"
      ];
    }
  );
  gatewayStart = pkgs.writeShellScript "cli-proxy-start" ''
    # Declared listener/configuration boundary: ${desired}
    set -eu
    umask 077
    if [ -n "''${MANAGEMENT_PASSWORD:-}" ]; then
      printf '%s\n' 'Refusing MANAGEMENT_PASSWORD: it forces remote management.' >&2
      exit 1
    fi
    cd ${lib.escapeShellArg "${state}/gateway"}
    exec ${gateway}/bin/cli-proxy-api -config ${lib.escapeShellArg "${state}/gateway/config.yaml"}
  '';
  managerStart = pkgs.writeShellScript "cpa-manager-plus-start" ''
    set -eu
    umask 077
    cd ${lib.escapeShellArg "${state}/manager"}
    export CPA_MANAGER_CONFIG=${managerConfig}
    # Non-secret compatibility marker; this local gateway accepts no-key requests.
    export CPA_MANAGEMENT_KEY=local
    exec ${manager}/bin/cpa-manager-plus
  '';
  dashboard = pkgs.writeShellScriptBin "cli-proxy-dashboard" ''
    set -eu
    /usr/bin/open ${lib.escapeShellArg "${dashboardURL}/management.html"}
  '';
  login = pkgs.writeShellScriptBin "cli-proxy-login" ''
    set -eu
    umask 077
    case "''${1:-}" in
      codex) flag=-codex-login ;;
      codex-device) flag=-codex-device-login ;;
      claude) flag=-claude-login ;;
      antigravity) flag=-antigravity-login ;;
      *) printf '%s\n' 'Usage: cli-proxy-login {codex|codex-device|claude|antigravity}' >&2; exit 2 ;;
    esac
    exec ${gateway}/bin/cli-proxy-api -config ${lib.escapeShellArg "${state}/gateway/config.yaml"} "$flag"
  '';
  agent = start: log: {
    enable = true;
    config = {
      ProgramArguments = [ "${start}" ];
      RunAtLoad = true;
      KeepAlive = true;
      ThrottleInterval = 10;
      ProcessType = "Background";
      Umask = 63;
      StandardOutPath = "${state}/logs/${log}.log";
      StandardErrorPath = "${state}/logs/${log}.log";
    };
  };
in
{
  options.nixConfig.cliProxy = {
    enable = lib.mkEnableOption "local CLIProxyAPI and CPA Manager Plus Full";
    stateDirectory = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/Library/Application Support/nix-config/cli-proxy";
      description = "Private writable application state; never a Nix store path.";
    };
    gatewayPort = lib.mkOption {
      type = lib.types.port;
      default = 8317;
    };
    dashboardPort = lib.mkOption {
      type = lib.types.port;
      default = 18317;
    };
  };
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.isDarwin;
        message = "CLIProxyAPI's launch agents require Darwin.";
      }
      {
        assertion =
          lib.hasPrefix "/" state
          && !(lib.hasPrefix "/nix/store" state)
          && cfg.gatewayPort != cfg.dashboardPort;
        message = "CLIProxyAPI requires an absolute mutable state directory and distinct ports.";
      }
    ];
    home.packages = [
      gateway
      manager
      dashboard
      login
    ];
    home.activation.cliProxyState =
      lib.hm.dag.entryBetween [ "setupLaunchAgents" ] [ "writeBoundary" ]
        ''
          run ${python}/bin/python3 ${./cli-proxy-state.py} ${lib.escapeShellArg state} ${desired}
        '';
    # The pinned Home Manager modules/launchd/default.nix uses bootout --wait.
    # This macOS launchctl rejects it with "Unrecognized target specifier", leaving
    # the old arguments loaded after installing the new plist. Reconcile only
    # these two services against launchd's actual arguments; unchanged jobs stay up.
    home.activation.cliProxyRunning = lib.hm.dag.entryAfter [ "setupLaunchAgents" ] (
      lib.concatMapStringsSep "\n"
        ({ name, start }: ''
          cliProxyTarget="gui/$UID/org.nix-community.home.${name}"
          if ! /bin/launchctl print "$cliProxyTarget" 2>/dev/null | \
              ${pkgs.gnugrep}/bin/grep -F "exec ${start}" >/dev/null; then
            if /bin/launchctl print "$cliProxyTarget" >/dev/null 2>&1; then
              run /bin/launchctl bootout "$cliProxyTarget"
              if [[ ! -v DRY_RUN ]]; then
                # bootout returns before launchd finishes removing the job.
                # The first activation's bootstrap preceded removal by 17 ms.
                for cliProxyAttempt in {1..100}; do
                  if ! /bin/launchctl print "$cliProxyTarget" >/dev/null 2>&1; then
                    break
                  fi
                  /bin/sleep 0.1
                done
                if /bin/launchctl print "$cliProxyTarget" >/dev/null 2>&1; then
                  printf '%s\n' "Timed out stopping $cliProxyTarget" >&2
                  exit 1
                fi
              fi
            fi
            run /bin/launchctl bootstrap "gui/$UID" \
              ${lib.escapeShellArg "${config.home.homeDirectory}/Library/LaunchAgents/org.nix-community.home.${name}.plist"}
          fi
        '')
        [
          {
            name = "cli-proxy-api";
            start = gatewayStart;
          }
          {
            name = "cpa-manager-plus";
            start = managerStart;
          }
        ]
    );
    launchd.agents = {
      cli-proxy-api = agent gatewayStart "gateway";
      cpa-manager-plus = agent managerStart "manager";
    };
  };
}
