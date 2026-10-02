{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.nixConfig.cliProxy;
  pins = builtins.fromJSON (builtins.readFile ./cli-proxy-pin.json);
  system = pkgs.stdenv.hostPlatform.system;
  nativePackage =
    name: pin: description:
    pkgs.stdenvNoCC.mkDerivation {
      pname = name;
      inherit (pin) version;
      src = pkgs.fetchurl {
        url = "https://github.com/${pin.repository}/releases/download/v${pin.version}/${pin.assetPrefix}${pin.version}_${pin.assetSuffixes.${system}}";
        sha256 = pin.hashes.${system};
      };
      # CPA's archive is flat; Manager's archive has a single top directory.
      sourceRoot = if name == "cli-proxy-api" then "." else null;
      dontBuild = true;
      dontFixup = true;
      installPhase = ''
        mkdir -p "$out/bin" "$out/share/licenses/${name}"
        install -m755 ${name} "$out/bin/${name}"
        install -m644 LICENSE "$out/share/licenses/${name}/LICENSE"
      '';
      meta = {
        inherit description;
        license = lib.licenses.mit;
        platforms = lib.platforms.darwin;
      };
    };
  gateway = nativePackage "cli-proxy-api" pins.gateway "Upstream CLIProxyAPI native gateway";
  manager =
    nativePackage "cpa-manager-plus" pins.manager
      "CPA Manager Plus Full with its embedded dashboard";
  state = cfg.stateDirectory;
  dashboardURL = "http://127.0.0.1:${toString cfg.dashboardPort}";
  gatewayURL = "http://127.0.0.1:${toString cfg.gatewayPort}";
  python = pkgs.python3.withPackages (p: [
    p.pyyaml
    p.bcrypt
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
        disable-control-panel = true;
        disable-auto-update-panel = true;
      };
      oauth.auth-dir = "${state}/auth";
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
      managementKeyFile = "${state}/keys/management";
      adminKeyFile = "${state}/keys/admin";
      collectorMode = "http";
      corsOrigins = [
        dashboardURL
        "http://localhost:${toString cfg.dashboardPort}"
      ];
    }
  );
  gatewayStart = pkgs.writeShellScript "cli-proxy-start" ''
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
    exec ${manager}/bin/cpa-manager-plus
  '';
  dashboard = pkgs.writeShellScriptBin "cli-proxy-dashboard" ''
    set -eu
    /usr/bin/pbcopy < ${lib.escapeShellArg "${state}/keys/admin"}
    /usr/bin/open ${lib.escapeShellArg "${dashboardURL}/management.html"}
    printf '%s\n' 'Dashboard admin key copied. Paste it into the login field.'
  '';
  clientKey = pkgs.writeShellScriptBin "cli-proxy-client-key" ''
    set -eu
    /usr/bin/pbcopy < ${lib.escapeShellArg "${state}/keys/client"}
    printf '%s\n' 'Client API key copied.'
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
      clientKey
      login
    ];
    home.activation.cliProxyState =
      lib.hm.dag.entryBetween [ "setupLaunchAgents" ] [ "writeBoundary" ]
        ''
          run ${python}/bin/python3 ${./cli-proxy-state.py} ${lib.escapeShellArg state} ${desired}
        '';
    launchd.agents = {
      cli-proxy-api = agent gatewayStart "gateway";
      cpa-manager-plus = agent managerStart "manager";
    };
  };
}
