{
  description = "Public multi-host Nix configuration for macOS and future NixOS servers";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    nix-darwin = {
      url = "github:nix-darwin/nix-darwin/nix-darwin-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    herdr = {
      url = "github:ogulcancelik/herdr/v0.8.2";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # The DivMode fork of Maxmedawar/tandem, carrying the native Herdr terminal
    # backend that lets ChatGPT drive Herdr's agents without tmux. Upstream is
    # preserved as the fork's `upstream` remote; see DivMode/tandem#1.
    #
    # Pinned to an EXACT COMMIT, not to `feat/herdr-backend`. A branch moves,
    # and an activation that resolved one would install whatever it pointed at
    # that morning — which for the component that lets a remote model open
    # sessions on this Mac is not a pin at all. `nix flake update` cannot move
    # it either: updating Tandem means changing the revision here deliberately,
    # after re-running its typecheck and tests against the new commit.
    #
    # Base: upstream 0.1.0 at a98bcafd2c40ae5473b85fe41183e4f391933799.
    # Verified at this commit: typecheck passes, 37 test files / 400 tests pass.
    #
    # `flake = false` because upstream ships no flake.nix; the package is built
    # by modules/home/ai/tandem/package.nix.
    tandem = {
      url = "github:DivMode/tandem/6c843bd32337b5286f163cfb311c5ad2f28b5928";
      flake = false;
    };

    # Packages for AI coding agents, updated daily by upstream automation.
    # Claude Code publishes several releases a day, far faster than its Homebrew
    # cask tracks: on 2026-08-13 the newest homebrew-cask commit still described
    # 2.1.223 while upstream was on 2.1.231, so no lock update could have closed
    # that gap while it remained a cask.
    #
    # Its nixpkgs is deliberately NOT followed to ours. This input pins
    # nixpkgs-unstable, and overriding that would rebuild every derivation away
    # from what upstream tests and publishes to its own binary cache, for no
    # benefit — the package is a signed vendor binary plus a wrapper.
    llm-agents.url = "github:numtide/llm-agents.nix";

    # Matt Pocock's engineering skills. Consumed as a pinned source tree rather
    # than installed with `claude plugins install`, which writes mutable state
    # this repository could not restore. MIT licensed, so nothing is vendored:
    # only referenced, and updated with `./scripts/update.sh mattpocock-skills`.
    mattpocock-skills = {
      url = "github:mattpocock/skills";
      flake = false;
    };

    # Grafana's gcx CLI, pinned to a release tag. One input feeds two
    # consumers: modules/home/development.nix builds the CLI binary from it
    # (nixpkgs packages gcx, but its pinned release trails upstream), and
    # modules/home/ai loads the repository's claude-plugin/ directory as a
    # Claude Code plugin. Building both from the same pin keeps the binary and
    # the skills that describe it at one version by construction.
    #
    # A tag pin does not advance with `nix flake update` — updating gcx means
    # moving the tag HERE, then letting the vendor-hash mismatch in
    # development.nix report the new hash if Go dependencies changed.
    gcx-src = {
      url = "github:grafana/gcx/v1.2.0";
      flake = false;
    };

    nix-homebrew.url = "github:zhaofengli/nix-homebrew";

    homebrew-core = {
      url = "github:homebrew/homebrew-core";
      flake = false;
    };

    homebrew-cask = {
      url = "github:homebrew/homebrew-cask";
      flake = false;
    };
  };

  outputs =
    inputs@{
      nixpkgs,
      nix-darwin,
      ...
    }:
    let
      localPath = builtins.getEnv "NIX_CONFIG_LOCAL";
      rawLocal =
        if localPath == "" then
          import ./local.example.nix
        else if builtins.substring 0 1 localPath != "/" then
          throw "NIX_CONFIG_LOCAL must be an absolute path"
        else
          import (builtins.toPath localPath);
      requiredLocalFields = [
        "user"
        "hostName"
        "system"
        "homeDirectory"
        "git"
        "onePassword"
        "downloadsDirectory"
      ];
      missingLocalFields = builtins.filter (name: !(builtins.hasAttr name rawLocal)) requiredLocalFields;
      gitFieldsPresent =
        rawLocal ? git
        && builtins.isAttrs rawLocal.git
        && builtins.all (name: builtins.hasAttr name rawLocal.git) [
          "name"
          "email"
          "signingKey"
        ];
      sshAgentKeyIdsPresent =
        rawLocal ? onePassword
        && builtins.isAttrs rawLocal.onePassword
        && rawLocal.onePassword ? sshAgentKeyIds
        && builtins.isList rawLocal.onePassword.sshAgentKeyIds
        && rawLocal.onePassword.sshAgentKeyIds != [ ]
        && builtins.all (
          itemId: builtins.isString itemId && builtins.match "^[a-z0-9]{26}$" itemId != null
        ) rawLocal.onePassword.sshAgentKeyIds;
      local =
        if missingLocalFields != [ ] then
          throw "local.nix is missing one or more required top-level fields; compare it with local.example.nix"
        else if !gitFieldsPresent then
          throw "local.nix git must define name, email, and signingKey; compare it with local.example.nix"
        else if !sshAgentKeyIdsPresent then
          throw "local.nix onePassword.sshAgentKeyIds must contain one or more 26-character 1Password item IDs"
        else if
          !(builtins.all (value: builtins.isString value && value != "") [
            rawLocal.user
            rawLocal.hostName
            rawLocal.system
            rawLocal.homeDirectory
            rawLocal.git.name
            rawLocal.git.email
            rawLocal.git.signingKey
          ])
        then
          throw "local.nix identity values must be non-empty strings"
        else if builtins.match "^/Users/[^/]+$" rawLocal.homeDirectory == null then
          throw "local.nix homeDirectory must be an absolute /Users/<name> path"
        else if
          !(builtins.isString rawLocal.downloadsDirectory)
          || builtins.match "^/.+[^/]$" rawLocal.downloadsDirectory == null
        then
          throw "local.nix downloadsDirectory must be an absolute path with no trailing slash; Chrome's DownloadDirectory policy has no fallback, so it must also name a location that is always present"
        else if
          !(builtins.elem rawLocal.system [
            "aarch64-darwin"
            "x86_64-darwin"
          ])
        then
          throw "local.nix system must be a supported Darwin architecture"
        else if builtins.match "^[^[:space:]@]+@[^[:space:]@]+$" rawLocal.git.email == null then
          throw "local.nix git.email must be a valid non-empty commit email"
        else if builtins.match "^ssh-ed25519 [A-Za-z0-9+/=]+( .*)?$" rawLocal.git.signingKey == null then
          throw "local.nix git.signingKey must be an Ed25519 SSH public key, never private-key material"
        else
          rawLocal;
      localConfigured = localPath != "";
      ai = import ./ai;
    in
    {
      darwinConfigurations.example-mac = nix-darwin.lib.darwinSystem {
        inherit (local) system;
        specialArgs = {
          inherit
            inputs
            local
            localConfigured
            ai
            ;
        };
        modules = [ ./hosts/example-mac ];
      };

      checks =
        nixpkgs.lib.genAttrs
          [
            "aarch64-darwin"
            "x86_64-darwin"
            "aarch64-linux"
            "x86_64-linux"
          ]
          (system: {
            codex-config-merge = (import ./ai/codex { pkgs = nixpkgs.legacyPackages.${system}; }).tests;
          });

      # `nixfmt-tree`, not bare `nixfmt`. `nix fmt` invokes the formatter with
      # the paths to format, and passing none makes bare `nixfmt` read stdin —
      # so the documented `nix fmt` workflow silently formatted nothing and
      # exited non-zero with "unexpected end of input". The treefmt wrapper
      # formats the whole tree when invoked with no arguments, which is what
      # AGENTS.md, README.md, and docs/operations/rebuild.md all tell you to do.
      formatter.aarch64-darwin = nixpkgs.legacyPackages.aarch64-darwin.nixfmt-tree;
      formatter.x86_64-darwin = nixpkgs.legacyPackages.x86_64-darwin.nixfmt-tree;
      formatter.aarch64-linux = nixpkgs.legacyPackages.aarch64-linux.nixfmt-tree;
      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt-tree;
    };
}
