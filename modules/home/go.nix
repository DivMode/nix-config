# The Go toolchain for the Go programs this repository builds from source
# (gcx, CLIProxyAPI, CPA Manager Plus), at upstream's newest release rather
# than the one the locked nixpkgs ships.
#
# Upstream projects raise their go.mod `go` line to a patch release on the day
# it ships, and nixpkgs trails it: on 2026-10-21 gcx v1.7.1 required go
# 1.26.10, released the day before, while nixos-26.05 had 1.26.8 and
# nixpkgs-unstable 1.26.9 — so the whole system build failed. The release is
# named in ./go-pin.json, which `scripts/update.sh` moves to go.dev's newest
# release before anything that depends on it. It is built by nixpkgs' own
# derivation for that minor line, so nixpkgs' Go patches still apply; only the
# version and source change. Everything else from nixpkgs keeps nixpkgs' Go
# and its binary cache.
{ lib, pkgs }:
let
  pin = lib.importJSON ./go-pin.json;
  minorLine = lib.replaceStrings [ "." ] [ "_" ] (lib.versions.majorMinor pin.version);
  go = pkgs."go_${minorLine}".overrideAttrs {
    inherit (pin) version;
    src = pkgs.fetchurl {
      url = "https://go.dev/dl/go${pin.version}.src.tar.gz";
      inherit (pin) hash;
    };
  };
in
{
  inherit go;
  buildGoModule = pkgs.buildGoModule.override { inherit go; };
}
