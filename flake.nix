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
      url = "github:ogulcancelik/herdr/v0.8.0";
      inputs.nixpkgs.follows = "nixpkgs";
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
