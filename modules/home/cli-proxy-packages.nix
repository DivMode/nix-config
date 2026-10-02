{ lib, pkgs }:
let
  pins = builtins.fromJSON (builtins.readFile ./cli-proxy-pin.json);
  source =
    pin:
    pkgs.fetchurl {
      name = "${builtins.baseNameOf pin.repository}-${pin.version}.tar.gz";
      url = "https://codeload.github.com/${pin.repository}/tar.gz/refs/tags/v${pin.version}";
      sha256 = pin.sourceHash;
    };
  boundary = directory: ''
    mkdir -p ${directory}/internal/nixlocal
    cp ${./cli-proxy-loopback.go} ${directory}/internal/nixlocal/loopback.go
    cp ${./cli-proxy-loopback-test.go} ${directory}/internal/nixlocal/loopback_test.go
  '';
  npmLock =
    pkgs.runCommand "cpa-manager-plus-local-${pins.manager.version}-npm-lock"
      {
        outputHashMode = "flat";
        outputHashAlgo = "sha256";
        outputHash = pins.manager.lockHash;
        NODE_EXTRA_CA_CERTS = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      }
      ''
        ${pkgs.gnutar}/bin/tar -xOf ${source pins.manager} \
          CPA-Manager-Plus-${pins.manager.version}/package-lock.json > package-lock.json
        ${pkgs.nodejs}/bin/node ${./cli-proxy-npm-lock.mjs} package-lock.json "$out"
      '';
  panel = pkgs.buildNpmPackage {
    pname = "cpa-manager-plus-local-panel";
    inherit (pins.manager) version;
    src = source pins.manager;
    npmDepsFetcherVersion = 2;
    npmDepsHash = pins.manager.npmDepsHash;
    npmWorkspace = "apps/web";
    patches = [ ./cli-proxy-local-panel.patch ];
    postPatch = "cp ${npmLock} package-lock.json";
    VERSION = "v${pins.manager.version}";
    installPhase = ''
      mkdir -p "$out/share/cpa-manager-plus"
      cp apps/web/dist/index.html "$out/share/cpa-manager-plus/management.html"
    '';
  };
  metadata = {
    license = lib.licenses.mit;
    platforms = lib.platforms.darwin;
  };
in
{
  gateway = pkgs.buildGoModule {
    pname = "cli-proxy-api-local";
    inherit (pins.gateway) version;
    src = source pins.gateway;
    vendorHash = pins.gateway.vendorHash;
    patches = [ ./cli-proxy-local-gateway.patch ];
    postPatch = boundary ".";
    subPackages = [ "cmd/server" ];
    ldflags = [
      "-s"
      "-w"
      "-X main.Version=${pins.gateway.version}"
    ];
    checkPhase = "go test ./internal/nixlocal";
    postInstall = ''mv "$out/bin/server" "$out/bin/cli-proxy-api"'';
    meta = metadata // {
      description = "CLIProxyAPI restricted to local access without keys";
    };
  };
  manager = pkgs.buildGoModule {
    pname = "cpa-manager-plus-local";
    inherit (pins.manager) version;
    src = source pins.manager;
    vendorHash = pins.manager.vendorHash;
    modRoot = "apps/manager-server";
    overrideModAttrs = _: { preBuild = ""; };
    patches = [ ./cli-proxy-local-manager.patch ];
    postPatch = boundary "apps/manager-server";
    preBuild = "cp ${panel}/share/cpa-manager-plus/management.html internal/httpapi/web/management.html";
    subPackages = [ "cmd/cpa-manager-plus" ];
    ldflags = [
      "-s"
      "-w"
      "-X github.com/seakee/cpa-manager-plus/apps/manager-server/internal/buildinfo.Version=${pins.manager.version}"
    ];
    checkPhase = "go test ./internal/nixlocal";
    meta = metadata // {
      description = "CPA Manager Plus Full with local access without keys";
    };
  };
}
