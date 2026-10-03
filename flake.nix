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

    # Packages for AI coding agents, updated daily by upstream automation:
    # Herdr and ccstatusline come from here. Claude Code no longer does — it
    # updates itself; see modules/home/development.nix.
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

    # Anthropic's own example skills. Upstream ships a marketplace but no
    # plugin manifest at the root, so it cannot be loaded as one plugin the way
    # mattpocock-skills is; modules/home/ai selects individual skill
    # directories from it for Claude Code instead — what `npx skills add`
    # does, minus the mutable copy under ~/.claude. Apache-2.0, referenced not
    # vendored, and updated with `./scripts/update.sh anthropic-skills`.
    anthropic-skills = {
      url = "github:anthropics/skills";
      flake = false;
    };

    # Grafana's gcx CLI, pinned to a release tag. One input feeds two
    # consumers: modules/home/development.nix builds the CLI binary from it
    # (nixpkgs packages gcx, but its pinned release trails upstream), and
    # modules/home/ai loads the repository's claude-plugin/ directory as a
    # Claude Code plugin. Building both from the same pin keeps the binary and
    # the skills that describe it at one version by construction.
    #
    # A tag pin does not advance with `nix flake update`, so
    # `./scripts/update.sh` moves it: on a full run, or `update.sh gcx`, it
    # rewrites this tag to the latest GitHub release, re-locks, and refreshes
    # the Go vendor hash in modules/home/gcx-pin.json when it changed. The tag
    # is a tag rather than the default branch because gcx's version string and
    # release notes are derived from it.
    gcx-src = {
      url = "github:grafana/gcx/v1.3.1";
      flake = false;
    };

    # Claude Code plugin that dispatches scoped work to the Codex CLI and keeps
    # each execution's prompt, raw events, and handoff. Pinned to the v0.5.1
    # tag (a pre-release on upstream's release/0.5.1 branch, never merged to
    # main): it adds the background runner the skills launch Codex through,
    # which v0.5.0 lacks. modules/home/ai loads it as a plugin and layers the
    # local delegation policy onto it. MIT; referenced, not vendored. A tag
    # pin does not move with `nix flake update`; edit the tag to upgrade.
    codex-orchestrator = {
      url = "github:alexzh3/codex-orchestrator/v0.5.1";
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
          "signingKeyReference"
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
          throw "local.nix git must define name, email, signingKey, and signingKeyReference; preserve existing fields and add the service-account key reference from local.example.nix"
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
            rawLocal.git.signingKeyReference
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
            agent-instructions = (import ./ai/instructions { pkgs = nixpkgs.legacyPackages.${system}; }).tests;
            orchestration-docs = (import ./docs/links.nix { pkgs = nixpkgs.legacyPackages.${system}; }).tests;
            codex-config-merge = (import ./ai/codex { pkgs = nixpkgs.legacyPackages.${system}; }).tests;
            command-governor-settings =
              (import ./modules/home/command-governor-settings.nix {
                pkgs = nixpkgs.legacyPackages.${system};
              }).tests;
            cli-proxy-state =
              let
                pkgs = nixpkgs.legacyPackages.${system};
                python = pkgs.python3.withPackages (p: [
                  p.pyyaml
                ]);
              in
              pkgs.runCommand "cli-proxy-state-tests" { } ''
                cp ${./modules/home/cli-proxy-state.py} cli-proxy-state.py
                cp ${./modules/home/cli-proxy-state-test.py} cli-proxy-state-test.py
                ${python}/bin/python3 cli-proxy-state-test.py
                touch "$out"
              '';
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
